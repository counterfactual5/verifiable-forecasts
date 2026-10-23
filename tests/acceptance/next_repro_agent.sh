#!/usr/bin/env bash
# R5 acceptance: the reproducible tier is the three time-series model agents (timesfm-3.0,
# timestral-209m, chronos-2) with public weights pinned at a 40-hex revision. Each registers its
# modelHash with the three-argument registerModel and reveals on the 1e-3 grid (1e15 on the 1e18
# scale); `python -m vol_agents.tsfm_recompute` re-runs the weights in a separate interpreter
# (VOL_REPRO_PYTHON) and passes only when the onchain modelHash matches and every bucket is within
# 1e15 (exact / tolerant), else exits non-zero, never falling back. The retired Chronos-Bolt path
# stays gone.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/agents"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

forecast=vol_agents/tsfm_forecast.py
runner=vol_agents/tsfm_local.py
recompute=vol_agents/tsfm_recompute.py
t=tests/test_api_agent.py
for f in "$forecast" "$runner" "$recompute" "$t"; do
    [[ -f $f ]] && ok "$f exists" || bad "$f exists"
done
[[ $fail -eq 0 ]] || { echo FAIL; exit 1; }
for f in vol_agents/repro_agent.py vol_agents/repro_runner.py vol_agents/recompute.py; do
    [[ ! -e $f ]] && ok "retired $f is gone" || bad "retired $f is gone"
done
if grep -rnE 'repro_agent|repro_runner|vol_agents\.recompute\b|from \. import recompute' vol_agents tests ../demo --include='*.py'; then
    bad "nothing imports the retired Chronos-Bolt path"
else ok "nothing imports the retired Chronos-Bolt path"; fi

# the runner is executed by another interpreter: stdlib at module level, model libraries lazily
if grep -nE '^(import|from) (torch|chronos|numpy|transformers|huggingface_hub|timesfm|timestral)' "$runner"; then
    bad "runner imports model libraries only lazily"
else ok "runner imports model libraries only lazily"; fi
if grep -nE '"?(torch|chronos-forecasting|timesfm)' pyproject.toml; then bad "agents dependencies add no torch"; else ok "agents dependencies add no torch"; fi
grep -q 'registerModel(address,address,bytes32)' ../demo/fork_round.py \
    && ok "replay registers with the three-argument registerModel" || bad "replay registers with the three-argument registerModel"
grep -q 'modelHash(uint256)' "$recompute" && ok "recompute reads the onchain modelHash" || bad "recompute reads the onchain modelHash"

consts=$(uv run python - <<'EOF' 2>&1
import re
from vol_agents import contract_math as cm
from vol_agents import tsfm_forecast as sf
errs = []
if not (sf.PROB_QUANTUM == sf.RECOMPUTE_TOLERANCE == 10**15 and cm.PROB_SCALE == 10**18):
    errs.append(f"grid {sf.PROB_QUANTUM} tolerance {sf.RECOMPUTE_TOLERANCE} scale {cm.PROB_SCALE}")
rep = sorted(m for m in sf.MODELS if sf.spec(m).tier == sf.REPRODUCIBLE)
if rep != ["chronos-2", "timesfm-3.0", "timestral-209m"]:
    errs.append(f"reproducible models {rep}")
for m in rep:
    if not re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40}", sf.spec(m).weights or ""):
        errs.append(f"{m} weights {sf.spec(m).weights}")
r = [10**17, 2 * 10**17, 3 * 10**17, 2 * 10**17, 2 * 10**17]
e = sf.RECOMPUTE_TOLERANCE
if [sf.compare_reveal(r, x)[1] for x in (r, [r[0] + e, r[1] - e] + r[2:],
                                          [r[0] + e + 1, r[1] - e - 1] + r[2:])] != [sf.EXACT, sf.TOLERANT, sf.FAIL]:
    errs.append("compare_reveal verdicts")
q = sf.quantize_reveal([0.1234, 0.2, 0.3, 0.1766, 0.2])
if sum(q) != cm.PROB_SCALE or any(v % sf.PROB_QUANTUM for v in q):
    errs.append(f"quantize_reveal {q}")
print("; ".join(errs) or "OK")
EOF
)
[[ $consts == *OK ]] && ok "1e15 grid and tolerance on the 1e18 scale, exact/tolerant/fail verdicts, three pinned reproducible models" \
    || bad "1e15 grid and tolerance, verdicts, pinned models: $consts"

out=$(uv run pytest "$t" -v -rs 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "pytest $t green" || { bad "pytest $t green (rc $rc)"; printf '%s\n' "$out" | tail -40; }
if printf '%s\n' "$out" | grep -qE 'SKIPPED|skipped'; then
    bad "no test skipped"; printf '%s\n' "$out" | grep -E 'SKIP' | head
else ok "no test skipped"; fi
for name in \
    test_reveal_quantization_sums_exactly_on_the_grid \
    test_recompute_tolerance_accepts_one_grid_step_and_rejects_beyond \
    test_model_hash_binds_public_weights_parameters_and_code \
    test_three_model_agents_are_independent_with_honest_tiers \
    test_local_recompute_repeats_the_api_forecast \
    test_recompute_falls_back_to_the_onchain_context_the_agent_may_have_used \
    test_reproducible_agent_round_registers_hash_and_recomputes; do
    printf '%s\n' "$out" | grep -qE "::${name} PASSED" && ok "$name passes" || bad "$name passes"
done

# With real public weights available, the offline recompute is deterministic on this machine.
if [[ -n "${VOL_REPRO_PYTHON:-}" ]]; then
    feats=$(uv run python -c "from vol_agents import contract_math as cm; from vol_agents.round import history_ticks; print(','.join(map(str, cm.features_from_segment_ticks(history_ticks()))))")
    bounds=$(uv run python -c "from vol_agents import contract_math as cm; print(','.join(map(str, cm.BOUNDS)))")
    a=$(uv run python -m vol_agents.tsfm_recompute --model timesfm-3.0 --features="$feats" --bounds="$bounds" 2>&1); ra=$?
    b=$(uv run python -m vol_agents.tsfm_recompute --model timesfm-3.0 --features="$feats" --bounds="$bounds" 2>&1); rb=$?
    [[ $ra -eq 0 && $rb -eq 0 && "$a" == "$b" ]] && ok "real timesfm-3.0 recompute repeats exactly ($a)" \
        || bad "real timesfm-3.0 recompute repeats exactly (rc $ra/$rb): ${a: -300} | ${b: -300}"
else
    echo "skip - real-weights determinism (VOL_REPRO_PYTHON unset; the replay's recompute covers it)"
fi

uv run ruff check . >/dev/null 2>&1 && ok "ruff check" || { bad "ruff check"; uv run ruff check . 2>&1 | tail -10; }

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
