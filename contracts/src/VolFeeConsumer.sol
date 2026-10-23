// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC8004Reputation} from "./interfaces/IERC8004Reputation.sol";

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
        returns (bool recorded, uint256 modelId, uint256[5] memory probs, int256 logScore);
    function agentBound(uint256 modelId) external view returns (bool);
    function agentOfModel(uint256 modelId) external view returns (uint256);
    function isZkModel(uint256 modelId) external view returns (bool);
    function baselineLogScore() external view returns (int256);
    function reputationRegistry() external view returns (address);
}

/// @title VolFeeConsumer
/// @notice Sets an hourly AMM swap fee from a VolMarket round's revealed forecasts: the forecasts
///         are mixed by their models' ERC-8004 reputation, and the mix's expected realized
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

    event FeeRecorded(uint256 indexed id, uint24 fee, uint256 expectedVarE18, uint256[5] mix);

    uint256 private constant BUCKETS = 5;
    /// @dev Probability scale: forecast probs and the mix are fixed-point with 1e18 = 1, log scores
    ///      and reputation means are 1e18-scaled too.
    uint256 private constant PROB_SCALE = 1e18;
    /// @dev expectedVarE18 carries PROB_SCALE and feePerVarE18 carries 1e18.
    uint256 private constant VAR_FEE_SCALE = 1e36;
    /// @dev ERC-8004 summaries are compared in 18 decimals; a mainnet summary with more decimals
    ///      cannot be upscaled and counts as no reputation.
    uint8 private constant REPUTATION_DECIMALS = 18;

    IVolMarketReader public immutable market;
    /// @dev ERC-8004 tags VolMarket writes log scores under: tag1 "logScore", tag2 per model
    ///      "vol-<delta>s-<n>" for zk models and that plus "-commit" for commit-only ones.
    string public tag1;
    string public tag2Zk;
    string public tag2Commit;
    /// @dev Representative realized variance of each bucket in tick^2, the unit of
    ///      VolMarket.realizedVol; non-decreasing so the fee cannot fall as mass moves up.
    uint256[5] public bucketVar;
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
        uint256[5] memory bucketVar_,
        uint256 feePerVarE18_,
        uint24 minFee_,
        uint24 maxFee_
    ) {
        if (address(market_) == address(0) || minFee_ > maxFee_) revert InvalidParams();
        for (uint256 b = 1; b < BUCKETS; ++b) {
            if (bucketVar_[b] < bucketVar_[b - 1]) revert InvalidParams();
        }
        // expectedVarE18 <= bucketVar[4] * PROB_SCALE must fit in uint256.
        if (bucketVar_[BUCKETS - 1] > type(uint256).max / PROB_SCALE) revert InvalidParams();
        market = market_;
        tag1 = tag1_;
        tag2Zk = tag2Zk_;
        tag2Commit = tag2Commit_;
        bucketVar = bucketVar_;
        feePerVarE18 = feePerVarE18_;
        minFee = minFee_;
        maxFee = maxFee_;
    }

    /// @notice Fee for round `id` from its revealed forecasts, valid from the reveal deadline
    ///         until startTime.
    /// @return fee in pips, clamped to [minFee, maxFee]
    /// @return mix reputation-weighted forecast, 1e18-scaled, summing exactly to 1e18
    /// @return expectedVarE18 sum_b mix[b] * bucketVar[b]: tick^2 scaled by 1e18
    function quote(uint256 id) public view returns (uint24 fee, uint256[5] memory mix, uint256 expectedVarE18) {
        (uint64 startTime,,,,,,,) = market.getRound(id);
        if (block.timestamp < startTime - market.revealLead()) revert TooEarly();
        if (block.timestamp >= startTime) revert TooLate();
        mix = _mix(id);
        for (uint256 b = 0; b < BUCKETS; ++b) {
            expectedVarE18 += mix[b] * bucketVar[b];
        }
        fee = _fee(expectedVarE18);
    }

    /// @notice Permissionless on-chain record of round `id`'s fee, once per round.
    function record(uint256 id) external returns (uint24 fee) {
        if (feeRecorded[id]) revert AlreadyRecorded();
        uint256[5] memory mix;
        uint256 expectedVarE18;
        (fee, mix, expectedVarE18) = quote(id);
        feeRecorded[id] = true;
        feeOf[id] = fee;
        emit FeeRecorded(id, fee, expectedVarE18, mix);
    }

    /// @dev mix[b] = sum_i w_i * p_i[b] / W rounded down; the last bucket takes the remainder so
    ///      the mix sums exactly to PROB_SCALE, as VolMarket's revealed probs do.
    function _mix(uint256 id) internal view returns (uint256[5] memory mix) {
        (uint256[5][] memory probs, uint256[] memory weights, uint256 n, uint256 totalWeight) = _forecasts(id);
        uint256 assigned;
        for (uint256 b = 0; b < BUCKETS - 1; ++b) {
            uint256 sum;
            for (uint256 i = 0; i < n; ++i) {
                sum += weights[i] * probs[i][b];
            }
            mix[b] = sum / totalWeight;
            assigned += mix[b];
        }
        mix[BUCKETS - 1] = PROB_SCALE - assigned;
    }

    /// @dev Revealed forecasts and their weights; committed-only entries are skipped. A weight is the
    ///      model's mean log score above the market's uniform baseline, 0 at or below it, as
    ///      VolMarket._excess pays forecasters. Without a registry, when any revealed
    ///      model has no reputation, or when every weight is 0, all revealed forecasts weigh the
    ///      same. Equal weight is the simplest safe fallback, chosen over the market's own scoring
    ///      history, and a partly rated round never silently drops its unrated forecasts.
    function _forecasts(uint256 id)
        internal
        view
        returns (uint256[5][] memory probs, uint256[] memory weights, uint256 n, uint256 totalWeight)
    {
        uint256 count = market.predictorCount(id);
        probs = new uint256[5][](count);
        weights = new uint256[](count);
        address registry = market.reputationRegistry();
        bool rated = registry != address(0);
        for (uint256 i = 0; i < count; ++i) {
            (bool recorded, uint256 modelId, uint256[5] memory p) = _prediction(id, i);
            if (!recorded) continue;
            probs[n] = p;
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
        returns (bool recorded, uint256 modelId, uint256[5] memory probs)
    {
        (recorded, modelId, probs,) = market.getPrediction(id, market.predictorAt(id, i));
    }

    function _weight(address registry, uint256 modelId) internal view returns (bool found, uint256 weight) {
        int256 mean;
        (found, mean) = _reputation(registry, modelId);
        int256 baseline = market.baselineLogScore();
        if (found && mean > baseline) weight = uint256(mean - baseline);
    }

    /// @dev Mean log score (1e18) of `modelId`'s agent over the market's feedback under this
    ///      consumer's tags. Mainnet ERC-8004 v2.0.0 returns (uint64 count, int128 mean, uint8
    ///      decimals) under the same getSummary selector as the local registry's single int256
    ///      (18 decimals), so the shape is told apart by return length. The local registry returns
    ///      0 for no record, which is also a perfect log score: presence is decided by the record
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
            return (true, abi.decode(ret, (int256)));
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
