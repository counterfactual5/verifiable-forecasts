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
///         AI forecasts (5-bucket distributions) are accepted only with an EZKL proof whose public
///         inputs are features the contract derived from `observe()` at round creation.
/// @dev Round lifecycle: Open (bets, predictions until startTime) -> Sampling (until
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

    // ---------------------------------------------------------------- events
    event ModelRegistered(uint256 indexed modelId, address verifier, address operator);
    event RoundCreated(uint256 indexed roundId, uint64 startTime, uint256[] bounds, int256[16] features);
    event BetPlaced(uint256 indexed roundId, address indexed bettor, uint256 bucket, uint256 amount);
    event PredictionSubmitted(
        uint256 indexed roundId, address indexed predictor, uint256 indexed modelId, uint256[5] probs
    );
    event CheckpointSampled(uint256 indexed roundId, uint256 indexed k, int56 tickCumulative);
    event RoundSettled(uint256 indexed roundId, uint256 winningBucket, uint256 realizedVol, uint256 availablePoints);
    event RoundVoided(uint256 indexed roundId);
    event PredictionScored(uint256 indexed roundId, address indexed predictor, int256 logScore);
    event Claimed(uint256 indexed roundId, address indexed claimant, uint256 payout);
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
        mapping(uint256 => int56) checkpoints;
        mapping(address => mapping(uint256 => uint256)) stakes; // user -> bucket -> stake
        mapping(address => Prediction) predictions;
        address[] predictors;
    }

    struct Prediction {
        bool recorded;
        uint256 modelId;
        uint256[5] probs; // scaled by 1e18, sum exactly 1e18
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

    IERC20 public immutable token;
    uint256 public immutable feeBps; // protocol fee in basis points on the whole pool
    IUniswapV3PoolOracle public immutable pool;
    uint32 public immutable delta; // segment length in seconds
    uint8 public immutable nSegments;
    address public immutable owner;

    address[] public models; // modelId -> EZKL verifier
    mapping(uint256 => address) public modelOperator; // the only account that may submit with modelId
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

    // ---------------------------------------------------------------- modifiers
    modifier roundExists(uint256 id) {
        if (id >= roundCount) revert RoundNotFound();
        _;
    }

    // ---------------------------------------------------------------- constructor
    /// @param token_ settlement token
    /// @param feeBps_ protocol fee on the pool, e.g. 100 = 1%. Must be < 1000.
    /// @param pool_ Uniswap V3 pool (or anything exposing `observe`)
    /// @param delta_ segment length in seconds; 17 * delta_ must fit in uint32
    /// @param nSegments_ segments per round window, >= 2
    constructor(IERC20 token_, uint256 feeBps_, IUniswapV3PoolOracle pool_, uint32 delta_, uint8 nSegments_) {
        if (address(token_) == address(0) || address(pool_) == address(0)) revert ZeroAddress();
        if (feeBps_ >= 1000 || delta_ == 0 || nSegments_ < 2) revert InvalidParams();
        if (uint256(delta_) * (FEATURES + 1) > type(uint32).max) revert InvalidParams();
        token = token_;
        feeBps = feeBps_;
        pool = pool_;
        delta = delta_;
        nSegments = nSegments_;
        owner = msg.sender;
        tickPriceMath = new TickPriceMath();
    }

    // ---------------------------------------------------------------- models
    /// @notice Register an EZKL verifier for one model; predictions cite it by the returned id.
    /// @param operator the only account allowed to submit with this model: a proof does not bind its
    ///        sender, so without this anyone could resubmit a copied proof as their own forecast
    function registerModel(address verifier, address operator) external returns (uint256 modelId) {
        if (msg.sender != owner) revert NotOwner();
        if (verifier == address(0) || operator == address(0)) revert ZeroAddress();
        modelId = models.length;
        models.push(verifier);
        modelOperator[modelId] = operator;
        emit ModelRegistered(modelId, verifier, operator);
    }

    function modelCount() external view returns (uint256) {
        return models.length;
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
    /// @param bounds 4 strictly ascending realized-vol bounds in tick^2 (5 buckets)
    function createRound(uint64 startTime, uint256[] calldata bounds) external returns (uint256 id) {
        if (startTime <= block.timestamp) revert InvalidParams();
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
    /// @notice Submit a forecast proven by model `modelId` on this round's features.
    ///         One submission per predictor per round, before startTime.
    /// @param outputs the circuit's 5 public outputs (field elements, each < R/2, sum > 0)
    function submitPrediction(uint256 id, uint256 modelId, bytes calldata proof, uint256[5] calldata outputs)
        external
        roundExists(id)
    {
        Round storage r = rounds[id];
        if (block.timestamp >= r.startTime) revert TooLateToPredict();
        if (modelId >= models.length) revert UnknownModel();
        if (msg.sender != modelOperator[modelId]) revert NotModelOperator();
        Prediction storage p = r.predictions[msg.sender];
        if (p.recorded) revert AlreadyPredicted();
        if (r.predictors.length >= MAX_PREDICTORS) revert TooManyPredictors();

        uint256 sum;
        for (uint256 i = 0; i < BUCKETS; ++i) {
            if (outputs[i] >= FIELD_R / 2) revert BadOutputs();
            sum += outputs[i];
        }
        if (sum == 0) revert BadOutputs();

        _verify(models[modelId], proof, _instances(r.features, outputs));

        uint256[5] memory probs;
        uint256 assigned;
        for (uint256 i = 0; i < BUCKETS - 1; ++i) {
            probs[i] = (outputs[i] * 1e18) / sum;
            assigned += probs[i];
        }
        probs[BUCKETS - 1] = 1e18 - assigned;

        p.recorded = true;
        p.modelId = modelId;
        p.probs = probs;
        r.predictors.push(msg.sender);
        emit PredictionSubmitted(id, msg.sender, modelId, probs);
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
        try priceFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_FEED_AGE) {
                emit PriceCheckFailed(id, int24(meanTick), int256(poolPrice), answer, 2);
                return false;
            }
            uint8 feedDecimals;
            try priceFeed.decimals() returns (uint8 d) {
                feedDecimals = d;
            } catch {
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
            emit PriceCheckFailed(id, int24(meanTick), int256(poolPrice), 0, 5);
            return false;
        }
    }

    /// @dev logScore = max(ln p_win, -18e18); p_win = 0 also scores -18e18.
    function _score(Round storage r, uint256 id, uint256 win) internal {
        uint256 predictorsLen = r.predictors.length;
        for (uint256 i = 0; i < predictorsLen; ++i) {
            address who = r.predictors[i];
            Prediction storage p = r.predictions[who];
            uint256 pw = p.probs[win];
            int256 score = pw == 0 ? MIN_LOG_SCORE : MarketMath.log1e18(pw);
            if (score < MIN_LOG_SCORE) score = MIN_LOG_SCORE;
            p.logScore = score;
            emit PredictionScored(id, who, score);
        }
    }

    /// @dev Writes the scored log score of every predictor with a bound agent to the ERC-8004
    ///      reputation registry. The registry is untrusted here: a rejected write is reported as
    ///      an event and never blocks settlement or the claims that follow it.
    function _writeReputation(Round storage r, uint256 id) internal {
        if (address(reputationRegistry) == address(0)) return;
        uint256 predictorsLen = r.predictors.length;
        string memory tag2 = _reputationTag();
        for (uint256 i = 0; i < predictorsLen; ++i) {
            address who = r.predictors[i];
            Prediction storage p = r.predictions[who];
            uint256 modelId = p.modelId;
            if (!agentBound[modelId]) continue;
            uint256 agentId = agentOfModel[modelId];
            if (agentId == 0) continue; // binding without an agent: nothing to attribute
            _giveFeedback(id, who, agentId, _toInt128(p.logScore), tag2);
        }
    }

    function _giveFeedback(uint256 id, address who, uint256 agentId, int128 value, string memory tag2) internal {
        try reputationRegistry.giveFeedback(agentId, value, 18, "logScore", tag2, "", "", bytes32(0)) {}
        catch (bytes memory reason) {
            emit ReputationWriteFailed(id, who, agentId, keccak256(reason));
        }
    }

    /// @dev tag2 identifies the window the score belongs to: "vol-<delta>s-<nSegments>", derived
    ///      from the constructor parameters so that markets with different windows do not mix.
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
            try pool.observe(secs) returns (int56[] memory c, uint160[] memory) {
                for (uint256 i = 0; i < missing; ++i) {
                    cums[idx[i]] = c[i];
                    have |= 1 << idx[i];
                }
            } catch {
                uint32[] memory one = new uint32[](1);
                for (uint256 i = 0; i < missing; ++i) {
                    one[0] = secs[i];
                    try pool.observe(one) returns (int56[] memory c, uint160[] memory) {
                        cums[idx[i]] = c[0];
                        have |= 1 << idx[i];
                    } catch {}
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
        uint256 payout = MarketMath.payout(stake, r.totalStake, r.pools[r.winningBucket], feeBps);
        if (!token.transfer(msg.sender, payout)) revert TransferFailed();
        emit Claimed(id, msg.sender, payout);
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

    function predictorCount(uint256 id) external view returns (uint256) {
        return rounds[id].predictors.length;
    }
}
