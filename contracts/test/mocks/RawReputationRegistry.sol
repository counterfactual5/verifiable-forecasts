// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Reputation registry returning arbitrary getSummary bytes per agent, for exercising a
///         consumer's shape and range checks. readFeedback returns the records set per agent.
/// @dev Client and tag arguments are ignored; an agent without a summary returns empty data.
contract RawReputationRegistry {
    error FeedbackDisabled();

    bool public feedbackReverts;
    mapping(uint256 => bytes) private summaries;
    mapping(uint256 => string[]) private tag1sOf;
    mapping(uint256 => string[]) private tag2sOf;

    function setSummary(uint256 agentId, bytes calldata raw) external {
        summaries[agentId] = raw;
    }

    function addRecord(uint256 agentId, string calldata tag1, string calldata tag2) external {
        tag1sOf[agentId].push(tag1);
        tag2sOf[agentId].push(tag2);
    }

    function setFeedbackReverts(bool reverts_) external {
        feedbackReverts = reverts_;
    }

    function getSummary(uint256 agentId, address[] calldata, string calldata, string calldata) external view {
        bytes memory raw = summaries[agentId];
        assembly {
            return(add(raw, 32), mload(raw))
        }
    }

    function readFeedback(uint256 agentId, address)
        external
        view
        returns (int128[] memory values, uint8[] memory valueDecimals, string[] memory tag1s, string[] memory tag2s)
    {
        if (feedbackReverts) revert FeedbackDisabled();
        tag1s = tag1sOf[agentId];
        tag2s = tag2sOf[agentId];
        values = new int128[](tag1s.length);
        valueDecimals = new uint8[](tag1s.length);
    }
}
