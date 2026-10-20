# analysis/

Offline analysis for `verifiable-forecasts`. This subproject answers one question: **what are the right sampling
window length and bucket bounds for a base fee prediction market?**

It is the only place in the repository allowed to touch the network. Everything it produces is written to
`data/` (git-ignored) or to a committed small fixture, so the contract, the forecasters and the test suite
never need an RPC endpoint.

## Responsibilities

| Module | What it does |
|---|---|
| `src/fetch_fee_history.py` | Pull mainnet `baseFeePerGas` per block over a block range into `data/basefee_history.csv`. |
| `src/calibrate.py` | Scan candidate window lengths `K`, compute the distribution of the *window mean* base fee, and emit bucket bounds. |
| `src/pipeline.py` | One-shot `fetch → calibrate → data/params.json`. |

## Boundary

- **Depends on:** the standard library and the public JSON-RPC endpoint. No contract code, no model code.
- **Depends on nothing from:** `agents/`, `contracts/`, `dashboard/`, `chainlink/`.
  The only thing it shares with the contract is a *committed fixture* under `contracts/test/fixtures/`, read
  as data. That is the one permitted direction: `analysis → contracts` (as data), never the reverse.

## Setup

```bash
cd analysis
uv sync          # creates .venv from uv.lock
```

## Run

```bash
# 1. fetch ~2 weeks of mainnet base fees (writes data/basefee_history.csv)
uv run python src/fetch_fee_history.py --rpc https://ethereum-rpc.publicnode.com --from 26000000 --to 26200000

# 2. calibrate window length and bucket bounds (writes data/params.json, data/calibration.md)
uv run python src/calibrate.py --history data/basefee_history.csv --out data/params.json
```

### Pipeline entry point

`src/pipeline.py` is the one-shot entry point: optional fetch → calibrate → `data/params.json`. It owns no
calibration math, it only wires the two modules above together and checks the result against the contract's
bucket semantics.

```bash
# offline: calibrate an existing history CSV, nothing touches the network
uv run python src/pipeline.py --history data/basefee_history.csv --out data/params.json

# online: fetch first, then calibrate in the same run
uv run python src/pipeline.py --rpc https://ethereum-rpc.publicnode.com --from 26000000 --to 26200000 \
    --history data/basefee_history.csv --out data/params.json

uv run python src/pipeline.py --help
```

| Flag | Meaning |
|---|---|
| `--history` | History CSV (`block,base_fee_wei,ts`). The fetch step writes into this file too. Default `data/basefee_history.csv`. |
| `--out` | Output params JSON. Default `data/params.json`. Parent directories are created as needed. |
| `--rpc` | JSON-RPC endpoint for the optional fetch step. Default `https://ethereum-rpc.publicnode.com`. |
| `--from` / `--to` | Inclusive block range of the optional fetch step. Given together, or not at all. |
| `--candidates` | Comma-separated candidate window lengths. Default `10,25,50,100,200`. |
| `--fixture` | Bucket case fixture to check against the contract semantics before anything else runs; missing or disagreeing is an error. Default `contracts/test/fixtures/basefee_bucket_cases.json`. |

Without `--from`/`--to` the run is fully offline: it reads the existing history CSV and never opens a socket.
The offline path does not depend on `--rpc`, `--from` or `--to`; the optional fetch step is the only part that
needs the network.

## Test

```bash
cd analysis && uv run pytest tests/ -q
```

The suite is offline and deterministic: it runs against committed fixture rows, never against the network.

## Output contract

`data/params.json` is what the rest of the project consumes:

```json
{
  "window_k": 50,
  "bounds_wei": [1100000000, 1200000000, 1450000000],
  "quantiles": {
    "10": 900000000,
    "25": 1100000000,
    "50": 1200000000,
    "75": 1450000000,
    "90": 1800000000
  },
  "samples": 20000,
  "method": "contiguous K-block mean, integer floor division; nearest-rank integer quantiles; K minimizes (p90-p10)/p50 by cross multiplication; bounds are distinct positive p25/p50/p75"
}
```

`bounds_wei` is passed verbatim as the `bounds` array of `BaseFeeMarket.createRound`; it is the distinct
positive values among the p25/p50/p75 quantiles, so it holds one to three entries. A flat history whose
p25, p50 and p75 coincide yields a single bound (for example `[1000000000]`), which is valid: the contract
then has two buckets. `window_k` is the number of blocks in a round's sampling window, at most 256.
`method` is `calibrate.METHOD` verbatim.

### `data/params.json` schema

The pipeline writes exactly these five fields, and it refuses to write a payload that does not have them:

| Field | Type | Meaning |
|---|---|---|
| `window_k` | int, 1..256 | Recommended sampling window length in blocks (`createRound` rejects windows above 256). |
| `bounds_wei` | list of int | 1 to 32 strictly increasing positive bounds in wei, each at most int256 max (`2**255 - 1`), passed verbatim to `createRound`. |
| `quantiles` | object of int | Nearest-rank quantiles of the window-mean distribution, keyed by percentile (`"10"`, `"25"`, `"50"`, `"75"`, `"90"`). |
| `samples` | int > 0 | Number of complete window means the quantiles were computed from. |
| `method` | string | One line describing how the numbers were produced. |

Every bound and every quantile is an integer in wei. The contract rejects bounds that are not strictly
increasing or not positive, it accepts at most 32 of them and at least one, and every bound must fit in
`int256` (at most `2**255 - 1`). The pipeline enforces the same rules, plus `window_k <= 256`, before it
writes anything.

## Bucket semantics

The pipeline mirrors `BaseFeeMarket.bucketOf` exactly, so a calibrated mean and a settled round agree on
which bucket a value belongs to:

* bucket `0` is `(-inf, bounds[0])`;
* bucket `i` is `[bounds[i-1], bounds[i])`;
* the last bucket is `[bounds[n-1], +inf)`.

A value equal to a bound belongs to the bucket that *starts* at that bound, so `bounds[i]` is never in bucket
`i`. The boundary values are pinned down in the committed fixture
`contracts/test/fixtures/basefee_bucket_cases.json`, which the pipeline checks on every run and the Python
suite asserts case by case.

The fixture check is a fail-closed gate: the pipeline resolves the fixture (the default path or `--fixture`)
and verifies every case *before* the optional fetch step and before writing `params.json` or
`calibration.md`. A missing fixture, default or explicit, or a case that disagrees with the contract
semantics exits non-zero and leaves no output behind.

### `basefee_bucket_cases.json` schema

Exactly three fields, nothing else:

| Field | Type | Meaning |
|---|---|---|
| `bounds_wei` | list of int | The bounds array: positive and strictly increasing. |
| `cases` | list of object | One object per case with exactly `value_wei` (int) and `bucket` (int). |
| `semantics` | string | Human-readable statement of the half-open interval rule. |

```json
{
  "bounds_wei": [1000000000, 1500000000, 2500000000, 4000000000],
  "cases": [
    { "value_wei": 999999999, "bucket": 0 },
    { "value_wei": 1000000000, "bucket": 1 },
    { "value_wei": 1500000000, "bucket": 2 }
  ],
  "semantics": "Half-open intervals, matching BaseFeeMarket.bucketOf: ..."
}
```

The fixture is read as data, never imported: `analysis → contracts` is a one-way dependency, and the Solidity
source is not touched.

## Future work

- Pull multiple chains (Base, Arbitrum) to show the market is not mainnet-specific.
- Compare candidate estimators (EWMA vs TSFM) on the same window definition.
