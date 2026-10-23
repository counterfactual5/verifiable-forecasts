// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Mainnet-shaped ERC-8004 v2.0.0 reputation registry: getSummary has the local
///         registry's selector but returns (count, summaryValue, summaryValueDecimals).
/// @dev Summaries are keyed by (agentId, client, tag1, tag2); any other query returns count 0.
contract MockReputationTuple {
    struct Summary {
        uint64 count;
        int128 value;
        uint8 decimals;
    }

    error SummaryDisabled();

    bool public reverts;
    mapping(bytes32 => Summary) private summaries;

    function setSummary(
        uint256 agentId,
        address client,
        string calldata tag1,
        string calldata tag2,
        uint64 count,
        int128 value,
        uint8 decimals
    ) external {
        summaries[_key(agentId, client, tag1, tag2)] = Summary({count: count, value: value, decimals: decimals});
    }

    function setReverts(bool reverts_) external {
        reverts = reverts_;
    }

    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals)
    {
        if (reverts) revert SummaryDisabled();
        if (clientAddresses.length != 1) return (0, 0, 0);
        Summary storage s = summaries[_key(agentId, clientAddresses[0], tag1, tag2)];
        return (s.count, s.value, s.decimals);
    }

    function _key(uint256 agentId, address client, string calldata tag1, string calldata tag2)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(agentId, client, tag1, tag2));
    }
}
