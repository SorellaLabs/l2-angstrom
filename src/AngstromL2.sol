// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {UniConsumer} from "./modules/UniConsumer.sol";
import {IUniV4, IPoolManager, PoolId} from "./interfaces/IUniV4.sol";
import {TickIteratorLib, TickIteratorUp, TickIteratorDown} from "./libraries/TickIterator.sol";
import {
    PoolKey,
    IBeforeSwapHook,
    IAfterSwapHook,
    IAfterAddLiquidityHook,
    IAfterRemoveLiquidityHook
} from "./interfaces/IHooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks, IHooks} from "v4-core/src/libraries/Hooks.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {MixedSignLib} from "./libraries/MixedSignLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {Q96MathLib} from "./libraries/Q96MathLib.sol";
import {CompensationPriceFinder} from "./libraries/CompensationPriceFinder.sol";
import {PoolRewards, PoolRewardsLib} from "./types/PoolRewards.sol";
import {PoolKeyHelperLib} from "./libraries/PoolKeyHelperLib.sol";
import {getRequiredHookPermissions} from "src/hook-config.sol";
import {tuint256, tbytes32} from "transient-goodies/TransientPrimitives.sol";

import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2 is
    UniConsumer,
    IBeforeSwapHook,
    IAfterSwapHook,
    IAfterAddLiquidityHook,
    IAfterRemoveLiquidityHook
{
    using IUniV4 for IPoolManager;
    using PoolKeyHelperLib for PoolKey;
    using Hooks for IHooks;
    using MixedSignLib for *;
    using FixedPointMathLib for uint256;
    using Q96MathLib for uint256;

    using SafeCastLib for *;

    // TODO: Remove
    using FormatLib for *;

    error NegationOverflow();

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

    uint128 public unclaimedProtocolRevenue;
    uint64 internal blockOfLastTopOfBlock;
    mapping(PoolId id => PoolRewards) internal rewards;

    tuint256 internal liquidityBeforeSwap;
    tbytes32 internal slot0BeforeSwapStore;

    constructor(IPoolManager uniV4, address owner) UniConsumer(uniV4) {
        Hooks.validateHookPermissions(IHooks(address(this)), getRequiredHookPermissions());
    }

    function getPendingPositionRewards(
        PoolId id,
        address owner,
        int24 lowerTick,
        int24 upperTick,
        bytes32 salt
    ) public view returns (uint256 rewards0) {
        rewards0 =
            rewards[id].getPendingPositionRewards(UNI_V4, id, owner, lowerTick, upperTick, salt);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        PoolId id = key.calldataToId();
        rewards[id].updateAfterLiquidityAdd(UNI_V4, id, key.tickSpacing, sender, params);
        uint256 taxAmountInEther = _getJitTaxAmount();
        if (taxAmountInEther > 0) {
            UNI_V4.mint(address(this), NATIVE_CURRENCY_ID, taxAmountInEther);
            unclaimedProtocolRevenue += taxAmountInEther.toUint128();
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
        PoolId id = key.calldataToId();
        uint256 rewardAmount0 = rewards[id].updateAfterLiquidityRemove(UNI_V4, id, sender, params);
        uint256 taxAmountInEther = _getJitTaxAmount();
        if (taxAmountInEther > 0) {
            unclaimedProtocolRevenue += taxAmountInEther.toUint128();
        }
        if (rewardAmount0 > taxAmountInEther) {
            UNI_V4.burn(address(this), NATIVE_CURRENCY_ID, rewardAmount0 - taxAmountInEther);
        } else {
            UNI_V4.mint(address(this), NATIVE_CURRENCY_ID, taxAmountInEther - rewardAmount0);
        }
        return (
            this.afterRemoveLiquidity.selector,
            toBalanceDelta(taxAmountInEther.toInt128() - rewardAmount0.toInt128(), 0)
        );
    }

    // TODO: Dynamic LP fee
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyUniV4();

        PoolId id = key.calldataToId();
        slot0BeforeSwapStore.set(Slot0.unwrap(UNI_V4.getSlot0(id)));

        uint256 etherAmount = _getSwapTaxAmount();
        if (etherAmount == 0 || _getBlock() == blockOfLastTopOfBlock) {
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        int128 etherDelta = etherAmount.toInt256().toInt128();

        bool ethWasSpecified = params.zeroForOne == params.amountSpecified < 0; // ETH aka asset 0 was specified.

        liquidityBeforeSwap.set(UNI_V4.getPoolLiquidity(id));

        UNI_V4.mint(address(this), NATIVE_CURRENCY_ID, etherAmount);

        return (
            this.beforeSwap.selector,
            ethWasSpecified ? toBeforeSwapDelta(etherDelta, 0) : toBeforeSwapDelta(0, etherDelta),
            0
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        PoolId id = key.calldataToId();

        Slot0 slot0BeforeSwap = Slot0.wrap(slot0BeforeSwapStore.get());
        Slot0 slot0AfterSwap = UNI_V4.getSlot0(id);
        rewards[id].updateAfterTickMove(
            id, UNI_V4, slot0BeforeSwap.tick(), slot0AfterSwap.tick(), key.tickSpacing
        );

        uint64 blockNumber = _getBlock();
        if (_getSwapTaxAmount() == 0 || blockNumber == blockOfLastTopOfBlock) {
            return (this.afterSwap.selector, 0);
        }
        blockOfLastTopOfBlock = blockNumber;

        params.zeroForOne
            ? _zeroForOneDistributeTax(id, key.tickSpacing, slot0BeforeSwap, slot0AfterSwap)
            : _oneForZeroDistributeTax(id, key.tickSpacing, slot0BeforeSwap, slot0AfterSwap);

        return (this.afterSwap.selector, 0);
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

    function _getBlock() internal view returns (uint64) {
        // TODO
        return uint64(block.number);
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
        uint256 priorityFee = tx.gasprice - block.basefee;
        return getJitTaxAmount(priorityFee);
    }
}
