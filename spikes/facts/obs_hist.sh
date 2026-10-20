#!/usr/bin/env bash
# Usage: R=<rpc> ./obs_hist.sh <pool> <card> <block>...   lookback span at historical blocks
P=$1; C=$2; shift 2
for B in "$@"; do
  idx=$(cast call "$P" "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --block "$B" --rpc-url "$R" 2>&1 | sed -n 3p)
  c=$(cast call "$P" "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --block "$B" --rpc-url "$R" 2>&1 | sed -n 4p)
  o=$(( (idx + 1) % c ))
  old=$(cast call "$P" "observations(uint256)(uint32,int56,uint160,bool)" "$o" --block "$B" --rpc-url "$R" 2>&1 | head -1 | cut -d" " -f1)
  ts=$(cast block "$B" -f timestamp --rpc-url "$R")
  echo "block=$B card=$c span=$((ts - old))s ($(echo "scale=2;($ts-$old)/3600" | bc)h)"
  sleep 0.3
done
