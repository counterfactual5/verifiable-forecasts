#!/usr/bin/env bash
# R3 acceptance: optional Chainlink ETH/USD cross-check at settlement, with safe void/refund
# behavior for stale or materially divergent feeds and regression coverage when disabled.
set -uo pipefail
cd "$(dirname "$0")/../../contracts"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

[[ -f src/interfaces/AggregatorV3Interface.sol ]] && ok "AggregatorV3Interface exists" || bad "AggregatorV3Interface exists"
[[ -f test/mocks/MockAggregator.sol ]] && ok "MockAggregator exists" || bad "MockAggregator exists"
[[ -f test/VolMarket.t.sol ]] && ok "VolMarket tests exist" || bad "VolMarket tests exist"

        out=$(forge test --match-path test/VolMarket.t.sol 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "VolMarket suite green" || { bad "VolMarket suite green (rc $rc)"; printf '%s\n' "$out" | tail -30; }
for name in \
    test_PriceFeedMatchingPriceSettles \
    test_PriceFeedDeviationVoidsAndRefunds \
    test_PriceFeedStaleVoidsAndRefunds \
    test_TickToPriceMatchesReference \
    test_NoPriceFeedKeepsBehavior; do
    printf '%s\n' "$out" | grep -qE "\[PASS\].*$name" && ok "$name passes" || bad "$name passes"
done

cd ../agents
out=$(uv run pytest -q tests/test_round.py 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "agents end-to-end green" || { bad "agents end-to-end green (rc $rc)"; printf '%s\n' "$out" | tail -30; }

cd ..
grep -qE '^### Chainlink 喂价交叉校验$' docs/ARCHITECTURE.md \
    && ok "ARCHITECTURE.md Chainlink section no longer marked planned" \
    || bad "ARCHITECTURE.md Chainlink section no longer marked planned"
! grep -qE '^\\*\\*Planned — not implemented yet\\.\\*\\*' chainlink/README.md \
    && ok "chainlink/README.md no longer claims unimplemented" \
    || bad "chainlink/README.md no longer claims unimplemented"


[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
