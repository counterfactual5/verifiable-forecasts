// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice What VolMarket asks a bond registry before accepting a commit.
interface IBondGate {
    /// @return true when `modelId` holds at least its tier's required bond and is not withdrawing
    function isBonded(uint256 modelId) external view returns (bool);
}
