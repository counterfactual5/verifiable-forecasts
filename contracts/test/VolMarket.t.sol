// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
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

contract RevertingAggregator is AggregatorV3Interface {
    uint8 public constant override decimals = 8;

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("feed down");
    }
}

contract NoDecimalsAggregator is AggregatorV3Interface {
    int256 public immutable answer;

    constructor(int256 answer_) {
        answer = answer_;
    }

    function decimals() external pure override returns (uint8) {
        revert("no decimals");
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
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
    uint32 constant COMMIT_LEAD = 300;
    uint32 constant REVEAL_LEAD = 120;
    uint256 constant COMMIT_END = START - COMMIT_LEAD;
    uint256 constant REVEAL_END = START - REVEAL_LEAD;

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
        _deploy(feeBps, 0);
    }

    function _deploy(uint256 feeBps, uint256 shareBps) internal {
        pool = new MockPool();
        pool.setTickFrom(T0 - 20 * uint256(DELTA), 196000);
        market = _market(feeBps, shareBps, address(pool));
        feed = new MockAggregator(8, 2000e8);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; ++i) {
            vm.prank(users[i]);
            token.approve(address(market), type(uint256).max);
        }
    }

    function _market(uint256 feeBps, uint256 shareBps, address pool_) internal returns (VolMarket) {
        return new VolMarket(
            IERC20(address(token)), feeBps, shareBps, IUniswapV3PoolOracle(pool_), DELTA, N, COMMIT_LEAD, REVEAL_LEAD
        );
    }

    function _salt(address who) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", who));
    }

    function _commitment(uint256 id, uint256 modelId, uint256[5] memory out, bytes32 salt, address who)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(id, modelId, out, salt, who));
    }

    function _commit(uint256 id, uint256 modelId, address who, uint256[5] memory out) internal {
        vm.prank(who);
        market.commitPrediction(id, modelId, _commitment(id, modelId, out, _salt(who), who));
    }

    function _reveal(uint256 id, address who, bytes memory proof, uint256[5] memory out) internal {
        vm.prank(who);
        market.revealPrediction(id, proof, out, _salt(who));
    }

    /// @dev Commit during the commit phase, then reveal at the start of the reveal phase.
    function _commitReveal(uint256 id, uint256 modelId, address who, bytes memory proof, uint256[5] memory out)
        internal
    {
        _commit(id, modelId, who, out);
        vm.warp(COMMIT_END);
        _reveal(id, who, proof, out);
    }

    /// @dev Registers a commit-only model operated by `who` and commits `probs` with it.
    function _commitOnly(uint256 id, address who, uint256[5] memory probs) internal returns (uint256 modelId) {
        modelId = market.registerModel(address(0), who);
        _commit(id, modelId, who, probs);
    }

    /// @dev 1e18-scaled forecast with `pWin` on bucket `win` and the rest spread over the others.
    function _probs(uint256 win, uint256 pWin) internal pure returns (uint256[5] memory p) {
        uint256 rest = 1e18 - pWin;
        uint256 assigned = pWin;
        p[win] = pWin;
        uint256 last = win == 4 ? 3 : 4;
        for (uint256 i = 0; i < 5; ++i) {
            if (i == win || i == last) continue;
            p[i] = rest / 4;
            assigned += p[i];
        }
        p[last] = 1e18 - assigned;
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
        market = _market(0, 0, address(pool));
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
        vm.warp(END + 10);
        feed.setAnswer(3000e8, block.timestamp);
        _expectPriceCheckFailed(id, 196001, 3000e8, 4);
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
        int256 matching = int256(market.priceForTick(196001));
        feed.setAnswer(matching, END + 10);
        vm.warp(END + 10 + 4000);
        _expectPriceCheckFailed(id, 196001, matching, 2);
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
        vm.warp(END + 10);
        feed.setAnswer(0, block.timestamp);
        _expectPriceCheckFailed(id, 196001, 0, 2);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - before, 100e18);

        _deploy(0);
        _segments(_mixed());
        id = _create();
        market.setPriceFeed(address(feed));
        vm.warp(END + 10);
        int256 matching = int256(market.priceForTick(196001));
        feed.setAnswer(matching, block.timestamp + 1);
        _expectPriceCheckFailed(id, 196001, matching, 2);
        market.settle(id);
        (voided,,) = _rv(id);
        assertTrue(voided, "answer from the future");
    }

    function test_PriceFeedRevertVoids() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        market.setPriceFeed(address(new RevertingAggregator()));
        vm.warp(END + 10);
        _expectPriceCheckFailed(id, 196001, 0, 5);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
    }

    function test_PriceFeedDecimalsRevertVoids() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        int256 matching = int256(market.priceForTick(196001));
        market.setPriceFeed(address(new NoDecimalsAggregator(matching)));
        vm.warp(END + 10);
        _expectPriceCheckFailed(id, 196001, matching, 3);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
    }

    function test_PriceFeedAgeBoundary() public {
        uint256 maxAge = 3900;
        _deploy(0);
        assertEq(market.MAX_FEED_AGE(), maxAge);
        int256 matching = int256(market.priceForTick(196001));
        _segments(_mixed());
        uint256 id = _create();
        market.setPriceFeed(address(feed));
        vm.warp(END + 10 + maxAge);
        feed.setAnswer(matching, END + 10);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided, "age exactly MAX_FEED_AGE settles");

        _deploy(0);
        _segments(_mixed());
        id = _create();
        market.setPriceFeed(address(feed));
        vm.warp(END + 10 + maxAge + 1);
        feed.setAnswer(matching, END + 10);
        _expectPriceCheckFailed(id, 196001, matching, 2);
        market.settle(id);
        (voided,,) = _rv(id);
        assertTrue(voided, "one second older voids");
    }

    /// @dev feedPrice = 50 * poolPrice / 51 puts the deviation at exactly MAX_DEVIATION_BPS, so the
    ///      last segment's tick is searched for a pool price divisible by 51.
    function test_PriceFeedDeviationBoundary() public {
        _deploy(0);
        assertEq(market.MAX_DEVIATION_BPS(), 200);
        int24 tick = 196001;
        while (market.priceForTick(tick) % 51 != 0) {
            ++tick;
            assertLt(tick, 196001 + 1000, "no tick with a pool price divisible by 51");
        }
        uint256 poolPrice = market.priceForTick(tick);
        int256 atLimit = int256(poolPrice * 50 / 51);
        assertEq((poolPrice - uint256(atLimit)) * 10_000, uint256(atLimit) * 200, "exactly 200 bps");

        uint256 id = _roundEndingAtTick(tick);
        feed.setAnswer(atLimit, block.timestamp);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided, "exactly MAX_DEVIATION_BPS settles");

        id = _roundEndingAtTick(tick);
        feed.setAnswer(atLimit - 1, block.timestamp);
        _expectPriceCheckFailed(id, tick, atLimit - 1, 4);
        market.settle(id);
        (voided,,) = _rv(id);
        assertTrue(voided, "one unit beyond voids");
    }

    /// @dev Mirror of the boundary above with the pool below the feed: feedPrice = 50 * poolPrice / 49
    ///      puts the deviation at exactly MAX_DEVIATION_BPS of the feed price.
    function test_PriceFeedDeviationBelowFeedBoundary() public {
        _deploy(0);
        int24 tick = 196001;
        while (market.priceForTick(tick) % 49 != 0) {
            ++tick;
            assertLt(tick, 196001 + 1000, "no tick with a pool price divisible by 49");
        }
        uint256 poolPrice = market.priceForTick(tick);
        int256 atLimit = int256(poolPrice * 50 / 49);
        assertEq((uint256(atLimit) - poolPrice) * 10_000, uint256(atLimit) * 200, "exactly 200 bps");

        uint256 id = _roundEndingAtTick(tick);
        feed.setAnswer(atLimit, block.timestamp);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided, "exactly MAX_DEVIATION_BPS below the feed settles");

        id = _roundEndingAtTick(tick);
        feed.setAnswer(atLimit + 1, block.timestamp);
        _expectPriceCheckFailed(id, tick, atLimit + 1, 4);
        market.settle(id);
        (voided,,) = _rv(id);
        assertTrue(voided, "one unit beyond below the feed voids");
    }

    function test_PriceFeedDecimalsScaled() public {
        _deploy(0);
        uint256 price = market.priceForTick(196001);

        uint256 id = _roundWithFeed(new MockAggregator(6, int256(price / 100)));
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided, "6-decimal feed scaled up");

        id = _roundWithFeed(new MockAggregator(18, int256(price * 1e10)));
        market.settle(id);
        (voided,,) = _rv(id);
        assertFalse(voided, "18-decimal feed scaled down");

        id = _roundWithFeed(new MockAggregator(19, int256(price * 1e11)));
        _expectPriceCheckFailed(id, 196001, int256(price * 1e11), 3);
        market.settle(id);
        (voided,,) = _rv(id);
        assertTrue(voided, "more than 18 decimals voids");
    }

    /// @dev Fresh market and round on _mixed(), checked against `agg` with a fresh answer at END + 10.
    function _roundWithFeed(MockAggregator agg) internal returns (uint256 id) {
        int256 answer = agg.answer();
        _deploy(0);
        _segments(_mixed());
        id = _create();
        market.setPriceFeed(address(agg));
        vm.warp(END + 10);
        agg.setAnswer(answer, block.timestamp);
    }

    /// @dev Fresh round whose price check window [END, END + DELTA] sits entirely on `tick`.
    function _roundEndingAtTick(int24 tick) internal returns (uint256 id) {
        _deploy(0);
        _segments(_mixed());
        pool.setTickFrom(END, tick);
        id = _create();
        market.setPriceFeed(address(feed));
        vm.warp(END + DELTA);
    }

    function _expectPriceCheckFailed(uint256 id, int24 tick, int256 feedPrice, uint8 reason) internal {
        vm.expectEmit(true, false, false, true, address(market));
        emit VolMarket.PriceCheckFailed(id, tick, int256(market.priceForTick(tick)), feedPrice, reason);
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
        market = _market(0, 0, address(hungry));
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
        _commit(id, 0, alice, out);
        vm.prank(alice);
        vm.expectRevert(VolMarket.AlreadyPredicted.selector);
        market.commitPrediction(id, 0, bytes32(uint256(1)));

        vm.warp(COMMIT_END);
        _reveal(id, alice, _proof(), out);

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
        vm.expectRevert(VolMarket.AlreadyRevealed.selector);
        market.revealPrediction(id, _proof(), out, _salt(alice));
    }

    function test_RealProofScoredAtSettle() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        _commitReveal(id, 0, alice, _proof(), _outputs());

        vm.warp(START);
        vm.prank(bob);
        vm.expectRevert(VolMarket.TooLateToPredict.selector);
        market.commitPrediction(id, 0, bytes32(uint256(1)));

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
        _commit(id, 0, alice, _outputs());
        vm.warp(COMMIT_END);
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, proof, _outputs(), _salt(alice));
        (bool recorded,,,) = market.getPrediction(id, alice);
        assertFalse(recorded);
    }

    function test_TamperedOutputsRejected() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.commitPrediction(id, 1, bytes32(uint256(1)));

        uint256[5] memory out = _outputs();
        out[0] += 1;
        _commit(id, 0, alice, out);
        vm.warp(COMMIT_END);
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, _proof(), out, _salt(alice));

        out[0] = market.FIELD_R() / 2;
        vm.prank(alice);
        vm.expectRevert(VolMarket.BadOutputs.selector);
        market.revealPrediction(id, _proof(), out, _salt(alice));
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

        _commit(id, 0, alice, _outputs());
        vm.warp(COMMIT_END);
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, _proof(), _outputs(), _salt(alice));
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
        market.commitPrediction(id, 0, _commitment(id, 0, _outputs(), _salt(bob), bob));
        _commitReveal(id, 0, alice, _proof(), _outputs());
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
            _commit(id, i + 1, address(uint160(0x1000 + i)), _outputs());
        }
        assertEq(market.predictorCount(id), cap);
        vm.prank(alice);
        vm.expectRevert(VolMarket.TooManyPredictors.selector);
        market.commitPrediction(id, 0, bytes32(uint256(1)));
    }

    // -------- commit-reveal ----------------------------------------------

    function test_ForecastHiddenUntilRevealWindow() public {
        _deploy(0);
        uint256 id = _create();
        uint256[5] memory p = _probs(3, 0.6e18);
        uint256 modelId = _commitOnly(id, alice, p);

        assertEq(market.getCommitment(id, alice), _commitment(id, modelId, p, _salt(alice), alice));
        (bool recorded,, uint256[5] memory shown,) = market.getPrediction(id, alice);
        assertFalse(recorded, "nothing public before reveal");
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(shown[i], 0);
        }

        vm.warp(COMMIT_END - 1);
        vm.prank(alice);
        vm.expectRevert(VolMarket.RevealNotOpen.selector);
        market.revealPrediction(id, "", p, _salt(alice));

        vm.warp(COMMIT_END);
        vm.prank(bob);
        vm.expectRevert(VolMarket.TooLateToPredict.selector);
        market.commitPrediction(id, modelId, bytes32(uint256(1)));

        vm.warp(REVEAL_END);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vm.expectRevert(VolMarket.TooLateToReveal.selector);
        market.revealPrediction(id, "", p, _salt(alice));
        vm.revertToState(snap);

        vm.warp(REVEAL_END - 1);
        _reveal(id, alice, "", p);
        (recorded,, shown,) = market.getPrediction(id, alice);
        assertTrue(recorded, "public before the window starts");
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(shown[i], p[i]);
        }
    }

    function test_RevealMustMatchCommitment() public {
        _deploy(0);
        uint256 id = _create();
        uint256[5] memory p = _probs(3, 0.6e18);
        _commitOnly(id, alice, p);
        vm.warp(COMMIT_END);

        vm.prank(bob);
        vm.expectRevert(VolMarket.NotCommitted.selector);
        market.revealPrediction(id, "", p, _salt(bob));

        vm.prank(alice);
        vm.expectRevert(VolMarket.CommitmentMismatch.selector);
        market.revealPrediction(id, "", p, _salt(bob));

        uint256[5] memory other = _probs(2, 0.6e18);
        vm.prank(alice);
        vm.expectRevert(VolMarket.CommitmentMismatch.selector);
        market.revealPrediction(id, "", other, _salt(alice));

        _reveal(id, alice, "", p);
        vm.prank(alice);
        vm.expectRevert(VolMarket.AlreadyRevealed.selector);
        market.revealPrediction(id, "", p, _salt(alice));
    }

    /// @dev Bob copies Alice's commitment from her transaction; once Alice reveals he knows her
    ///      outputs and salt, but the commitment binds her address and model, so he cannot reveal
    ///      it, and the commit phase is already over for a fresh one.
    function test_CopiedCommitmentCannotBeRevealed() public {
        _deploy(0);
        uint256 id = _create();
        uint256[5] memory p = _probs(3, 0.6e18);
        uint256 aliceModel = _commitOnly(id, alice, p);
        uint256 bobModel = market.registerModel(address(0), bob);
        bytes32 copied = market.getCommitment(id, alice);
        vm.prank(bob);
        market.commitPrediction(id, bobModel, copied);

        vm.warp(COMMIT_END);
        _reveal(id, alice, "", p);
        vm.prank(bob);
        vm.expectRevert(VolMarket.CommitmentMismatch.selector);
        market.revealPrediction(id, "", p, _salt(alice));
        vm.prank(bob);
        vm.expectRevert(VolMarket.TooLateToPredict.selector);
        market.commitPrediction(id, bobModel, _commitment(id, bobModel, p, _salt(bob), bob));
        assertTrue(aliceModel != bobModel);
    }

    function test_UnrevealedForecastNotScored() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        _commitOnly(id, alice, _probs(3, 0.9e18));
        _commitOnly(id, bob, _probs(3, 0.5e18));
        vm.warp(COMMIT_END);
        _reveal(id, bob, "", _probs(3, 0.5e18));

        vm.recordLogs();
        _settleAfterWindow(id);
        uint256 scored;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == VolMarket.PredictionScored.selector) ++scored;
        }
        assertEq(scored, 1, "only the revealed forecast is scored");
        (bool recorded,,, int256 score) = market.getPrediction(id, alice);
        assertFalse(recorded);
        assertEq(score, 0);
        (,,, score) = market.getPrediction(id, bob);
        assertEq(score, MarketMath.log1e18(0.5e18));
    }

    // -------- commit-only models ------------------------------------------

    function test_CommitOnlyModelRevealsWithoutProof() public {
        _deployProofPool(_segTicks());
        assertTrue(market.isZkModel(0));
        uint256 modelId = market.registerModel(address(0), bob);
        assertFalse(market.isZkModel(modelId));
        assertEq(market.models(modelId), address(0));
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.isZkModel(modelId + 1);
        vm.expectRevert(VolMarket.ZeroAddress.selector);
        market.registerModel(address(0), address(0));

        uint256 id = _create();
        uint256[5] memory out = [uint256(1), 2, 3, 4, 10];
        _commit(id, modelId, bob, out);
        vm.warp(COMMIT_END);
        _reveal(id, bob, hex"deadbeef", out);
        (bool recorded, uint256 got, uint256[5] memory probs,) = market.getPrediction(id, bob);
        assertTrue(recorded);
        assertEq(got, modelId);
        assertEq(probs[0], uint256(1e18) / 20);
        assertEq(probs[4], 1e18 - probs[0] - probs[1] - probs[2] - probs[3]);

        _settleAfterWindow(id);
        (,,, int256 score) = market.getPrediction(id, bob);
        assertEq(score, MarketMath.log1e18(probs[0]));
    }

    /// @dev _mixed() settles in bucket 3; a revealed forecast with zero weight there must not block
    ///      settlement (log1e18(0) reverts) and scores the floor.
    function test_ZeroWinProbabilityScoresFloor() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        uint256[5] memory out = [uint256(1), 1, 1, 0, 1];
        _commitOnly(id, bob, out);
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.warp(COMMIT_END);
        _reveal(id, bob, "", out);
        (,, uint256[5] memory probs,) = market.getPrediction(id, bob);
        assertEq(probs[3], 0);

        _settleAfterWindow(id);
        (bool voided, uint256 bucket,) = _rv(id);
        assertFalse(voided);
        assertEq(bucket, 3);
        (,,, int256 score) = market.getPrediction(id, bob);
        assertEq(score, market.MIN_LOG_SCORE());
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - before, 100e18);
    }

    function test_TinyWinProbabilityClampedToFloor() public {
        _deploy(0);
        _segments(_mixed());
        uint256 id = _create();
        uint256[5] memory out = [uint256(2e17), 2e17, 2e17, 1, 2e17];
        _commitOnly(id, bob, out);
        vm.warp(COMMIT_END);
        _reveal(id, bob, "", out);
        (,, uint256[5] memory probs,) = market.getPrediction(id, bob);
        assertEq(probs[3], 1);
        assertLt(MarketMath.log1e18(probs[3]), market.MIN_LOG_SCORE(), "raw log score below the floor");

        _settleAfterWindow(id);
        (,,, int256 score) = market.getPrediction(id, bob);
        assertEq(score, market.MIN_LOG_SCORE());
    }

    function test_OutputsMustNotOverflowProbabilityScale() public {
        _deploy(0);
        uint256 id = _create();
        uint256 max = market.MAX_OUTPUT();
        assertLt(max, market.FIELD_R() / 2, "negative field encodings stay rejected");
        uint256[5] memory big = [max + 1, 0, 0, 0, 0];
        uint256[5] memory ok = [max, max, max, max, max];
        _commitOnly(id, alice, big);
        _commitOnly(id, bob, ok);
        vm.warp(COMMIT_END);
        vm.prank(alice);
        vm.expectRevert(VolMarket.BadOutputs.selector);
        market.revealPrediction(id, "", big, _salt(alice));
        _reveal(id, bob, "", ok);
        (,, uint256[5] memory probs,) = market.getPrediction(id, bob);
        assertEq(probs[0], 0.2e18);
    }

    // -------- predictor share ---------------------------------------------

    /// @dev Fee 1 % of 1000, half of it to predictors. Two forecasts beat the uniform baseline, one
    ///      matches it exactly and one falls below: only the first two share the 5, pro rata to
    ///      their excess log score, and the last claimer takes the rounding remainder.
    function test_PredictorShareSplitByExcessScore() public {
        _deploy(100, 5000);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(bob);
        market.bet(id, 0, 900e18);

        address p1 = makeAddr("p1");
        address p2 = makeAddr("p2");
        address p3 = makeAddr("p3");
        address p4 = makeAddr("p4");
        uint256[5] memory uniform = [uint256(1), 1, 1, 1, 1];
        _commitOnly(id, p1, _probs(3, 0.5e18));
        _commitOnly(id, p2, _probs(3, 0.8e18));
        _commitOnly(id, p3, uniform);
        _commitOnly(id, p4, _probs(3, 0.05e18));
        vm.warp(COMMIT_END);
        _reveal(id, p1, "", _probs(3, 0.5e18));
        _reveal(id, p2, "", _probs(3, 0.8e18));
        _reveal(id, p3, "", uniform);
        _reveal(id, p4, "", _probs(3, 0.05e18));

        vm.prank(p1);
        vm.expectRevert(VolMarket.RoundNotSettled.selector);
        market.claimPredictorReward(id);

        _settleAfterWindow(id);
        int256 base = MarketMath.log1e18(0.2e18);
        assertEq(market.baselineLogScore(), base);
        (,,, int256 s3) = market.getPrediction(id, p3);
        assertEq(s3, base, "uniform forecast scores exactly the baseline");
        uint256 e1 = uint256(MarketMath.log1e18(0.5e18) - base);
        uint256 e2 = uint256(MarketMath.log1e18(0.8e18) - base);
        uint256 share = 5e18;
        assertEq(market.predictorPool(id), share);

        vm.prank(p1);
        market.claimPredictorReward(id);
        assertEq(token.balanceOf(p1), share * e1 / (e1 + e2), "pro rata to excess score");
        vm.prank(p2);
        market.claimPredictorReward(id);
        assertEq(token.balanceOf(p2), share - token.balanceOf(p1), "last claimer takes the remainder");
        assertGe(token.balanceOf(p2), share * e2 / (e1 + e2));

        address[2] memory losers = [p3, p4];
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(losers[i]);
            vm.expectRevert(VolMarket.NothingToClaim.selector);
            market.claimPredictorReward(id);
        }
        vm.prank(p1);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claimPredictorReward(id);

        vm.expectEmit(true, false, false, true, address(market));
        emit VolMarket.FeeCollected(id, 5e18);
        market.collectFee(id);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(address(market)), 0, "round fully drained");
    }

    function test_NoPredictorBeatsBaselineFeeToOwner() public {
        _deploy(100, 5000);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(bob);
        market.bet(id, 0, 900e18);
        _commitOnly(id, carol, _probs(3, 0.1e18));
        vm.warp(COMMIT_END);
        _reveal(id, carol, "", _probs(3, 0.1e18));
        _settleAfterWindow(id);

        assertEq(market.predictorPool(id), 0);
        vm.prank(carol);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claimPredictorReward(id);
        market.collectFee(id);
        assertEq(token.balanceOf(address(this)), 10e18, "whole fee to owner");
    }

    function test_UnrevealedPredictorEarnsNothing() public {
        _deploy(100, 10_000);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(bob);
        market.bet(id, 0, 900e18);
        _commitOnly(id, carol, _probs(3, 0.9e18));
        _commitOnly(id, bob, _probs(3, 0.5e18));
        vm.warp(COMMIT_END);
        _reveal(id, bob, "", _probs(3, 0.5e18));
        _settleAfterWindow(id);

        vm.prank(carol);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claimPredictorReward(id);
        vm.prank(bob);
        market.claimPredictorReward(id);
        assertEq(token.balanceOf(bob), 1_000_000e18 - 900e18 + 10e18, "the only revealed beater takes it all");
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.collectFee(id);
    }

    function test_RefundedRoundsPayNoPredictorShare() public {
        // voided: checkpoints 0 and 1 fall out of history
        _deploy(100, 5000);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        _commitOnly(id, carol, _probs(3, 0.9e18));
        vm.warp(COMMIT_END);
        _reveal(id, carol, "", _probs(3, 0.9e18));
        vm.warp(END + 10);
        pool.setOldest(_t(1) + 1);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
        assertEq(market.predictorPool(id), 0);
        vm.prank(carol);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claimPredictorReward(id);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.collectFee(id);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(address(market)), 0);

        // no winner: the only stake is on bucket 0, the round lands in bucket 3
        _deploy(100, 5000);
        _segments(_mixed());
        id = _create();
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        _commitOnly(id, carol, _probs(3, 0.9e18));
        vm.warp(COMMIT_END);
        _reveal(id, carol, "", _probs(3, 0.9e18));
        _settleAfterWindow(id);
        (,,, int256 score) = market.getPrediction(id, carol);
        assertGt(score, market.baselineLogScore(), "beats the baseline, but there is no fee");
        assertEq(market.predictorPool(id), 0);
        vm.prank(carol);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claimPredictorReward(id);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - before, 100e18);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_ConstructorValidatesShareAndPhases() public {
        pool = new MockPool();
        IUniswapV3PoolOracle p = IUniswapV3PoolOracle(address(pool));
        IERC20 t = IERC20(address(token));
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(t, 100, 10_001, p, DELTA, N, COMMIT_LEAD, REVEAL_LEAD);
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(t, 100, 5000, p, DELTA, N, REVEAL_LEAD, REVEAL_LEAD);
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(t, 100, 5000, p, DELTA, N, REVEAL_LEAD, COMMIT_LEAD);
        VolMarket m = new VolMarket(t, 100, 10_000, p, DELTA, N, COMMIT_LEAD, 0);
        assertEq(m.predictorShareBps(), 10_000);
        assertEq(m.commitLead(), COMMIT_LEAD);
        assertEq(m.revealLead(), 0);
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
    ///      below the pro-rata floor, and the winners split exactly total - fee. Three forecasters
    ///      with fuzzed p(bucket 3) split exactly the predictor share of the fee among those above
    ///      the uniform baseline, and the owner receives exactly the rest of the fee.
    function testFuzz_WinnersSplitExactlyTotalMinusFee(
        uint256[3] memory win,
        uint256 lose,
        uint256 feeBps,
        uint256 shareBps,
        uint256[3] memory pWin
    ) public {
        feeBps = bound(feeBps, 0, 999);
        shareBps = bound(shareBps, 0, 10_000);
        lose = bound(lose, 1, 1e24);
        _deploy(feeBps, shareBps);
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

        address[3] memory forecasters = _forecasters(id, pWin);

        _settleAfterWindow(id);
        assertEq(_claimWinners(id, winners, win, total, winPool, feeBps), total - fee, "winners split total - fee");
        assertEq(token.balanceOf(address(market)), fee, "only the fee remains");

        uint256 share = _claimPredictorShares(id, forecasters, fee, shareBps);
        if (fee - share > 0) {
            market.collectFee(id);
        } else {
            vm.expectRevert(VolMarket.NothingToClaim.selector);
            market.collectFee(id);
        }
        assertEq(token.balanceOf(address(this)), fee - share, "owner receives the rest of the fee");
        assertEq(token.balanceOf(address(market)), 0, "round fully drained");
    }

    /// @dev Every winner claims; no payout falls below the pro-rata floor. Returns the total paid.
    function _claimWinners(
        uint256 id,
        address[3] memory winners,
        uint256[3] memory win,
        uint256 total,
        uint256 winPool,
        uint256 feeBps
    ) internal returns (uint256 paid) {
        for (uint256 i = 0; i < 3; ++i) {
            uint256 b0 = token.balanceOf(winners[i]);
            vm.prank(winners[i]);
            market.claim(id);
            uint256 got = token.balanceOf(winners[i]) - b0;
            assertGe(got, MarketMath.payout(win[i], total, winPool, feeBps), "below pro-rata floor");
            paid += got;
        }
    }

    /// @dev Three commit-only forecasters with p(bucket 3) = pWin[i], committed and revealed.
    function _forecasters(uint256 id, uint256[3] memory pWin) internal returns (address[3] memory f) {
        f = [makeAddr("f0"), makeAddr("f1"), makeAddr("f2")];
        for (uint256 i = 0; i < 3; ++i) {
            pWin[i] = bound(pWin[i], 1, 1e18);
            _commitOnly(id, f[i], _probs(3, pWin[i]));
        }
        vm.warp(COMMIT_END);
        for (uint256 i = 0; i < 3; ++i) {
            _reveal(id, f[i], "", _probs(3, pWin[i]));
        }
    }

    /// @dev Every forecaster above the baseline claims; returns the predictor share they split.
    function _claimPredictorShares(uint256 id, address[3] memory forecasters, uint256 fee, uint256 shareBps)
        internal
        returns (uint256 share)
    {
        uint256 excessSum;
        uint256[3] memory excess;
        for (uint256 i = 0; i < 3; ++i) {
            (,,, int256 score) = market.getPrediction(id, forecasters[i]);
            if (score > market.baselineLogScore()) excess[i] = uint256(score - market.baselineLogScore());
            excessSum += excess[i];
        }
        share = excessSum == 0 ? 0 : fee * shareBps / 10_000;
        assertEq(market.predictorPool(id), share, "predictor pool");

        uint256 rewarded;
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(forecasters[i]);
            if (share == 0 || excess[i] == 0) {
                vm.expectRevert(VolMarket.NothingToClaim.selector);
                market.claimPredictorReward(id);
                continue;
            }
            market.claimPredictorReward(id);
            uint256 got = token.balanceOf(forecasters[i]);
            assertGe(got, share * excess[i] / excessSum, "below pro-rata floor");
            rewarded += got;
        }
        assertEq(rewarded, share, "predictors split exactly their share");
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

    /// @dev Settling an id before it is created must not mark the round created under it later as
    ///      settled and voided.
    function test_SettleUnknownRoundReverts() public {
        _deploy(0);
        _segments(_mixed());
        vm.warp(T0);
        vm.expectRevert(VolMarket.RoundNotFound.selector);
        market.settle(0);

        uint256 id = _create();
        assertEq(id, 0);
        _settleAfterWindow(id);
        (bool voided, uint256 bucket,) = _rv(id);
        assertFalse(voided);
        assertEq(bucket, 3);
    }

    function test_CreateRoundValidation() public {
        _deploy(0);
        vm.warp(T0);
        uint256[] memory b = _bounds();
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(uint64(T0), b);
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(uint64(T0 + COMMIT_LEAD), b);
        market.createRound(uint64(T0 + COMMIT_LEAD + 1), b);
        b[2] = b[1];
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b);
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, new uint256[](5));
    }
}
