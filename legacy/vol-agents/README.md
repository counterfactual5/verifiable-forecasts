# agents/

Forecast bots that enter the verifiable-forecasts. Every bot implements the same
interface and returns a **probability vector over the bucket bounds**, ready to
be recorded onchain via `recordPrediction` before a round's window opens; the
contract then scores the vector against the realized outcome with the log score
rule.

## Interface

```python
forecast(history, horizon, bounds) -> list[int]
```

- `history`: sequence of base-fee values in wei (ints), oldest first.
- `horizon`: how many blocks ahead the forecast targets (the bots here forecast
  the next window mean; `horizon` is kept in the signature for future use).
- `bounds`: bucket bounds in wei. Bucket `i` covers `[bounds[i-1], bounds[i])`,
  bucket `0` covers `(-inf, bounds[0])`, the last covers `[bounds[n-1], +inf)` —
  half-open, matching `BaseFeeMarket.bucketOf`.
- Return value: `len(bounds) + 1` integers scaled by `1e18`, each in
  `[0, 1e18]`, summing to **exactly** `1e18` — the same validation the contract
  applies in `recordPrediction`.

## Layout

| Module | What it does |
|---|---|
| `src/agents_bots/probability.py` | Integer probability-vector construction (float weights in, exact 1e18-sum ints out) and `bucket_of`. |
| `src/agents_bots/naive.py` | Baseline: distribution of the previous window's mean bucket. |
| `src/agents_bots/ewma.py` | Baseline: exponentially weighted moving average with fixed decay. |
| `src/agents_bots/tsfm.py` | Client for the TimesFM inference **process** (JSON over stdio); falls back with `TsfmUnavailable`. |
| `scripts/tsfm_runner.py` | The runner side of that protocol; runs inside the model venv (`~/Work/chronos-experiment/.venv`), never imported here. |
| `src/agents_bots/backtest.py` | Chronological backtest: log score, Brier, hit rate, cumulative PnL; strict-prefix split, no future information. |
| `src/agents_bots/pipeline.py` | Runs all three bots; degrades to EWMA/naive when TimesFM is unavailable. |
| `scripts/run_backtest.py` | CLI that runs the backtest for all bots on a fixture or CSV history. |

## Boundary

- **Depends on:** `analysis/`'s published `data/params.json` (bucket bounds and
  window length) — as data at runtime, never as an import. `agents` and
  `analysis` do not import each other.
- **Depends on nothing from:** `contracts/` source, `dashboard/`, `chainlink/`.
- The model runs in a **separate process** (see `scripts/tsfm_runner.py`) so a
  heavy or crashed model never takes a bot down; the bot only reads the JSON the
  runner prints.

## Usage

```bash
make agents-sync        # one-time: install locked deps
make agents             # ruff + pytest
cd agents && uv run python scripts/run_backtest.py --window 50
```

The default bot list is `naive,ewma`. TimesFM is opt-in
(`--bots naive,ewma,tsfm`): every forecast step spawns a fresh runner
process, and each process cold-loads the model, so a tsfm backtest costs one
model load per step. `--tsfm-timeout SECS` bounds each runner process
(120 s by default).

The TimesFM runner needs the model venv and a local model cache
(`HF_HUB_OFFLINE=1`); without it, bots fall back to EWMA/naive — the demo
completes either way.

## Why three bots

The point of the market is not that a model is good, but that a model's forecast
is *publicly verifiable*. Three forecasters of increasing sophistication
(naive → EWMA → TimesFM) make the log-score leaderboard meaningful: a trivial
baseline anchors the bottom, the zero-shot model has to beat it in public.
