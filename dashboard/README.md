# dashboard/

Optional viewer for rounds, bets, predictions and the log-score leaderboard. **Not implemented yet, and
first on the cut list.**

The demo does not need a web app: a terminal log of one full round plus a static matplotlib figure tells the
same story, and the deadline is close enough that a dependency surface is a liability rather than a feature.

## Planned contents (if time allows)

| Module | What it does |
|---|---|
| `app.py` | Streamlit entry: round list, round detail, leaderboard. |
| `src/read_model.py` | Reads round state from a local Anvil node or a JSON export. |

## Boundary

- **Depends on:** a local node or a JSON export of round state. Read-only.
- **Depends on nothing from:** `analysis/`, `agents/`, `contracts/`.

## If it stays unimplemented

The root `README.md` must then point at the static artefacts (the calibration chart, the backtest chart, the
terminal transcript of a full round) instead. That fallback is the reason this directory may legitimately stay
a README.
