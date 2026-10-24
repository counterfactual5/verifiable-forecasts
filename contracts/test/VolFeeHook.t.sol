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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "../lib/v4-periphery/test/shared/HookMiner.sol";
import {VolFeeHook, IVolFeeSource, IVolRoundSource} from "../src/hooks/VolFeeHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockFeeSource is IVolFeeSource {
    mapping(uint256 => uint24) public feeOf;
    mapping(uint256 => bool) public feeRecorded;

    function set(uint256 id, uint24 fee) external {
        feeOf[id] = fee;
        feeRecorded[id] = true;
    }
}

contract MockRounds is IVolRoundSource {
    uint64[] private starts;

    function push(uint64 startTime) external {
        starts.push(startTime);
    }

    function roundCount() external view returns (uint256) {
        return starts.length;
    }

    function getRound(uint256 id) external view returns (uint64) {
        return starts[id];
    }
}

contract VolFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev PoolManager v4.0.0 creation code, built from lib/v4-core with its own profile
    ///      (solc 0.8.26, via_ir, optimizer 44444444 runs, cancun); this repo pins solc 0.8.28.
    string constant MANAGER_CODE = "test/fixtures/v4_pool_manager_v4.0.0.hex";
    uint160 constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    uint256 constant WINDOW = 3600;
    uint256 constant LOOKBACK = 4;
    uint24 constant MIN_FEE = 100;
    uint24 constant MAX_FEE = 30_000;
    uint24 constant FALLBACK_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    /// @dev sqrt(1) in Q64.96.
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant SWAP_IN = 1e18;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    MockFeeSource source;
    MockRounds rounds;
    VolFeeHook hook;
    Currency c0;
    Currency c1;
    PoolKey key;
    uint64 start;

    function setUp() public {
        vm.warp(1_000_000);
        bytes memory code = vm.parseBytes(vm.readFile(MANAGER_CODE));
        bytes memory init = abi.encodePacked(code, abi.encode(address(this)));
        address m;
        assembly {
            m := create(0, add(init, 0x20), mload(init))
        }
        require(m != address(0), "manager deploy");
        manager = IPoolManager(m);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        source = new MockFeeSource();
        rounds = new MockRounds();
        start = uint64(block.timestamp);
        hook = _deployHook();

        MockERC20 a = new MockERC20();
        MockERC20 b = new MockERC20();
        (c0, c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        a.approve(address(lpRouter), type(uint256).max);
        b.approve(address(lpRouter), type(uint256).max);

        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-6000, 6000, 1e24, 0), "");
    }

    function _deployHook() internal returns (VolFeeHook h) {
        bytes memory args = abi.encode(manager, source, rounds, WINDOW, LOOKBACK, MIN_FEE, MAX_FEE, FALLBACK_FEE);
        (address expected, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(VolFeeHook).creationCode, args);
        h = new VolFeeHook{salt: salt}(manager, source, rounds, WINDOW, LOOKBACK, MIN_FEE, MAX_FEE, FALLBACK_FEE);
        require(address(h) == expected, "mined address");
    }

    function _swap(PoolKey memory k) internal returns (BalanceDelta) {
        return swapRouter.swap(
            k,
            IPoolManager.SwapParams(true, -int256(SWAP_IN), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @dev Token0 fees accrued to LPs by one swap, from the pool's global fee growth.
    function _lpFee0(PoolKey memory k) internal returns (uint256) {
        PoolId id = k.toId();
        (uint256 before,) = manager.getFeeGrowthGlobals(id);
        uint128 liquidity = manager.getLiquidity(id);
        _swap(k);
        (uint256 afterGrowth,) = manager.getFeeGrowthGlobals(id);
        return (afterGrowth - before) * liquidity / FixedPoint128.Q128;
    }

    // ------------------------------------------------------------------ feeAt
    function test_feeAt_returnsRecordedFee() public {
        rounds.push(start);
        source.set(0, 500);
        (uint24 fee, uint256 id, bool recorded) = hook.feeAt(block.timestamp);
        assertEq(fee, 500);
        assertEq(id, 0);
        assertTrue(recorded);
    }

    function test_feeAt_clamps() public {
        rounds.push(start);
        rounds.push(start + uint64(WINDOW));
        source.set(0, MIN_FEE - 1);
        source.set(1, MAX_FEE + 1);
        (uint24 low,,) = hook.feeAt(start);
        (uint24 high,,) = hook.feeAt(start + WINDOW);
        assertEq(low, MIN_FEE);
        assertEq(high, MAX_FEE);
    }

    function test_feeAt_fallbackWithoutRoundOrRecord() public {
        (uint24 fee,, bool recorded) = hook.feeAt(block.timestamp);
        assertEq(fee, FALLBACK_FEE);
        assertFalse(recorded);
        rounds.push(start);
        (fee,, recorded) = hook.feeAt(block.timestamp);
        assertEq(fee, FALLBACK_FEE);
        assertFalse(recorded);
    }

    function test_feeAt_fallbackOutsideWindow() public {
        rounds.push(start);
        source.set(0, 500);
        (uint24 before,, bool r0) = hook.feeAt(start - 1);
        (uint24 last,, bool r1) = hook.feeAt(start + WINDOW - 1);
        (uint24 past,, bool r2) = hook.feeAt(start + WINDOW);
        assertEq(before, FALLBACK_FEE);
        assertFalse(r0);
        assertEq(last, 500);
        assertTrue(r1);
        assertEq(past, FALLBACK_FEE);
        assertFalse(r2);
    }

    function test_feeAt_skipsFutureRoundsWithinLookback() public {
        rounds.push(start);
        source.set(0, 700);
        for (uint256 i = 1; i < LOOKBACK; ++i) {
            rounds.push(start + uint64(i * WINDOW));
            source.set(i, 9000);
        }
        (uint24 fee, uint256 id,) = hook.feeAt(start);
        assertEq(fee, 700);
        assertEq(id, 0);
        rounds.push(start + uint64(LOOKBACK * WINDOW));
        (fee,,) = hook.feeAt(start);
        assertEq(fee, FALLBACK_FEE);
    }

    // ------------------------------------------------------------------ deployment
    function test_constructor_rejectsBadParams() public {
        vm.expectRevert(VolFeeHook.InvalidParams.selector);
        new VolFeeHook(manager, source, rounds, WINDOW, LOOKBACK, MAX_FEE, MIN_FEE, FALLBACK_FEE);
        vm.expectRevert(VolFeeHook.InvalidParams.selector);
        new VolFeeHook(manager, source, rounds, WINDOW, LOOKBACK, MIN_FEE, MAX_FEE, MAX_FEE + 1);
        vm.expectRevert(VolFeeHook.InvalidParams.selector);
        new VolFeeHook(
            manager, source, rounds, WINDOW, LOOKBACK, MIN_FEE, uint24(LPFeeLibrary.MAX_LP_FEE) + 1, FALLBACK_FEE
        );
        vm.expectRevert(VolFeeHook.InvalidParams.selector);
        new VolFeeHook(manager, source, rounds, 0, LOOKBACK, MIN_FEE, MAX_FEE, FALLBACK_FEE);
    }

    function test_constructor_rejectsUnminedAddress() public {
        vm.expectRevert();
        new VolFeeHook(manager, source, rounds, WINDOW, LOOKBACK, MIN_FEE, MAX_FEE, FALLBACK_FEE);
    }

    function test_initialize_rejectsStaticFeePool() public {
        PoolKey memory k = PoolKey(c0, c1, 3000, TICK_SPACING, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_beforeSwap_onlyPoolManager() public {
        vm.expectRevert(VolFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, IPoolManager.SwapParams(true, -1, 0), "");
    }

    // ------------------------------------------------------------------ swaps
    function test_swap_chargesRecordedFee() public {
        rounds.push(start);
        source.set(0, 500);
        assertApproxEqAbs(_lpFee0(key), SWAP_IN * 500 / 1e6, 1);
    }

    function test_swap_chargesFallbackFee() public {
        assertApproxEqAbs(_lpFee0(key), SWAP_IN * FALLBACK_FEE / 1e6, 1);
    }

    function test_swap_chargesClampedFee() public {
        rounds.push(start);
        source.set(0, MAX_FEE * 2);
        assertApproxEqAbs(_lpFee0(key), SWAP_IN * MAX_FEE / 1e6, 1);
    }

    function test_swap_higherFeeLowersOutput() public {
        rounds.push(start);
        rounds.push(start + uint64(WINDOW));
        source.set(0, 500);
        source.set(1, 10_000);
        uint256 snap = vm.snapshotState();
        int128 outLow = _swap(key).amount1();
        vm.revertToState(snap);
        vm.warp(start + WINDOW);
        int128 outHigh = _swap(key).amount1();
        assertGt(outLow, outHigh);
    }

    /// @dev Swap gas through the hook vs a hookless static-fee pool with the same liquidity.
    function test_swap_gasOverhead() public {
        rounds.push(start);
        source.set(0, 500);
        PoolKey memory plain = PoolKey(c0, c1, 500, TICK_SPACING, IHooks(address(0)));
        manager.initialize(plain, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(plain, IPoolManager.ModifyLiquidityParams(-6000, 6000, 1e24, 0), "");
        _swap(key);
        _swap(plain);
        uint256 g0 = gasleft();
        _swap(key);
        uint256 hooked = g0 - gasleft();
        g0 = gasleft();
        _swap(plain);
        uint256 bare = g0 - gasleft();
        emit log_named_uint("swap gas, hooked", hooked);
        emit log_named_uint("swap gas, no hook", bare);
        assertGt(hooked, bare);
    }
}
