// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {UniConsumer} from "./modules/UniConsumer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {IUniV4, IPoolManager, PoolId} from "./interfaces/IUniV4.sol";
import {TickIteratorLib, TickIteratorUp, TickIteratorDown} from "./libraries/TickIterator.sol";
import {
    PoolKey,
    IBeforeSwapHook,
    IAfterSwapHook,
    IAfterAddLiquidityHook,
    IAfterRemoveLiquidityHook,
    IBeforeInitializeHook
} from "./interfaces/IHooks.sol";
import {IFlashBlockNumber} from "./interfaces/IFlashBlockNumber.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks, IHooks} from "v4-core/src/libraries/Hooks.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {MixedSignLib} from "./libraries/MixedSignLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {Q96MathLib} from "./libraries/Q96MathLib.sol";
import {CompensationPriceFinder} from "./libraries/CompensationPriceFinder.sol";
import {PoolRewards, PoolRewardsLib} from "./types/PoolRewards.sol";
import {PoolKeyHelperLib} from "./libraries/PoolKeyHelperLib.sol";
import {getRequiredHookPermissions} from "src/hook-config.sol";
import {tuint256, tbytes32} from "transient-goodies/TransientPrimitives.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2 is
    UniConsumer,
    Ownable,
    IBeforeSwapHook,
    IAfterSwapHook,
    IAfterAddLiquidityHook,
    IAfterRemoveLiquidityHook
{
    using IUniV4 for IPoolManager;
    using PoolKeyHelperLib for PoolKey;
    using Hooks for IHooks;
    using MixedSignLib for *;
    using FixedPointMathLib for *;
    using Q96MathLib for uint256;
    using SafeCastLib for *;

    error NegationOverflow();
    error ProtocolFeeExceedsMaximum();
    error AttemptingToWithdrawLPRewards();
    error IncompatiblePoolConfiguration();

    event PoolLPFeeUpdated(PoolKey key, uint24 newFee);
    event PoolHookSwapFeeUpdated(PoolKey key, uint256 newFeeE6);

    /// @dev The `SWAP_TAXED_GAS` is the abstract estimated gas cost for a swap. We want it to be
    /// a constant so that competing searchers have a bid cost independent of how much gas swap
    /// actually uses, the overall tax just needs to scale proportional to `priority_fee * swap_fixed_cost`.
    uint256 internal constant SWAP_TAXED_GAS = 100_000;
    /// @dev MEV tax charged is `priority_fee * SWAP_MEV_TAX_FACTOR` meaning the tax rate is
    /// `SWAP_MEV_TAX_FACTOR / (SWAP_MEV_TAX_FACTOR + 1)`
    uint256 constant SWAP_MEV_TAX_FACTOR = 49;
    /// @dev Parameters for taxing just-in-time (JIT) liquidity
    uint256 internal constant JIT_TAXED_GAS = 100_000;
    uint256 internal constant JIT_MEV_TAX_FACTOR = SWAP_MEV_TAX_FACTOR * 4;

    uint256 internal constant NATIVE_CURRENCY_ID = 0;
    uint256 internal constant FACTOR_E6 = 1e6;
    uint256 internal constant MAX_PROTOCOL_FEE_E6 = 0.1e6;

    IFlashBlockNumber public immutable FLASH_BLOCK_NUMBER_PROVIDER;

    /// @dev Tracks how much of the ether held by the contract is unclaimed revenue vs. unclaimed
    /// LP rewards.
    uint128 public unclaimedProtocolRevenueInEther;
    uint128 internal _blockOfLastTopOfBlock;
    mapping(PoolId id => PoolRewards) internal rewards;
    mapping(PoolId id => uint256) internal _hookSwapFeeE6;

    tuint256 internal liquidityBeforeSwap;
    tbytes32 internal slot0BeforeSwapStore;

    constructor(IPoolManager uniV4, address owner, IFlashBlockNumber flashBlockNumberProvider)
        UniConsumer(uniV4)
        Ownable()
    {
        _initializeOwner(owner);
        Hooks.validateHookPermissions(IHooks(address(this)), getRequiredHookPermissions());
        FLASH_BLOCK_NUMBER_PROVIDER = flashBlockNumberProvider;
    }

    function withdrawProtocolRevenue(uint160 assetId, address to, uint256 amount) public {
        _checkOwner();

        if (assetId == NATIVE_CURRENCY_ID) {
            if (!(amount <= unclaimedProtocolRevenueInEther)) {
                revert AttemptingToWithdrawLPRewards();
            }
            unclaimedProtocolRevenueInEther -= amount.toUint128();
        }

        UNI_V4.transfer(to, assetId, amount);
    }

    function setPoolLPFee(PoolKey calldata key, uint24 newFee) public {
        _checkOwner();
        UNI_V4.updateDynamicLPFee(key, newFee);
        emit PoolLPFeeUpdated(key, newFee);
    }

    function setPoolHookSwapFee(PoolKey calldata key, uint256 newFeeE6) public {
        _checkOwner();
        if (!(newFeeE6 <= MAX_PROTOCOL_FEE_E6)) revert ProtocolFeeExceedsMaximum();
        _hookSwapFeeE6[key.calldataToId()] = newFeeE6;
        emit PoolHookSwapFeeUpdated(key, newFeeE6);
    }

    function getPendingPositionRewards(
        PoolKey calldata key,
        address owner,
        int24 lowerTick,
        int24 upperTick,
        bytes32 salt
    ) public view returns (uint256 rewards0) {
        PoolId id = key.calldataToId();
        rewards0 =
            rewards[id].getPendingPositionRewards(UNI_V4, id, owner, lowerTick, upperTick, salt);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        returns (bytes4)
    {
        _onlyUniV4();
        if (key.currency0.toId() != NATIVE_CURRENCY_ID) revert IncompatiblePoolConfiguration();
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert IncompatiblePoolConfiguration();
        return this.beforeInitialize.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        _onlyUniV4();

        PoolId id = key.calldataToId();
        rewards[id].updateAfterLiquidityAdd(UNI_V4, id, key.tickSpacing, sender, params);
        uint256 taxAmountInEther = _getJitTaxAmount();
        if (taxAmountInEther > 0) {
            UNI_V4.mint(address(this), NATIVE_CURRENCY_ID, taxAmountInEther);
            unclaimedProtocolRevenueInEther += taxAmountInEther.toUint128();
        }
        return (this.afterAddLiquidity.selector, toBalanceDelta(taxAmountInEther.toInt128(), 0));
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        _onlyUniV4();

        PoolId id = key.calldataToId();
        uint256 rewardAmount0 = rewards[id].updateAfterLiquidityRemove(UNI_V4, id, sender, params);
        uint256 taxAmountInEther = _getJitTaxAmount();
        if (taxAmountInEther > 0) {
            unclaimedProtocolRevenueInEther += taxAmountInEther.toUint128();
        }
        if (rewardAmount0 > taxAmountInEther) {
            UNI_V4.burn(address(this), NATIVE_CURRENCY_ID, rewardAmount0 - taxAmountInEther);
        } else if (rewardAmount0 < taxAmountInEther) {
            UNI_V4.mint(address(this), NATIVE_CURRENCY_ID, taxAmountInEther - rewardAmount0);
        }
        return (
            this.afterRemoveLiquidity.selector,
            toBalanceDelta(taxAmountInEther.toInt128() - rewardAmount0.toInt128(), 0)
        );
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyUniV4();

        PoolId id = key.calldataToId();
        slot0BeforeSwapStore.set(Slot0.unwrap(UNI_V4.getSlot0(id)));

        if (_getBlock() == _blockOfLastTopOfBlock) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        liquidityBeforeSwap.set(UNI_V4.getPoolLiquidity(id));
        uint256 etherAmount = _getSwapTaxAmount();
        int128 etherDelta = etherAmount.toInt128();

        // ETH aka asset 0 was specified.
        bool etherWasSpecified = params.zeroForOne == params.amountSpecified < 0;

        return (
            this.beforeSwap.selector,
            etherWasSpecified ? toBeforeSwapDelta(etherDelta, 0) : toBeforeSwapDelta(0, etherDelta),
            0
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) external override returns (bytes4, int128 hookDeltaUnspecified) {
        _onlyUniV4();

        PoolId id = key.calldataToId();
        uint256 taxInEther = _getSwapTaxAmount();
        hookDeltaUnspecified =
            _computeAndCollectProtocolSwapFee(key, id, params, swapDelta, taxInEther);

        Slot0 slot0BeforeSwap = Slot0.wrap(slot0BeforeSwapStore.get());
        Slot0 slot0AfterSwap = UNI_V4.getSlot0(id);
        rewards[id].updateAfterTickMove(
            id, UNI_V4, slot0BeforeSwap.tick(), slot0AfterSwap.tick(), key.tickSpacing
        );

        uint128 blockNumber = _getBlock();
        if (taxInEther == 0 || blockNumber == _blockOfLastTopOfBlock) {
            return (this.afterSwap.selector, hookDeltaUnspecified);
        }
        _blockOfLastTopOfBlock = blockNumber;

        params.zeroForOne
            ? _zeroForOneDistributeTax(id, key.tickSpacing, slot0BeforeSwap, slot0AfterSwap)
            : _oneForZeroDistributeTax(id, key.tickSpacing, slot0BeforeSwap, slot0AfterSwap);

        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    function _computeAndCollectProtocolSwapFee(
        PoolKey calldata key,
        PoolId id,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        uint256 taxInEther
    ) internal returns (int128 fee128) {
        uint256 protocolFeeE6 = _hookSwapFeeE6[id];
        bool exactIn = params.amountSpecified < 0;

        int128 targetAmount =
            exactIn != params.zeroForOne ? swapDelta.amount0() : swapDelta.amount1();
        uint256 absTargetAmount = targetAmount.abs();
        uint256 fee = exactIn
            ? absTargetAmount * protocolFeeE6 / FACTOR_E6
            : absTargetAmount * FACTOR_E6 / (FACTOR_E6 - protocolFeeE6) - absTargetAmount;
        fee128 = fee.toInt128();

        uint256 feeCurrencyId =
            (exactIn != params.zeroForOne ? key.currency0 : key.currency1).toId();
        if (feeCurrencyId == NATIVE_CURRENCY_ID) {
            unclaimedProtocolRevenueInEther += fee.toUint128();
            UNI_V4.mint(address(this), feeCurrencyId, fee + taxInEther);
        } else {
            UNI_V4.mint(address(this), feeCurrencyId, fee);
            UNI_V4.mint(address(this), NATIVE_CURRENCY_ID, taxInEther);
        }
    }

    function _zeroForOneDistributeTax(
        PoolId id,
        int24 tickSpacing,
        Slot0 slot0BeforeSwap,
        Slot0 slot0AfterSwap
    ) internal {
        TickIteratorDown memory ticks = TickIteratorLib.initDown(
            UNI_V4, id, tickSpacing, slot0BeforeSwap.tick(), slot0AfterSwap.tick()
        );

        uint256 taxInEther = _getSwapTaxAmount();
        uint128 liquidity = liquidityBeforeSwap.get().toUint128();
        (int24 lastTick, uint160 pstarSqrtX96) = CompensationPriceFinder.getZeroForOne(
            ticks, liquidity, taxInEther, slot0BeforeSwap.sqrtPriceX96(), slot0AfterSwap
        );

        ticks.reset(slot0BeforeSwap.tick());
        _zeroForOneCreditRewards(
            ticks, liquidity, taxInEther, slot0BeforeSwap.sqrtPriceX96(), lastTick, pstarSqrtX96
        );
    }

    function _oneForZeroDistributeTax(
        PoolId id,
        int24 tickSpacing,
        Slot0 slot0BeforeSwap,
        Slot0 slot0AfterSwap
    ) internal {
        TickIteratorUp memory ticks = TickIteratorLib.initUp(
            UNI_V4, id, tickSpacing, slot0BeforeSwap.tick(), slot0AfterSwap.tick()
        );

        uint256 taxInEther = _getSwapTaxAmount();
        uint128 liquidity = liquidityBeforeSwap.get().toUint128();
        (int24 lastTick, uint160 pstarSqrtX96) = CompensationPriceFinder.getOneForZero(
            ticks, liquidity, taxInEther, slot0BeforeSwap, slot0AfterSwap
        );

        ticks.reset(slot0BeforeSwap.tick());
        _oneForZeroCreditRewards(
            ticks, liquidity, taxInEther, slot0BeforeSwap.sqrtPriceX96(), lastTick, pstarSqrtX96
        );
    }

    function _zeroForOneCreditRewards(
        TickIteratorDown memory ticks,
        uint128 liquidity,
        uint256 taxInEther,
        uint160 priceUpperSqrtX96,
        int24 lastTick,
        uint160 pstarSqrtX96
    ) internal {
        uint256 pstarX96 = uint256(pstarSqrtX96).mulX96(pstarSqrtX96);
        uint256 cumulativeGrowthX128 = 0;
        uint160 priceLowerSqrtX96;

        while (ticks.hasNext()) {
            int24 tickNext = ticks.getNext();

            priceLowerSqrtX96 = max(TickMath.getSqrtPriceAtTick(tickNext), pstarSqrtX96);

            uint256 rangeReward = 0;
            if (tickNext >= lastTick && liquidity != 0) {
                uint256 delta0 = SqrtPriceMath.getAmount0Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                uint256 delta1 = SqrtPriceMath.getAmount1Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                rangeReward = (delta1.divX96(pstarX96) - delta0).min(taxInEther);

                unchecked {
                    taxInEther -= rangeReward;
                    cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(rangeReward, liquidity);
                }
            }

            unchecked {
                rewards[ticks.poolId].rewardGrowthOutsideX128[tickNext] += cumulativeGrowthX128;
            }

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, tickNext);
            liquidity = liquidity.sub(liquidityNet);

            priceUpperSqrtX96 = priceLowerSqrtX96;
        }

        // Distribute remainder to last range and update global accumulator.
        unchecked {
            cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(taxInEther, liquidity);
            rewards[ticks.poolId].globalGrowthX128 += cumulativeGrowthX128;
        }
    }

    function _oneForZeroCreditRewards(
        TickIteratorUp memory ticks,
        uint128 liquidity,
        uint256 taxInEther,
        uint160 priceLowerSqrtX96,
        int24 lastTick,
        uint160 pstarSqrtX96
    ) internal {
        uint256 pstarX96 = uint256(pstarSqrtX96).mulX96(pstarSqrtX96);
        uint256 cumulativeGrowthX128 = 0;
        uint160 priceUpperSqrtX96;

        while (ticks.hasNext()) {
            int24 tickNext = ticks.getNext();

            priceUpperSqrtX96 = min(TickMath.getSqrtPriceAtTick(tickNext), pstarSqrtX96);

            uint256 rangeReward = 0;
            if (tickNext <= lastTick || liquidity == 0) {
                uint256 delta0 = SqrtPriceMath.getAmount0Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                uint256 delta1 = SqrtPriceMath.getAmount1Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                rangeReward = (delta0 - delta1.divX96(pstarX96)).min(taxInEther);

                unchecked {
                    taxInEther -= rangeReward;
                    cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(rangeReward, liquidity);
                }
            }

            unchecked {
                rewards[ticks.poolId].rewardGrowthOutsideX128[tickNext] += cumulativeGrowthX128;
            }

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, tickNext);
            liquidity = liquidity.add(liquidityNet);

            priceLowerSqrtX96 = priceUpperSqrtX96;
        }

        // Distribute remainder to last range and update global accumulator.
        unchecked {
            cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(taxInEther, liquidity);
            rewards[ticks.poolId].globalGrowthX128 += cumulativeGrowthX128;
        }
    }

    function min(uint160 x, uint160 y) internal pure returns (uint160) {
        return x < y ? x : y;
    }

    function max(uint160 x, uint160 y) internal pure returns (uint160) {
        return x > y ? x : y;
    }

    function _getBlock() internal view returns (uint128) {
        if (address(FLASH_BLOCK_NUMBER_PROVIDER) == address(0)) {
            return uint128(block.number);
        }
        return uint128(FLASH_BLOCK_NUMBER_PROVIDER.getFlashblockNumber());
    }

    function getSwapTaxAmount(uint256 priorityFee) public pure returns (uint256) {
        return SWAP_MEV_TAX_FACTOR * SWAP_TAXED_GAS * priorityFee;
    }

    function getJitTaxAmount(uint256 priorityFee) public pure returns (uint256) {
        return JIT_MEV_TAX_FACTOR * JIT_TAXED_GAS * priorityFee;
    }

    function _getSwapTaxAmount() internal view returns (uint256) {
        uint256 priorityFee = tx.gasprice - block.basefee;
        return getSwapTaxAmount(priorityFee);
    }

    function _getJitTaxAmount() internal view returns (uint256) {
        if (_getBlock() == _blockOfLastTopOfBlock) {
            return 0;
        }
        uint256 priorityFee = tx.gasprice - block.basefee;
        return getJitTaxAmount(priorityFee);
    }
}
