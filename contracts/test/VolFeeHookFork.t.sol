// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "../lib/v4-periphery/test/shared/HookMiner.sol";
import {VolFeeHook, IVolFeeSource, IVolRoundSource} from "../src/hooks/VolFeeHook.sol";
import {VolFeeConsumer, IVolMarketReader} from "../src/VolFeeConsumer.sol";
import {VolMarket} from "../src/VolMarket.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IUniswapV3PoolOracle} from "../src/interfaces/IUniswapV3PoolOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IUniswapV3Slot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice A VolMarket round on the real ETH/USDC 0.05% V3 pool feeds VolFeeConsumer, whose recorded fee
///         VolFeeHook charges on a WETH/USDC dynamic-fee pool of the real v4 PoolManager.
///         Skipped without MAINNET_RPC_URL (archive node).
contract VolFeeHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Addresses: spikes/facts/FACTS.md (V3 pool, §1; PoolManager, §6).
    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant V3_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 26_260_000;

    uint32 constant DELTA = 300;
    uint8 constant N = 12;
    uint32 constant COMMIT_LEAD = 300;
    uint32 constant REVEAL_LEAD = 120;
    uint256 constant WINDOW = uint256(DELTA) * N;
    uint24 constant MIN_FEE = 100;
    uint24 constant MAX_FEE = 30_000;
    uint24 constant FALLBACK_FEE = 3000;
    int24 constant TICK_SPACING = 10;
    /// @dev 1,000 USDC, 6 decimals.
    uint256 constant SWAP_IN = 1_000e6;

    function test_fork_hookChargesRecordedRoundFee() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, FORK_BLOCK);

        (VolMarket market, VolFeeConsumer consumer, uint256 id, uint64 start) = _recordedRound();
        uint24 recommended = consumer.feeOf(id);
        assertTrue(consumer.feeRecorded(id));
        assertTrue(recommended != FALLBACK_FEE);

        VolFeeHook hook = _hook(consumer, market);
        (PoolKey memory key, PoolSwapTest swapRouter) = _pool(hook);

        vm.warp(start + 60);
        (uint24 charged, uint256 coveringId, bool recorded) = hook.feeAt(block.timestamp);
        assertEq(charged, recommended);
        assertEq(coveringId, id);
        assertTrue(recorded);

        uint256 lpFee = _lpFee0(key, swapRouter);
        assertApproxEqAbs(lpFee, SWAP_IN * recommended / 1e6, 1);
        emit log_named_uint("recorded fee (pips)", recommended);
        emit log_named_uint("LP fee on 1000 USDC (USDC units)", lpFee);

        vm.warp(start + WINDOW);
        (charged,, recorded) = hook.feeAt(block.timestamp);
        assertEq(charged, FALLBACK_FEE);
        assertFalse(recorded);
    }

    /// @dev One commit-only forecast (quantiles of ln RV 6.0 .. 8.0), revealed and recorded at the
    ///      reveal deadline.
    function _recordedRound() internal returns (VolMarket market, VolFeeConsumer consumer, uint256 id, uint64 start) {
        uint256[] memory levels = new uint256[](5);
        (levels[0], levels[1], levels[2], levels[3], levels[4]) = (1e17, 25e16, 5e17, 75e16, 9e17);
        market = new VolMarket(
            IERC20(address(new MockERC20())),
            100,
            5000,
            IUniswapV3PoolOracle(V3_POOL),
            DELTA,
            N,
            COMMIT_LEAD,
            REVEAL_LEAD,
            200,
            3900,
            VolMarket.QuantileConfig(levels, 12)
        );
        start = uint64(block.timestamp + 2 * COMMIT_LEAD);
        uint256[] memory bounds = new uint256[](4);
        (bounds[0], bounds[1], bounds[2], bounds[3]) = (200, 600, 1200, 2000);
        int256[] memory baseline = new int256[](5);
        (baseline[0], baseline[1], baseline[2], baseline[3], baseline[4]) = (5e18, 6e18, 7e18, 8e18, 9e18);
        id = market.createRound(start, bounds, baseline);
        uint256 modelId = market.registerModel(address(0), address(this));
        int256[] memory outputs = new int256[](5);
        for (uint256 k = 0; k < 5; ++k) {
            outputs[k] = int256(6 * 4096 + k * 2048);
        }
        bytes32 salt = keccak256("salt");
        market.commitPrediction(id, modelId, keccak256(abi.encode(id, modelId, outputs, salt, address(this))));
        vm.warp(start - COMMIT_LEAD);
        market.revealPrediction(id, "", outputs, salt);

        consumer = new VolFeeConsumer(
            IVolMarketReader(address(market)),
            "pinball",
            "vol-300s-12",
            "vol-300s-12-commit",
            -4e17,
            1e18,
            MIN_FEE,
            MAX_FEE
        );
        vm.warp(start - REVEAL_LEAD);
        consumer.record(id);
    }

    function _hook(VolFeeConsumer consumer, VolMarket market) internal returns (VolFeeHook hook) {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(MANAGER, consumer, market, WINDOW, uint256(4), MIN_FEE, MAX_FEE, FALLBACK_FEE);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(VolFeeHook).creationCode, args);
        hook = new VolFeeHook{salt: salt}(
            MANAGER,
            IVolFeeSource(address(consumer)),
            IVolRoundSource(address(market)),
            WINDOW,
            4,
            MIN_FEE,
            MAX_FEE,
            FALLBACK_FEE
        );
    }

    function _pool(VolFeeHook hook) internal returns (PoolKey memory key, PoolSwapTest swapRouter) {
        key = PoolKey(
            Currency.wrap(USDC), Currency.wrap(WETH), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook))
        );
        PoolModifyLiquidityTest lpRouter;
        (swapRouter, lpRouter) = _routers();
        (uint160 sqrtPrice, int24 tick,,,,,) = IUniswapV3Slot0(V3_POOL).slot0();
        MANAGER.initialize(key, sqrtPrice);
        int24 lower = (tick / TICK_SPACING - 100) * TICK_SPACING;
        int24 upper = (tick / TICK_SPACING + 100) * TICK_SPACING;
        lpRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lower, upper, 1e15, 0), "");
    }

    /// @dev USDC fees accrued to LPs by one SWAP_IN USDC -> WETH swap, from global fee growth.
    function _lpFee0(PoolKey memory key, PoolSwapTest swapRouter) internal returns (uint256) {
        PoolId pid = key.toId();
        (uint256 growthBefore,) = MANAGER.getFeeGrowthGlobals(pid);
        uint128 liquidity = MANAGER.getLiquidity(pid);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams(true, -int256(SWAP_IN), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (uint256 growthAfter,) = MANAGER.getFeeGrowthGlobals(pid);
        return (growthAfter - growthBefore) * liquidity / FixedPoint128.Q128;
    }

    function _routers() internal returns (PoolSwapTest swapRouter, PoolModifyLiquidityTest lpRouter) {
        swapRouter = new PoolSwapTest(MANAGER);
        lpRouter = new PoolModifyLiquidityTest(MANAGER);
        deal(USDC, address(this), 1e14);
        deal(WETH, address(this), 1e24);
        IERC20Approve(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Approve(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Approve(USDC).approve(address(lpRouter), type(uint256).max);
        IERC20Approve(WETH).approve(address(lpRouter), type(uint256).max);
    }
}
