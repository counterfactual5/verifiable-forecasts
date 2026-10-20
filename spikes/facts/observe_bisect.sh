#!/usr/bin/env bash
# Usage: R=<rpc> ./observe_bisect.sh <pool> <lo_ok> <hi_fail>   (pinned to one block)
set -uo pipefail
P=$1; lo=$2; hi=$3
B=$(cast block-number --rpc-url "$R")
ok() { cast call "$P" "observe(uint32[])(int56[],uint160[])" "[$1]" --block "$B" --rpc-url "$R" >/dev/null 2>"/tmp/obs_err"; }
ok "$lo" || { echo "lo $lo fails: $(cat /tmp/obs_err | head -2)"; exit 1; }
ok "$hi" && { echo "hi $hi succeeds"; exit 1; }
echo "hi err: $(grep -o 'OLD\|revert[^\n]*' /tmp/obs_err | head -1)"
while [ $((hi - lo)) -gt 1 ]; do m=$(( (lo + hi) / 2 )); if ok "$m"; then lo=$m; else hi=$m; fi; sleep 0.2; done
echo "block=$B max_secondsAgo=$lo ($(echo "scale=2;$lo/3600"|bc)h)"
