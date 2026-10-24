// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC8004Reputation} from "./interfaces/IERC8004Reputation.sol";
import {MarketMath} from "./lib/MarketMath.sol";

/// @notice The VolMarket views VolFeeConsumer reads; VolMarket satisfies it as deployed.
interface IVolMarketReader {
    function getRound(uint256 id)
        external
        view
        returns (
            uint64 startTime,
            bool settled,
            bool voided,
            uint256 winningBucket,
            uint256 realizedVol,
            uint256 totalStake,
            uint256[5] memory pools,
            uint256[] memory bounds
        );
    function revealLead() external view returns (uint32);
    function predictorCount(uint256 id) external view returns (uint256);
    function predictorAt(uint256 id, uint256 i) external view returns (address);
    function getPrediction(uint256 id, address who)
        external
        view
        returns (bool recorded, uint256 modelId, int256[] memory quantiles, int256 score);
    function quantileLevels() external view returns (uint256[] memory);
    function agentBound(uint256 modelId) external view returns (bool);
    function agentOfModel(uint256 modelId) external view returns (uint256);
    function isZkModel(uint256 modelId) external view returns (bool);
    function reputationRegistry() external view returns (address);
}

/// @title VolFeeConsumer
/// @notice Sets an hourly AMM swap fee from a VolMarket round's revealed forecasts: each forecast
///         is K quantiles of y = ln RV; they are averaged level by level (Vincentization) with
///         weights from their models' ERC-8004 pinball reputation, and the mix's expected realized
///         variance maps linearly to a fee clamped to [minFee, maxFee].
/// @dev Simulation/demo only: the fee is computed and recorded here, no real pool fee changes.
///      A quote exists only between the reveal deadline (startTime - revealLead), when every
///      forecast that will ever be public is public, and startTime, after which the window it
///      prices has begun.
contract VolFeeConsumer {
    error InvalidParams();
    error TooEarly();
    error TooLate();
    error NoForecasts();
    error AlreadyRecorded();

    event FeeRecorded(uint256 indexed id, uint24 fee, uint256 expectedVarE18, int256[] mix);

    /// @dev 1e18 = 1.0 for quantile levels; quantiles, the mix, scores and reputation means are
    ///      1e18-scaled ln units / scores.
    uint256 private constant WAD = 1e18;
    /// @dev expectedVarE18 carries 1e18 (tick^2 * 1e18) and feePerVarE18 carries 1e18.
    uint256 private constant VAR_FEE_SCALE = 1e36;
    /// @dev ERC-8004 summaries are compared in 18 decimals; a mainnet summary with more decimals
    ///      cannot be upscaled and counts as no reputation.
    uint8 private constant REPUTATION_DECIMALS = 18;

    IVolMarketReader public immutable market;
    /// @dev ERC-8004 tags VolMarket writes scores under: tag1 "pinball", tag2 per model
    ///      "vol-<delta>s-<n>" for zk models and that plus "-commit" for commit-only ones.
    string public tag1;
    string public tag2Zk;
    string public tag2Commit;
    /// @dev Score (-mean pinball loss, 1e18) of the climatological baseline quantiles over the
    ///      training period: a model weighs its mean reputation score above this, 0 at or below.
    int256 public immutable baselineScore;
    /// @dev Fee in pips (Uniswap v3 fee units, 1e-6; 500 = 5 bps) per tick^2 of expected variance,
    ///      1e18-scaled. Calibrated offline from LVR (Milionis et al. 2022): a CPMM loses
    ///      sigma^2 / 8 of pool value per unit time, with the virtual value 2 * L * sqrt(P) for
    ///      concentrated liquidity and 1 tick = ln(1.0001) of log price; dividing by an expected
    ///      hourly volume gives the fee at which fee * volume ~= LVR. The contract is only the
    ///      linear map.
    uint256 public immutable feePerVarE18;
    /// @dev Fee bounds in pips.
    uint24 public immutable minFee;
    uint24 public immutable maxFee;

    /// @dev Fee in pips recorded for a round.
    mapping(uint256 => uint24) public feeOf;
    mapping(uint256 => bool) public feeRecorded;

    constructor(
        IVolMarketReader market_,
        string memory tag1_,
        string memory tag2Zk_,
        string memory tag2Commit_,
        int256 baselineScore_,
        uint256 feePerVarE18_,
        uint24 minFee_,
        uint24 maxFee_
    ) {
        if (address(market_) == address(0) || minFee_ > maxFee_) revert InvalidParams();
        // reputation means are int128 values: a baseline outside int128 makes every weight 0 or
        // lets mean - baseline approach 2^255
        if (baselineScore_ < type(int128).min || baselineScore_ > type(int128).max) revert InvalidParams();
        market = market_;
        tag1 = tag1_;
        tag2Zk = tag2Zk_;
        tag2Commit = tag2Commit_;
        baselineScore = baselineScore_;
        feePerVarE18 = feePerVarE18_;
        minFee = minFee_;
        maxFee = maxFee_;
    }

    /// @notice Fee for round `id` from its revealed forecasts, valid from the reveal deadline
    ///         until startTime.
    /// @return fee in pips, clamped to [minFee, maxFee]
    /// @return mix reputation-weighted quantiles of ln RV, 1e18, one per market quantile level
    /// @return expectedVarE18 E[RV] of the mix, tick^2 scaled by 1e18
    function quote(uint256 id) public view returns (uint24 fee, int256[] memory mix, uint256 expectedVarE18) {
        (uint64 startTime,,,,,,,) = market.getRound(id);
        if (block.timestamp < startTime - market.revealLead()) revert TooEarly();
        if (block.timestamp >= startTime) revert TooLate();
        uint256[] memory tau = market.quantileLevels();
        mix = _mix(id, tau.length);
        expectedVarE18 = _expectedVar(mix, tau);
        fee = _fee(expectedVarE18);
    }

    /// @notice Permissionless on-chain record of round `id`'s fee, once per round.
    function record(uint256 id) external returns (uint24 fee) {
        if (feeRecorded[id]) revert AlreadyRecorded();
        int256[] memory mix;
        uint256 expectedVarE18;
        (fee, mix, expectedVarE18) = quote(id);
        feeRecorded[id] = true;
        feeOf[id] = fee;
        emit FeeRecorded(id, fee, expectedVarE18, mix);
    }

    /// @dev E[RV] of the quantile function of RV = exp(y) by the midpoint rule over the levels:
    ///      sum_k w_k * exp(mix_k) / sum_k w_k, w_k = tau_{k+1} - tau_{k-1} with tau_0 = 0 and
    ///      tau_{K+1} = 1e18 (twice the midpoint weights; the factor cancels). Each mix_k is clamped
    ///      to [Q_MIN, Q_MAX] first, so exp stays below ~1.2e44 and w_k * exp below 2^256 / 16.
    function _expectedVar(int256[] memory mix, uint256[] memory tau) internal pure returns (uint256) {
        uint256 n = tau.length;
        uint256 weighted;
        uint256 totalW;
        for (uint256 k = 0; k < n; ++k) {
            uint256 w = (k + 1 < n ? tau[k + 1] : WAD) - (k > 0 ? tau[k - 1] : 0);
            int256 q = mix[k];
            if (q < MarketMath.Q_MIN) q = MarketMath.Q_MIN;
            if (q > MarketMath.Q_MAX) q = MarketMath.Q_MAX;
            weighted += w * MarketMath.expWad(q);
            totalW += w;
        }
        return weighted / totalW;
    }

    /// @dev mix_k = sum_i w_i * q_ik / W, Solidity division (rounds toward zero). A weighted mean
    ///      of increasing vectors is non-decreasing. Weights are < 2^129 (int128 means minus an
    ///      int128 baseline) and market quantiles |q| <= 60e18 < 2^66, so each product is < 2^195
    ///      and the sum over <= 32 forecasts stays far inside int256; anything larger reverts.
    function _mix(uint256 id, uint256 k) internal view returns (int256[] memory mix) {
        (int256[][] memory qs, uint256[] memory weights, uint256 n, uint256 totalWeight) = _forecasts(id, k);
        mix = new int256[](k);
        for (uint256 j = 0; j < k; ++j) {
            int256 sum;
            for (uint256 i = 0; i < n; ++i) {
                sum += int256(weights[i]) * qs[i][j];
            }
            mix[j] = sum / int256(totalWeight);
        }
    }

    /// @dev Revealed forecasts with K quantiles and their weights; committed-only entries are
    ///      skipped. A weight is the model's mean reputation score above baselineScore, 0 at or
    ///      below it, as VolMarket pays forecasters by their loss below the round's baseline loss.
    ///      Without a registry, when any revealed model has no reputation, or when every weight is
    ///      0, all revealed forecasts weigh the same. Equal weight is the simplest safe fallback,
    ///      and a partly rated round never silently drops its unrated forecasts.
    function _forecasts(uint256 id, uint256 k)
        internal
        view
        returns (int256[][] memory qs, uint256[] memory weights, uint256 n, uint256 totalWeight)
    {
        uint256 count = market.predictorCount(id);
        qs = new int256[][](count);
        weights = new uint256[](count);
        address registry = market.reputationRegistry();
        bool rated = registry != address(0);
        for (uint256 i = 0; i < count; ++i) {
            (bool recorded, uint256 modelId, int256[] memory q) = _prediction(id, i);
            if (!recorded || q.length != k) continue;
            qs[n] = q;
            if (rated) (rated, weights[n]) = _weight(registry, modelId);
            totalWeight += weights[n];
            ++n;
        }
        if (n == 0) revert NoForecasts();
        if (!rated || totalWeight == 0) {
            for (uint256 i = 0; i < n; ++i) {
                weights[i] = 1;
            }
            totalWeight = n;
        }
    }

    function _prediction(uint256 id, uint256 i)
        internal
        view
        returns (bool recorded, uint256 modelId, int256[] memory quantiles)
    {
        (recorded, modelId, quantiles,) = market.getPrediction(id, market.predictorAt(id, i));
    }

    function _weight(address registry, uint256 modelId) internal view returns (bool found, uint256 weight) {
        int256 mean;
        (found, mean) = _reputation(registry, modelId);
        if (found && mean > baselineScore) weight = uint256(mean - baselineScore);
    }

    /// @dev Mean score (1e18) of `modelId`'s agent over the market's feedback under this
    ///      consumer's tags. Mainnet ERC-8004 v2.0.0 returns (uint64 count, int128 mean, uint8
    ///      decimals) under the same getSummary selector as the local registry's single int256
    ///      (18 decimals), so the shape is told apart by return length. The local registry returns
    ///      0 for no record, which is also a perfect score: presence is decided by the record
    ///      count, never by the value. A failed call or any other shape counts as no reputation.
    function _reputation(address registry, uint256 modelId) internal view returns (bool found, int256 mean) {
        if (!market.agentBound(modelId)) return (false, 0);
        uint256 agentId = market.agentOfModel(modelId);
        string memory tag2 = market.isZkModel(modelId) ? tag2Zk : tag2Commit;
        address[] memory clients = new address[](1);
        clients[0] = address(market);
        (bool ok, bytes memory ret) = registry.staticcall(
            abi.encodeWithSelector(IERC8004Reputation.getSummary.selector, agentId, clients, tag1, tag2)
        );
        if (!ok) return (false, 0);
        if (ret.length == 96) return _decodeTupleSummary(ret);
        if (ret.length == 32) {
            if (_matchingRecords(registry, agentId, tag2) == 0) return (false, 0);
            int256 value = abi.decode(ret, (int256));
            if (value < type(int128).min || value > type(int128).max) return (false, 0);
            return (true, value);
        }
        return (false, 0);
    }

    /// @dev Decoded as full words and range-checked, so a dirty return counts as no reputation
    ///      instead of reverting the quote.
    function _decodeTupleSummary(bytes memory ret) internal pure returns (bool found, int256 mean) {
        (uint256 count, int256 value, uint256 decimals) = abi.decode(ret, (uint256, int256, uint256));
        if (count == 0 || count > type(uint64).max || decimals > REPUTATION_DECIMALS) return (false, 0);
        if (value < type(int128).min || value > type(int128).max) return (false, 0);
        return (true, value * int256(10 ** (REPUTATION_DECIMALS - decimals)));
    }

    /// @dev Records the market wrote for `agentId` under this consumer's tags.
    function _matchingRecords(address registry, uint256 agentId, string memory tag2)
        internal
        view
        returns (uint256 matched)
    {
        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeCall(IERC8004Reputation.readFeedback, (agentId, address(market))));
        if (!ok) return 0;
        (,, string[] memory tag1s, string[] memory tag2s) = abi.decode(ret, (int128[], uint8[], string[], string[]));
        bytes32 tag1Hash = keccak256(bytes(tag1));
        bytes32 tag2Hash = keccak256(bytes(tag2));
        for (uint256 i = 0; i < tag1s.length; ++i) {
            if (keccak256(bytes(tag1s[i])) == tag1Hash && keccak256(bytes(tag2s[i])) == tag2Hash) ++matched;
        }
    }

    /// @dev fee = expectedVarE18 * feePerVarE18 / VAR_FEE_SCALE pips, clamped. A product past
    ///      uint256 is far above any uint24 fee, so it clamps to maxFee instead of reverting.
    function _fee(uint256 expectedVarE18) internal view returns (uint24) {
        if (feePerVarE18 != 0 && expectedVarE18 > type(uint256).max / feePerVarE18) return maxFee;
        uint256 raw = (expectedVarE18 * feePerVarE18) / VAR_FEE_SCALE;
        if (raw < minFee) return minFee;
        if (raw > maxFee) return maxFee;
        return uint24(raw);
    }
}
