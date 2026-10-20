#!/usr/bin/env bash
# Usage: R=<rpc> ./observe_gas.sh <pool>
P=$1
arr() { local s=""; for ((i = 0; i < $1; i++)); do s="$s,$((i * $2))"; done; echo "[${s#,}]"; }
for spec in "1 0" "1 3600" "1 14400" "2 14400" "13 300" "13 1200" "25 300" "25 600" "49 300" "49 420"; do
  set -- $spec
  if [ "$1" = 1 ]; then a="[$2]"; else a=$(arr "$1" "$2"); fi
  g=$(cast estimate "$P" "observe(uint32[])" "$a" --rpc-url "$R" 2>&1 | tail -1)
  echo "n=$1 step=${2}s gas=$g"
  sleep 0.3
done
