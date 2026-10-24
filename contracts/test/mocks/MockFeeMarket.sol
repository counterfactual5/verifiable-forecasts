// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVolMarketReader} from "../../src/VolFeeConsumer.sol";

/// @notice VolMarket read surface with settable rounds, forecasts, quantile levels and agent bindings.
contract MockFeeMarket is IVolMarketReader {
    struct Forecast {
        bool recorded;
        uint256 modelId;
        int256[] quantiles;
    }

    uint32 public revealLead;
    address public reputationRegistry;
    mapping(uint256 => bool) public agentBound;
    mapping(uint256 => uint256) public agentOfModel;
    mapping(uint256 => bool) public isZkModel;

    uint256[] private levels;
    mapping(uint256 => uint64) private startTimes;
    mapping(uint256 => address[]) private predictors;
    mapping(uint256 => mapping(address => Forecast)) private forecasts;

    /// @dev Levels default to VolMarket's [0.1, 0.25, 0.5, 0.75, 0.9] (1e18).
    constructor(uint32 revealLead_) {
        revealLead = revealLead_;
        levels = [uint256(1e17), 25e16, 5e17, 75e16, 9e17];
    }

    function setLevels(uint256[] calldata levels_) external {
        levels = levels_;
    }

    function quantileLevels() external view returns (uint256[] memory) {
        return levels;
    }

    function setRound(uint256 id, uint64 startTime) external {
        startTimes[id] = startTime;
    }

    function setReputationRegistry(address registry) external {
        reputationRegistry = registry;
    }

    function setModel(uint256 modelId, bool zk) external {
        isZkModel[modelId] = zk;
    }

    function bindAgent(uint256 modelId, uint256 agentId) external {
        agentBound[modelId] = true;
        agentOfModel[modelId] = agentId;
    }

    /// @notice Append `who` as a committed predictor; `recorded` false leaves it unrevealed.
    function addForecast(uint256 id, address who, bool recorded, uint256 modelId, int256[] calldata quantiles)
        external
    {
        predictors[id].push(who);
        forecasts[id][who] = Forecast({recorded: recorded, modelId: modelId, quantiles: quantiles});
    }

    function getRound(uint256 id)
        external
        view
        returns (uint64, bool, bool, uint256, uint256, uint256, uint256[5] memory, uint256[] memory)
    {
        uint256[5] memory pools;
        return (startTimes[id], false, false, 0, 0, 0, pools, new uint256[](4));
    }

    function predictorCount(uint256 id) external view returns (uint256) {
        return predictors[id].length;
    }

    function predictorAt(uint256 id, uint256 i) external view returns (address) {
        return predictors[id][i];
    }

    function getPrediction(uint256 id, address who) external view returns (bool, uint256, int256[] memory, int256) {
        Forecast storage f = forecasts[id][who];
        return (f.recorded, f.modelId, f.quantiles, 0);
    }
}
