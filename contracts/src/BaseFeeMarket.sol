// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title BaseFeeMarket
/// @notice Parimutuel prediction market on the average EIP-1559 base fee over a
///         window of blocks. Settlement reads `block.basefee` (EIP-3198) via
///         permissionless per-block `sample()` calls, so no oracle is needed.
///         Also records AI forecasts (probability vectors) before each round and
///         scores them onchain against the realized outcome (log score, Winkler
///         style precision scaled by 1e18).
/// @dev Round lifecycle: Open (bets) -> Sampling -> Settled (claims).
///      A round is voided (full refund) when sampling coverage < MIN_COVERAGE.
contract BaseFeeMarket {
    // ---------------------------------------------------------------- errors
    error NotOwner();
    error InvalidParams();
    error RoundExists();
    error RoundNotFound();
    error NotOpen();
    error BettingClosed();
    error SamplingNotStarted();
    error SamplingOngoing();
    error AlreadySampled();
    error OutOfWindow();
    error AlreadySettled();
    error NothingToClaim();
    error ZeroAddress();
    error BadProbabilityVector();
    error TooLateToPredict();
    error RoundNotSettled();
    error TransferFailed();

    // ---------------------------------------------------------------- events
    event RoundCreated(uint256 indexed roundId, uint256 startBlock, uint256 endBlock, int256[] bounds);
    event BetPlaced(uint256 indexed roundId, address indexed bettor, uint256 bucket, uint256 amount);
    event SampleRecorded(uint256 indexed roundId, uint256 indexed blockNumber, uint256 baseFee);
    event RoundSettled(uint256 indexed roundId, uint256 winningBucket, uint256 avgBaseFee, uint256 sampledCount);
    event RoundVoided(uint256 indexed roundId);
    event Claimed(uint256 indexed roundId, address indexed claimant, uint256 payout);
    event PredictionRecorded(uint256 indexed roundId, address indexed predictor, uint256[] probs);
    event PredictionScored(uint256 indexed roundId, address indexed predictor, int256 logScore);

    // ---------------------------------------------------------------- types
    enum Phase {
        Open, // accepting bets and predictions until startBlock
        Sampling, // startBlock <= current <= endBlock
        Settled // outcome fixed (or voided)
    }

    struct Round {
        uint256 startBlock; // first block of the sampling window (inclusive)
        uint256 endBlock; // last block of the sampling window (inclusive)
        int256[] bounds; // bucket i = [bounds[i-1], bounds[i]); bucket 0 = (-inf, bounds[0]), last = [bounds[n-1], +inf)
        Phase phase;
        uint256[] pools; // per-bucket stake
        uint256 totalStake;
        uint256 samplesSeen; // count of distinct sampled blocks
        uint256 sampledBits; // bitset of sampled in-window blocks (window <= 256)
        uint256 sumBaseFee; // cumulative sum of sampled base fees (wei per gas)
        uint256 winningBucket;
        bool voided;
        mapping(address => mapping(uint256 => uint256)) stakes; // user -> bucket -> stake
        mapping(address => Prediction) predictions;
        address[] predictors;
    }

    struct Prediction {
        bool recorded;
        uint256[] probs; // probabilities scaled by 1e18, must sum to 1e18
        int256 logScore; // set at settlement
    }

    // ---------------------------------------------------------------- storage
    IERC20 public immutable token;
    uint256 public immutable feeBps; // protocol fee in basis points on winnings
    uint256 public constant MIN_COVERAGE_BPS = 9000; // 90% of window blocks
    uint256 public roundCount;
    mapping(uint256 => Round) private rounds;

    // ---------------------------------------------------------------- modifiers
    modifier roundExists(uint256 id) {
        if (id >= roundCount) revert RoundNotFound();
        _;
    }

    // ---------------------------------------------------------------- constructor
    /// @param token_ settlement token
    /// @param feeBps_ protocol fee on winnings, e.g. 100 = 1%. Must be < 1000.
    constructor(IERC20 token_, uint256 feeBps_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (feeBps_ >= 1000) revert InvalidParams();
        token = token_;
        feeBps = feeBps_;
    }

    // ---------------------------------------------------------------- round mgmt
    /// @notice Create a round. Bounds are absolute base-fee values in wei.
    ///         Window length (end - start + 1) must be in [1, 256].
    function createRound(uint256 startBlock, uint256 endBlock, int256[] calldata bounds) external returns (uint256 id) {
        if (endBlock < startBlock || endBlock - startBlock + 1 > 256) revert InvalidParams();
        uint256 n = bounds.length;
        if (n == 0 || n > 32) revert InvalidParams();
        for (uint256 i = 1; i < n; ++i) {
            if (bounds[i] <= bounds[i - 1]) revert InvalidParams();
        }
        if (bounds[0] <= 0) revert InvalidParams(); // base fee is always > 0
        uint256 id_ = roundCount++;
        Round storage r = rounds[id_];
        r.startBlock = startBlock;
        r.endBlock = endBlock;
        r.bounds = bounds;
        r.pools = new uint256[](n + 1);
        emit RoundCreated(id_, startBlock, endBlock, bounds);
        return id_;
    }

    // ---------------------------------------------------------------- betting
    function bet(uint256 id, uint256 bucket, uint256 amount) external roundExists(id) {
        Round storage r = rounds[id];
        if (block.number >= r.startBlock) revert BettingClosed();
        if (bucket > r.bounds.length) revert InvalidParams();
        if (amount == 0) revert InvalidParams();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        r.pools[bucket] += amount;
        r.totalStake += amount;
        r.stakes[msg.sender][bucket] += amount;
        emit BetPlaced(id, msg.sender, bucket, amount);
    }

    // ---------------------------------------------------------------- predictions
    /// @notice Record a forecast before the window starts. probs must sum to 1e18.
    function recordPrediction(uint256 id, uint256[] calldata probs) external roundExists(id) {
        Round storage r = rounds[id];
        if (block.number >= r.startBlock) revert TooLateToPredict();
        if (probs.length != r.bounds.length + 1) revert BadProbabilityVector();
        uint256 sum;
        for (uint256 i = 0; i < probs.length; ++i) {
            if (probs[i] > 1e18) revert BadProbabilityVector();
            sum += probs[i];
        }
        if (sum != 1e18) revert BadProbabilityVector();
        if (!r.predictions[msg.sender].recorded) {
            r.predictors.push(msg.sender);
            r.predictions[msg.sender].recorded = true;
        }
        r.predictions[msg.sender].probs = probs;
        emit PredictionRecorded(id, msg.sender, probs);
    }

    // ---------------------------------------------------------------- sampling
    /// @notice Anyone can record the current block's base fee for a round whose
    ///         window covers block.number. One sample per block.
    function sample(uint256 id) external roundExists(id) {
        Round storage r = rounds[id];
        uint256 bn = block.number;
        if (bn < r.startBlock) revert SamplingNotStarted();
        if (bn > r.endBlock) revert SamplingOngoing();
        uint256 bit = 1 << (bn - r.startBlock);
        if (r.sampledBits & bit != 0) revert AlreadySampled();
        r.sampledBits |= bit;
        r.samplesSeen += 1;
        uint256 bf = block.basefee;
        r.sumBaseFee += bf;
        emit SampleRecorded(id, bn, bf);
    }

    // ---------------------------------------------------------------- settlement
    /// @notice Settle after the window ends. winning bucket = bucket containing
    ///         the mean sampled base fee. Voids (refund) when coverage < 90%.
    function settle(uint256 id) external roundExists(id) {
        Round storage r = rounds[id];
        if (block.number <= r.endBlock) revert SamplingOngoing();
        if (r.phase == Phase.Settled) revert AlreadySettled();
        uint256 windowLen = r.endBlock - r.startBlock + 1;
        r.phase = Phase.Settled;

        if (r.samplesSeen * 10000 < windowLen * MIN_COVERAGE_BPS) {
            r.voided = true;
            emit RoundVoided(id);
            return;
        }

        uint256 avg = r.sumBaseFee / r.samplesSeen;
        uint256 win = bucketOf(r.bounds, int256(uint256(avg)));
        r.winningBucket = win;
        emit RoundSettled(id, win, avg, r.samplesSeen);

        uint256 winners = r.pools[win];
        uint256 predictorsLen = r.predictors.length;
        for (uint256 i = 0; i < predictorsLen; ++i) {
            address p = r.predictors[i];
            uint256 pi = r.predictions[p].probs[win];
            // logScore = ln(p_win) scaled 1e18 (<= 0); p=0 => floor at -18e18
            int256 score = pi == 0 ? int256(-18e18) : log1e18(pi);
            r.predictions[p].logScore = score;
            emit PredictionScored(id, p, score);
        }
        // silence unused warning pattern (winners used in claim math)
        winners;
    }

    // ---------------------------------------------------------------- claims
    /// @notice Winners claim a pro-rata share of the whole pool minus fee.
    ///         Voided rounds: everyone claims back their full stake.
    function claim(uint256 id) external roundExists(id) {
        Round storage r = rounds[id];
        if (r.phase != Phase.Settled) revert RoundNotSettled();

        if (r.voided) {
            uint256 refund;
            uint256 n = r.bounds.length + 1;
            for (uint256 b = 0; b < n; ++b) {
                refund += r.stakes[msg.sender][b];
            }
            if (refund == 0) revert NothingToClaim();
            for (uint256 b = 0; b < n; ++b) {
                r.stakes[msg.sender][b] = 0;
            }
            r.totalStake -= refund;
            if (!token.transfer(msg.sender, refund)) revert TransferFailed();
            emit Claimed(id, msg.sender, refund);
            return;
        }

        uint256 stake = r.stakes[msg.sender][r.winningBucket];
        if (stake == 0) revert NothingToClaim();
        r.stakes[msg.sender][r.winningBucket] = 0;
        uint256 winners = r.pools[r.winningBucket];
        // payout = stake / winners * (totalStake - fee)
        uint256 fee = (r.totalStake * feeBps) / 10000;
        uint256 payout = (stake * (r.totalStake - fee)) / winners;
        if (!token.transfer(msg.sender, payout)) revert TransferFailed();
        emit Claimed(id, msg.sender, payout);
    }

    // ---------------------------------------------------------------- views
    function getRound(uint256 id)
        external
        view
        roundExists(id)
        returns (
            uint256 startBlock,
            uint256 endBlock,
            Phase phase,
            uint256[] memory pools,
            uint256 totalStake,
            uint256 samplesSeen,
            uint256 sumBaseFee,
            uint256 winningBucket,
            bool voided,
            int256[] memory bounds
        )
    {
        Round storage r = rounds[id];
        return (
            r.startBlock,
            r.endBlock,
            r.phase,
            r.pools,
            r.totalStake,
            r.samplesSeen,
            r.sumBaseFee,
            r.winningBucket,
            r.voided,
            r.bounds
        );
    }

    function getStake(uint256 id, address who, uint256 bucket) external view returns (uint256) {
        return rounds[id].stakes[who][bucket];
    }

    function getPrediction(uint256 id, address who)
        external
        view
        returns (bool recorded, uint256[] memory probs, int256 logScore)
    {
        Prediction storage p = rounds[id].predictions[who];
        return (p.recorded, p.probs, p.logScore);
    }

    function predictorCount(uint256 id) external view returns (uint256) {
        return rounds[id].predictors.length;
    }

    // ---------------------------------------------------------------- internal
    /// @dev bucket index for value v: i = number of bounds <= v... specifically
    ///      bucket 0: v < bounds[0]; bucket i: bounds[i-1] <= v < bounds[i];
    ///      bucket n: v >= bounds[n-1].
    function bucketOf(int256[] storage bounds, int256 v) internal view returns (uint256) {
        uint256 n = bounds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (v < bounds[i]) return i;
        }
        return n;
    }

    uint256 private constant LN2_1E18 = 0.693147180559945309e18;

    /// @dev ln(x/1e18) * 1e18 for x in [1, 1e18]; result <= 0, abs error < 1e9.
    ///      Range reduction: x = m * 2^-e with m/1e18 in [0.5, 1), then
    ///      ln(x/1e18) = ln(m/1e18) - e*ln2, where ln(m) uses
    ///      ln(m) = 2*artanh((m-1)/(m+1)) with |y| <= 1/3 (fast convergence).
    function log1e18(uint256 x) internal pure returns (int256) {
        require(x >= 1 && x <= 1e18, "log domain");
        uint256 e;
        uint256 m = x;
        while (m * 2 < 1e18) {
            m *= 2;
            ++e;
        }
        // now m in [0.5e18, 1e18)
        int256 num = int256(m) - 1e18;
        int256 den = int256(m) + 1e18;
        int256 y = (num * 1e18) / den; // y in [-1/3, 0]
        int256 y2 = (y * y) / 1e18; // <= 1/9
        int256 term = y;
        int256 sum;
        for (uint256 k = 0; k < 24; ++k) {
            sum += term / int256(2 * k + 1);
            term = (term * y2) / 1e18;
            if (term == 0) break;
        }
        int256 ln = 2 * sum - int256(e) * int256(LN2_1E18);
        require(ln <= 0, "ln(p<=1) must be <= 0");
        return ln;
    }
}
