// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VolFeeConsumer, IVolMarketReader} from "../src/VolFeeConsumer.sol";
import {MarketMath} from "../src/lib/MarketMath.sol";
import {ReputationRegistryLite} from "../src/erc8004/ReputationRegistryLite.sol";
import {MockFeeMarket} from "./mocks/MockFeeMarket.sol";
import {MockReputationTuple} from "./mocks/MockReputationTuple.sol";
import {RawReputationRegistry} from "./mocks/RawReputationRegistry.sol";

contract VolFeeConsumerTest is Test {
    uint32 constant REVEAL_LEAD = 100;
    /// @dev -(training-period mean pinball loss of the climatological baseline), 1e18.
    int256 constant BASELINE = -366844839083915113;
    string constant TAG1 = "pinball";
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
            IVolMarketReader(address(market)), TAG1, TAG2_ZK, TAG2_COMMIT, BASELINE, feePerVarE18, minFee, maxFee
        );
    }

    /// @dev Five quantiles a, a + 1, ..., a + 4 in tenths of a ln unit, 1e18-scaled.
    function _q(int256 tenths) internal pure returns (int256[] memory q) {
        q = new int256[](5);
        for (uint256 k = 0; k < 5; ++k) {
            q[k] = tenths * 1e17 + int256(k) * 1e18;
        }
    }

    /// @dev Every level at `v`: a point forecast.
    function _flat(int256 v) internal pure returns (int256[] memory q) {
        q = new int256[](5);
        for (uint256 k = 0; k < 5; ++k) {
            q[k] = v;
        }
    }

    function _qA() internal pure returns (int256[] memory) {
        return _q(40); // 4 .. 8
    }

    function _qB() internal pure returns (int256[] memory) {
        return _q(60); // 6 .. 10
    }

    function _equalMixAB() internal pure returns (int256[] memory) {
        return _q(50);
    }

    /// @dev (3 * A + B) / 4, the mix for reputation weights 3:1.
    function _weightedMixAB() internal pure returns (int256[] memory) {
        return _q(45);
    }

    /// @dev alice reveals A with the zk model, bob reveals B with the commit-only model.
    function _addAB(uint256 id) internal {
        market.addForecast(id, alice, true, ZK_MODEL, _qA());
        market.addForecast(id, bob, true, COMMIT_MODEL, _qB());
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

    function _mixOf(uint256 id) internal view returns (int256[] memory mix) {
        (, mix,) = consumer.quote(id);
    }

    function _same(int256[] memory a, int256[] memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _assertMix(int256[] memory actual, int256[] memory expected) internal pure {
        assertEq(actual.length, expected.length, "mix length");
        for (uint256 k = 0; k < expected.length; ++k) {
            assertEq(actual[k], expected[k]);
        }
    }

    function _weightedMix(int256[] memory a, int256[] memory b, uint256 wa, uint256 wb)
        internal
        pure
        returns (int256[] memory mix)
    {
        mix = new int256[](a.length);
        for (uint256 k = 0; k < a.length; ++k) {
            mix[k] = (int256(wa) * a[k] + int256(wb) * b[k]) / int256(wa + wb);
        }
    }

    // ------------------------------------------------------------ weighting
    function test_ReputationWeightsDifferFromEqual() public {
        _addAB(0);
        _bindAB();
        _rateAB();
        _open();
        (uint24 fee, int256[] memory mix, uint256 expectedVarE18) = consumer.quote(0);
        _assertMix(mix, _weightedMixAB());
        assertFalse(_same(mix, _equalMixAB()));
        // (0.25 e^4.5 + 0.4 e^5.5 + 0.5 e^6.5 + 0.4 e^7.5 + 0.25 e^8.5) / 1.8 tick^2
        assertApproxEqRel(expectedVarE18, 1336033915616782447511, 1e3);
        assertEq(fee, 1336);
    }

    /// @dev Vincentization: each level is the weighted mean of that level across forecasts, and
    ///      the mix of two increasing forecasts is non-decreasing.
    function testFuzz_MixIsWeightedMeanPerLevel(int256 a, int256 b, uint64 wA, uint64 wB) public {
        a = bound(a, -200, 550);
        b = bound(b, -200, 550);
        market.addForecast(0, alice, true, ZK_MODEL, _q(a));
        market.addForecast(0, bob, true, COMMIT_MODEL, _q(b));
        _bindAB();
        market.setReputationRegistry(address(tuple));
        _rate(AGENT_A, TAG2_ZK, BASELINE + int256(uint256(wA)), 18);
        _rate(AGENT_B, TAG2_COMMIT, BASELINE + int256(uint256(wB)), 18);
        _open();
        int256[] memory mix = _mixOf(0);
        if (wA == 0 && wB == 0) {
            _assertMix(mix, _weightedMix(_q(a), _q(b), 1, 1));
        } else {
            _assertMix(mix, _weightedMix(_q(a), _q(b), wA, wB));
        }
        for (uint256 k = 1; k < 5; ++k) {
            assertGe(mix[k], mix[k - 1]);
        }
    }

    /// @dev Weights 1, 3, 7; division rounds toward zero, also for a negative level.
    function test_MixOddVectors() public {
        int256[] memory a = new int256[](5);
        int256[] memory b = new int256[](5);
        int256[] memory c = new int256[](5);
        a[0] = -5;
        b[0] = -7;
        c[0] = 1;
        for (uint256 k = 1; k < 5; ++k) {
            a[k] = int256(k) * 1e18 + 1;
            b[k] = int256(k) * 1e18 + 3;
            c[k] = int256(k) * 1e18 + 7;
        }
        market.addForecast(0, alice, true, ZK_MODEL, a);
        market.addForecast(0, bob, true, COMMIT_MODEL, b);
        market.addForecast(0, carol, true, ZK_MODEL_2, c);
        _bindAB();
        market.bindAgent(ZK_MODEL_2, AGENT_C);
        market.setReputationRegistry(address(tuple));
        _rate(AGENT_A, TAG2_ZK, BASELINE + 1, 18);
        _rate(AGENT_B, TAG2_COMMIT, BASELINE + 3, 18);
        _rate(AGENT_C, TAG2_ZK, BASELINE + 7, 18);
        _open();
        int256[] memory mix = _mixOf(0);
        // (-5 - 21 + 7) / 11 = -19 / 11 -> -1 (toward zero, not -2)
        assertEq(mix[0], -1);
        // k * 1e18 + (1 + 9 + 49) / 11 -> k * 1e18 + 5
        assertEq(mix[3], 3e18 + 5);
    }

    // ------------------------------------------------------------ expected variance and fee map
    /// @dev Shifting every quantile of a forecast up never lowers the expected variance or the fee.
    function testFuzz_FeeMonotoneInVolatility(int256 a, uint256 up) public {
        a = bound(a, -200, 550);
        up = bound(up, 0, 10e18);
        int256[] memory p = _q(a);
        int256[] memory q = _q(a);
        for (uint256 k = 0; k < 5; ++k) {
            q[k] += int256(up);
        }
        market.addForecast(0, alice, true, ZK_MODEL, p);
        market.addForecast(1, alice, true, ZK_MODEL, q);
        _open();
        (uint24 feeBefore,, uint256 varBefore) = consumer.quote(0);
        (uint24 feeAfter,, uint256 varAfter) = consumer.quote(1);
        assertGe(varAfter, varBefore);
        assertGe(feeAfter, feeBefore);
    }

    /// @dev A point forecast at ln v prices v tick^2 (floor of exp(ln v) may lose one pip).
    function test_FeeRisesWithForecastLevel() public {
        uint256[5] memory vars = [uint256(100), 400, 900, 1600, 2500];
        uint24 prev;
        for (uint256 i = 0; i < 5; ++i) {
            market.setRound(10 + i, start);
            market.addForecast(10 + i, alice, true, ZK_MODEL, _flat(MarketMath.lnWad(vars[i])));
        }
        _open();
        for (uint256 i = 0; i < 5; ++i) {
            (uint24 fee,, uint256 expectedVarE18) = consumer.quote(10 + i);
            assertApproxEqRel(expectedVarE18, vars[i] * 1e18, 1e9);
            assertApproxEqAbs(fee, vars[i], 1);
            assertGt(fee, prev);
            prev = fee;
        }
    }

    /// @dev Levels 0.2 and 0.3: midpoint weights tau_2 - tau_0 = 0.3 and 1 - tau_1 = 0.8, so
    ///      E = (0.3 * e^0 + 0.8 * e^(10 ln2)) / 1.1, not the plain mean of the two.
    function test_ExpectedVarUsesMidpointWeights() public {
        uint256[] memory levels = new uint256[](2);
        levels[0] = 2e17;
        levels[1] = 3e17;
        market.setLevels(levels);
        int256[] memory q = new int256[](2);
        q[0] = 0;
        q[1] = 10 * 0.693147180559945309e18;
        market.addForecast(0, alice, true, ZK_MODEL, q);
        _open();
        (, int256[] memory mix, uint256 expectedVarE18) = consumer.quote(0);
        assertEq(mix.length, 2);
        assertApproxEqRel(expectedVarE18, 744999999999999996892, 1e3);
        // a single median level prices exp(q) exactly
        levels = new uint256[](1);
        levels[0] = 5e17;
        market.setLevels(levels);
        q = new int256[](1);
        q[0] = 0;
        market.addForecast(1, alice, true, ZK_MODEL, q);
        (,, expectedVarE18) = consumer.quote(1);
        assertEq(expectedVarE18, 1e18);
    }

    /// @dev Quantiles outside [Q_MIN, Q_MAX] are clamped before exp instead of reverting.
    function test_MixClampedBeforeExp() public {
        market.addForecast(0, alice, true, ZK_MODEL, _flat(200e18));
        market.addForecast(1, alice, true, ZK_MODEL, _flat(-200e18));
        _open();
        (uint24 highFee,, uint256 highVar) = consumer.quote(0);
        assertEq(highVar, MarketMath.expWad(MarketMath.Q_MAX));
        assertEq(highFee, 10_000);
        (uint24 lowFee,, uint256 lowVar) = consumer.quote(1);
        assertEq(lowVar, MarketMath.expWad(MarketMath.Q_MIN));
        assertEq(lowFee, 100);
    }

    function test_FeeClampedToBounds() public {
        VolFeeConsumer clamped = _consumer(1e18, 500, 2000);
        market.addForecast(0, alice, true, ZK_MODEL, _flat(MarketMath.lnWad(100)));
        market.addForecast(1, alice, true, ZK_MODEL, _flat(MarketMath.lnWad(2500)));
        _open();
        (uint24 lowFee,, uint256 lowVar) = clamped.quote(0);
        (uint24 highFee,, uint256 highVar) = clamped.quote(1);
        assertApproxEqRel(lowVar, 100e18, 1e9);
        assertEq(lowFee, 500);
        assertApproxEqRel(highVar, 2500e18, 1e9);
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
        (uint24 feeBefore, int256[] memory mixBefore,) = consumer.quote(0);

        // committed, never revealed, and without reputation: neither its quantiles nor its missing
        // reputation may change the weighted result
        market.addForecast(0, carol, false, ZK_MODEL_2, _q(500));
        (uint24 feeAfter, int256[] memory mixAfter,) = consumer.quote(0);
        _assertMix(mixAfter, mixBefore);
        _assertMix(mixAfter, _weightedMixAB());
        assertEq(feeAfter, feeBefore);
    }

    /// @dev A revealed forecast with a different quantile count than the market's levels cannot be
    ///      mixed level by level and is skipped like an unrevealed one.
    function test_WrongLengthForecastIgnored() public {
        _addAB(0);
        _open();
        int256[] memory six = new int256[](6);
        market.addForecast(0, carol, true, ZK_MODEL_2, six);
        _assertMix(_mixOf(0), _equalMixAB());
        market.addForecast(1, carol, true, ZK_MODEL_2, new int256[](4));
        vm.expectRevert(VolFeeConsumer.NoForecasts.selector);
        consumer.quote(1);
    }

    function test_RevertsWithoutRevealedForecast() public {
        _open();
        vm.expectRevert(VolFeeConsumer.NoForecasts.selector);
        consumer.quote(0);
        market.addForecast(0, alice, false, ZK_MODEL, _qA());
        vm.expectRevert(VolFeeConsumer.NoForecasts.selector);
        consumer.quote(0);
    }

    // ------------------------------------------------------------ reputation sources
    function test_ReadsMainnetTupleSummary() public {
        _addAB(0);
        _bindAB();
        market.setReputationRegistry(address(tuple));
        // 6-decimal means: -0.109438 and -0.309438
        _rate(AGENT_A, TAG2_ZK, -109438, 6);
        _rate(AGENT_B, TAG2_COMMIT, -309438, 6);
        _open();
        int256[] memory mix = _mixOf(0);
        uint256 wa = uint256(-109438e12 - BASELINE);
        uint256 wb = uint256(-309438e12 - BASELINE);
        _assertMix(mix, _weightedMix(_qA(), _qB(), wa, wb));
        assertFalse(_same(mix, _equalMixAB()));

        // the same means at 18 decimals give the same mix
        _rate(AGENT_A, TAG2_ZK, -109438e12, 18);
        _rate(AGENT_B, TAG2_COMMIT, -309438e12, 18);
        _assertMix(_mixOf(0), mix);

        // count 0, decimals that cannot be upscaled, and a reverting registry mean no reputation
        tuple.setSummary(AGENT_B, address(market), TAG1, TAG2_COMMIT, 0, int128(BASELINE + 1e17), 18);
        _assertMix(_mixOf(0), _equalMixAB());
        _rate(AGENT_B, TAG2_COMMIT, -309438e12, 19);
        _assertMix(_mixOf(0), _equalMixAB());
        _rate(AGENT_B, TAG2_COMMIT, -309438e12, 18);
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
        market.addForecast(1, alice, true, ZK_MODEL, _qA());
        market.addForecast(1, carol, true, ZK_MODEL_2, _qB());
        market.bindAgent(ZK_MODEL_2, AGENT_C);
        _assertMix(_mixOf(1), _equalMixAB());
    }

    /// @dev Agent A gets a valid tuple summary 3e17 above the baseline; agent B gets `rawB`, so the
    ///      mix is weighted 3:1 only if `rawB` is read as a mean 1e17 above the baseline.
    function _rawAB(bytes memory rawB) internal returns (RawReputationRegistry raw) {
        raw = new RawReputationRegistry();
        market.setReputationRegistry(address(raw));
        _addAB(0);
        _bindAB();
        raw.setSummary(AGENT_A, abi.encode(uint256(1), BASELINE + 3e17, uint256(18)));
        raw.setSummary(AGENT_B, rawB);
        _open();
    }

    function test_TupleCountPastUint64IsNoReputation() public {
        RawReputationRegistry raw = _rawAB(abi.encode(uint256(1) << 64, BASELINE + 1e17, uint256(18)));
        _assertMix(_mixOf(0), _equalMixAB());
        raw.setSummary(AGENT_B, abi.encode(uint256(type(uint64).max), BASELINE + 1e17, uint256(18)));
        _assertMix(_mixOf(0), _weightedMixAB());
    }

    function test_TupleValueOutsideInt128IsNoReputation() public {
        RawReputationRegistry raw = _rawAB(abi.encode(uint256(1), int256(type(int128).max) + 1, uint256(18)));
        _assertMix(_mixOf(0), _equalMixAB());
        raw.setSummary(AGENT_B, abi.encode(uint256(1), int256(type(int128).min) - 1, uint256(18)));
        _assertMix(_mixOf(0), _equalMixAB());
        raw.setSummary(AGENT_B, abi.encode(uint256(1), int256(type(int128).min), uint256(18)));
        _assertMix(_mixOf(0), _qA());
    }

    function test_SummaryOfOtherLengthIsNoReputation() public {
        RawReputationRegistry raw = _rawAB(abi.encode(uint256(1), BASELINE + 1e17, uint256(18), uint256(0)));
        _assertMix(_mixOf(0), _equalMixAB());
        raw.setSummary(AGENT_B, abi.encode(uint256(1), BASELINE + 1e17, uint256(18)));
        _assertMix(_mixOf(0), _weightedMixAB());
    }

    function test_IntSummaryNeedsBothTagsMatching() public {
        RawReputationRegistry raw = _rawAB(abi.encode(BASELINE + 1e17));
        raw.setSummary(AGENT_A, abi.encode(BASELINE + 3e17));
        raw.addRecord(AGENT_A, TAG1, TAG2_ZK);
        raw.addRecord(AGENT_B, "logScore", TAG2_COMMIT);
        _assertMix(_mixOf(0), _equalMixAB());
        raw.addRecord(AGENT_B, TAG1, TAG2_COMMIT);
        _assertMix(_mixOf(0), _weightedMixAB());
    }

    /// @dev A single-int summary is an int128 average; a value past int128 would let the weight
    ///      reach 2^255 and wrap the signed mix, so it counts as no reputation.
    function test_IntSummaryOutsideInt128IsNoReputation() public {
        RawReputationRegistry raw = _rawAB(abi.encode(int256(type(int128).max) + 1));
        raw.setSummary(AGENT_A, abi.encode(BASELINE + 3e17));
        raw.addRecord(AGENT_A, TAG1, TAG2_ZK);
        raw.addRecord(AGENT_B, TAG1, TAG2_COMMIT);
        _assertMix(_mixOf(0), _equalMixAB());
        raw.setSummary(AGENT_B, abi.encode(type(int256).max));
        _assertMix(_mixOf(0), _equalMixAB());
        raw.setSummary(AGENT_B, abi.encode(BASELINE + 1e17));
        _assertMix(_mixOf(0), _weightedMixAB());
    }

    function test_IntSummaryWithUnreadableFeedbackIsNoReputation() public {
        RawReputationRegistry raw = _rawAB(abi.encode(BASELINE + 1e17));
        raw.setSummary(AGENT_A, abi.encode(BASELINE + 3e17));
        raw.addRecord(AGENT_A, TAG1, TAG2_ZK);
        raw.addRecord(AGENT_B, TAG1, TAG2_COMMIT);
        _assertMix(_mixOf(0), _weightedMixAB());
        raw.setFeedbackReverts(true);
        _assertMix(_mixOf(0), _equalMixAB());
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
        (uint24 fee,, uint256 expectedVarE18) = consumer.quote(0);
        assertEq(fee, 1336);
        vm.expectEmit(true, false, false, true, address(consumer));
        emit VolFeeConsumer.FeeRecorded(0, 1336, expectedVarE18, _weightedMixAB());
        assertEq(consumer.record(0), 1336);
        assertEq(consumer.feeOf(0), 1336);
        assertTrue(consumer.feeRecorded(0));
        vm.expectRevert(VolFeeConsumer.AlreadyRecorded.selector);
        consumer.record(0);
    }

    // ------------------------------------------------------------ constructor
    function test_ConstructorRejectsInvalidParams() public {
        IVolMarketReader m = IVolMarketReader(address(market));
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(IVolMarketReader(address(0)), TAG1, TAG2_ZK, TAG2_COMMIT, BASELINE, 1e18, 100, 200);
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, BASELINE, 1e18, 201, 200);
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, int256(type(int128).min) - 1, 1e18, 100, 200);
        vm.expectRevert(VolFeeConsumer.InvalidParams.selector);
        new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, int256(type(int128).max) + 1, 1e18, 100, 200);
        // equal fee bounds and the int128 ends are valid
        VolFeeConsumer c = new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, type(int128).min, 1e18, 200, 200);
        assertEq(c.baselineScore(), type(int128).min);
        new VolFeeConsumer(m, TAG1, TAG2_ZK, TAG2_COMMIT, type(int128).max, 1e18, 200, 200);
    }
}
