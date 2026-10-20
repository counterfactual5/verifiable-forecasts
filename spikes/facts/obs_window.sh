#!/usr/bin/env bash
# Usage: R=<rpc> ./obs_window.sh <pool> <idx> <card>
set -euo pipefail
P=$1; I=$2; C=$3
now=$(cast block latest -f timestamp --rpc-url "$R")
newest=$(cast call "$P" "observations(uint256)(uint32,int56,uint160,bool)" "$I" --rpc-url "$R" | head -1 | cut -d" " -f1)
o=$(( (I + 1) % C ))
old=$(cast call "$P" "observations(uint256)(uint32,int56,uint160,bool)" "$o" --rpc-url "$R")
init=$(echo "$old" | sed -n 4p)
if [ "$init" != "true" ]; then o=0; old=$(cast call "$P" "observations(uint256)(uint32,int56,uint160,bool)" 0 --rpc-url "$R"); fi
oldest=$(echo "$old" | head -1 | cut -d" " -f1)
echo "now=$now newest=$newest oldest(idx $o)=$oldest span=$((now-oldest))s ($(echo "scale=2;($now-$oldest)/3600"|bc)h) newest_age=$((now-newest))s"
