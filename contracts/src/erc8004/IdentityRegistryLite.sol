// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC8004Identity} from "../interfaces/IERC8004Identity.sol";

/// @title IdentityRegistryLite
/// @notice Minimal local registry modeled on the ERC-8004 identity registry of
///         erc-8004/erc-8004-contracts v2.0.0, with the deviations listed on
///         IERC8004Identity. For unit tests and offline demos only.
/// @dev Agent ids are minted starting at 1; the caller of `register` is the owner. No
///      transfers or approvals in the Lite subset.
contract IdentityRegistryLite is IERC8004Identity {
    error AgentNotFound(uint256 agentId);

    uint256 private _nextAgentId = 1;

    mapping(uint256 agentId => address owner) private _owners;
    mapping(uint256 agentId => string agentURI) private _uris;

    function register(string calldata agentURI) external override returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _owners[agentId] = msg.sender;
        _uris[agentId] = agentURI;
        emit Registered(agentId, agentURI, msg.sender);
    }

    function ownerOf(uint256 agentId) external view override returns (address) {
        address owner = _owners[agentId];
        if (owner == address(0)) revert AgentNotFound(agentId);
        return owner;
    }

    function agentCount() external view override returns (uint256) {
        return _nextAgentId - 1;
    }

    function getAgentURI(uint256 agentId) external view override returns (string memory) {
        if (_owners[agentId] == address(0)) revert AgentNotFound(agentId);
        return _uris[agentId];
    }
}
