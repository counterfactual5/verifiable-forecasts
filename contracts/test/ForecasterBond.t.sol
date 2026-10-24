// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VolMarket} from "../src/VolMarket.sol";
import {ForecasterBond, IVolMarketBondView} from "../src/ForecasterBond.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IUniswapV3PoolOracle} from "../src/interfaces/IUniswapV3PoolOracle.sol";
import {SpikeModelVerifier} from "../src/verifier/SpikeModelVerifier.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @dev MockERC20 that, once armed, calls `target` with `data` on its next transfer.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public data;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        address t = target;
        if (t != address(0)) {
            target = address(0);
            (bool ok, bytes memory ret) = t.call(data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        return super.transfer(to, amount);
    }
}

contract ForecasterBondTest is Test {
    uint32 constant DELTA = 300;
    uint8 constant N = 12;
    uint256 constant T0 = 1_000_000;
    uint64 constant START = uint64(T0 + 600);
    uint256 constant END = START + uint256(N) * DELTA;
    uint32 constant COMMIT_LEAD = 300;
    uint32 constant REVEAL_LEAD = 120;
    uint256 constant COMMIT_END = START - COMMIT_LEAD;

    uint256 constant BOND_COMMIT = 100e18;
    uint256 constant BOND_REPRO = 50e18;
    uint256 constant WITHDRAW_DELAY = 1 days;
    uint256 constant SCAN = 4;
    uint256 constant NONREVEAL_BPS = 5000;
    uint256 constant CHALLENGE_BPS = 10_000;
    uint256 constant REPORTER_BPS = 3000;
    uint256 constant CHALLENGER_BOND = 10e18;
    uint256 constant WINDOW = 2 hours;
    uint256 constant TIMEOUT = 1 days;

    ReentrantToken token;
    MockPool pool;
    VolMarket market;
    ForecasterBond bond;

    address alice = makeAddr("alice"); // commit-only model
    address bob = makeAddr("bob"); // reproducible model
    address carol = makeAddr("carol"); // zk model
    address dave = makeAddr("dave"); // reproducible model that forecasts well
    address erin = makeAddr("erin"); // second good forecaster, commit-only
    address eve = makeAddr("eve"); // challenger / reporter
    address arbiter = makeAddr("arbiter");
    address sink = makeAddr("sink");

    uint256 commitModel;
    uint256 reproModel;
    uint256 zkModel;
    uint256 daveModel;
    uint256 erinModel;

    function setUp() public {
        token = new ReentrantToken();
        pool = new MockPool();
        pool.setTickFrom(T0 - 20 * uint256(DELTA), 196000);
        // Segment ticks giving RV 49, bucket 3 (VolMarketTest._mixed).
        int24[12] memory ticks =
            [int24(196000), 196002, 195999, 196003, 196003, 196002, 196000, 196001, 195999, 195999, 196002, 196001];
        for (uint256 k = 0; k < N; ++k) {
            pool.setTickFrom(START + k * DELTA, ticks[k]);
        }
        market = new VolMarket(
            IERC20(address(token)),
            100,
            5000,
            IUniswapV3PoolOracle(address(pool)),
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            200,
            3900
        );
        commitModel = market.registerModel(address(0), alice);
        reproModel = market.registerModel(address(0), bob, keccak256("bob-weights"));
        zkModel = market.registerModel(address(new SpikeModelVerifier()), carol);
        daveModel = market.registerModel(address(0), dave, keccak256("dave-weights"));
        erinModel = market.registerModel(address(0), erin);
        bond = _bond(BOND_COMMIT, NONREVEAL_BPS, REPORTER_BPS);
        address[6] memory users = [alice, bob, carol, dave, erin, eve];
        for (uint256 i = 0; i < users.length; ++i) {
            token.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            token.approve(address(market), type(uint256).max);
            token.approve(address(bond), type(uint256).max);
            vm.stopPrank();
        }
    }

    // -------- helpers --------------------------------------------------

    function _bond(uint256 bondCommit, uint256 nonRevealBps, uint256 reporterBps) internal returns (ForecasterBond) {
        return new ForecasterBond(
            IVolMarketBondView(address(market)),
            ForecasterBond.Params({
                arbiter: arbiter,
                sink: sink,
                bondCommitOnly: bondCommit,
                bondReproducible: BOND_REPRO,
                withdrawDelay: WITHDRAW_DELAY,
                lockScanRounds: SCAN,
                nonRevealSlashBps: nonRevealBps,
                challengeSlashBps: CHALLENGE_BPS,
                reporterShareBps: reporterBps,
                challengerBond: CHALLENGER_BOND,
                challengeWindow: WINDOW,
                resolveTimeout: TIMEOUT
            })
        );
    }

    function _bounds() internal pure returns (uint256[] memory b) {
        b = new uint256[](4);
        b[0] = 8;
        b[1] = 20;
        b[2] = 45;
        b[3] = 110;
    }

    function _create() internal returns (uint256) {
        vm.warp(T0);
        return market.createRound(START, _bounds());
    }

    function _probs(uint256 win, uint256 pWin) internal pure returns (uint256[5] memory p) {
        uint256 rest = (1e18 - pWin) / 4;
        for (uint256 i = 0; i < 5; ++i) {
            p[i] = i == win ? pWin : rest;
        }
        p[win == 4 ? 3 : 4] += 1e18 - pWin - rest * 4;
    }

    function _salt(address who) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", who));
    }

    function _commit(uint256 id, uint256 modelId, address who, uint256[5] memory out) internal {
        vm.prank(who);
        market.commitPrediction(id, modelId, keccak256(abi.encode(id, modelId, out, _salt(who), who)));
    }

    function _reveal(uint256 id, address who, uint256[5] memory out) internal {
        vm.prank(who);
        market.revealPrediction(id, "", out, _salt(who));
    }

    function _post(address who, uint256 modelId) internal {
        vm.prank(who);
        bond.postBond(modelId);
    }

    function _settle(uint256 id) internal {
        vm.warp(END + 10);
        market.settle(id);
    }

    /// @dev Round 0: alice commits and never reveals; bob and dave reveal; settled.
    function _nonRevealRound() internal returns (uint256 id) {
        _post(alice, commitModel);
        id = _create();
        _commit(id, commitModel, alice, _probs(3, 0.9e18));
        _commit(id, daveModel, dave, _probs(3, 0.8e18));
        vm.warp(COMMIT_END);
        _reveal(id, dave, _probs(3, 0.8e18));
        _settle(id);
    }

    /// @dev Round 0 with bob's reproducible forecast and dave's good one revealed, not yet settled.
    function _reproRound() internal returns (uint256 id) {
        _post(bob, reproModel);
        id = _create();
        _commit(id, reproModel, bob, _probs(3, 0.6e18));
        _commit(id, daveModel, dave, _probs(3, 0.8e18));
        vm.warp(COMMIT_END);
        _reveal(id, bob, _probs(3, 0.6e18));
        _reveal(id, dave, _probs(3, 0.8e18));
    }

    function _challenge(uint256 id) internal returns (uint256 cid) {
        vm.prank(eve);
        cid = bond.challenge(id, reproModel, keccak256("recomputed"));
    }

    // -------- bonds by tier ---------------------------------------------

    function test_RequiredBondByTier() public view {
        assertEq(bond.requiredBond(commitModel), BOND_COMMIT);
        assertEq(bond.requiredBond(reproModel), BOND_REPRO);
        assertEq(bond.requiredBond(zkModel), 0);
        assertTrue(bond.isBonded(zkModel), "zk needs no bond");
        assertFalse(bond.isBonded(commitModel));
        assertFalse(bond.isBonded(reproModel));
    }

    function test_PostBondTakesTierAmountOnlyFromOperator() public {
        vm.prank(eve);
        vm.expectRevert(ForecasterBond.NotOperator.selector);
        bond.postBond(commitModel);
        uint256 before = token.balanceOf(alice);
        _post(alice, commitModel);
        assertEq(before - token.balanceOf(alice), BOND_COMMIT);
        assertTrue(bond.isBonded(commitModel));
        vm.prank(alice);
        vm.expectRevert(ForecasterBond.InvalidParams.selector);
        bond.postBond(commitModel);
    }

    function test_ConstructorRejectsZeroBondsAndBadBps() public {
        vm.expectRevert(ForecasterBond.InvalidParams.selector);
        _bond(0, NONREVEAL_BPS, REPORTER_BPS);
        vm.expectRevert(ForecasterBond.InvalidParams.selector);
        _bond(BOND_COMMIT, 10_001, REPORTER_BPS);
        vm.expectRevert(ForecasterBond.InvalidParams.selector);
        _bond(BOND_COMMIT, NONREVEAL_BPS, 10_001);
    }

    // -------- non-reveal slash -------------------------------------------

    function test_NonRevealSlashPermissionlessAfterSettleOnlyOnce() public {
        _post(alice, commitModel);
        uint256 id = _create();
        _commit(id, commitModel, alice, _probs(3, 0.9e18));
        _commit(id, daveModel, dave, _probs(3, 0.8e18));
        vm.warp(COMMIT_END);
        _reveal(id, dave, _probs(3, 0.8e18));
        vm.warp(END - 1);
        vm.prank(eve);
        vm.expectRevert(ForecasterBond.NotSlashable.selector);
        bond.slashNonReveal(id, commitModel);
        _settle(id);

        uint256 eveBefore = token.balanceOf(eve);
        vm.prank(eve);
        bond.slashNonReveal(id, commitModel);
        uint256 slashedAmount = BOND_COMMIT * NONREVEAL_BPS / 10_000;
        uint256 toEve = slashedAmount * REPORTER_BPS / 10_000;
        assertEq(token.balanceOf(eve) - eveBefore, toEve);
        (uint256 amount,,,) = bond.bonds(commitModel);
        assertEq(amount, BOND_COMMIT - slashedAmount);
        assertFalse(bond.isBonded(commitModel), "below requirement after a slash");

        uint256 daveBefore = token.balanceOf(dave);
        vm.prank(dave);
        bond.claimSlashReward(id, commitModel);
        assertEq(token.balanceOf(dave) - daveBefore, slashedAmount - toEve, "sole above-baseline forecaster");
        assertEq(token.balanceOf(address(bond)), BOND_COMMIT - slashedAmount, "nothing stranded");

        vm.prank(eve);
        vm.expectRevert(ForecasterBond.AlreadySlashed.selector);
        bond.slashNonReveal(id, commitModel);
    }

    function test_NonRevealSlashRejectsRevealedOrForeignModel() public {
        uint256 id = _reproRound();
        _settle(id);
        vm.expectRevert(ForecasterBond.NotSlashable.selector);
        bond.slashNonReveal(id, reproModel);
        vm.expectRevert(ForecasterBond.NotSlashable.selector);
        bond.slashNonReveal(id, commitModel); // alice never committed
    }

    function test_SlashWithoutAboveBaselineForecasterGoesToSink() public {
        _post(alice, commitModel);
        uint256 id = _create();
        _commit(id, commitModel, alice, _probs(3, 0.9e18));
        _settle(id);
        vm.prank(eve);
        bond.slashNonReveal(id, commitModel);
        uint256 slashedAmount = BOND_COMMIT * NONREVEAL_BPS / 10_000;
        assertEq(token.balanceOf(sink), slashedAmount - slashedAmount * REPORTER_BPS / 10_000);
    }

    /// @dev Odd bond and split ratios, two above-baseline forecasters with different excess: the
    ///      reporter, both claims and the remaining bond add up to the bond exactly.
    function testFuzz_SlashSplitConserves(uint256 bondCommit, uint256 nonRevealBps, uint256 reporterBps) public {
        bondCommit = bound(bondCommit, 1, 1_000_000e18);
        nonRevealBps = bound(nonRevealBps, 1, 10_000);
        reporterBps = bound(reporterBps, 0, 10_000);
        bond = _bond(bondCommit, nonRevealBps, reporterBps);
        vm.prank(alice);
        token.approve(address(bond), type(uint256).max);
        uint256 slashedAmount = bondCommit * nonRevealBps / 10_000;
        vm.assume(slashedAmount > 0);
        _post(alice, commitModel);
        uint256 id = _create();
        _commit(id, commitModel, alice, _probs(3, 0.9e18));
        _commit(id, daveModel, dave, _probs(3, 0.8e18));
        _commit(id, erinModel, erin, _probs(3, 0.37e18));
        vm.warp(COMMIT_END);
        _reveal(id, dave, _probs(3, 0.8e18));
        _reveal(id, erin, _probs(3, 0.37e18));
        _settle(id);

        uint256[3] memory before = [token.balanceOf(eve), token.balanceOf(dave), token.balanceOf(erin)];
        vm.prank(eve);
        bond.slashNonReveal(id, commitModel);
        if (slashedAmount - slashedAmount * reporterBps / 10_000 != 0) {
            vm.prank(erin);
            bond.claimSlashReward(id, commitModel);
            vm.prank(dave);
            bond.claimSlashReward(id, commitModel);
        }
        uint256 paid =
            token.balanceOf(eve) - before[0] + token.balanceOf(dave) - before[1] + token.balanceOf(erin) - before[2];
        assertEq(paid, slashedAmount, "every slashed unit paid out");
        assertEq(token.balanceOf(address(bond)), bondCommit - slashedAmount);
        assertEq(token.balanceOf(sink), 0);
    }

    // -------- withdrawal ---------------------------------------------------

    function test_WithdrawAfterDelayOnly() public {
        _post(bob, reproModel);
        vm.prank(bob);
        vm.expectRevert(ForecasterBond.NotWithdrawing.selector);
        bond.withdraw(reproModel);
        vm.prank(bob);
        bond.requestWithdraw(reproModel);
        assertFalse(bond.isBonded(reproModel), "withdrawing models are not bonded");
        vm.warp(block.timestamp + WITHDRAW_DELAY - 1);
        vm.prank(bob);
        vm.expectRevert(ForecasterBond.WithdrawLocked.selector);
        bond.withdraw(reproModel);
        vm.warp(block.timestamp + 1);
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        bond.withdraw(reproModel);
        assertEq(token.balanceOf(bob) - before, BOND_REPRO);
    }

    function test_WithdrawLockedWhileCommitUnsettledOrUnrevealed() public {
        _post(alice, commitModel);
        uint256 id = _create();
        _commit(id, commitModel, alice, _probs(3, 0.9e18));
        vm.prank(alice);
        bond.requestWithdraw(commitModel);
        vm.warp(T0 + WITHDRAW_DELAY);
        vm.prank(alice);
        vm.expectRevert(ForecasterBond.WithdrawLocked.selector);
        bond.withdraw(commitModel); // round unsettled
        market.settle(id);
        vm.warp(END + WINDOW + WITHDRAW_DELAY);
        vm.prank(alice);
        vm.expectRevert(ForecasterBond.WithdrawLocked.selector);
        bond.withdraw(commitModel); // unrevealed and not yet slashed
        bond.slashNonReveal(id, commitModel);
        vm.prank(alice);
        bond.withdraw(commitModel);
        assertEq(token.balanceOf(address(bond)), 0);
    }

    function test_WithdrawLockedDuringOpenChallenge() public {
        uint256 id = _reproRound();
        uint256 cid = _challenge(id);
        vm.prank(bob);
        bond.requestWithdraw(reproModel);
        _settle(id);
        vm.warp(COMMIT_END + WITHDRAW_DELAY); // delay over, challenge past its deadline but still open
        vm.prank(bob);
        vm.expectRevert(ForecasterBond.WithdrawLocked.selector);
        bond.withdraw(reproModel);
        bond.expire(cid);
        vm.prank(bob);
        bond.withdraw(reproModel);
    }

    // -------- reproducible challenges --------------------------------------

    function test_ChallengeUpheldSlashesAndRewards() public {
        uint256 id = _reproRound();
        uint256 eveBefore = token.balanceOf(eve);
        uint256 cid = _challenge(id);
        assertEq(eveBefore - token.balanceOf(eve), CHALLENGER_BOND);
        vm.warp(END - 1);
        vm.prank(arbiter);
        vm.expectRevert(ForecasterBond.ChallengePending.selector);
        bond.resolve(cid, true); // round not settled
        _settle(id);
        vm.prank(arbiter);
        bond.resolve(cid, true);

        uint256 toEve = BOND_REPRO * REPORTER_BPS / 10_000;
        assertEq(token.balanceOf(eve), eveBefore + toEve, "challenger bond back plus reporter share");
        (uint256 amount,,,) = bond.bonds(reproModel);
        assertEq(amount, 0);
        (uint256 poolAmount,,) = bond.rewardPool(id, reproModel);
        assertEq(poolAmount, BOND_REPRO - toEve);
        vm.prank(bob);
        vm.expectRevert(ForecasterBond.NothingToClaim.selector);
        bond.claimSlashReward(id, reproModel); // the slashed operator is excluded
        uint256 daveBefore = token.balanceOf(dave);
        vm.prank(dave);
        bond.claimSlashReward(id, reproModel);
        assertEq(token.balanceOf(dave) - daveBefore, BOND_REPRO - toEve);
        assertEq(token.balanceOf(address(bond)), 0);
        vm.expectRevert(ForecasterBond.AlreadySlashed.selector);
        _challenge(id);
    }

    function test_ChallengeRejectedPaysOperator() public {
        uint256 id = _reproRound();
        uint256 cid = _challenge(id);
        _settle(id);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(arbiter);
        bond.resolve(cid, false);
        assertEq(token.balanceOf(bob) - bobBefore, CHALLENGER_BOND);
        (uint256 amount,,, uint256 open) = bond.bonds(reproModel);
        assertEq(amount, BOND_REPRO);
        assertEq(open, 0);
        vm.prank(arbiter);
        vm.expectRevert(ForecasterBond.ChallengeClosed.selector);
        bond.resolve(cid, true);
    }

    function test_ChallengeTimeoutRefundsWithoutSlash() public {
        uint256 id = _reproRound();
        uint256 eveBefore = token.balanceOf(eve);
        uint256 cid = _challenge(id);
        vm.expectRevert(ForecasterBond.ChallengePending.selector);
        bond.expire(cid);
        _settle(id);
        vm.warp(COMMIT_END + TIMEOUT);
        vm.prank(arbiter);
        vm.expectRevert(ForecasterBond.ChallengeExpired.selector);
        bond.resolve(cid, true);
        bond.expire(cid);
        assertEq(token.balanceOf(eve), eveBefore);
        (uint256 amount,,,) = bond.bonds(reproModel);
        assertEq(amount, BOND_REPRO);
    }

    function test_OnlyArbiterResolves() public {
        uint256 id = _reproRound();
        uint256 cid = _challenge(id);
        _settle(id);
        address[3] memory others = [eve, bob, address(this)];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(ForecasterBond.NotArbiter.selector);
            bond.resolve(cid, true);
        }
    }

    function test_ChallengeOnlyReproducibleRevealedInWindow() public {
        uint256 id = _reproRound();
        vm.prank(eve);
        vm.expectRevert(ForecasterBond.NothingToSlash.selector);
        bond.challenge(id, daveModel, bytes32(0)); // reproducible but unbonded
        vm.prank(eve);
        vm.expectRevert(ForecasterBond.NotChallengeable.selector);
        bond.challenge(id, commitModel, bytes32(0));
        _challenge(id);
        vm.prank(eve);
        vm.expectRevert(ForecasterBond.ChallengePending.selector);
        bond.challenge(id, reproModel, bytes32(0));
        vm.warp(END + WINDOW);
        vm.prank(eve);
        vm.expectRevert(ForecasterBond.NotChallengeable.selector);
        bond.challenge(id, reproModel, bytes32(0));
    }

    // -------- reentrancy ---------------------------------------------------

    function test_TokenCallbackCannotReenter() public {
        uint256 id = _nonRevealRound();
        token.arm(address(bond), abi.encodeCall(ForecasterBond.claimSlashReward, (id, commitModel)));
        vm.prank(eve);
        vm.expectRevert(ForecasterBond.Reentrancy.selector);
        bond.slashNonReveal(id, commitModel);
    }

    // -------- VolMarket bond gate --------------------------------------------

    function test_GateRejectsUnbondedCommits() public {
        market.setBondGate(address(bond));
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(VolMarket.NotBonded.selector);
        market.commitPrediction(id, commitModel, keccak256("x"));
        vm.prank(bob);
        vm.expectRevert(VolMarket.NotBonded.selector);
        market.commitPrediction(id, reproModel, keccak256("x"));
        _post(alice, commitModel);
        _commit(id, commitModel, alice, _probs(3, 0.9e18));
        assertEq(market.predictorCount(id), 1);
    }

    function test_GateLeavesZkModelsUnaffected() public {
        market.setBondGate(address(bond));
        uint256 id = _create();
        vm.prank(carol);
        market.commitPrediction(id, zkModel, keccak256("x"));
        assertEq(market.predictorCount(id), 1);
    }

    function test_GateRefusesCommitsWhileWithdrawing() public {
        market.setBondGate(address(bond));
        _post(alice, commitModel);
        vm.prank(alice);
        bond.requestWithdraw(commitModel);
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(VolMarket.NotBonded.selector);
        market.commitPrediction(id, commitModel, keccak256("x"));
    }

    function test_GateSetOnceByOwner() public {
        vm.prank(eve);
        vm.expectRevert(VolMarket.NotOwner.selector);
        market.setBondGate(address(bond));
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.setBondGate(address(0));
        market.setBondGate(address(bond));
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.setBondGate(address(1));
    }
}
