// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Integer fixed-point Uniswap V3 tick conversion for the USDC/WETH pool.
contract TickPriceMath {
    // 1e18 fixed-point scale for 1.0001^tick.
    uint256 private constant SCALE = 1e18;

    /// @return ETH/USD price with 8 decimals for token0=USDC (6 decimals), token1=WETH (18 decimals).
    function priceForTick(int24 tick) external pure returns (uint256) {
        uint256 ratio = SCALE;
        uint256 exponent = uint256(uint24(tick >= 0 ? tick : -tick));
        uint256 base = 1_000_100_000_000_000_000;
        while (exponent != 0) {
            if (exponent & 1 != 0) ratio = ratio * base / SCALE;
            exponent >>= 1;
            if (exponent != 0) base = base * base / SCALE;
        }
        // Tick gives raw token1/token0; USD per ETH (8 decimals) is reciprocal for positive ticks.
        return tick >= 0 ? SCALE * 1e20 / ratio : ratio * 100;
    }
}
