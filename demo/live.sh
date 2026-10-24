#!/usr/bin/env bash
# One live run: replays the HOURS (default 24) most recent completed mainnet hours on a fresh anvil
# fork (LIVE=1 in demo/fork_round.py) and writes dashboard/live-replay.json. Run hourly by
# deploy/vf-live.timer on the server; `make live` runs it once locally. Reads MAINNET_RPC_URL,
# VOL_TSFM_* and optional HOURS from the environment or the repo's .env.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
hours="${HOURS:-}"
if [[ -f "$REPO/.env" ]]; then set -a; source "$REPO/.env"; set +a; fi
export LIVE=1 HOURS="${hours:-${HOURS:-}}"
mkdir -p "$REPO/demo/out"
if command -v flock >/dev/null; then
  exec 9>"$REPO/demo/out/live.lock"
  if ! flock -n 9; then echo "previous live run still running; skipping" >&2; exit 0; fi
fi
# Long context for the time-series model agents (vol_agents.history): mainnet swaps of the last days,
# appended incrementally. A failed fetch only leaves the cache older; history.py then falls back
# to the round's 16 onchain points.
export VOL_HISTORY_CACHE="${VOL_HISTORY_CACHE:-$REPO/analysis/data/swaps_tail.csv}"
export VOL_HISTORY_CONTEXT="${VOL_HISTORY_CONTEXT:-512}"
(cd "$REPO/analysis" && uv run python src/fetch_swaps.py --tail --days 4 \
  --out "$VOL_HISTORY_CACHE") || echo "swap tail failed" >&2
export FOUNDRY_OUT="${FOUNDRY_OUT:-$REPO/demo/out/forge}"
export FOUNDRY_CACHE_PATH="${FOUNDRY_CACHE_PATH:-$REPO/demo/out/forge-cache}"
if ! build_log="$(cd "$REPO/contracts" && forge build --skip test --skip script 2>&1)"; then
  echo "$build_log" >&2; exit 1
fi
PYTHONPATH="$REPO/agents" exec uv run --project "$REPO/agents" python "$REPO/demo/fork_round.py"
