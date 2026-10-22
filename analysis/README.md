# analysis/

Offline analysis for the vol market. This subproject answers one question: **which four realized-vol
bucket bounds should `VolMarket.createRound` use?** It pulls Uniswap V3 `Swap` events, recomputes the
contract's realized-vol caliber from them, and calibrates the bounds from the resulting distribution.

It is the only place in the repository allowed to touch the network. Everything it produces is written to
`data/` (git-ignored), so the contract, the forecasters and the test suite never need an RPC endpoint.

## Responsibilities

| Module | What it does |
|---|---|
| `src/fetch_swaps.py` | Pull `Swap` logs of the ETH/USDC 0.05% pool in ≤10k-block segments into `data/swaps.csv` (`block,tick,timestamp`); resumable. |
| `src/vol_calibrate.py` | Rebuild `tickCumulative` from the swaps, compute RV with the contract's caliber, emit 4 strictly increasing bounds (p20/p40/p60/p80) to `data/vol_params.json` plus a calibration report. |

The module docstrings carry the full rules (segment checks, resume, tick rebuild, known deviations).

## Boundary

- **Depends on:** the standard library and the public JSON-RPC endpoint. No contract code, no model code.
- **Depends on nothing from:** `agents/`, `contracts/`, `dashboard/`, `chainlink/`.
  The only thing it shares with the contract is the committed fixture
  `contracts/test/fixtures/vol_rv_cases.json`, read as data. That is the one permitted direction:
  `analysis → contracts` (as data), never the reverse.

## Setup

```bash
cd analysis
uv sync          # creates .venv from uv.lock
```

## Run

```bash
# 1. fetch Swap events (network; writes data/swaps.csv)
uv run python src/fetch_swaps.py --rpc https://mainnet.gateway.tenderly.co --from 17000000 --to 17100000

# 2. calibrate the bounds offline (writes data/vol_params.json and the calibration report)
uv run python src/vol_calibrate.py --swaps data/swaps.csv
```

`--delta` and `--n-segments` default to the contract's 300 s × 12; `bounds` in `data/vol_params.json` is
passed verbatim as the `bounds` argument of `VolMarket.createRound`.

## Test

```bash
cd analysis && uv run pytest tests/ -q
```

The suite is offline and deterministic: it replays recorded RPC responses and checks the RV caliber
against `vol_rv_cases.json` case by case.
