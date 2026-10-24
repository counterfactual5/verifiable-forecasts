// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MarketMath} from "../src/lib/MarketMath.sol";

/// @dev Library calls go through this wrapper so that their reverts can be expected.
contract MarketMathHarness {
    function lnWad(uint256 x) external pure returns (int256) {
        return MarketMath.lnWad(x);
    }

    function expWad(int256 x) external pure returns (uint256) {
        return MarketMath.expWad(x);
    }

    function pinball(int256 y, int256[] memory q, uint256[] memory tau) external pure returns (uint256) {
        return MarketMath.pinball(y, q, tau);
    }
}

contract MarketMathTest is Test {
    int256 constant LN2 = 0.693147180559945309e18;
    MarketMathHarness h;

    function setUp() public {
        h = new MarketMathHarness();
    }

    function _levels() internal pure returns (uint256[] memory t) {
        t = new uint256[](5);
        t[0] = 1e17;
        t[1] = 25e16;
        t[2] = 5e17;
        t[3] = 75e16;
        t[4] = 9e17;
    }

    function _q(int256 a, int256 b, int256 c, int256 d, int256 e) internal pure returns (int256[] memory q) {
        q = new int256[](5);
        q[0] = a;
        q[1] = b;
        q[2] = c;
        q[3] = d;
        q[4] = e;
    }

    function test_Log1e18_Precision() public pure {
        // ln(0.5) = -0.6931471805599453
        assertApproxEqAbs(MarketMath.log1e18(0.5e18), -0.6931471805599453e18, 1e9);
        // ln(0.9) = -0.10536051565782628
        assertApproxEqAbs(MarketMath.log1e18(9e17), -0.10536051565782628e18, 1e9);
        // ln(0.01) = -4.605170185988091
        assertApproxEqAbs(MarketMath.log1e18(1e16), -4.605170185988091e18, 1e9);
        // ln(1e-9) = -20.72326583694641
        assertApproxEqAbs(MarketMath.log1e18(1e9), -20.723265836946411e18, 1e9);
    }

    // ---------------------------------------------------------------- lnWad
    function test_LnWadExactPoints() public pure {
        assertEq(MarketMath.lnWad(1), 0, "ln 1 is exactly 0, the RV floor");
        assertApproxEqAbs(MarketMath.lnWad(2), LN2, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(3), 1.098612288668109691e18, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(49), 3.89182029811062661e18, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(900), 6.802394763324311192e18, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(1e18), 41.446531673892822312e18, 1e9);
        // ln(e^k) for integers nearest e^20 and e^40 (floor(e^k) differs from e^k by < 1)
        assertApproxEqAbs(MarketMath.lnWad(485165195), 20e18, 1e10);
        assertApproxEqAbs(MarketMath.lnWad(235385266837019985), 40e18, 1e10);
    }

    function test_LnWadExtremeInputs() public pure {
        // 2^k is exact in the range reduction: ln = k * ln2
        assertApproxEqAbs(MarketMath.lnWad(1 << 100), 100 * LN2, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(1 << 196), 196 * LN2, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(1 << 200), 200 * LN2, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(1 << 255), 255 * LN2, 1e9);
        // ln(2^256 - 1) = 256 ln2 - 2^-256
        assertApproxEqAbs(MarketMath.lnWad(type(uint256).max), 256 * LN2, 1e9);
        assertApproxEqAbs(MarketMath.lnWad(type(uint256).max / 3), 256 * LN2 - 1.098612288668109691e18, 1e9);
    }

    function test_LnWadRejectsZero() public {
        vm.expectRevert(bytes("ln domain"));
        h.lnWad(0);
    }

    /// @dev Never reverts on its domain, and ln(2x) - ln(x) stays ln2.
    function testFuzz_LnWadDoublingAddsLn2(uint256 x) public pure {
        x = bound(x, 1, type(uint256).max / 2);
        int256 a = MarketMath.lnWad(x);
        int256 b = MarketMath.lnWad(2 * x);
        assertGe(a, 0);
        assertApproxEqAbs(b - a, LN2, 2e9);
    }

    function testFuzz_LnWadMonotone(uint256 x, uint256 y) public pure {
        x = bound(x, 1, type(uint256).max);
        y = bound(y, x, type(uint256).max);
        // series error is below 1e9, so ln may only step back by that much on ties of the reduction
        assertGe(MarketMath.lnWad(y) + 2e9, MarketMath.lnWad(x));
    }

    // ---------------------------------------------------------------- expWad
    function test_ExpWadPoints() public pure {
        assertEq(MarketMath.expWad(0), 1e18);
        assertApproxEqRel(MarketMath.expWad(1e18), 2.718281828459045235e18, 1e3);
        assertApproxEqRel(MarketMath.expWad(-1e18), 0.367879441171442321e18, 1e3);
        assertApproxEqRel(MarketMath.expWad(LN2 * 10), 1024e18, 1e3);
        assertApproxEqRel(MarketMath.expWad(6.802394763324311192e18), 900e18, 1e3);
        // the quantile range [Q_MIN, Q_MAX]
        assertApproxEqRel(MarketMath.expWad(MarketMath.Q_MAX), 114200738981568428366295718.3e18, 1e3);
        assertApproxEqRel(MarketMath.expWad(MarketMath.Q_MIN), 2061153622, 1e9);
        assertEq(MarketMath.expWad(-42e18), 0, "underflows to 0 below 1 wei");
        assertEq(MarketMath.expWad(type(int256).min), 0);
    }

    function test_ExpWadDomainGuard() public {
        h.expWad(MarketMath.EXP_MAX);
        vm.expectRevert(bytes("exp domain"));
        h.expWad(MarketMath.EXP_MAX + 1);
    }

    function testFuzz_ExpWadInvertsLnWad(uint256 x) public pure {
        x = bound(x, 1, 1e40);
        assertApproxEqRel(MarketMath.expWad(MarketMath.lnWad(x)), x * 1e18, 1e9);
    }

    // ---------------------------------------------------------------- pinball
    /// @dev y = 1: per level u = 1 - q; rho = tau * u for u >= 0, (1 - tau) * (-u) otherwise.
    function test_PinballHandValues() public view {
        int256[] memory q = _q(-1e18, 0, 1e18, 2e18, 3e18);
        // u = 2, 1, 0, -1, -2 => 0.2, 0.25, 0, 0.25, 0.2 => sum 0.9 / 5
        assertEq(h.pinball(1e18, q, _levels()), 0.18e18);
        // y far above every quantile: sum tau_k * (y - q_k) / 5
        assertEq(h.pinball(10e18, q, _levels()), (1e17 * 11 + 25e16 * 10 + 5e17 * 9 + 75e16 * 8 + 9e17 * 7) / 5);
        // y exactly on every quantile: 0
        assertEq(h.pinball(5e18, _q(5e18, 5e18, 5e18, 5e18, 5e18), _levels()), 0);
    }

    function test_PinballFloorsEachTermAndTheMean() public view {
        uint256[] memory tau = new uint256[](3);
        tau[0] = 1;
        tau[1] = 5e17;
        tau[2] = 1e18 - 1;
        int256[] memory q = new int256[](3);
        q[0] = 0;
        q[1] = 0;
        q[2] = 2;
        // u = 1, 1, -1 => floor(1e-18) = 0, floor(0.5) = 0, floor(1e-18) = 0
        assertEq(h.pinball(1, q, tau), 0);
        // u = 3e18, 3e18, 3e18 - 2 => 3, 1.5e18, floor((3e18-2)(1e18-1)/1e18) => total / 3 floored
        uint256 t2 = uint256(1e18 - 1) * (3e18 - 2) / 1e18;
        assertEq(h.pinball(3e18, q, tau), (3 + 1.5e18 + t2) / 3);
    }

    function test_PinballRejectsBadShape() public {
        vm.expectRevert(bytes("pinball shape"));
        h.pinball(0, new int256[](0), new uint256[](0));
        vm.expectRevert(bytes("pinball shape"));
        h.pinball(0, new int256[](5), new uint256[](4));
    }

    /// @dev Documented safe range: |y|, |q_k| <= 2^190 and tau < 1e18 never revert, and the loss is
    ///      at most max |y - q_k|.
    function testFuzz_PinballNoOverflowInBounds(int256 y, int256[5] memory raw) public view {
        int256 lim = int256(1 << 190);
        y = bound(y, -lim, lim);
        int256[] memory q = new int256[](5);
        uint256 maxGap;
        for (uint256 k = 0; k < 5; ++k) {
            q[k] = bound(raw[k], -lim, lim);
            uint256 gap = y >= q[k] ? uint256(y - q[k]) : uint256(q[k] - y);
            if (gap > maxGap) maxGap = gap;
        }
        assertLe(h.pinball(y, q, _levels()), maxGap);
    }

    /// @dev Values past int256 never wrap: the checked subtraction reverts instead.
    function test_PinballRevertsInsteadOfWrapping() public {
        vm.expectRevert();
        h.pinball(type(int256).max, _q(-1, 0, 1, 2, 3), _levels());
        vm.expectRevert();
        h.pinball(type(int256).min, _q(1, 2, 3, 4, 5), _levels());
    }

    function testFuzz_PinballZeroOnlyWhenOnEveryQuantile(int256 y, int256 shift) public view {
        y = bound(y, -100e18, 100e18);
        shift = bound(shift, 1e6, 10e18);
        assertEq(h.pinball(y, _q(y, y, y, y, y), _levels()), 0);
        assertGt(h.pinball(y + shift, _q(y, y, y, y, y), _levels()), 0);
        assertGt(h.pinball(y - shift, _q(y, y, y, y, y), _levels()), 0);
    }
}
