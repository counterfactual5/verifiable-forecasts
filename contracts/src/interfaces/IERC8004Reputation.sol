// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ERC-8004 agent reputation interface
/// @notice Mirrors the reputation half of ERC-8004 as deployed by the reference
///         implementation erc-8004/erc-8004-contracts v2.0.0 (getVersion() == "2.0.0");
///         see spikes/facts/FACTS.md section 4. Minimal local subset for unit tests
///         and offline demos: signatures are pinned, VolMarket wiring consumes them.
interface IERC8004Reputation {
    event NewFeedback(
        uint256 indexed agentId, address indexed client, int128 value, uint8 valueDecimals, string tag1, string tag2
    );

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    /// @return The average of the matching records, normalized to 18 decimals.
    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external
        view
        returns (int256);

    function readFeedback(uint256 agentId, address client)
        external
        view
        returns (int128[] memory values, uint8[] memory valueDecimals, string[] memory tag1s, string[] memory tag2s);
}
