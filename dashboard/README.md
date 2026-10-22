# dashboard/

Read-only, build-free view of one VolMarket round: round status, each agent's bucket probabilities,
realized volatility and winning bucket, log scores, ERC-8004 reputation, the Chainlink cross-check
and the zk verification status. One static `index.html`, no dependencies, no wallet, no writes.

## Run

```bash
bash demo/run.sh                          # writes demo/out/fork_round.json (mainnet fork round)
python3 -m http.server 8765 --bind 127.0.0.1   # from the repo root
open http://127.0.0.1:8765/dashboard/
```

Data source, first found wins: `?data=<url>`, `../demo/out/fork_round.json` (latest demo run),
`sample-round.json` (a committed snapshot of one demo run, so the page works without running the
demo). The page has to be served over HTTP: browsers block `fetch` from `file://`.

## Boundary

- Reads only the JSON written by `demo/fork_round.py`; never calls a contract write.
- Depends on nothing from `contracts/`, `agents/` or `analysis/` at runtime.
