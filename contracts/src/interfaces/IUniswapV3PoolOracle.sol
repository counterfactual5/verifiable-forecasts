// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Oracle subset of IUniswapV3PoolDerivedState.
interface IUniswapV3PoolOracle {
    /// @dev Reverts ("OLD") for the whole batch if any requested point predates the oldest observation.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
