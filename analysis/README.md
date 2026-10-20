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

# or both in one shot
uv run python src/pipeline.py --rpc https://ethereum-rpc.publicnode.com --blocks 20000
```

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
  "bounds_wei": [1000000000, 1500000000, 2500000000],
  "quantiles": {"10": 900000000, "50": 1200000000, "90": 1800000000},
  "samples": 20000,
  "method": "window-mean p10/p25/p50/p75/p90, log-spaced bounds"
}
```

`bounds_wei` is passed verbatim as the `bounds` array of `BaseFeeMarket.createRound`. `window_k` is the number
of blocks in a round's sampling window.

## Future work

- Pull multiple chains (Base, Arbitrum) to show the market is not mainnet-specific.
- Compare candidate estimators (EWMA vs TSFM) on the same window definition.
