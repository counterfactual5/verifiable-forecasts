// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MarketMath
/// @notice Pure math shared by parimutuel bucket markets (bucketing, log score, payouts).
library MarketMath {
    uint256 internal constant LN2_1E18 = 0.693147180559945309e18;
    uint256 internal constant BPS = 10000;

    /// @dev bucket index for value v over ascending bounds:
    ///      bucket 0: v < bounds[0]; bucket i: bounds[i-1] <= v < bounds[i];
    ///      bucket n: v >= bounds[n-1].
    function bucketOf(int256[] memory bounds, int256 v) internal pure returns (uint256) {
        uint256 n = bounds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (v < bounds[i]) return i;
        }
        return n;
    }

    /// @dev Same half-open semantics as the int256 overload, for non-negative values.
    function bucketOf(uint256[] memory bounds, uint256 v) internal pure returns (uint256) {
        uint256 n = bounds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (v < bounds[i]) return i;
        }
        return n;
    }

    /// @dev ln(x/1e18) * 1e18 for x in [1, 1e18]; result <= 0, abs error < 1e9.
    ///      Range reduction: x = m * 2^-e with m/1e18 in [0.5, 1), then
    ///      ln(x/1e18) = ln(m/1e18) - e*ln2, where ln(m) uses
    ///      ln(m) = 2*artanh((m-1)/(m+1)) with |y| <= 1/3 (fast convergence).
    function log1e18(uint256 x) internal pure returns (int256) {
        require(x >= 1 && x <= 1e18, "log domain");
        uint256 e;
        uint256 m = x;
        while (m * 2 < 1e18) {
            m *= 2;
            ++e;
        }
        // now m in [0.5e18, 1e18)
        int256 num = int256(m) - 1e18;
        int256 den = int256(m) + 1e18;
        int256 y = (num * 1e18) / den; // y in [-1/3, 0]
        int256 y2 = (y * y) / 1e18; // <= 1/9
        int256 term = y;
        int256 sum;
        for (uint256 k = 0; k < 24; ++k) {
            sum += term / int256(2 * k + 1);
            term = (term * y2) / 1e18;
            if (term == 0) break;
        }
        int256 ln = 2 * sum - int256(e) * int256(LN2_1E18);
        require(ln <= 0, "ln(p<=1) must be <= 0");
        return ln;
    }

    /// @dev Protocol fee on the whole pool, rounded down.
    function fee(uint256 total, uint256 feeBps) internal pure returns (uint256) {
        return (total * feeBps) / BPS;
    }

    /// @dev Pro-rata parimutuel payout: stake * (total - fee) / winners, rounded down.
    function payout(uint256 stake, uint256 total, uint256 winners, uint256 feeBps) internal pure returns (uint256) {
        return (stake * (total - fee(total, feeBps))) / winners;
    }
}
