#!/usr/bin/env bash
# R5 acceptance: a reproducible agent runs pinned public Chronos-Bolt weights in a separate
# interpreter (VOL_REPRO_PYTHON), quantizes to integer basis points, registers its modelHash with
# the three-argument registerModel and an agent card carrying it; `python -m vol_agents.recompute`
# re-runs the model from onchain features and exits non-zero on any mismatch, never falling back.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/agents"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

export VOL_REPRO_PYTHON="${VOL_REPRO_PYTHON:-$HOME/Work/chronos-experiment/.venv/bin/python}"
[[ -x "$VOL_REPRO_PYTHON" ]] && ok "VOL_REPRO_PYTHON executable ($VOL_REPRO_PYTHON)" \
    || { bad "VOL_REPRO_PYTHON executable ($VOL_REPRO_PYTHON)"; echo FAIL; exit 1; }

agent=vol_agents/repro_agent.py
runner=vol_agents/repro_runner.py
recompute=vol_agents/recompute.py
t=tests/test_repro_agent.py
for f in "$agent" "$runner" "$recompute" "$t"; do
    [[ -f $f ]] && ok "$f exists" || bad "$f exists"
done
[[ $fail -eq 0 ]] || { echo FAIL; exit 1; }

# the runner is executed by another interpreter: stdlib at module level, model libraries lazily
if grep -nE '^(import|from) (torch|chronos|numpy|transformers|huggingface_hub)' "$runner"; then
    bad "runner imports model libraries only lazily"
else ok "runner imports model libraries only lazily"; fi
grep -qE '[0-9a-f]{40}' "$runner" && ok "runner pins a 40-hex model revision" || bad "runner pins a 40-hex model revision"
grep -q 'chronos-bolt' "$runner" && ok "runner names a chronos-bolt model" || bad "runner names a chronos-bolt model"
if grep -nE '"?(torch|chronos-forecasting)' pyproject.toml; then bad "agents dependencies add no torch"; else ok "agents dependencies add no torch"; fi
grep -q 'registerModel(address,address,bytes32)' "$agent" "$recompute" vol_agents/*.py 2>/dev/null \
    && ok "agent registers with the three-argument registerModel" || bad "agent registers with the three-argument registerModel"
grep -q 'modelHash(uint256)' "$recompute" && ok "recompute reads the onchain modelHash" || bad "recompute reads the onchain modelHash"
grep -q 'ApiAgent' vol_agents/api_agent.py && ok "ApiAgent kept" || bad "ApiAgent kept"

out=$(uv run pytest "$t" -v -rs 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "pytest $t green" || { bad "pytest $t green (rc $rc)"; printf '%s\n' "$out" | tail -40; }
if printf '%s\n' "$out" | grep -qE 'SKIPPED|skipped'; then
    bad "no test skipped with VOL_REPRO_PYTHON set"; printf '%s\n' "$out" | grep -E 'SKIP' | head
else ok "no test skipped with VOL_REPRO_PYTHON set"; fi
for name in \
    test_quantize_bps_sums_and_no_zero_bucket \
    test_quantize_bps_is_multiple_of_1e14 \
    test_model_hash_combines_weights_config_runner \
    test_runner_request_shape \
    test_inference_deterministic_same_machine \
    test_recompute_offline_prints_vector \
    test_repro_round_registers_reveals_and_recomputes \
    test_recompute_fails_on_tampered_reveal \
    test_recompute_fails_on_hash_mismatch \
    test_recompute_fails_on_runner_error_no_fallback; do
    printf '%s\n' "$out" | grep -qE "::${name} PASSED" && ok "$name passes" || bad "$name passes"
done

old=$(uv run pytest tests/test_api_agent.py tests/test_contract_math.py -q 2>&1); orc=$?
[[ $orc -eq 0 ]] && ok "existing api_agent / contract_math tests still green" \
    || { bad "existing api_agent / contract_math tests still green (rc $orc)"; printf '%s\n' "$old" | tail -15; }

uv run ruff check . >/dev/null 2>&1 && ok "ruff check" || { bad "ruff check"; uv run ruff check . 2>&1 | tail -10; }

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
