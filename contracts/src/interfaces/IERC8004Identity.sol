// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ERC-8004 agent identity interface
/// @notice Mirrors the identity half of ERC-8004 as deployed by the reference
///         implementation erc-8004/erc-8004-contracts v2.0.0 (getVersion() == "2.0.0");
///         see spikes/facts/FACTS.md section 4. Minimal local subset for unit tests
///         and offline demos: signatures are pinned, VolMarket wiring consumes them.
interface IERC8004Identity {
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    function register(string calldata agentURI) external returns (uint256 agentId);

    function ownerOf(uint256 agentId) external view returns (address);

    function agentCount() external view returns (uint256);

    function getAgentURI(uint256 agentId) external view returns (string memory);
}
