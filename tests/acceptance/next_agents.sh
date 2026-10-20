#!/usr/bin/env bash
# R3 acceptance: small models trained and exported for EZKL, agents that prove and submit to VolMarket
# on a local chain, 2-3 agents on different models compared after one round; analysis and the
# VolMarket contract tests stay green.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

cd "$root/agents" 2>/dev/null || { bad "agents/ exists"; echo FAIL; exit 1; }
[[ -f pyproject.toml ]] && ok "agents/pyproject.toml" || { bad "agents/pyproject.toml"; echo FAIL; exit 1; }

# 2-3 trained models, each exported as its own ONNX file, all different
models=(models/*/model.onnx)
n=0; [[ -f "${models[0]}" ]] && n=${#models[@]}
if [[ $n -ge 2 && $n -le 3 ]]; then ok "$n trained models exported to ONNX"; else bad "2-3 trained models exported to ONNX (found $n)"; fi
uniq=$(shasum "${models[@]}" 2>/dev/null | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
[[ $n -ge 2 && $uniq -eq $n ]] && ok "the models differ" || bad "the models differ"

out=$(uv run pytest -v 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "agents tests green" || { bad "agents tests green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
for name in \
    test_models_export_to_ezkl \
    test_agent_proves_and_submits \
    test_agents_compare_after_round; do
    printf '%s\n' "$out" | grep -qE "::${name}(\[[^]]*\])? PASSED" && ok "$name passes" || bad "$name passes"
done

# the round comparison written by the agents after settling one round on the local chain
cmp=out/compare_round.json
if [[ -f $cmp ]] && python3 - "$cmp" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
rows = d["agents"]
assert 2 <= len(rows) <= 3, f"{len(rows)} agents"
assert len({r["model"] for r in rows}) == len(rows), "agents must use different models"
for r in rows:
    assert r["submitted"] is True, r
    assert isinstance(r["score"], int), r
EOF
then ok "comparison of 2-3 agents on different models ($cmp)"; else bad "comparison of 2-3 agents on different models ($cmp)"; fi

cd "$root/analysis" && uv run pytest -q >/dev/null 2>&1 && ok "analysis tests green" || bad "analysis tests green"
cd "$root/contracts" && forge test --match-path test/VolMarket.t.sol >/dev/null 2>&1 && ok "VolMarket tests green" || bad "VolMarket tests green"

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
