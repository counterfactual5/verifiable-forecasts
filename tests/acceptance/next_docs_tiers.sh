#!/usr/bin/env bash
# Docs-tier acceptance: docs/ARCHITECTURE.md and docs/SPEC.md describe the three-argument registerModel and the
# reproducible tier as implemented (matching contracts/src/VolMarket.sol); the SPEC Full Verify code
# block stays a single command.
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

sol = open("contracts/src/VolMarket.sol", encoding="utf-8").read()
check(re.search(r"function registerModel\(address verifier, address operator, bytes32 modelHash_?\)", sol) is not None,
      "VolMarket still has the three-argument registerModel")

arch = open("docs/ARCHITECTURE.md", encoding="utf-8").read()
spec = open("docs/SPEC.md", encoding="utf-8").read()
for name, txt in (("ARCHITECTURE", arch), ("SPEC", spec)):
    check(re.search(r"registerModel\(\s*(address\s+)?verifier,\s*(address\s+)?operator,\s*(bytes32\s+)?modelHash\s*\)", txt) is not None,
          f"{name} documents registerModel(verifier, operator, modelHash)")
    check(re.search(r"verificationTier", txt) is not None, f"{name} names verificationTier")

check(re.search(r"可复现[^\n]*已实现|可复现[^\n]*已完成", arch) is not None, "ARCHITECTURE marks the reproducible tier implemented")
check(any(l.startswith("|") and re.search(r"registerModel\([^)]*modelHash", l) and "可复现" in l and "已完成" in l for l in spec.splitlines()),
      "SPEC feature table has a done row for the reproducible tier with the three-argument registerModel")
check(any(l.startswith("| `registerModel(") and "modelHash" in l for l in arch.splitlines()),
      "ARCHITECTURE interface table row for registerModel carries modelHash")
demo = arch.split("## 8.", 1)[1].split("\n## ", 1)[0] if "## 8." in arch else ""
check(bool(demo) and "演示比离线回合多一个仅承诺 agent（`api_agent.py`" not in demo and "可复现" in demo
      and all(n in demo for n in ("agent-timesfm-3.0", "agent-timestral-209m", "agent-chronos-2")),
      "ARCHITECTURE demo section names the three reproducible model agents, not the API placeholder")
trust = arch.split("## 10.", 1)[1].split("\n## ", 1)[0] if "## 10." in arch else ""
check(bool(trust) and "modelHash" in trust, "ARCHITECTURE trust boundary covers the reproducible tier")
check(not any("大模型" in s and "出处" in s and "TEE" in s and "可复现" not in s for s in re.split(r"[。\n]", arch)),
      "ARCHITECTURE no longer says large-model provenance needs TEE only")

head = re.search(r"^### 分级验证.*$", arch, re.M)
check(head is not None and "可复现" in head.group(0), "ARCHITECTURE tiered-verification heading includes the reproducible tier")
check("未配置时用确定性占位预测" not in arch, "ARCHITECTURE no longer presents the placeholder as the only non-zk agent")
check("ModelHashSet" in arch, "ARCHITECTURE names the ModelHashSet event")

tiers = {int(v): k for k, v in re.findall(r"uint8\s+(?:public\s+)?constant\s+TIER_(\w+)\s*=\s*(\d+)", sol)}
check(len(tiers) == 3, f"VolMarket tier constants found {tiers}")
words = {"COMMIT_ONLY": r"仅承诺|commit-only", "REPRODUCIBLE": r"可复现|reproducible", "ZK": r"\bzk\b"}
para = next((p for p in re.split(r"\n\s*\n", arch) if "verificationTier" in p), "")
check(bool(tiers) and all(re.search(rf"{v}\s*[=：:]\s*({words[k]})|({words[k]})\s*[=：:（(]\s*{v}", para, re.I) for v, k in tiers.items()),
      "ARCHITECTURE maps every verificationTier value to its tier as the contract constants do")
sec = arch.split("### 分级验证", 1)[1].split("\n### ", 1)[0] if "### 分级验证" in arch else ""
check(re.search(r"可复现[^\n]*-commit|-commit[^\n]*可复现", sec) is not None, "ARCHITECTURE tiered verification says reproducible models also write tag2 -commit")

fv = spec.split("## Full Verify", 1)[1].split("\n## ", 1)[0] if "## Full Verify" in spec else ""
block = re.search(r"```[^\n]*\n(.*?)```", fv, re.S)
lines = [l for l in (block.group(1).splitlines() if block else []) if l.strip() and not l.strip().startswith("#")]
check(lines == ["make check && make test"], f"SPEC Full Verify code block is exactly the one-line command {lines}")
outside = re.sub(r"```.*?```", "", fv, flags=re.S)
sents = [x for x in re.split(r"(?<=[。.;；])(?!\d)\s*|\n\s*\n", outside) if x.strip()]
check(any("VOL_REPRO_PYTHON" in x and "test_api_agent" in x and re.search(r"不需要|无需|without", x) for x in sents),
      "SPEC Full Verify says outside the code block that the agents tests (test_api_agent) run without VOL_REPRO_PYTHON")
check(any("VOL_REPRO_PYTHON" in x and "tsfm_recompute" in x and re.search(r"失败|fail", x, re.I) and re.search(r"不回退|no fallback", x) for x in sents),
      "SPEC Full Verify says tsfm_recompute fails without VOL_REPRO_PYTHON, with no fallback")
check(not re.search(r"Chronos-Bolt|test_repro_agent", fv, re.I), "SPEC Full Verify no longer names the retired Chronos-Bolt tests")
import glob
skips = [p for p in glob.glob("agents/tests/*.py")
         if re.search(r"skip[\s\S]{0,200}?VOL_REPRO_PYTHON", open(p, encoding="utf-8").read())]
check(not skips, f"no agents test is skipped on VOL_REPRO_PYTHON {skips}")

print("PASS" if not fail else "FAIL")
sys.exit(fail)
EOF
