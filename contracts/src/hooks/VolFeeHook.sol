// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice The VolFeeConsumer views the hook reads: per-round fee in pips (1e-6, 500 = 5 bps) and
///         whether it was recorded. feeOf is 0 for an unrecorded round, so feeRecorded decides.
interface IVolFeeSource {
    function feeOf(uint256 id) external view returns (uint24);
    function feeRecorded(uint256 id) external view returns (bool);
}

/// @notice The VolMarket views the hook reads to find the round whose window covers now.
/// @dev Declared with only the first return word of VolMarket.getRound (startTime); the ABI
///      decoder ignores the trailing words.
interface IVolRoundSource {
    function roundCount() external view returns (uint256);
    function getRound(uint256 id) external view returns (uint64 startTime);
}

/// @title VolFeeHook
/// @notice Uniswap v4 dynamic-fee hook charging, on every swap, the fee VolFeeConsumer recorded for
///         the VolMarket round whose window covers block.timestamp, clamped to [minFee, maxFee];
///         fallbackFee when no covering round has a recorded fee.
/// @dev The hook address must carry exactly the afterInitialize and beforeSwap flags (CREATE2-mined).
///      A round is voided only after its window ends, so a voided round's fee is still charged
///      during the window it priced.
contract VolFeeHook {
    error NotPoolManager();
    error NotDynamicFee();
    error InvalidParams();

    IPoolManager public immutable poolManager;
    IVolFeeSource public immutable feeSource;
    IVolRoundSource public immutable rounds;
    /// @dev Round window length in seconds: VolMarket delta * nSegments.
    uint256 public immutable window;
    /// @dev Rounds scanned back from the newest; rounds created ahead of time sit above the
    ///      covering one.
    uint256 public immutable maxLookback;
    /// @dev Fees are in pips, the unit of both VolFeeConsumer.feeOf and the v4 LP fee
    ///      (1e-6, LPFeeLibrary.MAX_LP_FEE = 1e6 = 100%), so no conversion factor applies.
    uint24 public immutable minFee;
    uint24 public immutable maxFee;
    uint24 public immutable fallbackFee;

    constructor(
        IPoolManager poolManager_,
        IVolFeeSource feeSource_,
        IVolRoundSource rounds_,
        uint256 window_,
        uint256 maxLookback_,
        uint24 minFee_,
        uint24 maxFee_,
        uint24 fallbackFee_
    ) {
        if (
            address(poolManager_) == address(0) || address(feeSource_) == address(0) || address(rounds_) == address(0)
                || window_ == 0 || maxLookback_ == 0 || minFee_ > maxFee_ || maxFee_ > LPFeeLibrary.MAX_LP_FEE
                || fallbackFee_ < minFee_ || fallbackFee_ > maxFee_
        ) revert InvalidParams();
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        poolManager = poolManager_;
        feeSource = feeSource_;
        rounds = rounds_;
        window = window_;
        maxLookback = maxLookback_;
        minFee = minFee_;
        maxFee = maxFee_;
        fallbackFee = fallbackFee_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev A static-fee pool would ignore the override, so only dynamic-fee pools may attach.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert NotDynamicFee();
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint24 fee,,) = feeAt(block.timestamp);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Fee in pips the hook charges at `timestamp`.
    /// @return fee clamped recorded fee, or fallbackFee
    /// @return id covering round (meaningless when !recorded)
    /// @return recorded whether a covering round with a recorded fee was found
    function feeAt(uint256 timestamp) public view returns (uint24 fee, uint256 id, bool recorded) {
        uint256 count = rounds.roundCount();
        uint256 floor = count > maxLookback ? count - maxLookback : 0;
        for (uint256 i = count; i > floor; --i) {
            uint256 start = rounds.getRound(i - 1);
            if (start <= timestamp && timestamp < start + window) {
                id = i - 1;
                if (!feeSource.feeRecorded(id)) break;
                fee = feeSource.feeOf(id);
                if (fee < minFee) fee = minFee;
                if (fee > maxFee) fee = maxFee;
                return (fee, id, true);
            }
        }
        return (fallbackFee, id, false);
    }
}
