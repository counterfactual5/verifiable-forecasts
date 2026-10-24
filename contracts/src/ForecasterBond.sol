// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";
import {IBondGate} from "./interfaces/IBondGate.sol";

/// @notice The VolMarket views ForecasterBond reads; VolMarket satisfies it as deployed.
interface IVolMarketBondView {
    function token() external view returns (IERC20);
    function verificationTier(uint256 modelId) external view returns (uint8);
    function modelOperator(uint256 modelId) external view returns (address);
    function roundCount() external view returns (uint256);
    function delta() external view returns (uint32);
    function nSegments() external view returns (uint8);
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
    function getPrediction(uint256 id, address who)
        external
        view
        returns (bool recorded, uint256 modelId, uint256[5] memory probs, int256 logScore);
    function getCommitment(uint256 id, address who) external view returns (bytes32);
    function predictorCount(uint256 id) external view returns (uint256);
    function predictorAt(uint256 id, uint256 i) external view returns (address);
    function baselineLogScore() external view returns (int256);
}

/// @title ForecasterBond
/// @notice Per-model bonds by verification tier, slashing for unrevealed commits, and an
///         optimistic challenge of reproducible-tier forecasts, all in the market's token.
/// @dev Reads VolMarket only; VolMarket asks `isBonded` before a commit when this contract is
///      set as its bond gate. Challenges are resolved by `arbiter`, an interim trust assumption:
///      large models cannot be re-run on-chain, so a recomputation mismatch is judged off-chain
///      (vol_agents.tsfm_recompute) by one party until an on-chain fraud proof or a multi-party
///      arbiter replaces it. An unresolved challenge refunds the challenger and slashes nothing.
contract ForecasterBond is IBondGate {
    error InvalidParams();
    error ZeroAddress();
    error NotOperator();
    error NotArbiter();
    error Reentrancy();
    error TransferFailed();
    error Withdrawing();
    error NotWithdrawing();
    error WithdrawLocked();
    error NothingToSlash();
    error AlreadySlashed();
    error NotSlashable();
    error NotChallengeable();
    error ChallengeClosed();
    error ChallengeExpired();
    error ChallengePending();
    error NothingToClaim();

    event BondPosted(uint256 indexed modelId, uint256 amount, uint256 total);
    event WithdrawRequested(uint256 indexed modelId, uint256 roundCount);
    event BondWithdrawn(uint256 indexed modelId, uint256 amount);
    event Slashed(
        uint256 indexed roundId, uint256 indexed modelId, address indexed reporter, uint256 amount, uint256 toReporter
    );
    event SlashSunk(uint256 indexed roundId, uint256 indexed modelId, uint256 amount);
    event ChallengeOpened(
        uint256 indexed challengeId, uint256 indexed roundId, uint256 indexed modelId, address challenger, bytes32 claim
    );
    event ChallengeResolved(uint256 indexed challengeId, bool upheld);
    event ChallengeExpiredRefund(uint256 indexed challengeId);
    event SlashRewardClaimed(uint256 indexed roundId, uint256 indexed modelId, address indexed who, uint256 amount);

    /// @dev Tier ids as VolMarket.verificationTier returns them.
    uint8 public constant TIER_COMMIT_ONLY = 0;
    uint8 public constant TIER_REPRODUCIBLE = 1;
    uint256 private constant BPS = 10_000;

    struct Params {
        address arbiter; // resolves challenges; interim trust assumption
        address sink; // receives the forecaster part of a slash when no forecaster beat the baseline
        uint256 bondCommitOnly; // token units required of a commit-only (black-box) model, > 0
        uint256 bondReproducible; // token units required of a reproducible model, > 0; zk requires 0
        uint256 withdrawDelay; // seconds between requestWithdraw and withdraw
        uint256 lockScanRounds; // rounds before the request scanned for open commits, >= 1
        uint256 nonRevealSlashBps; // share of the bond slashed per unrevealed commit, (0, 10000]
        uint256 challengeSlashBps; // share of the bond slashed per upheld challenge, (0, 10000]
        uint256 reporterShareBps; // share of a slash paid to its challenger or reporter, <= 10000
        uint256 challengerBond; // token units a challenger posts, > 0
        uint256 challengeWindow; // seconds after the round window ends during which challenges open
        uint256 resolveTimeout; // seconds the arbiter has to resolve an opened challenge, > 0
    }

    struct Bond {
        uint256 amount;
        uint256 withdrawRequestedAt; // 0 = not withdrawing
        uint256 requestRoundCount; // market.roundCount() at the request
        uint256 openChallenges;
    }

    struct Challenge {
        uint256 roundId;
        uint256 modelId;
        address challenger;
        uint256 deadline; // resolve before this timestamp; at or after it anyone may expire
        bytes32 claim; // hash of the challenger's recomputed outputs
        bool open;
    }

    /// @dev The forecaster part of one slash, claimed pro rata to excess log score (1e18 scale).
    struct RewardPool {
        uint256 amount;
        uint256 totalExcess;
        uint256 claimedExcess;
        uint256 paid;
        address excluded; // the slashed operator never shares its own slash
        mapping(address => bool) claimed;
    }

    IVolMarketBondView public immutable market;
    IERC20 public immutable token;
    address public immutable arbiter;
    address public immutable sink;
    uint256 public immutable bondCommitOnly;
    uint256 public immutable bondReproducible;
    uint256 public immutable withdrawDelay;
    uint256 public immutable lockScanRounds;
    uint256 public immutable nonRevealSlashBps;
    uint256 public immutable challengeSlashBps;
    uint256 public immutable reporterShareBps;
    uint256 public immutable challengerBond;
    uint256 public immutable challengeWindow;
    uint256 public immutable resolveTimeout;

    mapping(uint256 => Bond) public bonds;
    Challenge[] public challenges;
    mapping(uint256 => mapping(uint256 => bool)) public challengeOpen; // roundId => modelId
    mapping(uint256 => mapping(uint256 => bool)) public slashed; // roundId => modelId, one slash each
    mapping(uint256 => mapping(uint256 => RewardPool)) private pools; // roundId => modelId

    uint256 private locked = 1;

    modifier nonReentrant() {
        _enter();
        _;
        locked = 1;
    }

    modifier onlyOperator(uint256 modelId) {
        _onlyOperator(modelId);
        _;
    }

    function _enter() internal {
        if (locked != 1) revert Reentrancy();
        locked = 2;
    }

    function _onlyOperator(uint256 modelId) internal view {
        if (msg.sender != market.modelOperator(modelId)) revert NotOperator();
    }

    constructor(IVolMarketBondView market_, Params memory p) {
        if (address(market_) == address(0) || p.arbiter == address(0) || p.sink == address(0)) revert ZeroAddress();
        if (p.bondCommitOnly == 0 || p.bondReproducible == 0 || p.challengerBond == 0) revert InvalidParams();
        if (p.lockScanRounds == 0 || p.resolveTimeout == 0) revert InvalidParams();
        if (p.nonRevealSlashBps == 0 || p.nonRevealSlashBps > BPS) revert InvalidParams();
        if (p.challengeSlashBps == 0 || p.challengeSlashBps > BPS || p.reporterShareBps > BPS) revert InvalidParams();
        market = market_;
        token = market_.token();
        arbiter = p.arbiter;
        sink = p.sink;
        bondCommitOnly = p.bondCommitOnly;
        bondReproducible = p.bondReproducible;
        withdrawDelay = p.withdrawDelay;
        lockScanRounds = p.lockScanRounds;
        nonRevealSlashBps = p.nonRevealSlashBps;
        challengeSlashBps = p.challengeSlashBps;
        reporterShareBps = p.reporterShareBps;
        challengerBond = p.challengerBond;
        challengeWindow = p.challengeWindow;
        resolveTimeout = p.resolveTimeout;
    }

    // ---------------------------------------------------------------- bonds
    /// @notice Bond the tier requires of `modelId`; 0 for zk models.
    function requiredBond(uint256 modelId) public view returns (uint256) {
        uint8 tier = market.verificationTier(modelId);
        if (tier == TIER_COMMIT_ONLY) return bondCommitOnly;
        if (tier == TIER_REPRODUCIBLE) return bondReproducible;
        return 0;
    }

    function isBonded(uint256 modelId) external view returns (bool) {
        uint256 required = requiredBond(modelId);
        if (required == 0) return true;
        Bond storage b = bonds[modelId];
        return b.withdrawRequestedAt == 0 && b.amount >= required;
    }

    /// @notice Top the model's bond up to its tier's requirement, e.g. after a slash.
    function postBond(uint256 modelId) external nonReentrant onlyOperator(modelId) {
        Bond storage b = bonds[modelId];
        if (b.withdrawRequestedAt != 0) revert Withdrawing();
        uint256 required = requiredBond(modelId);
        if (b.amount >= required) revert InvalidParams();
        uint256 top = required - b.amount;
        b.amount = required;
        if (!token.transferFrom(msg.sender, address(this), top)) revert TransferFailed();
        emit BondPosted(modelId, top, required);
    }

    /// @notice Start the withdrawal delay. The model stops counting as bonded, so VolMarket refuses
    ///         its new commits; the bond stays slashable until withdrawn.
    function requestWithdraw(uint256 modelId) external onlyOperator(modelId) {
        Bond storage b = bonds[modelId];
        if (b.amount == 0) revert NothingToClaim();
        if (b.withdrawRequestedAt != 0) revert Withdrawing();
        b.withdrawRequestedAt = block.timestamp;
        b.requestRoundCount = market.roundCount();
        emit WithdrawRequested(modelId, b.requestRoundCount);
    }

    /// @notice Withdraw after the delay, with no open challenge and every commit in the last
    ///         lockScanRounds rounds before the request settled, revealed or already slashed, and
    ///         past its challenge window.
    function withdraw(uint256 modelId) external nonReentrant onlyOperator(modelId) {
        Bond storage b = bonds[modelId];
        if (b.withdrawRequestedAt == 0) revert NotWithdrawing();
        if (block.timestamp < b.withdrawRequestedAt + withdrawDelay) revert WithdrawLocked();
        if (b.openChallenges != 0) revert WithdrawLocked();
        if (_hasOpenCommit(modelId, msg.sender, b.requestRoundCount)) revert WithdrawLocked();
        uint256 amount = b.amount;
        delete bonds[modelId];
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit BondWithdrawn(modelId, amount);
    }

    /// @dev Rounds the model joined while bonded end before the request (new commits are refused
    ///      once it is withdrawing), so lockScanRounds must cover the rounds that can still be
    ///      unsettled or inside their challenge window when a request is made.
    function _hasOpenCommit(uint256 modelId, address operator, uint256 roundCount) internal view returns (bool) {
        uint256 from = roundCount > lockScanRounds ? roundCount - lockScanRounds : 0;
        for (uint256 id = from; id < roundCount; ++id) {
            if (market.getCommitment(id, operator) == bytes32(0)) continue;
            (bool recorded, uint256 mid,,) = market.getPrediction(id, operator);
            if (mid != modelId) continue;
            (uint64 startTime, bool settled,,,,,,) = market.getRound(id);
            if (!settled || block.timestamp < _roundEnd(startTime) + challengeWindow) return true;
            if (!recorded && !slashed[id][modelId] && bonds[modelId].amount * nonRevealSlashBps >= BPS) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- non-reveal slash
    /// @notice Anyone slashes nonRevealSlashBps of the bond of a model that committed in a settled
    ///         round and never revealed; once per round and model. The caller is paid as reporter.
    function slashNonReveal(uint256 roundId, uint256 modelId) external nonReentrant {
        address operator = market.modelOperator(modelId);
        if (market.getCommitment(roundId, operator) == bytes32(0)) revert NotSlashable();
        (bool recorded, uint256 mid,,) = market.getPrediction(roundId, operator);
        if (recorded || mid != modelId) revert NotSlashable();
        (, bool settled,,,,,,) = market.getRound(roundId);
        if (!settled) revert NotSlashable();
        _slash(roundId, modelId, operator, msg.sender, nonRevealSlashBps);
    }

    // ---------------------------------------------------------------- reproducible challenges
    /// @notice Challenge a revealed reproducible-tier forecast as not matching its model hash, until
    ///         challengeWindow seconds after the round window ends. Posts challengerBond.
    /// @param claim hash of the challenger's recomputed outputs, for the arbiter and the record
    function challenge(uint256 roundId, uint256 modelId, bytes32 claim)
        external
        nonReentrant
        returns (uint256 challengeId)
    {
        if (market.verificationTier(modelId) != TIER_REPRODUCIBLE) revert NotChallengeable();
        address operator = market.modelOperator(modelId);
        (bool recorded, uint256 mid,,) = market.getPrediction(roundId, operator);
        if (!recorded || mid != modelId) revert NotChallengeable();
        (uint64 startTime,,,,,,,) = market.getRound(roundId);
        if (block.timestamp >= _roundEnd(startTime) + challengeWindow) revert NotChallengeable();
        if (challengeOpen[roundId][modelId]) revert ChallengePending();
        if (slashed[roundId][modelId]) revert AlreadySlashed();
        if (bonds[modelId].amount == 0) revert NothingToSlash();

        challengeId = challenges.length;
        challenges.push(
            Challenge({
                roundId: roundId,
                modelId: modelId,
                challenger: msg.sender,
                deadline: block.timestamp + resolveTimeout,
                claim: claim,
                open: true
            })
        );
        challengeOpen[roundId][modelId] = true;
        ++bonds[modelId].openChallenges;
        if (!token.transferFrom(msg.sender, address(this), challengerBond)) revert TransferFailed();
        emit ChallengeOpened(challengeId, roundId, modelId, msg.sender, claim);
    }

    /// @notice Arbiter verdict before the deadline, once the round is settled. Upheld: the bond is
    ///         slashed by challengeSlashBps and the challenger gets its bond back plus the reporter
    ///         share. Rejected: the challenger bond goes to the model operator.
    function resolve(uint256 challengeId, bool upheld) external nonReentrant {
        if (msg.sender != arbiter) revert NotArbiter();
        Challenge storage c = _close(challengeId);
        if (block.timestamp >= c.deadline) revert ChallengeExpired();
        (, bool settled,,,,,,) = market.getRound(c.roundId);
        if (!settled) revert ChallengePending();
        address operator = market.modelOperator(c.modelId);
        if (upheld) {
            _slash(c.roundId, c.modelId, operator, c.challenger, challengeSlashBps);
            if (!token.transfer(c.challenger, challengerBond)) revert TransferFailed();
        } else {
            if (!token.transfer(operator, challengerBond)) revert TransferFailed();
        }
        emit ChallengeResolved(challengeId, upheld);
    }

    /// @notice Anyone closes a challenge the arbiter left unresolved past its deadline: the
    ///         challenger is refunded and nothing is slashed.
    function expire(uint256 challengeId) external nonReentrant {
        Challenge storage c = _close(challengeId);
        if (block.timestamp < c.deadline) revert ChallengePending();
        if (!token.transfer(c.challenger, challengerBond)) revert TransferFailed();
        emit ChallengeExpiredRefund(challengeId);
    }

    function challengeCount() external view returns (uint256) {
        return challenges.length;
    }

    function _close(uint256 challengeId) internal returns (Challenge storage c) {
        c = challenges[challengeId];
        if (!c.open) revert ChallengeClosed();
        c.open = false;
        challengeOpen[c.roundId][c.modelId] = false;
        --bonds[c.modelId].openChallenges;
    }

    // ---------------------------------------------------------------- slash and rewards
    /// @dev amount = bond * bps / BPS, rounded down. The reporter gets amount * reporterShareBps /
    ///      BPS, rounded down; the rest is the round's forecaster pool, or goes to `sink` when the
    ///      round is voided or no other forecaster beat the baseline. Every token is assigned.
    function _slash(uint256 roundId, uint256 modelId, address operator, address reporter, uint256 bps) internal {
        if (slashed[roundId][modelId]) revert AlreadySlashed();
        Bond storage b = bonds[modelId];
        uint256 amount = (b.amount * bps) / BPS;
        if (amount == 0) revert NothingToSlash();
        b.amount -= amount;
        slashed[roundId][modelId] = true;
        uint256 toReporter = (amount * reporterShareBps) / BPS;
        uint256 rest = amount - toReporter;
        uint256 totalExcess = _totalExcess(roundId, operator);
        if (totalExcess != 0) {
            RewardPool storage pool = pools[roundId][modelId];
            pool.amount = rest;
            pool.totalExcess = totalExcess;
            pool.excluded = operator;
        }
        emit Slashed(roundId, modelId, reporter, amount, toReporter);
        if (toReporter != 0 && !token.transfer(reporter, toReporter)) revert TransferFailed();
        if (totalExcess == 0 && rest != 0) {
            if (!token.transfer(sink, rest)) revert TransferFailed();
            emit SlashSunk(roundId, modelId, rest);
        }
    }

    /// @notice A forecaster of the slashed round that beat the baseline claims its share of the
    ///         forecaster part of the slash of `modelId`, pro rata to its excess log score.
    /// @dev Each share rounds down; the last claimer receives the remainder, so the pool is paid out
    ///      exactly. pool * excess cannot overflow for pools below 2^256 / 1.61e18 token units.
    function claimSlashReward(uint256 roundId, uint256 modelId) external nonReentrant {
        RewardPool storage pool = pools[roundId][modelId];
        uint256 excess = msg.sender == pool.excluded ? 0 : _excessOf(roundId, msg.sender);
        if (pool.amount == 0 || excess == 0 || pool.claimed[msg.sender]) revert NothingToClaim();
        pool.claimed[msg.sender] = true;
        pool.claimedExcess += excess;
        uint256 share = pool.claimedExcess == pool.totalExcess
            ? pool.amount - pool.paid
            : (pool.amount * excess) / pool.totalExcess;
        pool.paid += share;
        if (!token.transfer(msg.sender, share)) revert TransferFailed();
        emit SlashRewardClaimed(roundId, modelId, msg.sender, share);
    }

    function rewardPool(uint256 roundId, uint256 modelId)
        external
        view
        returns (uint256 amount, uint256 totalExcess, uint256 paid)
    {
        RewardPool storage pool = pools[roundId][modelId];
        return (pool.amount, pool.totalExcess, pool.paid);
    }

    /// @dev Sum of excess over the round's committed predictors except `excluded`; 0 when voided.
    ///      Bounded by VolMarket.MAX_PREDICTORS.
    function _totalExcess(uint256 roundId, address excluded) internal view returns (uint256 total) {
        (, bool settled, bool voided,,,,,) = market.getRound(roundId);
        if (!settled || voided) return 0;
        uint256 n = market.predictorCount(roundId);
        for (uint256 i = 0; i < n; ++i) {
            address who = market.predictorAt(roundId, i);
            if (who != excluded) total += _excessOf(roundId, who);
        }
    }

    /// @dev Log score above VolMarket's uniform baseline (both 1e18 scale), as VolMarket pays its
    ///      predictor share; the only place that knows the market's scoring rule.
    function _excessOf(uint256 roundId, address who) internal view returns (uint256) {
        (bool recorded,,, int256 score) = market.getPrediction(roundId, who);
        int256 baseline = market.baselineLogScore();
        return recorded && score > baseline ? uint256(score - baseline) : 0;
    }

    function _roundEnd(uint64 startTime) internal view returns (uint256) {
        return uint256(startTime) + uint256(market.nSegments()) * market.delta();
    }
}
