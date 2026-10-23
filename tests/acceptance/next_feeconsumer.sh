#!/usr/bin/env bash
# R1 acceptance: VolFeeConsumer reads the revealed forecasts of a round between the reveal deadline
# and startTime, mixes them by ERC-8004 reputation (equal weights without reputation) and maps the
# mixed distribution's expected variance to a clamped AMM fee; VolMarket keeps passing.
set -uo pipefail
cd "$(dirname "$0")/../../contracts"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

src=src/VolFeeConsumer.sol
t=test/VolFeeConsumer.t.sol
[[ -f $src ]] && ok "$src exists" || { bad "$src exists"; echo FAIL; exit 1; }
[[ -f $t ]] && ok "$t exists" || { bad "$t exists"; echo FAIL; exit 1; }

# the consumer reads the market and the reputation registry, it does not ship its own copies
grep -q 'predictorAt' "$src" && ok "reads predictors through VolMarket.predictorAt" || bad "reads predictors through VolMarket.predictorAt"
grep -q 'getSummary' "$src" && ok "reads ERC-8004 getSummary" || bad "reads ERC-8004 getSummary"
grep -q 'baselineLogScore' "$src" && ok "weights against the market's baselineLogScore" || bad "weights against the market's baselineLogScore"
grep -q 'revealLead' "$src" && ok "reveal deadline read from the market" || bad "reveal deadline read from the market"

out=$(forge test --match-path "$t" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "forge test $t green" || { bad "forge test $t green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
for name in \
    test_ReputationWeightsDifferFromEqual \
    test_MixSumsToOne \
    test_FeeMonotoneInVolatility \
    test_FeeClampedToBounds \
    test_RevertsBeforeRevealWindowEnds \
    test_RevertsAtOrAfterStart \
    test_UnrevealedPredictorIgnored \
    test_ReadsMainnetTupleSummary \
    test_ReadsLiteIntSummary \
    test_NoReputationFallsBackToEqual \
    test_RecordStoresFee; do
    printf '%s\n' "$out" | grep -qE "\[PASS\] ${name}\(" && ok "$name passes" || bad "$name passes"
done

vm=$(forge test --match-path test/VolMarket.t.sol 2>&1); vrc=$?
[[ $vrc -eq 0 ]] && ok "VolMarket tests still green" || { bad "VolMarket tests still green (rc $vrc)"; printf '%s\n' "$vm" | tail -15; }

forge fmt --check >/dev/null 2>&1 && ok "forge fmt --check" || bad "forge fmt --check"

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
