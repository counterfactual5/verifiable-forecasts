// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC8004Reputation} from "../interfaces/IERC8004Reputation.sol";

/// @title ReputationRegistryLite
/// @notice Minimal local subset of the ERC-8004 agent reputation registry, matching the
///         interface of the reference implementation erc-8004/erc-8004-contracts v2.0.0
///         (getVersion() == "2.0.0"). For unit tests and offline demos only.
/// @dev Anyone may submit feedback (no access control) and values may be negative.
///      Summaries normalize every record to 18 decimals before averaging, so record
///      values with fewer decimals are upscaled (a record with `valueDecimals == 0`
///      contributes `value * 1e18`).
contract ReputationRegistryLite is IERC8004Reputation {
    struct FeedbackRecord {
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
    }

    /// @dev Fixed decimals every summary is expressed in.
    uint8 private constant SUMMARY_DECIMALS = 18;

    error EmptyClientAddresses();
    error UnsupportedDecimals(uint8 valueDecimals);

    // agentId => client => appended feedback records
    mapping(uint256 agentId => mapping(address client => FeedbackRecord[] records)) private _records;

    /// @dev The dynamic parameters are taken as `memory` instead of `calldata`: the selector
    ///      and the ABI are unchanged, but a frame holding four `calldata` strings does not
    ///      fit the stack budget of the legacy code generator.
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string memory tag1,
        string memory tag2,
        string memory,
        string memory,
        bytes32
    ) external override {
        // `endpoint`, `feedbackURI` and `feedbackHash` are part of the pinned ERC-8004
        // signature but no Lite query reads them, so they are not stored.
        _records[agentId][msg.sender].push(
            FeedbackRecord({value: value, valueDecimals: valueDecimals, tag1: tag1, tag2: tag2})
        );
        emit NewFeedback(agentId, msg.sender, value, valueDecimals, tag1, tag2);
    }

    /// @notice Average over the records of `clientAddresses` whose tags match: an empty
    ///         query tag is a wildcard, a non-empty one must equal the stored tag.
    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external
        view
        override
        returns (int256)
    {
        if (clientAddresses.length == 0) revert EmptyClientAddresses();

        int256 sum;
        uint256 matched;
        for (uint256 i = 0; i < clientAddresses.length; ++i) {
            FeedbackRecord[] storage records = _records[agentId][clientAddresses[i]];
            for (uint256 j = 0; j < records.length; ++j) {
                FeedbackRecord storage record = records[j];
                if (!_tagMatches(tag1, record.tag1) || !_tagMatches(tag2, record.tag2)) continue;
                sum += _normalize(record.value, record.valueDecimals);
                ++matched;
            }
        }
        if (matched == 0) return 0;
        return sum / int256(matched);
    }

    /// @dev Public (not external) so that both parameters are dead before the ABI encoder
    ///      runs: the legacy code generator cannot encode four dynamic return values from
    ///      an external function.
    function readFeedback(uint256 agentId, address client)
        public
        view
        override
        returns (int128[] memory values, uint8[] memory valueDecimals, string[] memory tag1s, string[] memory tag2s)
    {
        FeedbackRecord[] storage records = _records[agentId][client];
        values = new int128[](records.length);
        valueDecimals = new uint8[](records.length);
        tag1s = new string[](records.length);
        tag2s = new string[](records.length);
        for (uint256 i = 0; i < records.length; ++i) {
            values[i] = records[i].value;
            valueDecimals[i] = records[i].valueDecimals;
            tag1s[i] = records[i].tag1;
            tag2s[i] = records[i].tag2;
        }
    }

    /// @dev Scale `value` from `valueDecimals` to 18 decimals by integer multiplication;
    ///      decimals above 18 cannot be represented by upscaling.
    function _normalize(int128 value, uint8 valueDecimals) private pure returns (int256) {
        if (valueDecimals > SUMMARY_DECIMALS) revert UnsupportedDecimals(valueDecimals);
        uint256 factor = 10 ** uint256(SUMMARY_DECIMALS - valueDecimals);
        return int256(value) * int256(factor);
    }

    /// @dev An empty query tag matches any stored tag; otherwise both must hash equal.
    function _tagMatches(string calldata query, string storage stored) private view returns (bool) {
        if (bytes(query).length == 0) return true;
        return keccak256(bytes(query)) == keccak256(bytes(stored));
    }
}
