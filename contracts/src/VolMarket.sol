// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";
import {IUniswapV3PoolOracle} from "./interfaces/IUniswapV3PoolOracle.sol";
import {IHalo2Verifier} from "./interfaces/IHalo2Verifier.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {IERC8004Reputation} from "./interfaces/IERC8004Reputation.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {MarketMath} from "./lib/MarketMath.sol";
import {TickPriceMath} from "./lib/TickPriceMath.sol";

/// @title VolMarket
/// @notice Parimutuel market on the realized volatility of a Uniswap V3 pool's TWAP tick over
///         `nSegments` segments of `delta` seconds. Settlement reads `observe()` directly, with
///         permissionless `sample()` checkpoints as a fallback when the pool's history runs out.
///         AI forecasts (5-bucket distributions) are committed as a hash first and revealed once
///         commits close, before the window starts. A zk model's reveal is accepted only with an
///         EZKL proof whose public inputs are features the contract derived from `observe()` at
///         round creation; a commit-only model (no verifier) proves timing, not provenance.
///         Forecasts that beat the uniform baseline share `predictorShareBps` of the round's fee.
/// @dev Round lifecycle: Commit (bets, commits until startTime - commitLead) -> Reveal (bets,
///      reveals until startTime - revealLead) -> bets until startTime -> Sampling (until
///      startTime + nSegments * delta) -> Settled (claims). Voided (full refund) when fewer than
///      90% of the nSegments + 1 checkpoints can be read.
contract VolMarket {
    // ---------------------------------------------------------------- errors
    error NotOwner();
    error InvalidParams();
    error ZeroAddress();
    error RoundNotFound();
    error BettingClosed();
    error TooLateToPredict();
    error AlreadyPredicted();
    error UnknownModel();
    error NotModelOperator();
    error TooManyPredictors();
    error BadOutputs();
    error InvalidProof();
    error CheckpointNotReached();
    error AlreadySampled();
    error OutOfWindow();
    error SamplingOngoing();
    error AlreadySettled();
    error RoundNotSettled();
    error NothingToClaim();
    error TransferFailed();
    error ReputationNotConfigured();
    error AgentNotOwned();
    error InsufficientGas();
    error RevealNotOpen();
    error TooLateToReveal();
    error NotCommitted();
    error AlreadyRevealed();
    error CommitmentMismatch();

    // ---------------------------------------------------------------- events
    event ModelRegistered(uint256 indexed modelId, address verifier, address operator);
    event RoundCreated(uint256 indexed roundId, uint64 startTime, uint256[] bounds, int256[16] features);
    event BetPlaced(uint256 indexed roundId, address indexed bettor, uint256 bucket, uint256 amount);
    event PredictionCommitted(
        uint256 indexed roundId, address indexed predictor, uint256 indexed modelId, bytes32 commitment
    );
    event PredictionRevealed(
        uint256 indexed roundId, address indexed predictor, uint256 indexed modelId, uint256[5] probs
    );
    event CheckpointSampled(uint256 indexed roundId, uint256 indexed k, int56 tickCumulative);
    event RoundSettled(uint256 indexed roundId, uint256 winningBucket, uint256 realizedVol, uint256 availablePoints);
    event RoundVoided(uint256 indexed roundId);
    event PredictionScored(uint256 indexed roundId, address indexed predictor, int256 logScore);
    event Claimed(uint256 indexed roundId, address indexed claimant, uint256 payout);
    event FeeCollected(uint256 indexed roundId, uint256 amount);
    event PredictorRewardClaimed(uint256 indexed roundId, address indexed predictor, uint256 amount);
    event ReputationSet(address indexed identityRegistry, address indexed reputationRegistry);
    event AgentLinked(uint256 indexed modelId, uint256 indexed agentId, address indexed operator);
    event ReputationWriteFailed(
        uint256 indexed roundId, address indexed predictor, uint256 indexed agentId, bytes32 reason
    );
    event PriceFeedSet(address indexed feed);
    event PriceCheckFailed(uint256 indexed roundId, int24 tick, int256 poolPrice, int256 feedPrice, uint8 reason);

    // ---------------------------------------------------------------- types
    struct Round {
        uint64 startTime; // t_0; checkpoint k is at startTime + k * delta
        bool settled;
        bool voided;
        uint8 winningBucket;
        uint256 realizedVol; // tick^2, normalized to nSegments - 1 terms
        uint256[] bounds; // 4 ascending bounds in tick^2; bucket semantics as MarketMath.bucketOf
        int256[16] features; // x_int_j = clamp(f_j, -64, 64) * 128 (input scale 2^12)
        uint256[5] pools; // per-bucket stake
        uint256 totalStake;
        uint256 sampledBits; // bit k set => checkpoints[k] holds tickCumulative(t_k)
        uint256 claimedWinStake; // winning-bucket stake already paid out
        uint256 paidOut; // tokens paid to winners so far
        bool feeCollected;
        uint256 totalExcess; // sum of revealed forecasts' log score above baseline (1e18 scale)
        uint256 claimedExcess; // excess of the forecasters that claimed their share so far
        uint256 predictorPaid; // tokens paid to forecasters so far
        mapping(uint256 => int56) checkpoints;
        mapping(address => mapping(uint256 => uint256)) stakes; // user -> bucket -> stake
        mapping(address => Prediction) predictions;
        address[] predictors;
    }

    struct Prediction {
        bool recorded; // revealed: probs are public and the forecast is scored
        uint256 modelId;
        bytes32 commitment; // nonzero once committed
        bool rewardClaimed;
        uint256[5] probs; // scaled by PROB_SCALE, sum exactly PROB_SCALE
        int256 logScore; // set at settlement
    }

    // ---------------------------------------------------------------- storage
    uint256 public constant BUCKETS = 5;
    uint256 public constant FEATURES = 16;
    uint256 public constant MIN_COVERAGE_BPS = 9000;
    int256 public constant MIN_LOG_SCORE = -18e18;
    int256 public constant FEATURE_CLAMP = 64; // ticks
    int256 public constant FEATURE_MULT = 128; // x = f / 32 at input scale 4096
    /// @dev BN254 scalar field modulus; negative inputs are encoded as R - |x|.
    uint256 public constant MAX_PREDICTORS = 32; // bounds the scoring loop in settle
    uint256 public constant FIELD_R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    /// @dev Probability scale: probs and log scores are fixed-point with 1e18 = 1.
    uint256 private constant PROB_SCALE = 1e18;
    /// @dev Largest accepted output: output * PROB_SCALE must not overflow, and the bound sits far
    ///      below FIELD_R / 2, so field encodings of negative values stay rejected.
    uint256 public constant MAX_OUTPUT = type(uint256).max / PROB_SCALE;

    IERC20 public immutable token;
    uint256 public immutable feeBps; // protocol fee in basis points on the whole pool
    IUniswapV3PoolOracle public immutable pool;
    uint32 public immutable delta; // segment length in seconds
    uint8 public immutable nSegments;
    address public immutable owner;
    /// @dev Commits close commitLead seconds before startTime, reveals close revealLead seconds
    ///      before it; commitLead > revealLead, so forecasts are public before the window opens.
    uint32 public immutable commitLead;
    uint32 public immutable revealLead;

    address[] public models; // modelId -> EZKL verifier; address(0) marks a commit-only model
    mapping(uint256 => address) public modelOperator; // the only account that may commit with modelId
    uint256 public roundCount;
    mapping(uint256 => Round) private rounds;

    // ---------------------------------------------------------------- ERC-8004 reputation
    /// @dev ERC-8004 registries. Both unset means the reputation wiring is disabled: the market
    ///      behaves exactly as it does without this feature.
    IERC8004Identity public identityRegistry;
    IERC8004Reputation public reputationRegistry;
    /// @dev modelId -> agentId of the model operator's agent.
    mapping(uint256 => uint256) public agentOfModel;
    /// @dev Binding marker: agent id 0 is a legal binding target, so it cannot double as the
    ///      "no agent" sentinel.
    mapping(uint256 => bool) public agentBound;

    // 1e18 fixed-point price math scale; feed prices are normalized to 8 decimals for comparison.
    uint256 private constant PRICE_SCALE = 1e18;
    uint256 public constant MAX_DEVIATION_BPS = 200;
    uint256 public constant MAX_FEED_AGE = 3900;
    uint8 private constant PRICE_DECIMALS = 8;
    uint256 private constant BPS = 10_000;
    TickPriceMath public immutable tickPriceMath;
    AggregatorV3Interface public priceFeed;

    /// @dev Gas cap on each call settle makes to the reputation registry or the price feed: one that
    ///      burns all gas it gets then fails like a reverting one instead of starving settle. Measured
    ///      on mainnet (spikes/facts/FACTS.md): ERC-8004 giveFeedback ~197k and Chainlink
    ///      latestRoundData ~37k, both including the 21k base fee; 500k leaves 2.5x headroom.
    uint256 public constant EXTERNAL_CALL_GAS = 500_000;
    /// @dev Gas a capped call needs left before it for the callee to receive the whole cap: EIP-150
    ///      keeps 1/64 back, and the argument encoding and account access between the gasleft()
    ///      snapshot and the CALL stay under a further 1/64 of the cap (~7.8k gas).
    uint256 private constant MIN_GAS_FOR_CAPPED_CALL = EXTERNAL_CALL_GAS + EXTERNAL_CALL_GAS / 32;

    // ---------------------------------------------------------------- predictor share
    /// @dev Basis points of each round's fee set aside for forecasters; the owner keeps the rest.
    uint256 public immutable predictorShareBps;
    /// @dev Log score (1e18 scale) of the uniform forecast, ln(1/BUCKETS), from the same log1e18
    ///      that scores forecasts: a uniform forecast scores exactly this and earns nothing.
    int256 public immutable baselineLogScore;

    // ---------------------------------------------------------------- modifiers
    modifier roundExists(uint256 id) {
        if (id >= roundCount) revert RoundNotFound();
        _;
    }

    // ---------------------------------------------------------------- constructor
    /// @param token_ settlement token
    /// @param feeBps_ protocol fee on the pool, e.g. 100 = 1%. Must be < 1000.
    /// @param pool_ Uniswap V3 pool (or anything exposing `observe`)
    /// @param predictorShareBps_ share of each round's fee paid to forecasters, <= 10000
    /// @param delta_ segment length in seconds; 17 * delta_ must fit in uint32
    /// @param nSegments_ segments per round window, >= 2
    /// @param commitLead_ seconds before startTime at which commits close
    /// @param revealLead_ seconds before startTime at which reveals close, < commitLead_
    constructor(
        IERC20 token_,
        uint256 feeBps_,
        uint256 predictorShareBps_,
        IUniswapV3PoolOracle pool_,
        uint32 delta_,
        uint8 nSegments_,
        uint32 commitLead_,
        uint32 revealLead_
    ) {
        if (address(token_) == address(0) || address(pool_) == address(0)) revert ZeroAddress();
        if (feeBps_ >= 1000 || delta_ == 0 || nSegments_ < 2) revert InvalidParams();
        if (uint256(delta_) * (FEATURES + 1) > type(uint32).max) revert InvalidParams();
        if (predictorShareBps_ > BPS || revealLead_ >= commitLead_) revert InvalidParams();
        token = token_;
        feeBps = feeBps_;
        predictorShareBps = predictorShareBps_;
        pool = pool_;
        delta = delta_;
        nSegments = nSegments_;
        commitLead = commitLead_;
        revealLead = revealLead_;
        baselineLogScore = MarketMath.log1e18(PROB_SCALE / BUCKETS);
        owner = msg.sender;
        tickPriceMath = new TickPriceMath();
    }

    // ---------------------------------------------------------------- models
    /// @notice Register a model; predictions cite it by the returned id.
    /// @param verifier the model's EZKL verifier, or address(0) for a commit-only model whose
    ///        reveals carry no proof
    /// @param operator the only account allowed to commit with this model: a proof does not bind its
    ///        sender, so without this anyone could resubmit a copied proof as their own forecast
    function registerModel(address verifier, address operator) external returns (uint256 modelId) {
        if (msg.sender != owner) revert NotOwner();
        if (operator == address(0)) revert ZeroAddress();
        modelId = models.length;
        models.push(verifier);
        modelOperator[modelId] = operator;
        emit ModelRegistered(modelId, verifier, operator);
    }

    function modelCount() external view returns (uint256) {
        return models.length;
    }

    /// @notice True for a model whose reveals must carry an EZKL proof, false for commit-only.
    function isZkModel(uint256 modelId) external view returns (bool) {
        if (modelId >= models.length) revert UnknownModel();
        return models[modelId] != address(0);
    }

    /// @notice Configure optional ETH/USD cross-check; zero address disables it.
    function setPriceFeed(address feed) external {
        if (msg.sender != owner) revert NotOwner();
        priceFeed = AggregatorV3Interface(feed);
        emit PriceFeedSet(feed);
    }

    function priceForTick(int24 tick) external view returns (uint256) {
        return _priceForTick(tick);
    }

    // ---------------------------------------------------------------- ERC-8004 reputation
    /// @notice Point the market at the ERC-8004 identity and reputation registries.
    /// @dev The zero address on both sides disables the feature; one zero side is a configuration
    ///      mistake and is rejected, because a half-configured wiring would silently drop scores.
    function setReputation(address identity, address reputation) external {
        if (msg.sender != owner) revert NotOwner();
        if ((identity == address(0)) != (reputation == address(0))) revert InvalidParams();
        identityRegistry = IERC8004Identity(identity);
        reputationRegistry = IERC8004Reputation(reputation);
        emit ReputationSet(identity, reputation);
    }

    /// @notice Bind the ERC-8004 agent of the caller to one of its models.
    /// @dev Only the model operator may bind, and only for an agent it owns: the market writes the
    ///      operator's scores under that agent id, so a binding must not be claimable by a third
    ///      party. Agent id 0 marks a model whose scores are not attributed to any agent.
    function linkAgent(uint256 modelId, uint256 agentId) external {
        if (modelId >= models.length) revert UnknownModel();
        if (msg.sender != modelOperator[modelId]) revert NotModelOperator();
        if (address(identityRegistry) == address(0)) revert ReputationNotConfigured();
        if (agentId != 0) {
            address agentOwner;
            try identityRegistry.ownerOf(agentId) returns (address ownerOf) {
                agentOwner = ownerOf;
            } catch {
                revert AgentNotOwned();
            }
            if (agentOwner != msg.sender) revert AgentNotOwned();
        }
        agentOfModel[modelId] = agentId;
        agentBound[modelId] = true;
        emit AgentLinked(modelId, agentId, msg.sender);
    }

    // ---------------------------------------------------------------- round mgmt
    /// @notice Create a round and snapshot its model features from the last 17 segments.
    /// @param startTime window start; after now + commitLead, so the commit phase is not empty
    /// @param bounds 4 strictly ascending realized-vol bounds in tick^2 (5 buckets)
    function createRound(uint64 startTime, uint256[] calldata bounds) external returns (uint256 id) {
        if (startTime <= block.timestamp + commitLead) revert InvalidParams();
        if (bounds.length != BUCKETS - 1) revert InvalidParams();
        for (uint256 i = 1; i < bounds.length; ++i) {
            if (bounds[i] <= bounds[i - 1]) revert InvalidParams();
        }
        int256[16] memory feats = _features();
        id = roundCount++;
        Round storage r = rounds[id];
        r.startTime = startTime;
        r.bounds = bounds;
        r.features = feats;
        emit RoundCreated(id, startTime, bounds, feats);
    }

    /// @dev Segment means b_j over [now - (17-j)delta, now - (16-j)delta], f_j = b_{j+1} - b_j.
    function _features() internal view returns (int256[16] memory feats) {
        uint256 points = FEATURES + 2;
        uint32[] memory secs = new uint32[](points);
        for (uint256 i = 0; i < points; ++i) {
            secs[i] = uint32((points - 1 - i) * delta);
        }
        (int56[] memory c,) = pool.observe(secs);
        int256 d = int256(uint256(delta));
        int256 prevMean = _floorDiv(int256(c[1]) - int256(c[0]), d);
        for (uint256 j = 0; j < FEATURES; ++j) {
            int256 mean = _floorDiv(int256(c[j + 2]) - int256(c[j + 1]), d);
            int256 f = mean - prevMean;
            if (f > FEATURE_CLAMP) f = FEATURE_CLAMP;
            if (f < -FEATURE_CLAMP) f = -FEATURE_CLAMP;
            feats[j] = f * FEATURE_MULT;
            prevMean = mean;
        }
    }

    // ---------------------------------------------------------------- betting
    function bet(uint256 id, uint256 bucket, uint256 amount) external roundExists(id) {
        Round storage r = rounds[id];
        if (block.timestamp >= r.startTime) revert BettingClosed();
        if (bucket >= BUCKETS || amount == 0) revert InvalidParams();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        r.pools[bucket] += amount;
        r.totalStake += amount;
        r.stakes[msg.sender][bucket] += amount;
        emit BetPlaced(id, msg.sender, bucket, amount);
    }

    // ---------------------------------------------------------------- predictions
    /// @notice Commit to a forecast of model `modelId`, before startTime - commitLead. One commit
    ///         per predictor per round.
    /// @param commitment keccak256(abi.encode(id, modelId, outputs, salt, msg.sender)): binding the
    ///        round, model and sender keeps a copied commitment from being revealed by anyone else
    function commitPrediction(uint256 id, uint256 modelId, bytes32 commitment) external roundExists(id) {
        Round storage r = rounds[id];
        if (block.timestamp >= r.startTime - commitLead) revert TooLateToPredict();
        if (modelId >= models.length) revert UnknownModel();
        if (msg.sender != modelOperator[modelId]) revert NotModelOperator();
        Prediction storage p = r.predictions[msg.sender];
        if (p.commitment != bytes32(0)) revert AlreadyPredicted();
        if (r.predictors.length >= MAX_PREDICTORS) revert TooManyPredictors();
        if (commitment == bytes32(0)) revert InvalidParams();
        p.modelId = modelId;
        p.commitment = commitment;
        r.predictors.push(msg.sender);
        emit PredictionCommitted(id, msg.sender, modelId, commitment);
    }

    /// @notice Reveal the committed forecast once commits are closed and before
    ///         startTime - revealLead. A zk model's outputs must come with a valid proof on this
    ///         round's features; a commit-only model's proof is ignored. Unrevealed forecasts are
    ///         neither scored nor paid.
    /// @param outputs 5 non-negative weights, each <= MAX_OUTPUT, sum > 0 (a zk model's circuit
    ///        outputs); probs are their 1e18-scaled shares
    function revealPrediction(uint256 id, bytes calldata proof, uint256[5] calldata outputs, bytes32 salt)
        external
        roundExists(id)
    {
        Round storage r = rounds[id];
        if (block.timestamp < r.startTime - commitLead) revert RevealNotOpen();
        if (block.timestamp >= r.startTime - revealLead) revert TooLateToReveal();
        Prediction storage p = r.predictions[msg.sender];
        if (p.commitment == bytes32(0)) revert NotCommitted();
        if (p.recorded) revert AlreadyRevealed();

        uint256 sum;
        for (uint256 i = 0; i < BUCKETS; ++i) {
            if (outputs[i] > MAX_OUTPUT) revert BadOutputs();
            sum += outputs[i];
        }
        if (sum == 0) revert BadOutputs();

        uint256 modelId = p.modelId;
        if (keccak256(abi.encode(id, modelId, outputs, salt, msg.sender)) != p.commitment) {
            revert CommitmentMismatch();
        }
        address verifier = models[modelId];
        if (verifier != address(0)) _verify(verifier, proof, _instances(r.features, outputs));

        uint256[5] memory probs;
        uint256 assigned;
        for (uint256 i = 0; i < BUCKETS - 1; ++i) {
            probs[i] = (outputs[i] * PROB_SCALE) / sum;
            assigned += probs[i];
        }
        probs[BUCKETS - 1] = PROB_SCALE - assigned;

        p.recorded = true;
        p.probs = probs;
        emit PredictionRevealed(id, msg.sender, modelId, probs);
    }

    function _instances(int256[16] storage feats, uint256[5] calldata outputs)
        internal
        view
        returns (uint256[] memory inst)
    {
        inst = new uint256[](FEATURES + BUCKETS);
        for (uint256 j = 0; j < FEATURES; ++j) {
            int256 x = feats[j];
            inst[j] = x >= 0 ? uint256(x) : FIELD_R - uint256(-x);
        }
        for (uint256 i = 0; i < BUCKETS; ++i) {
            inst[FEATURES + i] = outputs[i];
        }
    }

    /// @dev Low-level call: a failing generated verifier reverts with empty data, and a malformed
    ///      return must not be decoded as success.
    function _verify(address verifier, bytes calldata proof, uint256[] memory inst) internal {
        (bool ok, bytes memory ret) = verifier.call(abi.encodeCall(IHalo2Verifier.verifyProof, (proof, inst)));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) != 1) revert InvalidProof();
    }

    // ---------------------------------------------------------------- sampling
    /// @notice Anyone can store tickCumulative(t_k) once t_k has passed, so settlement survives the
    ///         pool's observation history rolling past the window.
    function sample(uint256 id, uint256 k) external roundExists(id) {
        Round storage r = rounds[id];
        if (k > nSegments) revert OutOfWindow();
        uint256 tk = r.startTime + k * delta;
        if (block.timestamp < tk) revert CheckpointNotReached();
        if (r.sampledBits & (1 << k) != 0) revert AlreadySampled();
        uint256 ago = block.timestamp - tk;
        if (ago > type(uint32).max) revert OutOfWindow();
        uint32[] memory secs = new uint32[](1);
        secs[0] = uint32(ago);
        (int56[] memory c,) = pool.observe(secs);
        r.checkpoints[k] = c[0];
        r.sampledBits |= 1 << k;
        emit CheckpointSampled(id, k, c[0]);
    }

    // ---------------------------------------------------------------- settlement
    /// @notice Settle once t_N has passed. RV = sum of squared differences of adjacent segment
    ///         means over the readable checkpoints, scaled to nSegments - 1 terms.
    function settle(uint256 id) external roundExists(id) {
        Round storage r = rounds[id];
        uint256 n = nSegments;
        if (block.timestamp < r.startTime + n * delta) revert SamplingOngoing();
        if (r.settled) revert AlreadySettled();
        r.settled = true;

        (int256[] memory cums, uint256 have, uint256 count) = _collect(r);
        (uint256 rv, uint256 m) = _realizedVol(cums, have);
        if (count * 10000 < (n + 1) * MIN_COVERAGE_BPS || m == 0) {
            r.voided = true;
            emit RoundVoided(id);
            return;
        }
        if (address(priceFeed) != address(0) && !_priceMatchesFeed(id)) {
            r.voided = true;
            emit RoundVoided(id);
            return;
        }

        uint256 win = MarketMath.bucketOf(r.bounds, rv);
        r.realizedVol = rv;
        r.winningBucket = uint8(win);
        emit RoundSettled(id, win, rv, count);
        _score(r, id, win);
        _writeReputation(r, id);
    }

    function _priceForTick(int24 tick) internal view returns (uint256) {
        return tickPriceMath.priceForTick(tick);
    }

    function _priceMatchesFeed(uint256 id) internal returns (bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = delta;
        secondsAgos[1] = 0;
        (int56[] memory cumulatives,) = pool.observe(secondsAgos);
        int256 diff = int256(cumulatives[1]) - int256(cumulatives[0]);
        int256 meanTick = _floorDiv(diff, int256(uint256(delta)));
        if (meanTick < type(int24).min || meanTick > type(int24).max) {
            emit PriceCheckFailed(id, int24(0), 0, 0, 1);
            return false;
        }
        uint256 poolPrice = _priceForTick(int24(meanTick));
        uint256 gasBefore = gasleft();
        try priceFeed.latestRoundData{gas: EXTERNAL_CALL_GAS}() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_FEED_AGE) {
                emit PriceCheckFailed(id, int24(meanTick), int256(poolPrice), answer, 2);
                return false;
            }
            uint8 feedDecimals;
            gasBefore = gasleft();
            try priceFeed.decimals{gas: EXTERNAL_CALL_GAS}() returns (uint8 d) {
                feedDecimals = d;
            } catch {
                _revertIfCapStarved(gasBefore);
                emit PriceCheckFailed(id, int24(meanTick), int256(poolPrice), answer, 3);
                return false;
            }
            if (feedDecimals > 18) {
                emit PriceCheckFailed(id, int24(meanTick), int256(poolPrice), answer, 3);
                return false;
            }
            uint256 feedPrice = uint256(answer);
            if (feedDecimals < PRICE_DECIMALS) feedPrice *= 10 ** uint256(PRICE_DECIMALS - feedDecimals);
            else if (feedDecimals > PRICE_DECIMALS) feedPrice /= 10 ** uint256(feedDecimals - PRICE_DECIMALS);
            uint256 deltaPrice = poolPrice > feedPrice ? poolPrice - feedPrice : feedPrice - poolPrice;
            if (deltaPrice * BPS > feedPrice * MAX_DEVIATION_BPS) {
                emit PriceCheckFailed(id, int24(meanTick), int256(poolPrice), int256(feedPrice), 4);
                return false;
            }
            return true;
        } catch {
            _revertIfCapStarved(gasBefore);
            emit PriceCheckFailed(id, int24(meanTick), int256(poolPrice), 0, 5);
            return false;
        }
    }

    /// @dev First statement in the catch of a capped call. A callee handed less than the cap may have
    ///      failed only because settle was sent with too little gas, and the gas settle has left
    ///      afterwards cannot tell: a proxy or a nested call fails once its own sub-call starves, and
    ///      reverts with its 1/64 still unspent. Reverting stops a caller from choosing a gas limit
    ///      that skips the call; a callee that fails with the whole cap is reported as before.
    function _revertIfCapStarved(uint256 gasBefore) internal pure {
        if (gasBefore < MIN_GAS_FOR_CAPPED_CALL) revert InsufficientGas();
    }

    /// @dev First statement in an observe catch. Uniswap V3 observe reads storage in its own frame
    ///      without sub-calls, so an observe that ran out of gas leaves settle at most 1/64 of
    ///      `gasBefore` (EIP-150); a real failure such as "OLD" leaves far more.
    function _revertIfObserveStarved(uint256 gasBefore) internal view {
        if (gasleft() <= gasBefore / 64) revert InsufficientGas();
    }

    /// @dev logScore = max(ln p_win, -18e18); p_win = 0 also scores -18e18. Unrevealed forecasts
    ///      keep logScore 0 and recorded = false. Also sums the excess scores the predictor share
    ///      is split by.
    function _score(Round storage r, uint256 id, uint256 win) internal {
        uint256 predictorsLen = r.predictors.length;
        uint256 totalExcess;
        for (uint256 i = 0; i < predictorsLen; ++i) {
            address who = r.predictors[i];
            Prediction storage p = r.predictions[who];
            if (!p.recorded) continue;
            uint256 pw = p.probs[win];
            int256 score = pw == 0 ? MIN_LOG_SCORE : MarketMath.log1e18(pw);
            if (score < MIN_LOG_SCORE) score = MIN_LOG_SCORE;
            p.logScore = score;
            totalExcess += _excess(score);
            emit PredictionScored(id, who, score);
        }
        r.totalExcess = totalExcess;
    }

    /// @dev Log score above the uniform baseline, 0 at or below it; at most -baselineLogScore
    ///      (about 1.61e18) since scores are <= 0.
    function _excess(int256 score) internal view returns (uint256) {
        return score > baselineLogScore ? uint256(score - baselineLogScore) : 0;
    }

    /// @dev Writes the scored log score of every revealed predictor with a bound agent to the
    ///      ERC-8004 reputation registry. The registry is untrusted here: a rejected write is
    ///      reported as an event and never blocks settlement or the claims that follow it.
    function _writeReputation(Round storage r, uint256 id) internal {
        if (address(reputationRegistry) == address(0)) return;
        uint256 predictorsLen = r.predictors.length;
        string memory zkTag = _reputationTag();
        string memory commitTag = string.concat(zkTag, "-commit");
        for (uint256 i = 0; i < predictorsLen; ++i) {
            address who = r.predictors[i];
            Prediction storage p = r.predictions[who];
            if (!p.recorded) continue;
            uint256 modelId = p.modelId;
            if (!agentBound[modelId]) continue;
            uint256 agentId = agentOfModel[modelId];
            if (agentId == 0) continue; // binding without an agent: nothing to attribute
            string memory tag2 = models[modelId] == address(0) ? commitTag : zkTag;
            _giveFeedback(id, who, agentId, _toInt128(p.logScore), tag2);
        }
    }

    function _giveFeedback(uint256 id, address who, uint256 agentId, int128 value, string memory tag2) internal {
        uint256 gasBefore = gasleft();
        try reputationRegistry.giveFeedback{gas: EXTERNAL_CALL_GAS}(
            agentId, value, 18, "logScore", tag2, "", "", bytes32(0)
        ) {}
        catch (bytes memory reason) {
            _revertIfCapStarved(gasBefore);
            emit ReputationWriteFailed(id, who, agentId, keccak256(reason));
        }
    }

    /// @dev tag2 identifies the window the score belongs to: "vol-<delta>s-<nSegments>", derived
    ///      from the constructor parameters so that markets with different windows do not mix.
    ///      Commit-only models append "-commit", so readers can filter by verification tier.
    function _reputationTag() internal view returns (string memory) {
        return string.concat("vol-", _toString(uint256(delta)), "s-", _toString(uint256(nSegments)));
    }

    /// @dev Clamp into int128: the reputation value is an int128, a wider score must not truncate.
    function _toInt128(int256 value) internal pure returns (int128) {
        if (value > int256(type(int128).max)) return type(int128).max;
        if (value < int256(type(int128).min)) return type(int128).min;
        return int128(value);
    }

    /// @dev Decimal string of `value`; the contract needs no string library for two tag fields.
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 rest = value; rest != 0; rest /= 10) {
            ++digits;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            buffer[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }

    /// @dev Stored checkpoints first; the rest via one batched observe, falling back to per-point
    ///      reads because observe reverts the whole batch when any point is too old.
    function _collect(Round storage r) internal view returns (int256[] memory cums, uint256 have, uint256 count) {
        uint256 points = uint256(nSegments) + 1;
        cums = new int256[](points);
        have = r.sampledBits;
        uint256 missing;
        for (uint256 k = 0; k < points; ++k) {
            if (have & (1 << k) != 0) {
                cums[k] = r.checkpoints[k];
            } else if (block.timestamp - (r.startTime + k * delta) <= type(uint32).max) {
                ++missing;
            }
        }

        uint32[] memory secs = new uint32[](missing);
        uint256[] memory idx = new uint256[](missing);
        uint256 j;
        for (uint256 k = 0; k < points; ++k) {
            if (have & (1 << k) != 0) continue;
            uint256 ago = block.timestamp - (r.startTime + k * delta);
            if (ago > type(uint32).max) continue;
            secs[j] = uint32(ago);
            idx[j++] = k;
        }

        if (missing > 0) {
            uint256 gasBefore = gasleft();
            try pool.observe(secs) returns (int56[] memory c, uint160[] memory) {
                for (uint256 i = 0; i < missing; ++i) {
                    cums[idx[i]] = c[i];
                    have |= 1 << idx[i];
                }
            } catch {
                _revertIfObserveStarved(gasBefore);
                uint32[] memory one = new uint32[](1);
                for (uint256 i = 0; i < missing; ++i) {
                    one[0] = secs[i];
                    gasBefore = gasleft();
                    try pool.observe(one) returns (int56[] memory c, uint160[] memory) {
                        cums[idx[i]] = c[0];
                        have |= 1 << idx[i];
                    } catch {
                        _revertIfObserveStarved(gasBefore);
                    }
                }
            }
        }

        for (uint256 k = 0; k < points; ++k) {
            if (have & (1 << k) != 0) ++count;
        }
    }

    /// @return rv floor(sum * (nSegments - 1) / m); m = number of squared terms
    function _realizedVol(int256[] memory cums, uint256 have) internal view returns (uint256 rv, uint256 m) {
        uint256 points = cums.length;
        uint256 sum;
        int256 prevMean;
        bool hasMean;
        bool hasPoint;
        uint256 prevK;
        for (uint256 k = 0; k < points; ++k) {
            if (have & (1 << k) == 0) continue;
            if (hasPoint) {
                int256 mean = _floorDiv(cums[k] - cums[prevK], int256((k - prevK) * delta));
                if (hasMean) {
                    int256 d = mean - prevMean;
                    sum += uint256(d * d);
                    ++m;
                }
                prevMean = mean;
                hasMean = true;
            }
            prevK = k;
            hasPoint = true;
        }
        if (m > 0) rv = (sum * (points - 2)) / m;
    }

    /// @dev Rounds toward negative infinity, as Uniswap OracleLibrary.consult does for the mean tick.
    function _floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) --q;
    }

    // ---------------------------------------------------------------- claims
    /// @notice Winners claim a pro-rata share of the whole pool minus fee. Voided rounds, and rounds
    ///         where nobody staked on the winning bucket, refund every stake in full.
    /// @dev Each payout rounds down; the last winner to claim receives the remainder, so the winners
    ///      split exactly total - fee and no rounding dust stays in the contract.
    function claim(uint256 id) external roundExists(id) {
        Round storage r = rounds[id];
        if (!r.settled) revert RoundNotSettled();

        if (r.voided || r.pools[r.winningBucket] == 0) {
            uint256 refund;
            for (uint256 b = 0; b < BUCKETS; ++b) {
                refund += r.stakes[msg.sender][b];
                r.stakes[msg.sender][b] = 0;
            }
            if (refund == 0) revert NothingToClaim();
            if (!token.transfer(msg.sender, refund)) revert TransferFailed();
            emit Claimed(id, msg.sender, refund);
            return;
        }

        uint256 stake = r.stakes[msg.sender][r.winningBucket];
        if (stake == 0) revert NothingToClaim();
        r.stakes[msg.sender][r.winningBucket] = 0;
        uint256 winPool = r.pools[r.winningBucket];
        uint256 payout;
        r.claimedWinStake += stake;
        if (r.claimedWinStake == winPool) {
            payout = r.totalStake - MarketMath.fee(r.totalStake, feeBps) - r.paidOut;
        } else {
            payout = MarketMath.payout(stake, r.totalStake, winPool, feeBps);
        }
        r.paidOut += payout;
        if (!token.transfer(msg.sender, payout)) revert TransferFailed();
        emit Claimed(id, msg.sender, payout);
    }

    /// @notice Send the owner's part of the round's protocol fee, the fee minus the predictor pool,
    ///         to `owner`; callable by anyone, once per round. Voided and no-winner rounds refund
    ///         everything and carry no fee.
    function collectFee(uint256 id) external roundExists(id) {
        Round storage r = rounds[id];
        if (!r.settled) revert RoundNotSettled();
        uint256 amount = r.feeCollected ? 0 : _roundFee(r) - _predictorPool(r);
        if (amount == 0) revert NothingToClaim();
        r.feeCollected = true;
        if (!token.transfer(owner, amount)) revert TransferFailed();
        emit FeeCollected(id, amount);
    }

    /// @notice A revealed forecaster whose log score beat the uniform baseline claims its share of
    ///         the predictor pool, pro rata to its excess score.
    /// @dev Each share rounds down; the last forecaster to claim receives the remainder, so the
    ///      forecasters split exactly the predictor pool. pool * excess cannot overflow for any
    ///      pool below 2^256 / 1.61e18 tokens (excess <= -baselineLogScore).
    function claimPredictorReward(uint256 id) external roundExists(id) {
        Round storage r = rounds[id];
        if (!r.settled) revert RoundNotSettled();
        Prediction storage p = r.predictions[msg.sender];
        uint256 pool_ = _predictorPool(r);
        uint256 excess = p.recorded ? _excess(p.logScore) : 0;
        if (pool_ == 0 || excess == 0 || p.rewardClaimed) revert NothingToClaim();
        p.rewardClaimed = true;
        r.claimedExcess += excess;
        uint256 amount = r.claimedExcess == r.totalExcess ? pool_ - r.predictorPaid : (pool_ * excess) / r.totalExcess;
        r.predictorPaid += amount;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit PredictorRewardClaimed(id, msg.sender, amount);
    }

    /// @notice Tokens of the round's fee set aside for forecasters that beat the baseline.
    function predictorPool(uint256 id) external view roundExists(id) returns (uint256) {
        return _predictorPool(rounds[id]);
    }

    /// @dev 0 for unsettled, voided and no-winner rounds, which refund every stake.
    function _roundFee(Round storage r) internal view returns (uint256) {
        if (!r.settled || r.voided || r.pools[r.winningBucket] == 0) return 0;
        return MarketMath.fee(r.totalStake, feeBps);
    }

    /// @dev The predictor share of the fee, rounded down so the owner keeps the remainder; 0 when no
    ///      revealed forecast beat the baseline, leaving the whole fee to the owner.
    function _predictorPool(Round storage r) internal view returns (uint256) {
        if (r.totalExcess == 0) return 0;
        return (_roundFee(r) * predictorShareBps) / BPS;
    }

    // ---------------------------------------------------------------- views
    function getRound(uint256 id)
        external
        view
        roundExists(id)
        returns (
            uint64 startTime,
            bool settled,
            bool voided,
            uint256 winningBucket,
            uint256 realizedVol,
            uint256 totalStake,
            uint256[5] memory pools,
            uint256[] memory bounds
        )
    {
        Round storage r = rounds[id];
        return (r.startTime, r.settled, r.voided, r.winningBucket, r.realizedVol, r.totalStake, r.pools, r.bounds);
    }

    function getFeatures(uint256 id) external view roundExists(id) returns (int256[16] memory) {
        return rounds[id].features;
    }

    function getCheckpoint(uint256 id, uint256 k) external view returns (bool sampled, int56 tickCumulative) {
        Round storage r = rounds[id];
        return (r.sampledBits & (1 << k) != 0, r.checkpoints[k]);
    }

    function getStake(uint256 id, address who, uint256 bucket) external view returns (uint256) {
        return rounds[id].stakes[who][bucket];
    }

    function getPrediction(uint256 id, address who)
        external
        view
        returns (bool recorded, uint256 modelId, uint256[5] memory probs, int256 logScore)
    {
        Prediction storage p = rounds[id].predictions[who];
        return (p.recorded, p.modelId, p.probs, p.logScore);
    }

    function getCommitment(uint256 id, address who) external view returns (bytes32) {
        return rounds[id].predictions[who].commitment;
    }

    /// @notice Committed predictors, revealed or not.
    function predictorCount(uint256 id) external view returns (uint256) {
        return rounds[id].predictors.length;
    }
}
