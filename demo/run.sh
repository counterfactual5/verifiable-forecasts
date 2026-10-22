#!/usr/bin/env bash
# Replays HOURS (default 24) consecutive real hours of VolMarket rounds on one local anvil fork of
# Ethereum mainnet; see demo/fork_round.py. Reads MAINNET_RPC_URL and optional HOURS /
# REPLAY_START from the environment or the repo's .env.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$REPO/.env" ]]; then set -a; source "$REPO/.env"; set +a; fi
# Separate Foundry output so the demo never races another forge build in contracts/.
export FOUNDRY_OUT="${FOUNDRY_OUT:-$REPO/demo/out/forge}"
export FOUNDRY_CACHE_PATH="${FOUNDRY_CACHE_PATH:-$REPO/demo/out/forge-cache}"
if ! build_log="$(cd "$REPO/contracts" && forge build --skip test --skip script 2>&1)"; then
  echo "$build_log" >&2; exit 1
fi
PYTHONPATH="$REPO/agents" exec uv run --project "$REPO/agents" python "$REPO/demo/fork_round.py"
