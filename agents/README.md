# agents/

Forecasters that enter the market. Each agent produces a **probability vector over the bucket bounds** and
records it onchain before the round's window opens; the contract scores every recorded vector against the
realized outcome with the log score rule.

This directory is not implemented yet. It is the next subproject after `analysis/`.

## Planned contents

| Module | What it does |
|---|---|
| `src/adapters/tsfm.py` | Adapter around a zero-shot time-series foundation model (TimesFM 3.x, already installed in `~/Work/chronos-experiment/.venv`). |
| `src/adapters/ewma.py` | Exponentially weighted moving average baseline. |
| `src/adapters/naive.py` | Random-walk baseline. |
| `src/bots/*.py` | One bot per forecaster: read the window definition, produce a distribution, submit it. |
| `src/scoring.py` | Offline re-implementation of the contract's log score, for backtesting without a chain. |

## Boundary

- **Depends on:** `analysis/`'s published `data/params.json` (bucket bounds and window length) — as data, at
  runtime, not as an import.
- **Depends on nothing from:** `analysis/` source, `contracts/` source, `dashboard/`, `chainlink/`.
  `analysis` and `agents` never import each other; the only channel is the JSON file both read.
- The model runs in a **separate process** so that a heavy or crashed model never takes the bot down. The bot
  only reads the forecast output.

## Why three forecasters

The point of the market is not that a model is good, but that a model's forecast is *publicly verifiable*.
Three forecasters of increasing sophistication (naive → EWMA → TSFM) make the log-score leaderboard meaningful:
a trivial baseline anchors the bottom, the zero-shot model has to beat it in public.

## Future work

- Add the same forecasters over multiple chains.
- Add a market-maker agent that quotes both sides.
