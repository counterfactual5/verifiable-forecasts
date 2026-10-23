#!/usr/bin/env bash
# R4 acceptance: VolMarket records an immutable modelHash at registration and derives a three-tier
# verification level (zk / reproducible / commit-only); reproducible models stay non-zk with the
# `-commit` ERC-8004 tag, and the two-argument registerModel keeps working.
set -uo pipefail
cd "$(dirname "$0")/../../contracts"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

src=src/VolMarket.sol
t=test/VolMarket.t.sol
[[ -f $src && -f $t ]] && ok "$src and $t exist" || { bad "$src and $t exist"; echo FAIL; exit 1; }

grep -qE 'function registerModel\(address [a-zA-Z_]+, address [a-zA-Z_]+, bytes32 [a-zA-Z_]+\)' "$src" \
    && ok "three-argument registerModel" || bad "three-argument registerModel"
grep -qE 'function registerModel\(address [a-zA-Z_]+, address [a-zA-Z_]+\)' "$src" \
    && ok "two-argument registerModel kept" || bad "two-argument registerModel kept"
grep -qE 'event ModelHashSet\(uint256 indexed modelId, bytes32 modelHash\)' "$src" \
    && ok "event ModelHashSet" || bad "event ModelHashSet"
grep -qE 'event ModelRegistered\(uint256 indexed modelId, address verifier, address operator\)' "$src" \
    && ok "ModelRegistered signature unchanged" || bad "ModelRegistered signature unchanged"
grep -qE 'function verificationTier\(uint256 [a-zA-Z_]+\)' "$src" && ok "verificationTier view" || bad "verificationTier view"
grep -qE 'TIER_ZK' "$src" && grep -qE 'TIER_REPRODUCIBLE' "$src" && grep -qE 'TIER_COMMIT_ONLY' "$src" \
    && ok "tiers are named constants" || bad "tiers are named constants"
if grep -qE 'function setModelHash|function updateModelHash' "$src"; then bad "modelHash has no setter"; else ok "modelHash has no setter"; fi

out=$(forge test --match-path "$t" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "forge test $t green" || { bad "forge test $t green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
for name in \
    test_RegisterModelWithHashStoresAndEmits \
    test_TierReproducibleWhenNoVerifierAndHash \
    test_TierZkWhenVerifierRegardlessOfHash \
    test_TierCommitOnlyWhenNeither \
    test_ModelHashUnknownModelReverts \
    test_VerificationTierUnknownModelReverts \
    test_RegisterModelWithHashZeroOperatorReverts \
    test_RegisterModelWithHashNotOwnerReverts \
    test_ReproducibleModelRevealSkipsProofAndTagsCommit \
    test_ZkModelWithHashStillRequiresProof; do
    printf '%s\n' "$out" | grep -qE "\[PASS\] ${name}\(" && ok "$name passes" || bad "$name passes"
done

for other in test/ERC8004.t.sol test/VolFeeConsumer.t.sol; do
    o=$(forge test --match-path "$other" 2>&1); orc=$?
    [[ $orc -eq 0 ]] && ok "$other still green" || { bad "$other still green (rc $orc)"; printf '%s\n' "$o" | tail -15; }
done

forge fmt --check >/dev/null 2>&1 && ok "forge fmt --check" || bad "forge fmt --check"

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
