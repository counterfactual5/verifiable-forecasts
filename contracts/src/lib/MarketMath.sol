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

    /// @dev 1e18 = 1.0 for ln values, quantiles, quantile levels and pinball losses.
    uint256 internal constant WAD = 1e18;
    /// @dev Safety range of a quantile of y = ln(RV), 1e18 ln units. ln of any reachable RV lies in
    ///      [0, 256 ln2 ~ 177.4] and plausible ones in [0, ~12]; the bounds keep exp(Q_MAX) * 1e18
    ///      far inside uint256 and the pinball terms far from overflow.
    int256 internal constant Q_MIN = -20e18;
    int256 internal constant Q_MAX = 60e18;
    /// @dev Largest expWad argument: exp(130) * 1e18 ~ 2.9e74 < 2^256 ~ 1.2e77.
    int256 internal constant EXP_MAX = 130e18;
    /// @dev Below this exp(x) * 1e18 < 1, so expWad returns 0.
    int256 internal constant EXP_MIN = -42e18;
    /// @dev Inputs below 2^LN_EXACT_BITS are reduced exactly: x * 1e18 < 2^196 * 2^60 = 2^256.
    uint256 internal constant LN_EXACT_BITS = 196;

    /// @dev ln(x) * 1e18 for an integer x >= 1; lnWad(1) = 0 exactly. Error < 1e9 (log1e18's) plus
    ///      < 0.42 per bit of LN2_1E18 truncation (< 110 for any uint256).
    ///      Range reduction: b = bit length of x, so m = x * 1e18 / 2^b is in [0.5e18, 1e18) and
    ///      ln(x) = ln(m / 1e18) + b * ln2. For b > 196 the low b - 196 bits of x are dropped first
    ///      (relative change < 2^-195) so the product stays below 2^256.
    function lnWad(uint256 x) internal pure returns (int256) {
        require(x >= 1, "ln domain");
        if (x == 1) return 0;
        uint256 b = _bitLength(x);
        uint256 m = b <= LN_EXACT_BITS ? (x * WAD) >> b : ((x >> (b - LN_EXACT_BITS)) * WAD) >> LN_EXACT_BITS;
        return log1e18(m) + int256(b) * int256(LN2_1E18);
    }

    /// @dev Number of significant bits of x > 0: x is in [2^(n-1), 2^n).
    function _bitLength(uint256 x) private pure returns (uint256 n) {
        for (uint256 s = 128; s > 0; s >>= 1) {
            if (x >> s != 0) {
                x >>= s;
                n += s;
            }
        }
        return n + 1;
    }

    /// @dev exp(x / 1e18) * 1e18, rounded down, for x <= EXP_MAX; 0 below EXP_MIN.
    ///      Range reduction: k = round(x / ln2), r = x - k ln2 in [-ln2/2, ln2/2], exp(r) by its
    ///      Taylor series (terms truncated toward zero), then shifted by k bits. Relative error
    ///      ~1e-17 above 1e18; below it the shift drops bits (absolute error < 2 wei).
    function expWad(int256 x) internal pure returns (uint256) {
        require(x <= EXP_MAX, "exp domain");
        if (x < EXP_MIN) return 0;
        int256 ln2 = int256(LN2_1E18);
        int256 k = (x >= 0 ? x + ln2 / 2 : x - ln2 / 2) / ln2;
        int256 r = x - k * ln2;
        int256 term = int256(WAD);
        int256 sum = term;
        for (int256 n = 1; term != 0; ++n) {
            term = (term * r) / (n * int256(WAD));
            sum += term;
        }
        return k >= 0 ? uint256(sum) << uint256(k) : uint256(sum) >> uint256(-k);
    }

    /// @dev Mean pinball loss of quantiles q at levels tau against outcome y, all 1e18-scaled:
    ///      u_k = y - q_k; rho_k = floor(tau_k * u_k / 1e18) if u_k >= 0, else
    ///      floor((1e18 - tau_k) * (-u_k) / 1e18); L = floor(sum rho_k / K).
    ///      Never reverts for |y|, |q_k| <= 2^190, tau_k <= 1e18 and K <= 16; outside that the checked
    ///      arithmetic reverts rather than wrapping.
    function pinball(int256 y, int256[] memory q, uint256[] memory tau) internal pure returns (uint256) {
        uint256 n = q.length;
        require(n > 0 && tau.length == n, "pinball shape");
        uint256 total;
        for (uint256 k = 0; k < n; ++k) {
            int256 u = y - q[k];
            total += u >= 0 ? (tau[k] * uint256(u)) / WAD : ((WAD - tau[k]) * uint256(-u)) / WAD;
        }
        return total / n;
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
