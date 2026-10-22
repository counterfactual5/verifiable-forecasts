#!/usr/bin/env bash
# R2 acceptance: VolMarket settles time-segmented rounds from observe(), accepts only predictions
# carrying a real EZKL proof over its own on-chain features, and wires the EZKL-generated verifier.
set -uo pipefail
cd "$(dirname "$0")/../../contracts"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

t=test/VolMarket.t.sol
[[ -f $t ]] && ok "VolMarket test file exists" || { bad "VolMarket test file exists"; echo FAIL; exit 1; }
[[ -f src/VolMarket.sol ]] && ok "src/VolMarket.sol exists" || bad "src/VolMarket.sol exists"

# the verifier is the EZKL-generated Halo2 verifier, not a stand-in
v=$(grep -lE '^contract Halo2Verifier|contract [A-Za-z0-9_]*Verifier[A-Za-z0-9_]* *\{' src/verifier/*.sol 2>/dev/null | head -1)
if [[ -n "$v" ]] && grep -q 'function verifyProof' "$v" && grep -q 'NUM_INSTANCES_MPTR' "$v"; then ok "EZKL verifier in src/verifier ($v)"; else bad "EZKL verifier in src/verifier"; fi
if grep -rlE 'function verifyProof' test/ 2>/dev/null | grep -q .; then bad "no verifyProof stand-in under test/"; else ok "no verifyProof stand-in under test/"; fi

# the proof fixture is a real EZKL proof (5 KB+, 21 instances)
pf=$(ls test/fixtures/*proof*.json 2>/dev/null | head -1)
if [[ -n "$pf" ]] && python3 - "$pf" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
proof = d.get("proof") or d.get("hex_proof")
if isinstance(proof, list):
    n = len(proof)
else:
    n = (len(proof) - 2) // 2 if str(proof).startswith("0x") else len(str(proof)) // 2
inst = d.get("instances")
if inst and isinstance(inst[0], list):
    inst = inst[0]
assert n >= 4000, f"proof only {n} bytes"
assert inst is not None and len(inst) == 21, "instances must be 21 (16 inputs + 5 outputs)"
EOF
then ok "real proof fixture ($pf)"; else bad "real proof fixture (test/fixtures/*proof*.json, >=4000-byte proof, 21 instances)"; fi

[[ -f test/fixtures/vol_rv_cases.json ]] && ok "vol_rv_cases.json fixture" || bad "vol_rv_cases.json fixture"

out=$(forge test --match-path "$t" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "forge test $t green" || { bad "forge test $t green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
for name in \
    test_SegmentedSettleFromObserve \
    test_NegativeTickFloorDiv \
    test_RvCasesFixture \
    test_SampleFallbackWhenObserveTooOld \
    test_RealProofAccepted \
    test_TamperedProofRejected \
    test_FeatureMismatchRejected \
    test_ParimutuelPayout \
    test_DoubleClaimReverts \
    test_LowCoverageVoidsAndRefunds; do
    printf '%s\n' "$out" | grep -qE "\[PASS\] ${name}\(" && ok "$name passes" || bad "$name passes"
done

forge fmt --check >/dev/null 2>&1 && ok "forge fmt --check" || bad "forge fmt --check"
sz=$(forge build --sizes 2>&1); src=$?
[[ $src -eq 0 ]] && ok "forge build --sizes within EIP-170" || { bad "forge build --sizes within EIP-170"; printf '%s\n' "$sz" | tail -15; }

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
