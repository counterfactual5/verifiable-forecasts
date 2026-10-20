#!/usr/bin/env bash
# Usage: ./run.sh [fixed|hashed] [--logits]
# Runs the full EZKL pipeline step by step, logging wall time + peak RSS per step.
set -euo pipefail
cd "$(dirname "$0")"
V=${1:-fixed}; shift || true
EXTRA="$*"
TAG=${V}${EXTRA:+_logits}
LOG=out/${TAG}_timing.log
mkdir -p out; : > "$LOG"
[ -f model.onnx ] || uv run python build_model.py
[ -f model_logits.onnx ] || uv run python build_model.py --logits
for step in settings calibrate compile srs setup witness prove verify; do
  echo "== $step" | tee -a "$LOG"
  /usr/bin/time -l .venv/bin/python pipeline.py "$step" --variant "$V" $EXTRA 2> "out/${TAG}_${step}.err" | tee -a "$LOG"
  grep -E " real |maximum resident|peak memory" "out/${TAG}_${step}.err" | tee -a "$LOG"
done
ls -l out/$TAG | tee -a "$LOG"
