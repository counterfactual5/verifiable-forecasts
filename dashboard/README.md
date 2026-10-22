# dashboard/

Read-only, build-free view of the VolMarket demo. One static `index.html`, no dependencies, no
wallet, no writes. It renders either JSON the demo writes:

- **Multi-hour replay** (`schema: "vol-replay/v1"`, written by `demo/fork_round.py`): cumulative and
  rolling log score of every agent against the uniform baseline, winning-bucket distribution,
  realized vol per round, cumulative forecaster fee share, per-agent totals with ERC-8004
  `getSummary`, and a per-round table with Etherscan links to the window's real mainnet blocks, its
  last pool swap and every replayed Chainlink report.
- **Single round** (older `fork_round.json` format): round status, each agent's bucket
  probabilities, realized vol, log scores, ERC-8004 reputation, the Chainlink cross-check and the zk
  verification status.

## Run

```bash
bash demo/run.sh                               # writes demo/out/fork_replay.json
python3 -m http.server 8765 --bind 127.0.0.1   # from the repo root
open http://127.0.0.1:8765/dashboard/
```

Data source, first found wins: `?data=<url>`, `../demo/out/fork_replay.json` (latest demo run),
`sample-replay.json` (committed 24-hour replay, so the page works without running the demo),
`../demo/out/fork_round.json`, `sample-round.json` (committed single round; open it with
`?data=sample-round.json`). The page has to be served over HTTP: browsers block `fetch` from
`file://`.

## Boundary

- Reads only the JSON written by `demo/fork_round.py`; never calls a contract write.
- Depends on nothing from `contracts/`, `agents/` or `analysis/` at runtime.
