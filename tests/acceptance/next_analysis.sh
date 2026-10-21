#!/usr/bin/env bash
# R1 acceptance: analysis fetches Swap event logs (tick + timestamp per swap), recomputes the
# contract's realized-vol caliber on the shared fixture item-by-item, and calibrates exactly
# 4 strictly increasing bounds that track the input data; legacy base-fee tests stay green.
set -uo pipefail
cd "$(dirname "$0")/../../analysis"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

[[ -f src/fetch_swaps.py ]] && ok "src/fetch_swaps.py exists" || bad "src/fetch_swaps.py exists"
[[ -f src/vol_calibrate.py ]] && ok "src/vol_calibrate.py exists" || bad "src/vol_calibrate.py exists"
for t in tests/test_fetch_swaps.py tests/test_vol_calibrate.py; do
    [[ -f $t ]] && ok "$t exists" || bad "$t exists"
done

out=$(uv run pytest -v tests/test_fetch_swaps.py tests/test_vol_calibrate.py 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "new analysis tests green" || { bad "new analysis tests green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
for name in \
    test_parse_swap_log_extracts_tick_and_timestamp \
    test_rv_cases_fixture_parity \
    test_calibrated_bounds_are_four_strictly_increasing \
    test_calibrated_bounds_change_with_input_data; do
    printf '%s\n' "$out" | grep -qE "${name} PASSED" && ok "$name passes" || bad "$name passes"
done

out=$(uv run pytest -q tests/test_calibrate.py tests/test_pipeline.py tests/test_fetch_fee_history.py 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "legacy analysis tests green" || { bad "legacy analysis tests green (rc $rc)"; printf '%s\n' "$out" | tail -20; }

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
