// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VolFeeConsumer, IVolMarketReader} from "../src/VolFeeConsumer.sol";
import {ReputationRegistryLite} from "../src/erc8004/ReputationRegistryLite.sol";
import {MockFeeMarket} from "./mocks/MockFeeMarket.sol";
import {MockReputationTuple} from "./mocks/MockReputationTuple.sol";

contract VolFeeConsumerTest is Test {
    uint32 constant REVEAL_LEAD = 100;
    int256 constant BASELINE = -1609437912434100366;
    string constant TAG1 = "logScore";
    string constant TAG2_ZK = "vol-300s-12";
    string constant TAG2_COMMIT = "vol-300s-12-commit";
    uint256 constant ZK_MODEL = 0;
    uint256 constant COMMIT_MODEL = 1;
    uint256 constant ZK_MODEL_2 = 2;
    uint256 constant AGENT_A = 7;
    uint256 constant AGENT_B = 8;
    uint256 constant AGENT_C = 9;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    MockFeeMarket market;
    MockReputationTuple tuple;
    VolFeeConsumer consumer;
    uint64 start;

    function setUp() public {
        vm.warp(1_000_000);
        market = new MockFeeMarket(REVEAL_LEAD);
        start = uint64(block.timestamp + 1000);
        market.setRound(0, start);
        market.setRound(1, start);
        market.setModel(ZK_MODEL, true);
        market.setModel(COMMIT_MODEL, false);
        market.setModel(ZK_MODEL_2, true);
        tuple = new MockReputationTuple();
        // feePerVarE18 = 1e18: one pip per tick^2 of expected variance.
        consumer = _consumer(1e18, 100, 10_000);
    }

    // ------------------------------------------------------------ helpers
    function _consumer(uint256 feePerVarE18, uint24 minFee, uint24 maxFee) internal returns (VolFeeConsumer) {
        return new VolFeeConsumer(
            IVolMarketReader(address(market)), TAG1, TAG2_ZK, TAG2_COMMIT, _vars(), feePerVarE18, minFee, maxFee
        );
    }

    function _vars() internal pure returns (uint256[5] memory v) {
        v = [uint256(100), 400, 900, 1600, 2500];
    }

    /// @dev Probabilities in per mille, scaled to 1e18.
    function _pm(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[5] memory p) {
        p = [a * 1e15, b * 1e15, c * 1e15, d * 1e15, e * 1e15];
    }

    function _probsA() internal pure returns (uint256[5] memory) {
        return _pm(500, 200, 100, 100, 100);
    }

    function _probsB() internal pure returns (uint256[5] memory) {
        return _pm(100, 100, 100, 200, 500);
    }

    function _equalMixAB() internal pure returns (uint256[5] memory) {
        return _pm(300, 150, 100, 150, 300);
    }

    /// @dev (3 * A + B) / 4, the mix for reputation weights 3:1.
    function _weightedMixAB() internal pure returns (uint256[5] memory) {
        return _pm(400, 175, 100, 125, 200);
    }

    /// @dev alice reveals A with the zk model, bob reveals B with the commit-only model.
    function _addAB(uint256 id) internal {
        market.addForecast(id, alice, true, ZK_MODEL, _probsA());
        market.addForecast(id, bob, true, COMMIT_MODEL, _probsB());
    }

    function _bindAB() internal {
        market.bindAgent(ZK_MODEL, AGENT_A);
        market.bindAgent(COMMIT_MODEL, AGENT_B);
    }

    function _rate(uint256 agentId, string memory tag2, int256 value, uint8 decimals) internal {
        tuple.setSummary(agentId, address(market), TAG1, tag2, 3, int128(value), decimals);
    }

    /// @dev Weights 3:1 above the baseline, through the mainnet-shaped registry.
    function _rateAB() internal {
        market.setReputationRegistry(address(tuple));
        _rate(AGENT_A, TAG2_ZK, BASELINE + 3e17, 18);
        _rate(AGENT_B, TAG2_COMMIT, BASELINE + 1e17, 18);
    }

    function _open() internal {
        vm.warp(start - REVEAL_LEAD);
    }

    function _mixOf(uint256 id) internal view returns (uint256[5] memory mix) {
        (, mix,) = consumer.quote(id);
    }

    function _same(uint256[5] memory a, uint256[5] memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _assertMix(uint256[5] memory actual, uint256[5] memory expected) internal pure {
        for (uint256 b = 0; b < 5; ++b) {
            assertEq(actual[b], expected[b]);
        }
    }

    function _sum(uint256[5] memory p) internal pure returns (uint256 s) {
        for (uint256 b = 0; b < 5; ++b) {
            s += p[b];
        }
    }

    /// @dev VolMarket's reveal normalization: floor shares, remainder to the last bucket.
    function _normalize(uint256[5] memory raw) internal pure returns (uint256[5] memory p) {
        uint256 sum;
        for (uint256 b = 0; b < 5; ++b) {
            raw[b] = bound(raw[b], 0, 1e30);
            sum += raw[b];
        }
        if (sum == 0) {
            raw[0] = 1;
            sum = 1;
        }
        uint256 assigned;
        for (uint256 b = 0; b < 4; ++b) {
            p[b] = (raw[b] * 1e18) / sum;
            assigned += p[b];
        }
        p[4] = 1e18 - assigned;
    }

    function _weightedMix(uint256[5] memory a, uint256[5] memory b, uint256 wa, uint256 wb)
        internal
        pure
        returns (uint256[5] memory mix)
    {
        uint256 assigned;
        for (uint256 i = 0; i < 4; ++i) {
            mix[i] = (wa * a[i] + wb * b[i]) / (wa + wb);
            assigned += mix[i];
        }
        mix[4] = 1e18 - assigned;
    }

    // ------------------------------------------------------------ weighting
    function test_ReputationWeightsDifferFromEqual() public {
        _addAB(0);
        _bindAB();
        _rateAB();
        _open();
        (uint24 fee, uint256[5] memory mix, uint256 expectedVarE18) = consumer.quote(0);
        _assertMix(mix, _weightedMixAB());
        assertFalse(_same(mix, _equalMixAB()));
        // 0.4*100 + 0.175*400 + 0.1*900 + 0.125*1600 + 0.2*2500 = 900 tick^2
        assertEq(expectedVarE18, 900e18);
        assertEq(fee, 900);
    }

    function test_MixSumsToOne(uint256[5] memory rawA, uint256[5] memory rawB, uint64 wA, uint64 wB) public {
        market.addForecast(0, alice, true, ZK_MODEL, _normalize(rawA));
        market.addForecast(0, bob, true, COMMIT_MODEL, _normalize(rawB));
        _bindAB();
        market.setReputationRegistry(address(tuple));
        _rate(AGENT_A, TAG2_ZK, BASELINE + int256(uint256(wA)), 18);
        _rate(AGENT_B, TAG2_COMMIT, BASELINE + int256(uint256(wB)), 18);
        _open();
        assertEq(_sum(_mixOf(0)), 1e18);
    }

    function test_MixSumsToOneOddVectors() public {
        market.addForecast(0, alice, true, ZK_MODEL, [uint256(1), 1, 1, 1, 1e18 - 4]);
        market.addForecast(
            0, bob, true, COMMIT_MODEL, [uint256(333333333333333333), 333333333333333333, 333333333333333334, 0, 0]
        );
        market.addForecast(0, carol, true, ZK_MODEL_2, [uint256(7), 11, 13, 17, 1e18 - 48]);
        _bindAB();
        market.bindAgent(ZK_MODEL_2, AGENT_C);
        market.setReputationRegistry(address(tuple));
        _rate(AGENT_A, TAG2_ZK, BASELINE + 1, 18);
        _rate(AGENT_B, TAG2_COMMIT, BASELINE + 3, 18);
        _rate(AGENT_C, TAG2_ZK, BASELINE + 7, 18);
        _open();
        uint256[5] memory mix = _mixOf(0);
        assertEq(_sum(mix), 1e18);
        // floor((1 + 3 * 333333333333333333 + 7 * 7) / 11)
        assertEq(mix[0], 90909090909090913);
    }

    // ------------------------------------------------------------ fee map
    function test_FeeMonotoneInVolatility(uint256[5] memory raw, uint256 from, uint256 to, uint256 amount) public {
        uint256[5] memory p = _normalize(raw);
        from = bound(from, 0, 3);
        to = bound(to, from + 1, 4);
        amount = bound(amount, 0, p[from]);
        uint256[5] memory q = p;
        q[from] -= amount;
        q[to] += amount;
        market.addForecast(0, alice, true, ZK_MODEL, p);
        market.addForecast(1, alice, true, ZK_MODEL, q);
        _open();
        (uint24 feeBefore,, uint256 varBefore) = consumer.quote(0);
        (uint24 feeAfter,, uint256 varAfter) = consumer.quote(1);
        assertGe(varAfter, varBefore);
        assertGe(feeAfter, feeBefore);
    }

    function test_FeeRisesBucketByBucket() public {
        uint24 prev;
        for (uint256 b = 0; b < 5; ++b) {
            uint256[5] memory p;
            p[b] = 1e18;
            market.setRound(10 + b, start);
            market.addForecast(10 + b, alice, true, ZK_MODEL, p);
        }
        _open();
        for (uint256 b = 0; b < 5; ++b) {
            (uint24 fee,,) = consumer.quote(10 + b);
            assertEq(fee, _vars()[b]);
            assertGt(fee, prev);
            prev = fee;
        }
    }

    function test_FeeClampedToBounds() public {
        VolFeeConsumer clamped = _consumer(1e18, 500, 2000);
        uint256[5] memory low;
        low[0] = 1e18;
        uint256[5] memory high;
        high[4] = 1e18;
        market.addForecast(0, alice, true, ZK_MODEL, low);
        market.addForecast(1, alice, true, ZK_MODEL, high);
        _open();
        (uint24 lowFee,, uint256 lowVar) = clamped.quote(0);
        (uint24 highFee,, uint256 highVar) = clamped.quote(1);
        assertEq(lowVar, 100e18);
        assertEq(lowFee, 500);
        assertEq(highVar, 2500e18);
        assertEq(highFee, 2000);

        // expectedVarE18 * feePerVarE18 past uint256 clamps instead of reverting
        VolFeeConsumer steep = _consumer(type(uint256).max, 500, 2000);
        (uint24 steepFee,,) = steep.quote(0);
        assertEq(steepFee, 2000);
    }

    // ------------------------------------------------------------ timing
    function test_RevertsBeforeRevealWindowEnds() public {
        _addAB(0);
        vm.warp(start - REVEAL_LEAD - 1);
        vm.expectRevert(VolFeeConsumer.TooEarly.selector);
        consumer.quote(0);
        vm.expectRevert(VolFeeConsumer.TooEarly.selector);
        consumer.record(0);
        vm.warp(start - REVEAL_LEAD);
        consumer.quote(0);
    }

    function test_RevertsAtOrAfterStart() public {
        _addAB(0);
        vm.warp(start - 1);
        consumer.quote(0);
        vm.warp(start);
        vm.expectRevert(VolFeeConsumer.TooLate.selector);
        consumer.quote(0);
        vm.expectRevert(VolFeeConsumer.TooLate.selector);
        consumer.record(0);
        vm.warp(start + 1);
        vm.expectRevert(VolFeeConsumer.TooLate.selector);
        consumer.quote(0);
        vm.expectRevert(VolFeeConsumer.TooLate.selector);
        consumer.record(0);
    }

    // ------------------------------------------------------------ forecasts considered
    function test_UnrevealedPredictorIgnored() public {
        _addAB(0);
        _bindAB();
        _rateAB();
        _open();
        (uint24 feeBefore, uint256[5] memory mixBefore,) = consumer.quote(0);

        uint256[5] memory extreme;
        extreme[4] = 1e18;
        // committed, never revealed, and without reputation: neither its probs nor its missing
        // reputation may change the weighted result
        market.addForecast(0, carol, false, ZK_MODEL_2, extreme);
        (uint24 feeAfter, uint256[5] memory mixAfter,) = consumer.quote(0);
        _assertMix(mixAfter, mixBefore);
        _assertMix(mixAfter, _weightedMixAB());
        assertEq(feeAfter, feeBefore);
    }

    function test_RevertsWithoutRevealedForecast() public {
        _open();
        vm.expectRevert(VolFeeConsumer.NoForecasts.selector);
        consumer.quote(0);
        market.addForecast(0, alice, false, ZK_MODEL, _probsA());
        vm.expectRevert(VolFeeConsumer.NoForecasts.selector);
        consumer.quote(0);
    }

    // ------------------------------------------------------------ reputation sources
    function test_ReadsMainnetTupleSummary() public {
        _addAB(0);
        _bindAB();
        market.setReputationRegistry(address(tuple));
        // 6-decimal means: -0.609438 and -1.509438
        _rate(AGENT_A, TAG2_ZK, -609438, 6);
        _rate(AGENT_B, TAG2_COMMIT, -1509438, 6);
        _open();
        uint256[5] memory mix = _mixOf(0);
        uint256 wa = uint256(-609438e12 - BASELINE);
        uint256 wb = uint256(-1509438e12 - BASELINE);
        _assertMix(mix, _weightedMix(_probsA(), _probsB(), wa, wb));
        assertFalse(_same(mix, _equalMixAB()));

        // the same means at 18 decimals give the same mix
        _rate(AGENT_A, TAG2_ZK, -609438e12, 18);
        _rate(AGENT_B, TAG2_COMMIT, -1509438e12, 18);
        _assertMix(_mixOf(0), mix);

        // count 0, decimals that cannot be upscaled, and a reverting registry mean no reputation
        tuple.setSummary(AGENT_B, address(market), TAG1, TAG2_COMMIT, 0, int128(BASELINE + 1e17), 18);
        _assertMix(_mixOf(0), _equalMixAB());
        _rate(AGENT_B, TAG2_COMMIT, -1509438e12, 19);
        _assertMix(_mixOf(0), _equalMixAB());
        _rate(AGENT_B, TAG2_COMMIT, -1509438e12, 18);
        tuple.setReverts(true);
        _assertMix(_mixOf(0), _equalMixAB());
    }

    function test_ReadsLiteIntSummary() public {
        ReputationRegistryLite lite = new ReputationRegistryLite();
        market.setReputationRegistry(address(lite));
        _addAB(0);
        _bindAB();
        vm.startPrank(address(market));
        lite.giveFeedback(AGENT_A, int128(BASELINE + 2e17), 18, TAG1, TAG2_ZK, "", "", bytes32(0));
        lite.giveFeedback(AGENT_A, int128(BASELINE + 4e17), 18, TAG1, TAG2_ZK, "", "", bytes32(0));
        lite.giveFeedback(AGENT_B, int128(BASELINE + 1e17), 18, TAG1, TAG2_COMMIT, "", "", bytes32(0));
        // wrong tier for a commit-only model: not part of its summary
        lite.giveFeedback(AGENT_B, 0, 18, TAG1, TAG2_ZK, "", "", bytes32(0));
        // agent C has only a record under the other tier
        lite.giveFeedback(AGENT_C, 0, 18, TAG1, TAG2_COMMIT, "", "", bytes32(0));
        vm.stopPrank();
        // another client's feedback is not the market's
        lite.giveFeedback(AGENT_B, 0, 18, TAG1, TAG2_COMMIT, "", "", bytes32(0));
        lite.giveFeedback(AGENT_C, 0, 18, TAG1, TAG2_ZK, "", "", bytes32(0));

        _open();
        _assertMix(_mixOf(0), _weightedMixAB());

        // Lite reports 0 (a perfect score) for agent C, yet it has no matching record
        market.addForecast(1, alice, true, ZK_MODEL, _probsA());
        market.addForecast(1, carol, true, ZK_MODEL_2, _probsB());
        market.bindAgent(ZK_MODEL_2, AGENT_C);
        _assertMix(_mixOf(1), _equalMixAB());
    }

    function test_NoReputationFallsBackToEqual() public {
        _addAB(0);
        market.bindAgent(ZK_MODEL, AGENT_A);
        _open();
        // registry unset
        _assertMix(_mixOf(0), _equalMixAB());

        // one revealed model is not bound to an agent
        market.setReputationRegistry(address(tuple));
        _rate(AGENT_A, TAG2_ZK, BASELINE + 3e17, 18);
        _rate(AGENT_B, TAG2_COMMIT, BASELINE + 1e17, 18);
        _assertMix(_mixOf(0), _equalMixAB());

        // both bound and rated: weighted
        market.bindAgent(COMMIT_MODEL, AGENT_B);
        _assertMix(_mixOf(0), _weightedMixAB());

        // every weight is 0: at and below the baseline
        _rate(AGENT_A, TAG2_ZK, BASELINE, 18);
        _rate(AGENT_B, TAG2_COMMIT, BASELINE - 1e17, 18);
        _assertMix(_mixOf(0), _equalMixAB());
    }

    // ------------------------------------------------------------ record
    function test_RecordStoresFee() public {
        _addAB(0);
        _bindAB();
        _rateAB();
        _open();
        vm.expectEmit(true, false, false, true, address(consumer));
        emit VolFeeConsumer.FeeRecorded(0, 900, 900e18, _weightedMixAB());
        assertEq(consumer.record(0), 900);
        assertEq(consumer.feeOf(0), 900);
        assertTrue(consumer.feeRecorded(0));
        vm.expectRevert(VolFeeConsumer.AlreadyRecorded.selector);
        consumer.record(0);
    }

    // ------------------------------------------------------------ constructor
    function test_ConstructorRejectsInvalidParams() public {
        IVolMarketReader m = IVolMarketReader(address(market));
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(IVolMarketReader(address(0)), TAG1, TAG2_ZK, TAG2_COMMIT, _vars(), 1e18, 100, 200);
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, _vars(), 1e18, 201, 200);
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, [uint256(100), 400, 300, 1600, 2500], 1e18, 100, 200);
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(
            m, TAG1, TAG2_ZK, TAG2_COMMIT, [uint256(100), 400, 900, 1600, type(uint256).max / 1e18 + 1], 1e18, 100, 200
        );
        // equal bounds and flat variances are valid
        new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, [uint256(5), 5, 5, 5, 5], 1e18, 200, 200);
    }
}
