#!/usr/bin/env bash
# R11 acceptance: docs/ARCHITECTURE.md gives the same opML answer as docs/PITCH.md (not pursued: needs a
# challenge window and an onchain single-step VM, and rests on a 1-of-N honesty assumption), and the
# registerModel natspec names what modelHash actually covers (weights, config, runner; not inputs),
# and so does every reproducible model's tsfm_forecast.model_hash_preimage.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
python3 - <<'EOF'
import re, sys

fail = 0
def check(cond, msg):
    global fail
    print(("ok - " if cond else "not ok - ") + msg)
    if not cond:
        fail = 1

arch = open("docs/ARCHITECTURE.md", encoding="utf-8").read()
pitch = open("docs/PITCH.md", encoding="utf-8").read()
check(re.search(r"不做 opML|Why not opML", pitch) is not None, "PITCH still says opML is not pursued")
lines = [l for l in arch.splitlines() if "opML" in l]
check(bool(lines), "ARCHITECTURE mentions opML")
check(not any(re.search(r"未评估|留在路线图|另一种选项", l) for l in lines), f"ARCHITECTURE no longer leaves opML open as an unevaluated roadmap option {lines[:1]}")
check(any(re.search(r"不做", l) and re.search(r"挑战窗口", l) and re.search(r"单步 ?VM", l) and "1-of-N" in l for l in lines),
      "ARCHITECTURE states opML is not pursued, with the challenge window, the onchain single-step VM and the 1-of-N assumption")

sol = open("contracts/src/VolMarket.sol", encoding="utf-8").read()
m = re.search(r"((?:\s*///[^\n]*\n)+)\s*function registerModel\(address verifier, address operator, bytes32 modelHash_\)", sol)
doc = m.group(1) if m else ""
check(bool(doc), "registerModel(verifier, operator, modelHash_) has natspec")
check("code and inputs" not in doc and re.search(r"weights", doc) and re.search(r"config", doc) and re.search(r"runner", doc),
      "registerModel natspec says modelHash covers weights, config and runner")
check(re.search(r"features", doc) is not None and re.search(r"on-?chain", doc) is not None,
      "registerModel natspec says the per-round features are read onchain")
import json, subprocess
probe = """
import json
from vol_agents import tsfm_forecast as sf
print(json.dumps({m: sf.model_hash_preimage(m) for m in sf.MODELS if sf.spec(m).tier == sf.REPRODUCIBLE}))
"""
r = subprocess.run(["uv", "run", "python", "-c", probe], cwd="agents", capture_output=True, text=True)
pre = json.loads(r.stdout.strip().splitlines()[-1]) if r.returncode == 0 and r.stdout.strip() else {}
check(len(pre) >= 3, f"tsfm_forecast has at least three reproducible models {sorted(pre)} {r.stderr[-300:]}")
hexed = lambda v: isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v) is not None
check(bool(pre) and all(re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40}", p.get("weights") or "") for p in pre.values()),
      "every reproducible modelHash preimage pins its weights at a 40-hex revision")
check(bool(pre) and all(p.get("inference") and p.get("postprocess") for p in pre.values()),
      "every reproducible modelHash preimage carries its inference and post-processing config")
check(bool(pre) and all(hexed(p.get("code_sha256")) and hexed(p.get("local_runner_sha256")) for p in pre.values()),
      "every reproducible modelHash preimage hashes the forecast code and the local runner")
check(bool(pre) and not any(re.search(r"features\"\s*:|\"round", json.dumps(p)) for p in pre.values()),
      "no reproducible modelHash preimage carries per-round inputs")

print("PASS" if not fail else "FAIL")
sys.exit(fail)
EOF
