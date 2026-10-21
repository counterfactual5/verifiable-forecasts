#!/usr/bin/env bash
# R2 acceptance: ERC-8004 reputation wiring. Agents register identities, settlement writes
# each predictor's log score to the reputation registry via giveFeedback (a failing write
# must not block settlement or claims), third-party feedback stays out of getSummary, and
# the untouched VolMarket suite plus the agents end-to-end round stay green.
set -uo pipefail
cd "$(dirname "$0")/../../contracts"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

for f in src/erc8004/IdentityRegistryLite.sol src/erc8004/ReputationRegistryLite.sol; do
    [[ -f $f ]] && ok "$f exists" || bad "$f exists"
done

out=$(forge test --match-path test/ERC8004.t.sol 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "ERC8004 targeted forge tests green" || { bad "ERC8004 targeted forge tests green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
for t in \
    test_AgentRegistersAndMarketWritesScore \
    test_ReputationFailureDoesNotBlockSettleOrClaim \
    test_NoReputationConfiguredKeepsBehavior \
    test_LinkAgentRequiresOperatorAndAgentOwner \
    test_SettleGasWith32BoundPredictors \
    test_ThirdPartyFeedbackExcludedFromSummary; do
    printf '%s\n' "$out" | grep -qE "\[PASS\].*$t" && ok "$t passes" || bad "$t passes"
done

out=$(forge test --match-path test/VolMarket.t.sol 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "VolMarket suite still green" || { bad "VolMarket suite still green (rc $rc)"; printf '%s\n' "$out" | tail -30; }

cd ../agents
out=$(uv run pytest -v tests/test_round.py 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "agents end-to-end green" || { bad "agents end-to-end green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
printf '%s\n' "$out" | grep -qE "test_agent_score_written_to_reputation PASSED" \
    && ok "test_agent_score_written_to_reputation passes" \
    || bad "test_agent_score_written_to_reputation passes"

cd ..
grep -qE '^### ERC-8004 信誉$' docs/ARCHITECTURE.md \
    && ok "ARCHITECTURE.md ERC-8004 section no longer marked planned" \
    || bad "ARCHITECTURE.md ERC-8004 section no longer marked planned"

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
