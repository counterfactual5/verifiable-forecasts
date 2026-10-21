// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {IERC8004Reputation} from "../src/interfaces/IERC8004Reputation.sol";
import {IdentityRegistryLite} from "../src/erc8004/IdentityRegistryLite.sol";
import {ReputationRegistryLite} from "../src/erc8004/ReputationRegistryLite.sol";
import {VolMarket} from "../src/VolMarket.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IUniswapV3PoolOracle} from "../src/interfaces/IUniswapV3PoolOracle.sol";
import {SpikeModelVerifier} from "../src/verifier/SpikeModelVerifier.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @dev Reputation registry whose feedback writes always revert: the market must survive it.
contract RevertingReputationRegistry is IERC8004Reputation {
    error FeedbackDisabled();

    function giveFeedback(
        uint256,
        int128,
        uint8,
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        bytes32
    ) external pure override {
        revert FeedbackDisabled();
    }

    function getSummary(uint256, address[] calldata, string calldata, string calldata)
        external
        pure
        override
        returns (int256)
    {
        return 0;
    }

    function readFeedback(uint256, address)
        external
        pure
        override
        returns (int128[] memory, uint8[] memory, string[] memory, string[] memory)
    {
        return (new int128[](0), new uint8[](0), new string[](0), new string[](0));
    }
}

