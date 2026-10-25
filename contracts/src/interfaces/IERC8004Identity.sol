// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ERC-8004 agent identity interface
/// @notice Minimal local interface modeled on the ERC-8004 identity registry of
///         erc-8004/erc-8004-contracts v2.0.0; see spikes/facts/FACTS.md section 4.
///         `register(string)`, `ownerOf` and `Registered` match v2.0.0. Deviations:
///         `agentCount` and `getAgentURI` do not exist in v2.0.0 (it is ERC-721 and
///         exposes `tokenURI`), and v2.0.0's other register overloads, metadata and
///         agent-wallet functions are omitted.
interface IERC8004Identity {
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    function register(string calldata agentURI) external returns (uint256 agentId);

    function ownerOf(uint256 agentId) external view returns (address);

    function agentCount() external view returns (uint256);

    function getAgentURI(uint256 agentId) external view returns (string memory);
}
