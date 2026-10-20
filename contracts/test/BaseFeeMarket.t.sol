// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseFeeMarket} from "../src/BaseFeeMarket.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ExposedHelpers} from "../src/ExposedHelpers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BaseFeeMarketTest is Test {
    BaseFeeMarket market;
    MockERC20 token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant PRECISION = 1e18;

    function setUp() public {
        token = new MockERC20();
        market = new BaseFeeMarket(IERC20(address(token)), 0); // 0 fee for most tests
        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);
    }

    // -------- helpers --------------------------------------------------

    /// @dev bounds for ~0.2 gwei basefee scenarios, in wei:
    /// buckets: [0, 0.16g), [0.16g, 0.20g), [0.20g, 0.26g), [0.26g, inf)
    function _bounds() internal pure returns (int256[] memory b) {
        b = new int256[](3);
        b[0] = int256(uint256(0.16e9));
        b[1] = int256(uint256(0.2e9));
        b[2] = int256(uint256(0.26e9));
    }

    function _window(uint256 start, uint256 len) internal view returns (uint256 end) {
        return start + len - 1;
    }

    /// @dev full life: create at block `start-2`, bets, roll through window with basefee `fee`, settle
    function _runRound(uint256 start, uint256 len, uint256 baseFeeWei) internal returns (uint256 id) {
        vm.roll(start - 2);
        id = market.createRound(start, _window(start, len), _bounds());

        vm.prank(alice);
        market.bet(id, 1, 100e18);
        vm.prank(bob);
        market.bet(id, 2, 100e18);

        for (uint256 i = 0; i < len; ++i) {
            vm.roll(start + i);
            vm.fee(baseFeeWei);
            market.sample(id);
        }
        vm.roll(_window(start, len) + 1);
        market.settle(id);
    }

    // -------- lifecycle --------------------------------------------------

    function test_FullLifecycle_ParimutuelSplit() public {
        uint256 id = _runRound(100, 10, 0.21e9); // avg 0.21g -> bucket 2 (bob)

        (
            ,
            uint256 endBlk,,
            uint256[] memory pools,
            uint256 total,
            uint256 seen,
            uint256 sum,
            uint256 win,
            bool voided,
        ) = market.getRound(id);
        assertEq(endBlk, 109);
        assertEq(pools.length, 4);
        assertEq(seen, 10);
        assertEq(win, 2, "winning bucket");
        assertEq(sum, 0.21e9 * 10, "sum of sampled fees");
        assertEq(total, 200e18);

        // bob gets the whole pool (minus 0 fee)
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        market.claim(id);
        assertEq(token.balanceOf(bob) - before, 200e18, "bob takes all");
    }

    function test_ProRataSplit_TwoWinners() public {
        vm.roll(98);
        uint256 id = market.createRound(100, _window(100, 10), _bounds());
        vm.prank(alice);
        market.bet(id, 2, 100e18); // alice on winning bucket
        vm.prank(bob);
        market.bet(id, 2, 300e18); // bob on winning bucket

        for (uint256 i = 0; i < 10; ++i) {
            vm.roll(100 + i);
            vm.fee(0.22e9);
            market.sample(id);
        }
        vm.roll(111);
        market.settle(id);

        uint256 aBefore = token.balanceOf(alice);
        uint256 bBefore = token.balanceOf(bob);
        vm.prank(alice);
        market.claim(id);
        vm.prank(bob);
        market.claim(id);
        assertEq(token.balanceOf(alice) - aBefore, 100e18, "alice quarter");
        assertEq(token.balanceOf(bob) - bBefore, 300e18, "bob three quarters");
    }

    // -------- boundary buckets ------------------------------------------

    function test_Boundary_BelowFirst() public {
        uint256 id = _runRound(200, 5, 0.1e9); // avg below bounds[0]=0.16g
        (,,,,,,, uint256 win,,) = market.getRound(id);
        assertEq(win, 0);
    }

    function test_Boundary_ExactlyOnEdge() public {
        // avg exactly 0.20e9 == bounds[1] -> bucket 2 ([0.20, 0.26)半开: v < bounds[i] rule => v=0.20 < 0.26 => bucket 2)
        uint256 id = _runRound(300, 4, 0.2e9);
        (,,,,,,, uint256 win,,) = market.getRound(id);
        assertEq(win, 2, "value equal to lower edge belongs to upper bucket");
    }

    function test_Boundary_AboveLast() public {
        uint256 id = _runRound(400, 4, 0.3e9);
        (,,,,,,, uint256 win,,) = market.getRound(id);
        assertEq(win, 3, "above last bound -> top bucket");
    }

    // -------- coverage void ----------------------------------------------

    function test_LowCoverage_VoidedRefund() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 109, _bounds());
        vm.prank(alice);
        market.bet(id, 1, 100e18);
        vm.prank(bob);
        market.bet(id, 2, 50e18);

        // sample only 5 of 10 blocks (50% < 90%)
        for (uint256 i = 0; i < 5; ++i) {
            vm.roll(100 + i);
            vm.fee(0.21e9);
            market.sample(id);
        }
        vm.roll(110);
        market.settle(id);

        (,,,, uint256 total,,,, bool voided,) = market.getRound(id);
        assertTrue(voided);
        assertEq(total, 150e18);

        uint256 aBefore = token.balanceOf(alice);
        uint256 bBefore = token.balanceOf(bob);
        vm.prank(alice);
        market.claim(id);
        vm.prank(bob);
        market.claim(id);
        assertEq(token.balanceOf(alice) - aBefore, 100e18, "alice refund");
        assertEq(token.balanceOf(bob) - bBefore, 50e18, "bob refund");
    }

    // -------- guard rails -------------------------------------------------

    function test_DoubleClaim_Reverts() public {
        uint256 id = _runRound(500, 5, 0.21e9);
        vm.prank(bob);
        market.claim(id);
        vm.prank(bob);
        vm.expectRevert(BaseFeeMarket.NothingToClaim.selector);
        market.claim(id);
    }

    function test_SampleOutsideWindow_Reverts() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        vm.roll(99);
        vm.expectRevert(BaseFeeMarket.SamplingNotStarted.selector);
        market.sample(id);
        vm.roll(106);
        vm.expectRevert(BaseFeeMarket.SamplingOngoing.selector);
        market.sample(id);
    }

    function test_DoubleSample_Reverts() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        vm.roll(100);
        vm.fee(0.2e9);
        market.sample(id);
        vm.expectRevert(BaseFeeMarket.AlreadySampled.selector);
        market.sample(id);
    }

    function test_BetAfterOpen_Reverts() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        vm.roll(100);
        vm.prank(alice);
        vm.expectRevert(BaseFeeMarket.BettingClosed.selector);
        market.bet(id, 1, 10e18);
    }

    function test_FeeTakenOnWinnings() public {
        BaseFeeMarket feeMarket = new BaseFeeMarket(IERC20(address(token)), 100); // 1%
        vm.prank(alice);
        token.approve(address(feeMarket), type(uint256).max);
        vm.prank(bob);
        token.approve(address(feeMarket), type(uint256).max);
        vm.roll(98);
        uint256 id = feeMarket.createRound(100, 104, _bounds());
        vm.prank(alice);
        feeMarket.bet(id, 1, 100e18);
        vm.prank(bob);
        feeMarket.bet(id, 1, 100e18);
        // settle on bucket 2 instead so alice+bob are NOT both winners... they bet bucket 1;
        // make fee land in bucket 1: 0.18e9 < bounds[1]=0.20e9 -> bucket 1 wins
        for (uint256 i = 0; i < 5; ++i) {
            vm.roll(100 + i);
            vm.fee(0.18e9);
            feeMarket.sample(id);
        }
        vm.roll(106);
        feeMarket.settle(id);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        feeMarket.claim(id);
        // pool 200, winners(alice+bob)=200, fee 2 => alice(100/200)*198 = 99
        assertApproxEqAbs(token.balanceOf(alice) - before, 99e18, 1, "pro-rata share net of 1% fee");
    }

    // -------- contract reads CURRENT block basefee (anti-fakeout) -----------

    function test_SettlementUsesCurrentBlockBaseFee() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        vm.prank(alice);
        market.bet(id, 2, 100e18);
        // window with alternating fees: avg = (0.20+0.22+0.20+0.22+0.20)/5 = 0.208
        uint256[5] memory fees = [uint256(0.2e9), 0.22e9, 0.2e9, 0.22e9, 0.2e9];
        for (uint256 i = 0; i < 5; ++i) {
            vm.roll(100 + i);
            vm.fee(fees[i]);
            market.sample(id);
        }
        vm.roll(106);
        market.settle(id);
        (,,,,,, uint256 sum, uint256 win,,) = market.getRound(id);
        assertEq(sum, 1.04e9, "sum of alternating fees");
        assertEq(win, 2, "avg 0.208 -> bucket 2");
    }

    // -------- predictions & scoring ----------------------------------------

    function _probs3(uint256 p0, uint256 p1, uint256 p2, uint256 p3) internal pure returns (uint256[] memory p) {
        p = new uint256[](4);
        p[0] = p0;
        p[1] = p1;
        p[2] = p2;
        p[3] = p3;
    }

    function test_PredictionScoring() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        // alice: confident-and-right on bucket 2; bob: confident-and-wrong
        vm.prank(alice);
        market.recordPrediction(id, _probs3(0, 0, PRECISION, 0));
        vm.prank(bob);
        market.recordPrediction(id, _probs3(0, 0, 0, PRECISION));
        // carol: uniform 25/25/25/25
        address carol = makeAddr("carol");
        vm.prank(carol);
        market.recordPrediction(id, _probs3(PRECISION / 4, PRECISION / 4, PRECISION / 4, PRECISION / 4));

        for (uint256 i = 0; i < 5; ++i) {
            vm.roll(100 + i);
            vm.fee(0.21e9);
            market.sample(id);
        }
        vm.roll(106);
        market.settle(id);

        (, uint256[] memory aP, int256 aS) = market.getPrediction(id, alice);
        (, uint256[] memory bP, int256 bS) = market.getPrediction(id, bob);
        (, uint256[] memory cP, int256 cS) = market.getPrediction(id, carol);

        assertEq(aP[2], PRECISION);
        // ln(1)=0
        assertEq(aS, 0, "perfect prediction scores 0");
        // ln(0) floored at -18e18
        assertEq(bS, -18e18, "zero prob on outcome floors");
        // ln(0.25) = -1.3862943611
        assertApproxEqAbs(cS, -1.3862943611198906e18, 1e9, "uniform logscore");
        assertGt(aS, cS, "right beats uniform");
        assertGt(cS, bS, "uniform beats wrong");

        assertEq(market.predictorCount(id), 3);
    }

    function test_Prediction_ProbMustSumToOne() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        vm.prank(alice);
        vm.expectRevert(BaseFeeMarket.BadProbabilityVector.selector);
        market.recordPrediction(id, _probs3(PRECISION / 2, 0, 0, 0));
    }

    function test_Prediction_TooLateAfterWindowStart() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        vm.roll(100);
        vm.prank(alice);
        vm.expectRevert(BaseFeeMarket.TooLateToPredict.selector);
        market.recordPrediction(id, _probs3(0, 0, PRECISION, 0));
    }

    function test_Prediction_OverwriteBeforeStart() public {
        vm.roll(98);
        uint256 id = market.createRound(100, 104, _bounds());
        vm.startPrank(alice);
        market.recordPrediction(id, _probs3(0, PRECISION, 0, 0));
        market.recordPrediction(id, _probs3(0, 0, PRECISION, 0)); // overwrite ok
        vm.stopPrank();
        assertEq(market.predictorCount(id), 1, "overwrite does not duplicate");
        (, uint256[] memory p,) = market.getPrediction(id, alice);
        assertEq(p[2], PRECISION);
    }

    // -------- creation validation ------------------------------------------

    function test_CreateBadBounds_Reverts() public {
        int256[] memory b = new int256[](2);
        b[0] = 5;
        b[1] = 5; // non-strictly-increasing
        vm.expectRevert(BaseFeeMarket.InvalidParams.selector);
        market.createRound(100, 104, b);
    }

    function test_CreateWindowTooLong_Reverts() public {
        vm.expectRevert(BaseFeeMarket.InvalidParams.selector);
        market.createRound(100, 100 + 256, _bounds()); // 257 blocks
    }

    // -------- log1e18 precision sanity ---------------------------------------

    function test_Log1e18_Precision() public {
        ExposedHelpers h = new ExposedHelpers(market);
        // ln(0.5) = -0.6931471805599453
        assertApproxEqAbs(h.exposed_log1e18(PRECISION / 2), -0.6931471805599453e18, 1e9);
        // ln(0.9) = -0.10536051565782628
        assertApproxEqAbs(h.exposed_log1e18(9e17), -0.10536051565782628e18, 1e9);
        // ln(0.01) = -4.605170185988091
        assertApproxEqAbs(h.exposed_log1e18(1e16), -4.605170185988091e18, 1e9);
        // ln(1e-9) = -20.72326583694641
        assertApproxEqAbs(h.exposed_log1e18(1e9), -20.723265836946411e18, 1e9);
    }
}