contract ERC8004Test is Test {
    IdentityRegistryLite identity;
    ReputationRegistryLite reputation;

    address agentOwner = makeAddr("agentOwner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint32 constant DELTA = 300;
    uint8 constant N = 12;
    uint256 constant T0 = 1_000_000; // createRound time
    uint64 constant START = uint64(T0 + 600);
    uint256 constant END = START + uint256(N) * DELTA;

    MockERC20 token;
    MockPool pool;
    VolMarket market;
    string proofJson;

    function setUp() public {
        identity = new IdentityRegistryLite();
        reputation = new ReputationRegistryLite();
        proofJson = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/spike_model_proof.json"));
    }

    // -------- helpers --------------------------------------------------

    function _registerAgent() internal returns (uint256 agentId) {
        vm.prank(agentOwner);
        agentId = identity.register("ipfs://agent-metadata");
    }

    function _feedback(
        address client,
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string memory tag1,
        string memory tag2
    ) internal {
        vm.prank(client);
        reputation.giveFeedback(
            agentId, value, valueDecimals, tag1, tag2, "https://agent.example", "ipfs://feedback", bytes32(0)
        );
    }

    function _clients(address only) internal pure returns (address[] memory clients) {
        clients = new address[](1);
        clients[0] = only;
    }

    // -------- market harness --------------------------------------------

    /// @dev Market on the proof fixture's pool timeline: the last segment continues through the
    ///      window, so the round realizes RV 0 and lands in bucket 0.
    function _deployMarket() internal {
        token = new MockERC20();
        pool = new MockPool();
        int256[] memory segTicks = _segTicks();
        for (uint256 j = 0; j < segTicks.length; ++j) {
            pool.setTickFrom(T0 - (17 - j) * uint256(DELTA), int24(segTicks[j]));
        }
        market = new VolMarket(IERC20(address(token)), 0, IUniswapV3PoolOracle(address(pool)), DELTA, N);
        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);
    }

    function _bounds() internal pure returns (uint256[] memory b) {
        b = new uint256[](4);
        b[0] = 8;
        b[1] = 20;
        b[2] = 45;
        b[3] = 110;
    }

    function _create() internal returns (uint256 id) {
        vm.warp(T0);
        id = market.createRound(START, _bounds());
    }

    function _proof() internal view returns (bytes memory) {
        return vm.parseJsonBytes(proofJson, ".proof");
    }

    function _outputs() internal view returns (uint256[5] memory out) {
        uint256[] memory o = vm.parseJsonUintArray(proofJson, ".outputs");
        assertEq(o.length, 5);
        for (uint256 i = 0; i < 5; ++i) {
            out[i] = o[i];
        }
    }

    function _segTicks() internal view returns (int256[] memory) {
        return vm.parseJsonIntArray(proofJson, ".segmentTicks");
    }

    function _reputationWriteFailedTopic() internal pure returns (bytes32) {
        return keccak256("ReputationWriteFailed(uint256,address,uint256,bytes32)");
    }

    /// @dev Number of ReputationWriteFailed events the market emitted during `logs`.
    function _countWriteFailures(Vm.Log[] memory logs) internal view returns (uint256 count) {
        bytes32 topic = _reputationWriteFailedTopic();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(market)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic) continue;
            ++count;
        }
    }

    // -------- identity -------------------------------------------------

    function test_LiteIdentityRegisterMintsAscendingIds() public {
        vm.expectEmit(true, true, true, true);
        emit IERC8004Identity.Registered(1, "ipfs://alice", alice);
        vm.prank(alice);
        uint256 first = identity.register("ipfs://alice");

        vm.prank(bob);
        uint256 second = identity.register("ipfs://bob");

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(identity.ownerOf(1), alice);
        assertEq(identity.ownerOf(2), bob);
        assertEq(identity.agentCount(), 2);
        assertEq(identity.getAgentURI(1), "ipfs://alice");
    }

    // -------- reputation -----------------------------------------------

    function test_LiteGiveFeedbackRecordsClientAndTags() public {
        uint256 agentId = _registerAgent();

        vm.expectEmit(true, true, true, true);
        emit IERC8004Reputation.NewFeedback(agentId, alice, -1.5e18, 18, "logScore", "volR2");
        _feedback(alice, agentId, -1.5e18, 18, "logScore", "volR2");

        (int128[] memory values, uint8[] memory valueDecimals, string[] memory tag1s, string[] memory tag2s) =
            reputation.readFeedback(agentId, alice);
        assertEq(values.length, 1);
        assertEq(int256(values[0]), -1.5e18);
        assertEq(uint256(valueDecimals[0]), 18);
        assertEq(tag1s[0], "logScore");
        assertEq(tag2s[0], "volR2");

        // Feedback lands under the submitting client only.
        (int128[] memory bobValues,,,) = reputation.readFeedback(agentId, bob);
        assertEq(bobValues.length, 0);
    }

    function test_LiteGetSummaryFiltersByClientAndTags() public {
        uint256 agentId = _registerAgent();
        _feedback(alice, agentId, -2e18, 18, "logScore", "volR2");
        _feedback(bob, agentId, 5e18, 18, "logScore", "volR2");

        // Client filter: only alice's record is averaged in.
        assertEq(reputation.getSummary(agentId, _clients(alice), "logScore", ""), -2e18);

        // Non-empty query tag2 must match exactly.
        _feedback(alice, agentId, 9e18, 18, "logScore", "otherTag");
        assertEq(reputation.getSummary(agentId, _clients(alice), "logScore", "otherTag"), 9e18);
        assertEq(reputation.getSummary(agentId, _clients(alice), "logScore", "volR2"), -2e18);

        // Empty query tag1 acts as a wildcard across alice's records: (-2e18 + 9e18) / 2.
        assertEq(reputation.getSummary(agentId, _clients(alice), "", ""), 3.5e18);
    }

    function test_LiteGetSummaryNormalizesDecimalsAndNegatives() public {
        uint256 agentId = _registerAgent();

        // 3 with 0 decimals normalizes to 3e18; average with 1e18 is 2e18.
        _feedback(alice, agentId, 3, 0, "logScore", "pos");
        _feedback(alice, agentId, 1e18, 18, "logScore", "pos");
        assertEq(reputation.getSummary(agentId, _clients(alice), "logScore", "pos"), 2e18);

        // -2 with 0 decimals normalizes to -2e18; average with 1.75e18 stays negative.
        _feedback(alice, agentId, -2, 0, "logScore", "neg");
        _feedback(alice, agentId, 1.75e18, 18, "logScore", "neg");
        assertEq(reputation.getSummary(agentId, _clients(alice), "logScore", "neg"), -0.125e18);
    }

    function test_LiteGetSummaryEmptyClientsReverts() public {
        uint256 agentId = _registerAgent();
        address[] memory none = new address[](0);
        vm.expectRevert(ReputationRegistryLite.EmptyClientAddresses.selector);
        reputation.getSummary(agentId, none, "logScore", "");
    }

    function test_LiteGetSummaryNoMatchesReturnsZero() public {
        uint256 agentId = _registerAgent();
        _feedback(alice, agentId, -2e18, 18, "logScore", "volR2");

        // Non-matching tag1 filter: no records are averaged.
        assertEq(reputation.getSummary(agentId, _clients(alice), "noSuchTag", ""), 0);
    }

    // -------- market wiring ---------------------------------------------

    function test_SetReputationRequiresOwner() public {
        _deployMarket();

        vm.prank(alice);
        vm.expectRevert(VolMarket.NotOwner.selector);
        market.setReputation(address(identity), address(reputation));

        // A half-configured wiring is rejected instead of silently dropping scores.
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.setReputation(address(identity), address(0));
        vm.expectRevert(VolMarket.InvalidParams.selector);
        market.setReputation(address(0), address(reputation));

        market.setReputation(address(identity), address(reputation));
        assertEq(address(market.identityRegistry()), address(identity));
        assertEq(address(market.reputationRegistry()), address(reputation));

        // The zero address on both sides disables the wiring again.
        market.setReputation(address(0), address(0));
        assertEq(address(market.identityRegistry()), address(0));
        assertEq(address(market.reputationRegistry()), address(0));
    }

    function test_LinkAgentRequiresOperatorAndAgentOwner() public {
        _deployMarket();
        uint256 modelId = market.registerModel(address(new SpikeModelVerifier()), alice);
        uint256 ownedModelId = market.registerModel(address(new SpikeModelVerifier()), agentOwner);

        // Without a configured identity registry there is nothing to bind to.
        vm.prank(alice);
        vm.expectRevert(VolMarket.ReputationNotConfigured.selector);
        market.linkAgent(modelId, 1);

        market.setReputation(address(identity), address(reputation));
        uint256 agentId = _registerAgent(); // owned by agentOwner
        uint256 modelCount = market.modelCount();

        vm.prank(alice);
        vm.expectRevert(VolMarket.UnknownModel.selector);
        market.linkAgent(modelCount, agentId);

        // Not the operator of the model.
        vm.prank(bob);
        vm.expectRevert(VolMarket.NotModelOperator.selector);
        market.linkAgent(modelId, agentId);

        // Operator of the model, but not the owner of the agent.
        vm.prank(alice);
        vm.expectRevert(VolMarket.AgentNotOwned.selector);
        market.linkAgent(modelId, agentId);

        // The agent owner binds the agent it owns.
        vm.prank(agentOwner);
        market.linkAgent(ownedModelId, agentId);
        assertTrue(market.agentBound(ownedModelId));
        assertEq(market.agentOfModel(ownedModelId), agentId);
    }

    function test_LinkAgentZeroAgentIdBindsButSkipsFeedback() public {
        _deployMarket();
        market.setReputation(address(identity), address(reputation));
        uint256 modelId = market.registerModel(address(new SpikeModelVerifier()), alice);

        vm.prank(alice);
        market.linkAgent(modelId, 0);
        assertTrue(market.agentBound(modelId), "binding marker set");
        assertEq(market.agentOfModel(modelId), 0);

        uint256 id = _create();
        vm.prank(alice);
        market.submitPrediction(id, modelId, _proof(), _outputs());

        vm.warp(END + 10);
        vm.recordLogs();
        market.settle(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Agent 0 is not an agent: no feedback call is made for it.
        assertEq(_countWriteFailures(logs), 0);
        (int128[] memory values,,,) = reputation.readFeedback(0, address(market));
        assertEq(values.length, 0);
    }

    function test_AgentRegistersAndMarketWritesScore() public {
        _deployMarket();
        market.setReputation(address(identity), address(reputation));

        uint256 agentId = _registerAgent(); // agentOwner owns the agent
        uint256 modelId = market.registerModel(address(new SpikeModelVerifier()), agentOwner);
        vm.prank(agentOwner);
        market.linkAgent(modelId, agentId);

        uint256 id = _create();
        vm.prank(agentOwner);
        market.submitPrediction(id, modelId, _proof(), _outputs());

        vm.warp(END + 10);
        market.settle(id);

        (,,, int256 score) = market.getPrediction(id, agentOwner);
        assertLt(score, 0);
        assertEq(reputation.getSummary(agentId, _clients(address(market)), "logScore", ""), score);

        // The market is the client of the record it wrote.
        (int128[] memory values, uint8[] memory decimals, string[] memory tag1s, string[] memory tag2s) =
            reputation.readFeedback(agentId, address(market));
        assertEq(values.length, 1);
        assertEq(int256(values[0]), score);
        assertEq(uint256(decimals[0]), 18);
        assertEq(tag1s[0], "logScore");
        assertEq(tag2s[0], "vol-300s-12");
    }

    function test_ReputationFailureDoesNotBlockSettleOrClaim() public {
        _deployMarket();
        RevertingReputationRegistry failing = new RevertingReputationRegistry();
        market.setReputation(address(identity), address(failing));

        uint256 agentId = _registerAgent();
        uint256 modelId = market.registerModel(address(new SpikeModelVerifier()), agentOwner);
        vm.prank(agentOwner);
        market.linkAgent(modelId, agentId);

        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        vm.prank(agentOwner);
        market.submitPrediction(id, modelId, _proof(), _outputs());

        vm.warp(END + 10);
        vm.recordLogs();
        market.settle(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The failed write is reported with round, predictor and agent.
        assertEq(_countWriteFailures(logs), 1);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(market)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != _reputationWriteFailedTopic()) continue;
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(agentOwner))));
            assertEq(logs[i].topics[3], bytes32(agentId));
            assertEq(
                abi.decode(logs[i].data, (bytes32)),
                keccak256(abi.encodePacked(RevertingReputationRegistry.FeedbackDisabled.selector))
            );
        }

        // Settlement and the payout are unaffected.
        (, uint256 bucket,) = _round(id);
        assertEq(bucket, 0);
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - balanceBefore, 100e18);
    }

    function test_NoReputationConfiguredKeepsBehavior() public {
        _deployMarket();
        uint256 agentId = _registerAgent();
        uint256 modelId = market.registerModel(address(new SpikeModelVerifier()), agentOwner);

        // Without a configured identity registry no binding can be made.
        vm.prank(agentOwner);
        vm.expectRevert(VolMarket.ReputationNotConfigured.selector);
        market.linkAgent(modelId, agentId);

        uint256 id = _create();
        vm.prank(alice);
        market.bet(id, 0, 100e18);
        vm.prank(agentOwner);
        market.submitPrediction(id, modelId, _proof(), _outputs());

        vm.warp(END + 10);
        vm.recordLogs();
        market.settle(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countWriteFailures(logs), 0);
        (,,, int256 score) = market.getPrediction(id, agentOwner);
        assertLt(score, 0);
        assertEq(reputation.getSummary(agentId, _clients(address(market)), "logScore", ""), 0);

        (, uint256 bucket, uint256 rv) = _round(id);
        assertEq(bucket, 0);
        assertEq(rv, 0);
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(token.balanceOf(alice) - balanceBefore, 100e18);
    }

    function test_ThirdPartyFeedbackExcludedFromSummary() public {
        _deployMarket();
        market.setReputation(address(identity), address(reputation));

        uint256 agentId = _registerAgent();
        uint256 modelId = market.registerModel(address(new SpikeModelVerifier()), agentOwner);
        vm.prank(agentOwner);
        market.linkAgent(modelId, agentId);

        uint256 id = _create();
        vm.prank(agentOwner);
        market.submitPrediction(id, modelId, _proof(), _outputs());
        vm.warp(END + 10);
        market.settle(id);

        (,,, int256 score) = market.getPrediction(id, agentOwner);

        // A third party writes a record for the same agent.
        vm.prank(alice);
        reputation.giveFeedback(agentId, 5e18, 18, "logScore", "vol-300s-12", "", "", bytes32(0));

        // The client filter keeps it out of the market's summary.
        assertEq(reputation.getSummary(agentId, _clients(address(market)), "logScore", ""), score);
        assertEq(reputation.getSummary(agentId, _clients(alice), "logScore", ""), 5e18);
    }

    function test_SettleGasWith32BoundPredictors() public {
        _deployMarket();
        market.setReputation(address(identity), address(reputation));

        uint256 count = market.MAX_PREDICTORS();
        assertEq(count, 32);
        address verifier = address(new SpikeModelVerifier());
        uint256[] memory agentIds = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            address operator = address(uint160(0x1000 + i));
            vm.prank(operator);
            agentIds[i] = identity.register("ipfs://agent");
            uint256 modelId = market.registerModel(verifier, operator);
            vm.prank(operator);
            market.linkAgent(modelId, agentIds[i]);
        }

        uint256 id = _create();
        for (uint256 i = 0; i < count; ++i) {
            vm.prank(address(uint160(0x1000 + i)));
            market.submitPrediction(id, i, _proof(), _outputs());
        }
        assertEq(market.predictorCount(id), count);

        vm.warp(END + 10);
        uint256 gasBefore = gasleft();
        market.settle(id);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("settle gas with 32 bound predictors", gasUsed);
        assertLt(gasUsed, 8_000_000, "settle gas with 32 bound predictors");

        // Every bound predictor got its score written under its own agent.
        for (uint256 i = 0; i < count; ++i) {
            (,,, int256 score) = market.getPrediction(id, address(uint160(0x1000 + i)));
            assertEq(reputation.getSummary(agentIds[i], _clients(address(market)), "logScore", ""), score);
        }
    }

    /// @dev Winning bucket and realized volatility of a settled round.
    function _round(uint256 id) internal view returns (bool voided, uint256 bucket, uint256 rv) {
        (, bool settled, bool v, uint256 b, uint256 r,,,) = market.getRound(id);
        assertTrue(settled, "settled");
        return (v, b, r);
    }
}
