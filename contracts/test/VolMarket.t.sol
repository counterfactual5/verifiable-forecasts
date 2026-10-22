// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VolMarket} from "../src/VolMarket.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IUniswapV3PoolOracle} from "../src/interfaces/IUniswapV3PoolOracle.sol";
import {MarketMath} from "../src/lib/MarketMath.sol";
import {SpikeModelVerifier} from "../src/verifier/SpikeModelVerifier.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @dev Price feed whose latestRoundData costs `burn` gas before answering. The gas is burnt in a
///      sub-call, as a Chainlink proxy reads its aggregator: a starved sub-call fails while the feed
///      itself keeps 1/64 back and reverts without running out of gas.
contract GasHungryAggregator is AggregatorV3Interface {
    uint8 public constant override decimals = 8;
    uint256 public immutable burn;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint256 burn_) {
        burn = burn_;
    }

    function burnGas() external view {
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        this.burnGas();
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev MockPool front that, once `hungry` is set, reverts "OLD" on batches (so settle reads one
///      point at a time) and charges `burn` gas for the single read at `hungryAgo`.
contract GasHungryPool {
    MockPool public immutable inner;
    uint256 public immutable burn;
    bool public hungry;
    uint32 public hungryAgo;

    constructor(MockPool inner_, uint256 burn_) {
        inner = inner_;
        burn = burn_;
    }

    function setHungry(uint32 secondsAgo) external {
        hungry = true;
        hungryAgo = secondsAgo;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory) {
        if (hungry) {
            require(secondsAgos.length == 1, "OLD");
            if (secondsAgos[0] == hungryAgo) {
                uint256 start = gasleft();
                while (start - gasleft() < burn) {}
            }
        }
        return inner.observe(secondsAgos);
    }
}

contract VolMarketTest is Test {
    uint32 constant DELTA = 300;
    uint8 constant N = 12;
    uint256 constant T0 = 1_000_000; // createRound time
    uint64 constant START = uint64(T0 + 600);
    uint256 constant END = START + uint256(N) * DELTA;

    MockERC20 token;
    MockPool pool;
    VolMarket market;
    MockAggregator feed;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    string proofJson;

    function setUp() public {
        token = new MockERC20();
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; ++i) {
            token.mint(users[i], 1_000_000e18);
        }
        proofJson = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/spike_model_proof.json"));
    }

    // -------- helpers --------------------------------------------------

    function _bounds() internal pure returns (uint256[] memory b) {
        b = new uint256[](4);
        b[0] = 8;
        b[1] = 20;
        b[2] = 45;
        b[3] = 110;
    }

    function _t(uint256 k) internal pure returns (uint256) {
        return START + k * DELTA;
    }

    /// @dev Fresh pool with flat history before START, and a market on it with approvals.
    function _deploy(uint256 feeBps) internal {
        pool = new MockPool();
        pool.setTickFrom(T0 - 20 * uint256(DELTA), 196000);
        market = new VolMarket(IERC20(address(token)), feeBps, IUniswapV3PoolOracle(address(pool)), DELTA, N);
        feed = new MockAggregator(8, 2000e8);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; ++i) {
            vm.prank(users[i]);
            token.approve(address(market), type(uint256).max);
        }
    }

    function _segments(int24[12] memory ticks) internal {
        for (uint256 k = 0; k < N; ++k) {
            pool.setTickFrom(_t(k), ticks[k]);
        }
    }

    /// @dev Segment ticks giving means diffs 2,-3,4,0,-1,-2,1,-2,0,3,-1 => RV 49, bucket 3.
    function _mixed() internal pure returns (int24[12] memory) {
        return [int24(196000), 196002, 195999, 196003, 196003, 196002, 196000, 196001, 195999, 195999, 196002, 196001];
    }

    function _create() internal returns (uint256 id) {
        vm.warp(T0);
        id = market.createRound(START, _bounds());
    }

    function _settleAfterWindow(uint256 id) internal {
        vm.warp(END + 10);
        market.settle(id);
    }

    function _rv(uint256 id) internal view returns (bool voided, uint256 bucket, uint256 rv) {
        (, bool settled, bool v, uint256 b, uint256 r,,,) = market.getRound(id);
        assertTrue(settled, "settled");
        return (v, b, r);
    }

    /// @dev Pool timeline for the proof fixture: 17 constant segments ending at T0, last tick continues.
    function _deployProofPool(int256[] memory segTicks) internal {
        pool = new MockPool();
        for (uint256 j = 0; j < segTicks.length; ++j) {
            pool.setTickFrom(T0 - (17 - j) * uint256(DELTA), int24(segTicks[j]));
        }
        market = new VolMarket(IERC20(address(token)), 0, IUniswapV3PoolOracle(address(pool)), DELTA, N);
        market.registerModel(address(new SpikeModelVerifier()), alice);
    }

    function _proof() internal view returns (bytes memory) {
        return vm.parseJsonBytes(proofJson, ".proof");
    }

    function _outputs() internal view returns (uint256[5] memory out) {
        uint256[] memory o = vm.parseJsonUintArray(proofJson, ".outputs");
        assertEq(o.length, 5);
        for (uint256 i = 0; i < 5; ++i) {
            out[i] = o[i];
        }
    }

    function _segTicks() internal view returns (int256[] memory) {
        return vm.parseJsonIntArray(proofJson, ".segmentTicks");
    }

    // -------- settlement from observe ----------------------------------

    function test_SegmentedSettleFromObserve() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();

        vm.warp(END - 1);
        vm.expectRevert(VolMarket.SamplingOngoing.selector);
        market.settle(id);

        _settleAfterWindow(id);
        (bool voided, uint256 bucket, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertEq(rv, 49);
        assertEq(bucket, 3);
        (bool sampled,) = market.getCheckpoint(id, 0);
        assertFalse(sampled, "settled purely from observe");

        vm.expectRevert(VolMarket.AlreadySettled.selector);
        market.settle(id);
    }

    function test_NegativeTickFloorDiv() public {
        _deploy(0);
        // tick -1 throughout except 1 s of -2 opening segment 4: its sum is -301 over 300 s, so
        // floorDiv gives -2 (truncation would give -1 and RV 0)
        pool.setTickFrom(_t(0), -1);
        pool.setTickFrom(_t(4), -2);
        pool.setTickFrom(_t(4) + 1, -1);
        uint256 id = _create();
        _settleAfterWindow(id);
        (bool voided, uint256 bucket, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertEq(rv, 2);
        assertEq(bucket, 0);
    }

    function test_RvCasesFixture() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/vol_rv_cases.json"));
        assertEq(vm.parseJsonUint(json, ".delta"), DELTA);
        assertEq(vm.parseJsonUint(json, ".nSegments"), N);
        uint256[] memory b = vm.parseJsonUintArray(json, ".bounds");
        uint256[] memory mine = _bounds();
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(b[i], mine[i], "bounds");
        }

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".cases[", vm.toString(n), "]"))) {
            _checkCase(json, string.concat(".cases[", vm.toString(n), "]"));
            ++n;
        }
        assertGe(n, 6, "case count");
    }

    function _checkCase(string memory json, string memory key) internal {
        string memory name = vm.parseJsonString(json, string.concat(key, ".name"));
        uint256[] memory offsets = vm.parseJsonUintArray(json, string.concat(key, ".timeline.offsets"));
        int256[] memory ticks = vm.parseJsonIntArray(json, string.concat(key, ".timeline.ticks"));
        uint256[] memory missing = vm.parseJsonUintArray(json, string.concat(key, ".missing"));

        _deploy(0);
        for (uint256 i = 0; i < offsets.length; ++i) {
            pool.setTickFrom(START + offsets[i], int24(ticks[i]));
        }
        uint256 id = _create();

        // a missing checkpoint k is made unreadable by sampling every earlier readable point and
        // then moving the pool's lookback limit past t_kmax
        uint256 kmax;
        uint256 missMask;
        for (uint256 i = 0; i < missing.length; ++i) {
            missMask |= 1 << missing[i];
            if (missing[i] > kmax) kmax = missing[i];
        }
        if (missing.length > 0) {
            for (uint256 k = 0; k < kmax; ++k) {
                if (missMask & (1 << k) != 0) continue;
                vm.warp(_t(k));
                market.sample(id, k);
            }
        }
        vm.warp(END + 10);
        if (missing.length > 0) pool.setOldest(_t(kmax) + 1);
        market.settle(id);

        (bool voided, uint256 bucket, uint256 rv) = _rv(id);
        assertEq(voided, vm.parseJsonBool(json, string.concat(key, ".voided")), name);
        if (!voided) {
            assertEq(rv, vm.parseJsonUint(json, string.concat(key, ".rv")), name);
            assertEq(bucket, vm.parseJsonUint(json, string.concat(key, ".bucket")), name);
        }
    }

    function test_SampleFallbackWhenObserveTooOld() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();

        vm.warp(_t(0) - 1);
        vm.expectRevert(VolMarket.CheckpointNotReached.selector);
        market.sample(id, 0);

        for (uint256 k = 0; k <= N; ++k) {
            vm.warp(_t(k) + 7);
            market.sample(id, k);
        }
        vm.expectRevert(VolMarket.AlreadySampled.selector);
        market.sample(id, N);

        vm.warp(END + 3 hours);
        pool.setOldest(END + 1);
        vm.expectRevert(bytes("OLD"));
        pool.tickCumulativeAt(_t(0));

        market.settle(id);
        (bool voided, uint256 bucket, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertEq(rv, 49);
        assertEq(bucket, 3);
    }

    // -------- Chainlink price cross-check -----------------------------

    function test_PriceFeedMatchingPriceSettles() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        market.setPriceFeed(address(feed));
        vm.warp(END + 10);
        feed.setAnswer(int256(market.priceForTick(196001)), block.timestamp);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided);
    }

    function test_PriceFeedDeviationVoidsAndRefunds() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        market.setPriceFeed(address(feed));
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        feed.setAnswer(3000e8, block.timestamp);
        vm.warp(END + 10);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - before, 100e18);
    }

    function test_PriceFeedStaleVoidsAndRefunds() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        market.setPriceFeed(address(feed));
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        feed.setAnswer(2000e8, block.timestamp);
        vm.warp(END + 4000);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - before, 100e18);
    }

    function test_PriceFeedInvalidAnswerVoidsAndRefunds() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        market.setPriceFeed(address(feed));
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        feed.setAnswer(0, block.timestamp);
        vm.warp(END + 10);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
    }

    /// @dev Sweeps settle's gas limit through the range where a 450k-gas feed read (under the
    ///      market's per-call cap) gets less than it needs: a matching price must never void the
    ///      round for lack of gas.
    function test_LowGasSettleCannotSkipPriceCheck() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        GasHungryAggregator hungry = new GasHungryAggregator(450_000);
        market.setPriceFeed(address(hungry));
        vm.warp(END + 10);
        hungry.setAnswer(int256(market.priceForTick(196001)), block.timestamp);

        uint256 settled;
        uint256 guarded;
        for (uint256 gasLimit = 200_000; gasLimit <= 1_200_000; gasLimit += 4_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(market).call{gas: gasLimit}(abi.encodeCall(VolMarket.settle, (id)));
            if (ok) {
                ++settled;
                (bool voided,,) = _rv(id);
                assertFalse(voided, "matching price voided by a starved feed read");
            } else if (bytes4(ret) == VolMarket.InsufficientGas.selector) {
                ++guarded;
            }
            vm.revertToState(snap);
        }
        assertGt(settled, 0, "some limit settles");
        assertGt(guarded, 0, "some limit is stopped by the gas guard");
    }

    /// @dev Checkpoints 11 and 12 are read one by one, the last at 6M gas: the read must cost more
    ///      than 63x the work settle does after it for a starved read to leave settle enough gas to
    ///      finish. Sweeping settle's gas limit through that read must never settle without it
    ///      (RV 52 over 12 points instead of 49).
    function test_LowGasSettleCannotSkipObservePoint() public {
        MockPool inner = new MockPool();
        inner.setTickFrom(T0 - 20 * uint256(DELTA), 196000);
        pool = inner;
        _segments(_mixed());
        GasHungryPool hungry = new GasHungryPool(inner, 6_000_000);
        market = new VolMarket(IERC20(address(token)), 0, IUniswapV3PoolOracle(address(hungry)), DELTA, N);
        uint256 id = _create();
        for (uint256 k = 0; k < N - 1; ++k) {
            vm.warp(_t(k) + 1);
            market.sample(id, k);
        }
        vm.warp(END + 10);
        hungry.setHungry(10);

        uint256 settled;
        uint256 guarded;
        for (uint256 gasLimit = 4_500_000; gasLimit <= 6_400_000; gasLimit += 30_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(market).call{gas: gasLimit}(abi.encodeCall(VolMarket.settle, (id)));
            if (ok) {
                ++settled;
                (bool voided,, uint256 rv) = _rv(id);
                assertFalse(voided);
                assertEq(rv, 49, "settled with a checkpoint dropped for lack of gas");
            } else if (bytes4(ret) == VolMarket.InsufficientGas.selector) {
                ++guarded;
            }
            vm.revertToState(snap);
        }
        assertGt(settled, 0, "some limit settles");
        assertGt(guarded, 0, "some limit is stopped by the gas guard");
    }

    function test_TickToPriceMatchesReference() public {
        _deploy(0);
        assertApproxEqAbs(market.priceForTick(196000), 3078e8, 2e10);
        assertApproxEqAbs(market.priceForTick(195900), 3080e8, 3e10);
    }

    function test_NoPriceFeedKeepsBehavior() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        _settleAfterWindow(id);
        (bool voided,, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertEq(rv, 49);
    }

    function test_RealProofAccepted() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();

        int256[16] memory feats = market.getFeatures(id);
        int256[] memory want = vm.parseJsonIntArray(proofJson, ".features");
        assertEq(want.length, 16);
        bool pos;
        bool neg;
        for (uint256 j = 0; j < 16; ++j) {
            assertEq(feats[j], want[j], "feature");
            assertLe(feats[j] < 0 ? -feats[j] : feats[j], 4096);
            pos = pos || feats[j] > 0;
            neg = neg || feats[j] < 0;
        }
        assertTrue(pos && neg);

        uint256[5] memory out = _outputs();
        vm.prank(alice);
        market.submitPrediction(id, 0, _proof(), out);

        (bool recorded, uint256 modelId, uint256[5] memory probs,) = market.getPrediction(id, alice);
        assertTrue(recorded);
        assertEq(modelId, 0);
        uint256 sum = out[0] + out[1] + out[2] + out[3] + out[4];
        uint256 total;
        for (uint256 i = 0; i < 5; ++i) {
            if (i < 4) assertEq(probs[i], out[i] * 1e18 / sum);
            total += probs[i];
        }
        assertEq(total, 1e18);
        assertEq(market.predictorCount(id), 1);

        vm.prank(alice);
        vm.expectRevert(VolMarket.AlreadyPredicted.selector);
        market.submitPrediction(id, 0, _proof(), out);
    }

    function test_RealProofScoredAtSettle() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        vm.prank(alice);
        market.submitPrediction(id, 0, _proof(), _outputs());

        vm.warp(START);
        vm.prank(bob);
        vm.expectRevert(VolMarket.TooLateToPredict.selector);
        market.submitPrediction(id, 0, _proof(), _outputs());

        // the last fixture tick continues through the window: RV 0, bucket 0
        _settleAfterWindow(id);
        (bool voided, uint256 bucket, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertEq(rv, 0);
        assertEq(bucket, 0);
        (,, uint256[5] memory probs, int256 score) = market.getPrediction(id, alice);
        assertEq(score, MarketMath.log1e18(probs[0]));
        assertLt(score, 0);
    }

    function test_TamperedProofRejected() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        bytes memory proof = _proof();
        proof[1000] = bytes1(uint8(proof[1000]) ^ 0x01);
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.submitPrediction(id, 0, proof, _outputs());
        (bool recorded,,,) = market.getPrediction(id, alice);
        assertFalse(recorded);
    }

    function test_TamperedOutputsRejected() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        uint256[5] memory out = _outputs();
        out[0] += 1;
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.submitPrediction(id, 0, _proof(), out);

        out[0] = market.FIELD_R() / 2;
        vm.prank(alice);
        vm.expectRevert(VolMarket.BadOutputs.selector);
        market.submitPrediction(id, 0, _proof(), out);

        vm.prank(alice);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.submitPrediction(id, 1, _proof(), _outputs());
    }

    function test_FeatureMismatchRejected() public {
        int256[] memory segTicks = _segTicks();
        segTicks[8] += 1;
        _deployProofPool(segTicks);
        uint256 id = _create();

        int256[16] memory feats = market.getFeatures(id);
        int256[] memory fixtureFeats = vm.parseJsonIntArray(proofJson, ".features");
        assertEq(feats[7], fixtureFeats[7] + 128);
        assertEq(feats[8], fixtureFeats[8] - 128);

        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.submitPrediction(id, 0, _proof(), _outputs());
    }

    function test_RegisterModelOnlyOwner() public {
        _deploy(0);
        vm.prank(alice);
        vm.expectRevert(VolMarket.NotOwner.selector);
        market.registerModel(address(1), alice);
        assertEq(market.registerModel(address(1), alice), 0);
        assertEq(market.registerModel(address(2), bob), 1);
        assertEq(market.modelCount(), 2);
        assertEq(market.modelOperator(1), bob);
    }

    function test_CopiedProofFromOtherSenderRejected() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        vm.prank(bob);
        vm.expectRevert(VolMarket.NotModelOperator.selector);
        market.submitPrediction(id, 0, _proof(), _outputs());
        vm.prank(alice);
        market.submitPrediction(id, 0, _proof(), _outputs());
        assertEq(market.predictorCount(id), 1);
    }

    function test_PredictorCapEnforced() public {
        _deployProofPool(_segTicks());
        uint256 cap = market.MAX_PREDICTORS();
        for (uint256 i = 0; i < cap; ++i) {
            market.registerModel(address(new SpikeModelVerifier()), address(uint160(0x1000 + i)));
        }
        uint256 id = _create();
        for (uint256 i = 0; i < cap; ++i) {
            vm.prank(address(uint160(0x1000 + i)));
            market.submitPrediction(id, i + 1, _proof(), _outputs());
        }
        assertEq(market.predictorCount(id), cap);
        vm.prank(alice);
        vm.expectRevert(VolMarket.TooManyPredictors.selector);
        market.submitPrediction(id, 0, _proof(), _outputs());
    }

    // -------- parimutuel ------------------------------------------------

    function test_ParimutuelPayout() public {
        _deploy(100); // 1% fee
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(carol);
        market.bet(id, 3, 300e18);
        vm.prank(bob);
        market.bet(id, 0, 600e18);

        vm.warp(START);
        vm.prank(bob);
        vm.expectRevert(VolMarket.BettingClosed.selector);
        market.bet(id, 0, 1);

        _settleAfterWindow(id);
        (, uint256 bucket,) = _rv(id);
        assertEq(bucket, 3);

        // pool 1000, fee 10, winners 400 => alice 100/400 * 990, carol 300/400 * 990
        uint256 a0 = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - a0, 247.5e18);
        uint256 c0 = token.balanceOf(carol);
        vm.prank(carol);
        market.claim(id);
        assertEq(token.balanceOf(carol) - c0, 742.5e18);

        vm.prank(bob);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claim(id);
    }

    /// @dev Three winners on bucket 3 and one loser; every winner can claim, payouts never fall
    ///      below the pro-rata floor, and the winners split exactly total - fee.
    function testFuzz_WinnersSplitExactlyTotalMinusFee(uint256[3] memory win, uint256 lose, uint256 feeBps) public {
        feeBps = bound(feeBps, 0, 999);
        lose = bound(lose, 1, 1e24);
        _deploy(feeBps);
        _segments(_mixed());
        uint256 id = _create();
        address[3] memory winners = [alice, carol, makeAddr("dave")];
        token.mint(winners[2], 1_000_000e18);
        vm.prank(winners[2]);
        token.approve(address(market), type(uint256).max);
        uint256 winPool;
        for (uint256 i = 0; i < 3; ++i) {
            win[i] = bound(win[i], 1, 1e24);
            winPool += win[i];
            vm.prank(winners[i]);
            market.bet(id, 3, win[i]);
        }
        vm.prank(bob);
        market.bet(id, 0, lose);
        uint256 total = winPool + lose;
        uint256 fee = MarketMath.fee(total, feeBps);

        _settleAfterWindow(id);
        uint256 paid;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 b0 = token.balanceOf(winners[i]);
            vm.prank(winners[i]);
            market.claim(id);
            uint256 got = token.balanceOf(winners[i]) - b0;
            assertGe(got, MarketMath.payout(win[i], total, winPool, feeBps), "below pro-rata floor");
            paid += got;
        }
        assertEq(paid, total - fee, "winners split total - fee");
        assertEq(token.balanceOf(address(market)), fee, "only the fee remains");

        if (fee > 0) {
            market.collectFee(id);
            assertEq(token.balanceOf(address(this)), fee, "owner receives the fee");
        }
        assertEq(token.balanceOf(address(market)), 0, "round fully drained");
    }

    function test_CollectFeeOnceAfterSettle() public {
        _deploy(100);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(bob);
        market.bet(id, 0, 900e18);

        vm.expectRevert(VolMarket.RoundNotSettled.selector);
        market.collectFee(id);

        _settleAfterWindow(id);
        vm.prank(bob);
        vm.expectEmit(true, false, false, true, address(market));
        emit VolMarket.FeeCollected(id, 10e18);
        market.collectFee(id);
        assertEq(token.balanceOf(address(this)), 10e18, "fee goes to owner, whoever calls");

        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.collectFee(id);

        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_NoFeeOnRefundedRounds() public {
        _deploy(100);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        _settleAfterWindow(id);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.collectFee(id);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_DoubleClaimReverts() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(bob);
        market.bet(id, 1, 100e18);

        vm.prank(alice);
        vm.expectRevert(VolMarket.RoundNotSettled.selector);
        market.claim(id);

        _settleAfterWindow(id);
        vm.prank(alice);
        market.claim(id);
        vm.prank(alice);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claim(id);
    }

    function test_LowCoverageVoidsAndRefunds() public {
        _deploy(100);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(bob);
        market.bet(id, 1, 250e18);
        uint256 a0 = token.balanceOf(alice);
        uint256 b0 = token.balanceOf(bob);

        // checkpoints 0 and 1 fall out of the pool's history before anyone samples them
        vm.warp(END + 10);
        pool.setOldest(_t(1) + 1);
        vm.expectEmit(true, false, false, false, address(market));
        emit VolMarket.RoundVoided(id);
        market.settle(id);

        (bool voided,, uint256 rv) = _rv(id);
        assertTrue(voided);
        assertEq(rv, 0);

        vm.prank(alice);
        market.claim(id);
        vm.prank(bob);
        market.claim(id);
        assertEq(token.balanceOf(alice) - a0, 100e18);
        assertEq(token.balanceOf(bob) - b0, 250e18);
        vm.prank(bob);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claim(id);
    }

    function test_OneMissingPointStillSettles() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        vm.warp(END + 10);
        pool.setOldest(_t(0) + 1);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided);
    }

    function test_NoWinnerRefunds() public {
        _deploy(100);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        uint256 a0 = token.balanceOf(alice);
        _settleAfterWindow(id);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - a0, 100e18);
    }

    function test_CreateRoundValidation() public {
        _deploy(0);
        vm.warp(T0);
        uint256[] memory b = _bounds();
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(uint64(T0), b);
        b[2] = b[1];
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b);
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, new uint256[](5));
    }
}
