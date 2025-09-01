// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.29;

import {UniConsumer} from "./modules/UniConsumer.sol";
import {IUniV4, IPoolManager, PoolId} from "./interfaces/IUniV4.sol";
import {TickIteratorLib, TickIteratorUp, TickIteratorDown} from "./libraries/TickIterator.sol";
import {
    PoolKey,
    BalanceDelta,
    IBeforeSwapHook,
    IAfterSwapHook,
    IBeforeInitializeHook
} from "./interfaces/IHooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks, IHooks} from "v4-core/src/libraries/Hooks.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {MixedSignLib} from "./libraries/MixedSignLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {CompensationPriceFinder} from "./libraries/CompensationPriceFinder.sol";
import {PoolRewards} from "./types/PoolRewards.sol";
import {PoolKeyHelperLib} from "./libraries/PoolKeyHelperLib.sol";

import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2 is UniConsumer, IBeforeSwapHook, IAfterSwapHook {
    using IUniV4 for IPoolManager;
    using PoolKeyHelperLib for PoolKey;
    using Hooks for IHooks;
    using MixedSignLib for *;
    using FixedPointMathLib for uint256;

    error NegationOverflow();

    /// @dev The `SWAP_TAXED_GAS` is the abstract estimated gas cost for a swap. We want it to be a constant so that competing searchers have a bid cost independent of how much gas swap actually uses, the overall tax just needs to scale proportional to `priority_fee * swap_fixed_cost`.
    uint256 internal constant SWAP_TAXED_GAS = 100_000;
    /// @dev MEV tax charged is `priority_fee * SWAP_MEV_TAX_FACTOR` meaning the tax rate is `SWAP_MEV_TAX_FACTOR / (SWAP_MEV_TAX_FACTOR + 1)`
    uint256 constant SWAP_MEV_TAX_FACTOR = 49;

    uint64 internal blockOfLastTopOfBlock;
    mapping(PoolId id => PoolRewards) internal rewards;

    uint128 internal transient liquidityBeforeSwap;
    Slot0 internal transient slot0BeforeSwap;

    constructor(IPoolManager uniV4, address owner) UniConsumer(uniV4) {
        Hooks.validateHookPermissions(IHooks(address(this)), requiredHookPermissions());
    }

    // TODO: Dynamic LP fee
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyUniV4();

        if (_getBlock() == blockOfLastTopOfBlock) {
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        uint256 etherAmount = _getSwapTaxAmount();
        int128 etherDelta = _negate(etherAmount);

        bool ethWasSpecified = params.zeroForOne == params.amountSpecified < 0; // ETH aka asset 0 was specified.

        PoolId id = key.calldataToId();
        liquidityBeforeSwap = UNI_V4.getPoolLiquidity(id);
        slot0BeforeSwap = UNI_V4.getSlot0(id);

        UNI_V4.mint(address(this), 0, etherAmount);

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
        uint64 blockNumber = _getBlock();
        if (blockNumber == blockOfLastTopOfBlock) {
            return (this.afterSwap.selector, 0);
        }
        blockOfLastTopOfBlock = blockNumber;

        params.zeroForOne ? _zeroForOneDistributeTax() : _oneForZeroDistributeTax(key);

        return (this.afterSwap.selector, 0);
    }

    function _zeroForOneDistributeTax() internal view {}

    function _oneForZeroDistributeTax(PoolKey calldata key) internal view {
        PoolId id = key.calldataToId();
        Slot0 slot0AfterSwap = UNI_V4.getSlot0(id);

        TickIteratorUp memory ticks = TickIteratorLib.initUp(
            UNI_V4, id, key.tickSpacing, slot0BeforeSwap.tick(), slot0AfterSwap.tick()
        );

        uint256 taxInEther = _getSwapTaxAmount();
        (uint256 pstarNumerator, uint256 pstarDenominator) = CompensationPriceFinder.getOneForZero(
            ticks, liquidityBeforeSwap, taxInEther, slot0BeforeSwap, slot0AfterSwap
        );

        ticks.reset(slot0AfterSwap.tick());

        uint128 liquidity = liquidityBeforeSwap;
        uint160 priceLowerSqrtX96 = slot0BeforeSwap.sqrtPriceX96();
        uint160 priceUpperSqrtX96;
        while (ticks.hasNext()) {
            int24 tickNext = ticks.getNext();
            priceUpperSqrtX96 = TickMath.getSqrtPriceAtTick(tickNext);

            uint256 delta0 = SqrtPriceMath.getAmount0Delta(
                priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
            );
            uint256 delta1 = SqrtPriceMath.getAmount1Delta(
                priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
            );

            uint256 rangeReward = delta0 - delta1.fullMulDiv(pstarDenominator, pstarNumerator);
            if (rangeReward > taxInEther) rangeReward = taxInEther;
            taxInEther -= rangeReward;
            console.log("rangeReward:", rangeReward);

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, tickNext);
            liquidity = liquidity.add(liquidityNet);

            priceLowerSqrtX96 = priceUpperSqrtX96;
        }

        priceUpperSqrtX96 = slot0AfterSwap.sqrtPriceX96();

        uint256 delta0 =
            SqrtPriceMath.getAmount0Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);
        uint256 delta1 =
            SqrtPriceMath.getAmount1Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);

        uint256 rangeReward = delta0 - delta1.fullMulDiv(pstarDenominator, pstarNumerator);
        if (rangeReward > taxInEther) rangeReward = taxInEther;
        taxInEther -= rangeReward;
        console.log("rangeReward:", rangeReward);
    }

    function divX96(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(numerator, FixedPoint96.Q96, denominator);
    }

    function mulX96(uint256 x, uint256 y) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivN(x, y, FixedPoint96.RESOLUTION);
    }

    function _getBlock() internal pure returns (uint64) {
        // TODO
        return 0;
    }

    function _getSwapTaxAmount() internal view returns (uint256) {
        uint256 priorityFee = tx.gasprice - block.basefee;
        return SWAP_MEV_TAX_FACTOR * SWAP_TAXED_GAS * priorityFee;
    }

    function _negate(uint256 x) internal pure returns (int128 y) {
        require(x <= 1 << 128, NegationOverflow());
        unchecked {
            return -int128(int256(x));
        }
    }
}
