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
import {InstanceVerifier} from "./mocks/InstanceVerifier.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IdentityRegistryLite} from "../src/erc8004/IdentityRegistryLite.sol";
import {ReputationRegistryLite} from "../src/erc8004/ReputationRegistryLite.sol";

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
    uint256 constant MAX_DEVIATION_BPS = 200;
    uint256 constant MAX_FEED_AGE = 3900;

    /// @dev Price-check parameters the next _deploy uses.
    uint256 maxDeviationBps = MAX_DEVIATION_BPS;
    uint256 maxFeedAge = MAX_FEED_AGE;

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

    uint8 constant S = 12; // outputs are q * 2^12
    int256 constant UNIT = int256(uint256(1e18 >> 12)); // 1e18 value of one output step
    int256 constant ONE = 4096; // 1.0 ln unit in output steps
    int256 constant LN49 = 15941; // round(ln 49 * 4096): _mixed() settles at RV 49
    uint256 constant FIELD_R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function _levels() internal pure returns (uint256[] memory t) {
        t = new uint256[](5);
        t[0] = 1e17;
        t[1] = 25e16;
        t[2] = 5e17;
        t[3] = 75e16;
        t[4] = 9e17;
    }

    function _market(uint256 feeBps, uint256 shareBps, address pool_) internal returns (VolMarket) {
        return new VolMarket(
            IERC20(address(token)),
            feeBps,
            shareBps,
            IUniswapV3PoolOracle(pool_),
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            maxDeviationBps,
            maxFeedAge,
            VolMarket.QuantileConfig(_levels(), S)
        );
    }

    function _salt(address who) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", who));
    }

    function _commitment(uint256 id, uint256 modelId, int256[] memory out, bytes32 salt, address who)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(id, modelId, out, salt, who));
    }

    function _commit(uint256 id, uint256 modelId, address who, int256[] memory out) internal {
        vm.prank(who);
        market.commitPrediction(id, modelId, _commitment(id, modelId, out, _salt(who), who));
    }

    function _reveal(uint256 id, address who, bytes memory proof, int256[] memory out) internal {
        vm.prank(who);
        market.revealPrediction(id, proof, out, _salt(who));
    }

    /// @dev Commit during the commit phase, then reveal at the start of the reveal phase.
    function _commitReveal(uint256 id, uint256 modelId, address who, bytes memory proof, int256[] memory out) internal {
        _commit(id, modelId, who, out);
        vm.warp(COMMIT_END);
        _reveal(id, who, proof, out);
    }

    /// @dev Registers a commit-only model operated by `who` and commits `out` with it.
    function _commitOnly(uint256 id, address who, int256[] memory out) internal returns (uint256 modelId) {
        modelId = market.registerModel(address(0), who);
        _commit(id, modelId, who, out);
    }

    /// @dev Five outputs mid + (k - 2) * step, in 2^-12 ln units.
    function _out(int256 mid, int256 step) internal pure returns (int256[] memory o) {
        o = new int256[](5);
        for (uint256 k = 0; k < 5; ++k) {
            o[k] = mid + (int256(k) - 2) * step;
        }
    }

    function _e18(int256[] memory o) internal pure returns (int256[] memory q) {
        q = new int256[](o.length);
        for (uint256 k = 0; k < o.length; ++k) {
            q[k] = o[k] * UNIT;
        }
    }

    /// @dev Baseline ln RV quantiles 2, 2.5, 3, 3.5, 4, on the output grid.
    function _baseOut() internal pure returns (int256[] memory) {
        return _out(3 * ONE, ONE / 2);
    }

    function _baseline() internal pure returns (int256[] memory) {
        return _e18(_baseOut());
    }

    /// @dev Pinball loss the market owes outputs `o` at realized vol `rv`.
    function _loss(uint256 rv, int256[] memory o) internal pure returns (uint256) {
        return MarketMath.pinball(MarketMath.lnWad(rv == 0 ? 1 : rv), _e18(o), _levels());
    }

    function _assertQuantiles(int256[] memory got, int256[] memory want) internal pure {
        assertEq(got.length, want.length, "quantile count");
        for (uint256 k = 0; k < want.length; ++k) {
            assertEq(got[k], want[k], "quantile");
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
        id = market.createRound(START, _bounds(), _baseline());
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

    /// @dev Pool timeline for the proof fixture: 17 constant segments ending at T0, last tick
    ///      continues. Model 0 (operator alice) accepts exactly the fixture proof bytes on
    ///      (fixture features, _zkOut()).
    function _deployProofPool(int256[] memory segTicks) internal {
        pool = new MockPool();
        for (uint256 j = 0; j < segTicks.length; ++j) {
            pool.setTickFrom(T0 - (17 - j) * uint256(DELTA), int24(segTicks[j]));
        }
        market = _market(0, 0, address(pool));
        market.registerModel(address(_zkVerifier()), alice);
    }

    function _zkVerifier() internal returns (InstanceVerifier) {
        return new InstanceVerifier(_proof(), _zkInstances(_zkOut()));
    }

    /// @dev K = 5 strictly increasing signed outputs; the negative one exercises field encoding.
    function _zkOut() internal pure returns (int256[] memory o) {
        o = new int256[](5);
        o[0] = -300;
        o[1] = 584;
        o[2] = 900;
        o[3] = 1188;
        o[4] = 2035;
    }

    /// @dev The fixture's 16 field-encoded features (encoded off-chain by the proof generator),
    ///      then the outputs, negative ones as FIELD_R - |x|.
    function _zkInstances(int256[] memory o) internal view returns (uint256[] memory inst) {
        uint256[] memory fixtureInst = vm.parseJsonUintArray(proofJson, ".instances");
        inst = new uint256[](16 + o.length);
        for (uint256 j = 0; j < 16; ++j) {
            inst[j] = fixtureInst[j];
        }
        for (uint256 k = 0; k < o.length; ++k) {
            inst[16 + k] = o[k] >= 0 ? uint256(o[k]) : FIELD_R - uint256(-o[k]);
        }
    }

    function _proof() internal view returns (bytes memory) {
        return vm.parseJsonBytes(proofJson, ".proof");
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

    function test_VoidedRoundRefundsEveryBucket() public {
        _deploy(100);
        _segments(_mixed());
        uint256 id = _create();
        market.setPriceFeed(address(feed));
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        vm.prank(bob);
        market.bet(id, 3, 40e18);
        vm.warp(END + 10);
        feed.setAnswer(3000e8, block.timestamp);
        _expectPriceCheckFailed(id, 196001, 3000e8, 4);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(market));
        emit VolMarket.Claimed(id, alice, 100e18);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - aliceBefore, 100e18, "bucket-0 staker gets stake back, not the pool");

        uint256 bobBefore = token.balanceOf(bob);
        vm.expectEmit(true, true, false, true, address(market));
        emit VolMarket.Claimed(id, bob, 40e18);
        vm.prank(bob);
        market.claim(id);
        assertEq(token.balanceOf(bob) - bobBefore, 40e18, "non-zero-bucket staker is refunded");
        assertEq(token.balanceOf(address(market)), 0, "no fee taken on a voided round");

        vm.prank(bob);
        vm.expectRevert(VolMarket.NothingToClaim.selector);
        market.claim(id);
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
        assertEq(market.maxFeedAge(), maxAge);
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
        assertEq(market.maxDeviationBps(), 200);
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

    /// @dev A pool 1.5% above the feed passes the default 200 bps check but not a 100 bps market.
    function test_CustomDeviationVoidsWhatDefaultSettles() public {
        uint256 id = _roundEndingAtTick(196001);
        int256 answer = int256(market.priceForTick(196001) * 10_000 / 10_150);
        feed.setAnswer(answer, block.timestamp);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided, "200 bps market settles a 1.5% deviation");

        maxDeviationBps = 100;
        id = _roundEndingAtTick(196001);
        assertEq(market.maxDeviationBps(), 100);
        feed.setAnswer(answer, block.timestamp);
        _expectPriceCheckFailed(id, 196001, answer, 4);
        market.settle(id);
        (voided,,) = _rv(id);
        assertTrue(voided, "100 bps market voids a 1.5% deviation");
    }

    function test_CustomFeedAgeBoundary() public {
        maxFeedAge = 600;
        uint256 id = _roundEndingAtTick(196001);
        assertEq(market.maxFeedAge(), 600);
        int256 matching = int256(market.priceForTick(196001));
        feed.setAnswer(matching, block.timestamp - 600);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertFalse(voided, "age exactly maxFeedAge settles");

        id = _roundEndingAtTick(196001);
        feed.setAnswer(matching, block.timestamp - 601);
        _expectPriceCheckFailed(id, 196001, matching, 2);
        market.settle(id);
        (voided,,) = _rv(id);
        assertTrue(voided, "one second past a 600 s maxFeedAge voids, under the 3900 s default it would settle");
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

    /// @dev The fixture proof predates quantile outputs (its 5 outputs are not increasing), so the
    ///      market tests use InstanceVerifier; this keeps the real proof checked by its verifier.
    function test_SpikeVerifierAcceptsFixtureProofOnly() public {
        SpikeModelVerifier v = new SpikeModelVerifier();
        uint256[] memory inst = vm.parseJsonUintArray(proofJson, ".instances");
        assertEq(inst.length, 21);
        assertTrue(v.verifyProof(_proof(), inst));
        bytes memory proof = _proof();
        proof[1000] = bytes1(uint8(proof[1000]) ^ 0x01);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(v.verifyProof, (proof, inst)));
        assertTrue(!ok || !abi.decode(ret, (bool)), "tampered proof verified");
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

        int256[] memory out = _zkOut();
        _commit(id, 0, alice, out);
        vm.prank(alice);
        vm.expectRevert(VolMarket.AlreadyPredicted.selector);
        market.commitPrediction(id, 0, bytes32(uint256(1)));

        vm.warp(COMMIT_END);
        vm.expectEmit(true, true, true, true, address(market));
        emit VolMarket.PredictionRevealed(id, alice, 0, _e18(out));
        _reveal(id, alice, _proof(), out);

        (bool recorded, uint256 modelId, int256[] memory q, int256 score) = market.getPrediction(id, alice);
        assertTrue(recorded);
        assertEq(modelId, 0);
        assertEq(score, 0, "not scored before settlement");
        _assertQuantiles(q, _e18(out));
        assertEq(q[0], -300 * 244_140_625_000_000, "1e18 >> 12 per output step");
        assertEq(market.predictorCount(id), 1);

        vm.prank(alice);
        vm.expectRevert(VolMarket.AlreadyRevealed.selector);
        market.revealPrediction(id, _proof(), out, _salt(alice));
    }

    /// @dev RV 0 scores as y = ln(1) = 0, where every pinball term is exact by hand.
    function test_RealProofScoredAtSettle() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        _commitReveal(id, 0, alice, _proof(), _zkOut());

        vm.warp(START);
        vm.prank(bob);
        vm.expectRevert(VolMarket.TooLateToPredict.selector);
        market.commitPrediction(id, 0, bytes32(uint256(1)));

        // the last fixture tick continues through the window: RV 0, bucket 0
        // baseline 2, 2.5, 3, 3.5, 4 at y = 0: (0.9*2 + 0.75*2.5 + 0.5*3 + 0.25*3.5 + 0.1*4) / 5
        uint256 baseLoss = 1.29e18;
        // outputs -300, 584, 900, 1188, 2035: 0.1*300 + 0.75*584 + 0.5*900 + 0.25*1188 + 0.1*2035
        uint256 loss = uint256((1215 * UNIT + (2035 * UNIT) / 10) / 5);
        vm.expectEmit(true, false, false, true, address(market));
        emit VolMarket.RoundScored(id, 0, baseLoss);
        vm.expectEmit(true, true, false, true, address(market));
        emit VolMarket.PredictionScored(id, alice, -int256(loss), loss);
        _settleAfterWindow(id);
        (bool voided, uint256 bucket, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertEq(rv, 0);
        assertEq(bucket, 0);
        (int256 lnRv, uint256 gotBase, int256[] memory baseQ) = market.getRoundScoring(id);
        assertEq(lnRv, 0);
        assertEq(gotBase, baseLoss);
        _assertQuantiles(baseQ, _baseline());
        (,,, int256 score) = market.getPrediction(id, alice);
        assertEq(score, -int256(loss));
        (uint256 gotLoss, uint256 excess) = market.getPredictionLoss(id, alice);
        assertEq(gotLoss, loss);
        assertEq(excess, baseLoss - loss);
    }

    function test_TamperedProofRejected() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        bytes memory proof = _proof();
        proof[1000] = bytes1(uint8(proof[1000]) ^ 0x01);
        _commit(id, 0, alice, _zkOut());
        vm.warp(COMMIT_END);
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, proof, _zkOut(), _salt(alice));
        (bool recorded,,,) = market.getPrediction(id, alice);
        assertFalse(recorded);
    }

    function test_TamperedOutputsRejected() public {
        _deployProofPool(_segTicks());
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.commitPrediction(id, 1, bytes32(uint256(1)));

        int256[] memory out = _zkOut();
        out[0] += 1;
        _commit(id, 0, alice, out);
        vm.warp(COMMIT_END);
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, _proof(), out, _salt(alice));

        // a field encoding of a negative output read as a huge positive one is out of range
        out[0] = int256(FIELD_R - 300);
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

        _commit(id, 0, alice, _zkOut());
        vm.warp(COMMIT_END);
        vm.prank(alice);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, _proof(), _zkOut(), _salt(alice));
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
        market.commitPrediction(id, 0, _commitment(id, 0, _zkOut(), _salt(bob), bob));
        _commitReveal(id, 0, alice, _proof(), _zkOut());
        assertEq(market.predictorCount(id), 1);
    }

    function test_PredictorCapEnforced() public {
        _deployProofPool(_segTicks());
        uint256 cap = market.MAX_PREDICTORS();
        for (uint256 i = 0; i < cap; ++i) {
            market.registerModel(address(_zkVerifier()), address(uint160(0x1000 + i)));
        }
        uint256 id = _create();
        for (uint256 i = 0; i < cap; ++i) {
            _commit(id, i + 1, address(uint160(0x1000 + i)), _zkOut());
        }
        assertEq(market.predictorCount(id), cap);
        vm.prank(alice);
        vm.expectRevert(VolMarket.TooManyPredictors.selector);
        market.commitPrediction(id, 0, bytes32(uint256(1)));
    }

    // -------- commit-reveal ----------------------------------------------

    function test_PredictorAtListsCommittersInOrder() public {
        _deploy(0);
        uint256 id = _create();
        _commitOnly(id, alice, _out(LN49, 100));
        _commitOnly(id, bob, _out(LN49, 200));
        assertEq(market.predictorCount(id), 2);
        assertEq(market.predictorAt(id, 0), alice);
        assertEq(market.predictorAt(id, 1), bob);
        vm.expectRevert();
        market.predictorAt(id, 2);
    }

    function test_ForecastHiddenUntilRevealWindow() public {
        _deploy(0);
        uint256 id = _create();
        int256[] memory p = _out(LN49, 300);
        uint256 modelId = _commitOnly(id, alice, p);

        assertEq(market.getCommitment(id, alice), _commitment(id, modelId, p, _salt(alice), alice));
        (bool recorded,, int256[] memory shown,) = market.getPrediction(id, alice);
        assertFalse(recorded, "nothing public before reveal");
        assertEq(shown.length, 0);

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
        _assertQuantiles(shown, _e18(p));
    }

    function test_RevealMustMatchCommitment() public {
        _deploy(0);
        uint256 id = _create();
        int256[] memory p = _out(LN49, 300);
        _commitOnly(id, alice, p);
        vm.warp(COMMIT_END);

        vm.prank(bob);
        vm.expectRevert(VolMarket.NotCommitted.selector);
        market.revealPrediction(id, "", p, _salt(bob));

        vm.prank(alice);
        vm.expectRevert(VolMarket.CommitmentMismatch.selector);
        market.revealPrediction(id, "", p, _salt(bob));

        int256[] memory other = _out(LN49 + 1, 300);
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
        int256[] memory p = _out(LN49, 300);
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
        _commitOnly(id, alice, _out(LN49, 100));
        _commitOnly(id, bob, _out(LN49, 300));
        vm.warp(COMMIT_END);
        _reveal(id, bob, "", _out(LN49, 300));

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
        (uint256 loss, uint256 excess) = market.getPredictionLoss(id, alice);
        assertEq(loss, 0);
        assertEq(excess, 0, "unrevealed: no excess even with loss 0");
        (,,, score) = market.getPrediction(id, bob);
        assertEq(score, -int256(_loss(49, _out(LN49, 300))));
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
        // the range ends Q_MIN = -20 and Q_MAX = 60 ln units are accepted
        int256[] memory out = _out(0, 1);
        out[0] = -20 * ONE;
        out[4] = 60 * ONE;
        _commit(id, modelId, bob, out);
        vm.warp(COMMIT_END);
        _reveal(id, bob, hex"deadbeef", out);
        (bool recorded, uint256 got, int256[] memory q,) = market.getPrediction(id, bob);
        assertTrue(recorded);
        assertEq(got, modelId);
        _assertQuantiles(q, _e18(out));
        assertEq(q[0], market.Q_MIN());
        assertEq(q[4], market.Q_MAX());

        _settleAfterWindow(id);
        (,,, int256 score) = market.getPrediction(id, bob);
        assertEq(score, -int256(_loss(0, out)));
    }

    // -------- model hash and verification tier ------------------------------

    bytes32 constant MODEL_HASH = keccak256("weights+code+data");

    function test_RegisterModelWithHashStoresAndEmits() public {
        _deploy(0);
        vm.expectEmit(true, false, false, true, address(market));
        emit VolMarket.ModelRegistered(0, address(0), alice);
        vm.expectEmit(true, false, false, true, address(market));
        emit VolMarket.ModelHashSet(0, MODEL_HASH);
        uint256 modelId = market.registerModel(address(0), alice, MODEL_HASH);
        assertEq(modelId, 0);
        assertEq(market.modelHash(modelId), MODEL_HASH);
        assertEq(market.modelOperator(modelId), alice);
        assertEq(market.modelCount(), 1);
    }

    function test_TierReproducibleWhenNoVerifierAndHash() public {
        _deploy(0);
        uint256 modelId = market.registerModel(address(0), alice, MODEL_HASH);
        assertEq(market.verificationTier(modelId), market.TIER_REPRODUCIBLE());
        assertFalse(market.isZkModel(modelId));
    }

    function test_TierZkWhenVerifierRegardlessOfHash() public {
        _deploy(0);
        uint256 hashed = market.registerModel(address(1), alice, MODEL_HASH);
        uint256 plain = market.registerModel(address(2), bob, bytes32(0));
        uint256 twoArg = market.registerModel(address(3), carol);
        assertEq(market.verificationTier(hashed), market.TIER_ZK());
        assertEq(market.verificationTier(plain), market.TIER_ZK());
        assertEq(market.verificationTier(twoArg), market.TIER_ZK());
        assertEq(market.modelHash(hashed), MODEL_HASH);
        assertTrue(market.isZkModel(hashed));
    }

    function test_TierCommitOnlyWhenNeither() public {
        _deploy(0);
        vm.recordLogs();
        uint256 twoArg = market.registerModel(address(0), alice);
        uint256 zeroHash = market.registerModel(address(0), bob, bytes32(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != VolMarket.ModelHashSet.selector, "no hash event for a zero hash");
        }
        assertEq(market.modelHash(twoArg), bytes32(0));
        assertEq(market.modelHash(zeroHash), bytes32(0));
        assertEq(market.verificationTier(twoArg), market.TIER_COMMIT_ONLY());
        assertEq(market.verificationTier(zeroHash), market.TIER_COMMIT_ONLY());
        assertTrue(market.TIER_COMMIT_ONLY() != market.TIER_REPRODUCIBLE());
        assertTrue(market.TIER_REPRODUCIBLE() != market.TIER_ZK());
        assertTrue(market.TIER_COMMIT_ONLY() != market.TIER_ZK());
    }

    function test_ModelHashUnknownModelReverts() public {
        _deploy(0);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.modelHash(0);
        market.registerModel(address(0), alice, MODEL_HASH);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.modelHash(1);
    }

    function test_VerificationTierUnknownModelReverts() public {
        _deploy(0);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.verificationTier(0);
        market.registerModel(address(0), alice, MODEL_HASH);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.verificationTier(1);
    }

    function test_RegisterModelWithHashZeroOperatorReverts() public {
        _deploy(0);
        vm.expectRevert(VolMarket.ZeroAddress.selector);
        market.registerModel(address(0), address(0), MODEL_HASH);
        assertEq(market.modelCount(), 0);
    }

    function test_RegisterModelWithHashNotOwnerReverts() public {
        _deploy(0);
        vm.prank(alice);
        vm.expectRevert(VolMarket.NotOwner.selector);
        market.registerModel(address(0), alice, MODEL_HASH);
        assertEq(market.modelCount(), 0);
    }

    function test_ReproducibleModelRevealSkipsProofAndTagsCommit() public {
        _deploy(0);
        _segments(_mixed());
        IdentityRegistryLite identity = new IdentityRegistryLite();
        ReputationRegistryLite reputation = new ReputationRegistryLite();
        market.setReputation(address(identity), address(reputation));
        vm.prank(bob);
        uint256 agentId = identity.register("ipfs://reproducible-agent");
        uint256 modelId = market.registerModel(address(0), bob, MODEL_HASH);
        vm.prank(bob);
        market.linkAgent(modelId, agentId);
        assertFalse(market.isZkModel(modelId));

        uint256 id = _create();
        int256[] memory out = _out(LN49, 300);
        _commit(id, modelId, bob, out);
        vm.warp(COMMIT_END);
        _reveal(id, bob, "", out);
        (bool recorded,,,) = market.getPrediction(id, bob);
        assertTrue(recorded);

        _settleAfterWindow(id);
        (,,, int256 score) = market.getPrediction(id, bob);
        (int128[] memory values,, string[] memory tag1s, string[] memory tags) =
            reputation.readFeedback(agentId, address(market));
        assertEq(tags.length, 1);
        assertEq(tag1s[0], "pinball");
        assertEq(tags[0], "vol-300s-12-commit");
        assertEq(int256(values[0]), score);
    }

    function test_ZkModelWithHashStillRequiresProof() public {
        _deployProofPool(_segTicks());
        uint256 modelId = market.registerModel(address(_zkVerifier()), bob, MODEL_HASH);
        assertEq(market.verificationTier(modelId), market.TIER_ZK());
        uint256 id = _create();
        int256[] memory out = _zkOut();
        _commit(id, modelId, bob, out);
        vm.warp(COMMIT_END);

        vm.prank(bob);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, "", out, _salt(bob));

        bytes memory proof = _proof();
        proof[1000] = bytes1(uint8(proof[1000]) ^ 0x01);
        vm.prank(bob);
        vm.expectRevert(VolMarket.InvalidProof.selector);
        market.revealPrediction(id, proof, out, _salt(bob));

        (bool recorded,,,) = market.getPrediction(id, bob);
        assertFalse(recorded);
        _reveal(id, bob, _proof(), out);
        (recorded,,,) = market.getPrediction(id, bob);
        assertTrue(recorded);
    }

    // -------- quantile validation and extreme outcomes -----------------------

    function _expectBadOutputs(uint256 id, address who, int256[] memory out) internal {
        vm.prank(who);
        vm.expectRevert(VolMarket.BadOutputs.selector);
        market.revealPrediction(id, "", out, _salt(who));
    }

    /// @dev Shape and range are checked before the commitment, so any malformed vector reverts
    ///      with BadOutputs whatever was committed.
    function test_RevealRejectsBadQuantiles() public {
        _deploy(0);
        uint256 id = _create();
        int256[] memory good = _out(LN49, 300);
        _commitOnly(id, alice, good);
        vm.warp(COMMIT_END);

        _expectBadOutputs(id, alice, new int256[](0));
        int256[] memory four = new int256[](4);
        for (uint256 k = 0; k < 4; ++k) {
            four[k] = good[k];
        }
        _expectBadOutputs(id, alice, four);
        int256[] memory six = new int256[](6);
        for (uint256 k = 0; k < 6; ++k) {
            six[k] = LN49 + int256(k) * 300;
        }
        _expectBadOutputs(id, alice, six);

        int256[] memory tie = _out(LN49, 300);
        tie[2] = tie[1];
        _expectBadOutputs(id, alice, tie);
        _expectBadOutputs(id, alice, _out(LN49, -300));
        _expectBadOutputs(id, alice, _out(LN49, 0));

        int256[] memory low = _out(LN49, 300);
        low[0] = -20 * ONE - 1;
        _expectBadOutputs(id, alice, low);
        int256[] memory high = _out(LN49, 300);
        high[4] = 60 * ONE + 1;
        _expectBadOutputs(id, alice, high);
        int256[] memory huge = _out(LN49, 300);
        huge[4] = type(int256).max;
        _expectBadOutputs(id, alice, huge);
        int256[] memory tiny = _out(LN49, 300);
        tiny[0] = type(int256).min;
        _expectBadOutputs(id, alice, tiny);

        _reveal(id, alice, "", good);
    }

    /// @dev RV 1 (one unit step) scores like RV 0: y = ln 1 = 0.
    function test_RealizedVolOneScoresAtLnZero() public {
        _deploy(0, 0);
        int24[12] memory ticks;
        for (uint256 k = 0; k < 12; ++k) {
            ticks[k] = k < 6 ? int24(100) : int24(101);
        }
        _segments(ticks);
        uint256 id = _create();
        int256[] memory out = _out(0, 300);
        _commitOnly(id, alice, out);
        vm.warp(COMMIT_END);
        _reveal(id, alice, "", out);
        _settleAfterWindow(id);
        (bool voided,, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertEq(rv, 1);
        (int256 lnRv, uint256 baseLoss,) = market.getRoundScoring(id);
        assertEq(lnRv, 0);
        assertEq(baseLoss, 1.29e18);
        (uint256 loss, uint256 excess) = market.getPredictionLoss(id, alice);
        assertEq(loss, _loss(1, out));
        assertEq(excess, baseLoss - loss);
    }

    /// @dev Segments alternating between the extreme ticks give the largest RV a pool can produce;
    ///      settlement scores it without overflow and every forecast falls below the outcome.
    function test_ExtremeRealizedVolScores() public {
        _deploy(0, 0);
        int24[12] memory ticks;
        for (uint256 k = 0; k < 12; ++k) {
            ticks[k] = k % 2 == 0 ? int24(-887272) : int24(887272);
        }
        _segments(ticks);
        uint256 id = _create();
        int256[] memory out = _out(LN49, 300);
        _commitOnly(id, alice, out);
        vm.warp(COMMIT_END);
        _reveal(id, alice, "", out);
        _settleAfterWindow(id);
        (bool voided,, uint256 rv) = _rv(id);
        assertFalse(voided);
        assertGt(rv, 3e12);
        (int256 lnRv, uint256 baseLoss,) = market.getRoundScoring(id);
        assertEq(lnRv, MarketMath.lnWad(rv));
        assertEq(baseLoss, MarketMath.pinball(lnRv, _baseline(), _levels()));
        (uint256 loss, uint256 excess) = market.getPredictionLoss(id, alice);
        assertEq(loss, _loss(rv, out));
        assertGt(excess, 0, "closer to the outcome than the baseline");
    }

    function test_ConstructorValidatesQuantileParams() public {
        pool = new MockPool();
        IUniswapV3PoolOracle p = IUniswapV3PoolOracle(address(pool));
        IERC20 t = IERC20(address(token));
        uint256[] memory l = _levels();

        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(new uint256[](0), S)
        );
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(l, 19)
        );
        uint256[] memory many = new uint256[](17);
        for (uint256 k = 0; k < 17; ++k) {
            many[k] = (k + 1) * 5e16;
        }
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(many, S)
        );
        l[0] = 0;
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(l, S)
        );
        l = _levels();
        l[4] = 1e18;
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(l, S)
        );
        l = _levels();
        l[2] = l[1];
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(l, S)
        );

        VolMarket m = new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(_levels(), S)
        );
        assertEq(m.quantileCount(), 5);
        assertEq(m.outputScaleBits(), 12);
        uint256[] memory got = m.quantileLevels();
        for (uint256 k = 0; k < 5; ++k) {
            assertEq(got[k], _levels()[k]);
        }

        // one level, the median, and the finest exact output scale 2^-18
        uint256[] memory median = new uint256[](1);
        median[0] = 5e17;
        m = new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(median, 18)
        );
        assertEq(m.quantileCount(), 1);
        assertEq(m.outputScaleBits(), 18);
        many = new uint256[](16);
        for (uint256 k = 0; k < 16; ++k) {
            many[k] = (k + 1) * 5e16;
        }
        m = new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(many, 0)
        );
        assertEq(m.quantileCount(), 16);
    }

    /// @dev outputScaleBits 0: outputs are whole ln units, so an output is worth 1e18.
    function test_OutputScaleBitsZeroRevealsWholeUnits() public {
        pool = new MockPool();
        pool.setTickFrom(T0 - 20 * uint256(DELTA), 196000);
        market = new VolMarket(
            IERC20(address(token)),
            0,
            0,
            IUniswapV3PoolOracle(address(pool)),
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(_levels(), 0)
        );
        uint256 id = _create();
        int256[] memory out = _out(3, 1);
        _commitOnly(id, alice, out);
        vm.warp(COMMIT_END);
        _reveal(id, alice, "", out);
        (,, int256[] memory q,) = market.getPrediction(id, alice);
        assertEq(q[0], 1e18);
        assertEq(q[4], 5e18);
    }

    // -------- predictor share ---------------------------------------------

    /// @dev Fee 1 % of 1000, half of it to predictors. Two forecasts beat the baseline quantiles'
    ///      pinball loss, one equals the baseline exactly and one falls below: only the first two
    ///      share the 5, pro rata to baseline loss - loss, and the last claimer takes the remainder.
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
        _commitOnly(id, p1, _out(LN49, 600));
        _commitOnly(id, p2, _out(LN49, 300));
        _commitOnly(id, p3, _baseOut());
        _commitOnly(id, p4, _out(LN49 - 3 * ONE, 300));
        vm.warp(COMMIT_END);
        _reveal(id, p1, "", _out(LN49, 600));
        _reveal(id, p2, "", _out(LN49, 300));
        _reveal(id, p3, "", _baseOut());
        _reveal(id, p4, "", _out(LN49 - 3 * ONE, 300));

        vm.prank(p1);
        vm.expectRevert(VolMarket.RoundNotSettled.selector);
        market.claimPredictorReward(id);

        _settleAfterWindow(id);
        uint256 base = _assertBaselineScoring(id, p3, p4);
        uint256 e1 = base - _loss(49, _out(LN49, 600));
        uint256 e2 = base - _loss(49, _out(LN49, 300));
        assertGt(e1, 0);
        assertGt(e2, e1, "the sharper centered forecast beats the wider one");
        (, uint256 x1) = market.getPredictionLoss(id, p1);
        assertEq(x1, e1);
        uint256 share = 5e18;
        assertEq(market.predictorPool(id), share);

        vm.prank(p1);
        market.claimPredictorReward(id);
        assertEq(token.balanceOf(p1), share * e1 / (e1 + e2), "pro rata to excess");
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

    /// @dev Round scored at ln 49 against the baseline; `equal` revealed the baseline itself and
    ///      `worse` a forecast with a higher loss. Returns the baseline loss.
    function _assertBaselineScoring(uint256 id, address equal, address worse) internal view returns (uint256 base) {
        (int256 lnRv, uint256 b, int256[] memory baseQ) = market.getRoundScoring(id);
        base = b;
        assertEq(lnRv, MarketMath.lnWad(49));
        assertApproxEqAbs(lnRv, 3.89182029811062661e18, 1e9);
        _assertQuantiles(baseQ, _baseline());
        assertEq(base, _loss(49, _baseOut()));
        (,,, int256 s3) = market.getPrediction(id, equal);
        assertEq(s3, -int256(base), "forecast equal to the baseline scores exactly the baseline");
        (, uint256 x3) = market.getPredictionLoss(id, equal);
        assertEq(x3, 0, "and has no excess");
        (uint256 l4, uint256 x4) = market.getPredictionLoss(id, worse);
        assertGt(l4, base);
        assertEq(x4, 0, "below the baseline: no excess");
    }

    function test_NoPredictorBeatsBaselineFeeToOwner() public {
        _deploy(100, 5000);
        _segments(_mixed());
        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 3, 100e18);
        vm.prank(bob);
        market.bet(id, 0, 900e18);
        _commitOnly(id, carol, _out(LN49 - 3 * ONE, 300));
        vm.warp(COMMIT_END);
        _reveal(id, carol, "", _out(LN49 - 3 * ONE, 300));
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
        _commitOnly(id, carol, _out(LN49, 100));
        _commitOnly(id, bob, _out(LN49, 300));
        vm.warp(COMMIT_END);
        _reveal(id, bob, "", _out(LN49, 300));
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
        _commitOnly(id, carol, _out(LN49, 100));
        vm.warp(COMMIT_END);
        _reveal(id, carol, "", _out(LN49, 100));
        vm.warp(END + 10);
        pool.setOldest(_t(1) + 1);
        market.settle(id);
        (bool voided,,) = _rv(id);
        assertTrue(voided);
        assertEq(market.predictorPool(id), 0);
        (uint256 vLoss, uint256 vExcess) = market.getPredictionLoss(id, carol);
        assertEq(vLoss, 0, "voided rounds are not scored");
        assertEq(vExcess, 0);
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
        _commitOnly(id, carol, _out(LN49, 100));
        vm.warp(COMMIT_END);
        _reveal(id, carol, "", _out(LN49, 100));
        _settleAfterWindow(id);
        (, uint256 excess) = market.getPredictionLoss(id, carol);
        assertGt(excess, 0, "beats the baseline, but there is no fee");
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
        uint256[] memory l = _levels();
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            10_001,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(l, S)
        );
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            REVEAL_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(l, S)
        );
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            REVEAL_LEAD,
            COMMIT_LEAD,
            MAX_DEVIATION_BPS,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(l, S)
        );
        VolMarket m = new VolMarket(
            t, 100, 10_000, p, DELTA, N, COMMIT_LEAD, 0, MAX_DEVIATION_BPS, MAX_FEED_AGE, VolMarket.QuantileConfig(l, S)
        );
        assertEq(m.predictorShareBps(), 10_000);
        assertEq(m.commitLead(), COMMIT_LEAD);
        assertEq(m.revealLead(), 0);
    }

    function test_ConstructorValidatesPriceCheck() public {
        pool = new MockPool();
        IUniswapV3PoolOracle p = IUniswapV3PoolOracle(address(pool));
        IERC20 t = IERC20(address(token));
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t, 100, 5000, p, DELTA, N, COMMIT_LEAD, REVEAL_LEAD, 0, MAX_FEED_AGE, VolMarket.QuantileConfig(_levels(), S)
        );
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            10_000,
            MAX_FEED_AGE,
            VolMarket.QuantileConfig(_levels(), S)
        );
        vm.expectRevert(VolMarket.InvalidParams.selector);
        new VolMarket(
            t,
            100,
            5000,
            p,
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            MAX_DEVIATION_BPS,
            0,
            VolMarket.QuantileConfig(_levels(), S)
        );
        VolMarket m = new VolMarket(
            t, 100, 5000, p, DELTA, N, COMMIT_LEAD, REVEAL_LEAD, 9999, 1, VolMarket.QuantileConfig(_levels(), S)
        );
        assertEq(m.maxDeviationBps(), 9999);
        assertEq(m.maxFeedAge(), 1);
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
    ///      with fuzzed quantile offsets split exactly the predictor share of the fee among those
    ///      beating the baseline quantiles, and the owner receives exactly the rest of the fee.
    function testFuzz_WinnersSplitExactlyTotalMinusFee(
        uint256[3] memory win,
        uint256 lose,
        uint256 feeBps,
        uint256 shareBps,
        int256[3] memory shift
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

        address[3] memory forecasters = _forecasters(id, shift);

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

    /// @dev Three commit-only forecasters centered `shift[i]` output steps off ln 49, committed and
    ///      revealed.
    function _forecasters(uint256 id, int256[3] memory shift) internal returns (address[3] memory f) {
        f = [makeAddr("f0"), makeAddr("f1"), makeAddr("f2")];
        for (uint256 i = 0; i < 3; ++i) {
            shift[i] = bound(shift[i], -4 * ONE, 4 * ONE);
            _commitOnly(id, f[i], _out(LN49 + shift[i], 300));
        }
        vm.warp(COMMIT_END);
        for (uint256 i = 0; i < 3; ++i) {
            _reveal(id, f[i], "", _out(LN49 + shift[i], 300));
        }
    }

    /// @dev Every forecaster above the baseline claims; returns the predictor share they split.
    function _claimPredictorShares(uint256 id, address[3] memory forecasters, uint256 fee, uint256 shareBps)
        internal
        returns (uint256 share)
    {
        (, uint256 base,) = market.getRoundScoring(id);
        uint256 excessSum;
        uint256[3] memory excess;
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 loss, uint256 ex) = market.getPredictionLoss(id, forecasters[i]);
            excess[i] = loss < base ? base - loss : 0;
            assertEq(ex, excess[i], "excess view");
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
        int256[] memory q = _baseline();
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(uint64(T0), b, q);
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(uint64(T0 + COMMIT_LEAD), b, q);
        vm.expectEmit(true, false, false, true, address(market));
        emit VolMarket.RoundCreated(0, uint64(T0 + COMMIT_LEAD + 1), b, q, _flatFeatures());
        market.createRound(uint64(T0 + COMMIT_LEAD + 1), b, q);
        b[2] = b[1];
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b, q);
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, new uint256[](5), q);
    }

    function _flatFeatures() internal pure returns (int256[16] memory feats) {}

    function test_CreateRoundRejectsBadBaseline() public {
        _deploy(0);
        vm.warp(T0);
        uint256[] memory b = _bounds();
        int256[] memory q = _baseline();

        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b, new int256[](4));
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b, new int256[](6));
        q[3] = q[2];
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b, q);
        q = _baseline();
        q[0] = market.Q_MIN() - 1;
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b, q);
        q = _baseline();
        q[4] = market.Q_MAX() + 1;
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.createRound(START, b, q);

        // the range ends are accepted and need not sit on the output grid
        q = _baseline();
        q[0] = market.Q_MIN();
        q[1] = 1;
        q[4] = market.Q_MAX();
        uint256 id = market.createRound(START, b, q);
        (int256 lnRv, uint256 baseLoss, int256[] memory got) = market.getRoundScoring(id);
        assertEq(lnRv, 0);
        assertEq(baseLoss, 0);
        _assertQuantiles(got, q);
    }
}
