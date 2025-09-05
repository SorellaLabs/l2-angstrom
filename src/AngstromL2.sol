// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

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
import {getRequiredHookPermissions} from "src/hook-config.sol";
import {tuint256, tbytes32} from "transient-goodies/TransientPrimitives.sol";
import {LargeSqrtLib} from "./libraries/LargeSqrtLib.sol";

import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2 is UniConsumer, IBeforeSwapHook, IAfterSwapHook {
    using IUniV4 for IPoolManager;
    using PoolKeyHelperLib for PoolKey;
    using Hooks for IHooks;
    using MixedSignLib for *;
    using FixedPointMathLib for uint256;
    using SafeCastLib for *;

    using FormatLib for *;

    error NegationOverflow();

    /// @dev The `SWAP_TAXED_GAS` is the abstract estimated gas cost for a swap. We want it to be a constant so that competing searchers have a bid cost independent of how much gas swap actually uses, the overall tax just needs to scale proportional to `priority_fee * swap_fixed_cost`.
    uint256 internal constant SWAP_TAXED_GAS = 100_000;
    /// @dev MEV tax charged is `priority_fee * SWAP_MEV_TAX_FACTOR` meaning the tax rate is `SWAP_MEV_TAX_FACTOR / (SWAP_MEV_TAX_FACTOR + 1)`
    uint256 constant SWAP_MEV_TAX_FACTOR = 49;

    uint64 internal blockOfLastTopOfBlock;
    mapping(PoolId id => PoolRewards) internal rewards;

    tuint256 internal liquidityBeforeSwap;
    tbytes32 internal slot0BeforeSwap;

    constructor(IPoolManager uniV4, address owner) UniConsumer(uniV4) {
        Hooks.validateHookPermissions(IHooks(address(this)), getRequiredHookPermissions());
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
        int128 etherDelta = etherAmount.toInt256().toInt128();

        bool ethWasSpecified = params.zeroForOne == params.amountSpecified < 0; // ETH aka asset 0 was specified.

        PoolId id = key.calldataToId();
        liquidityBeforeSwap.set(UNI_V4.getPoolLiquidity(id));
        slot0BeforeSwap.set(Slot0.unwrap(UNI_V4.getSlot0(id)));

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
        Slot0 slot0BeforeSwap_ = Slot0.wrap(slot0BeforeSwap.get());
        Slot0 slot0AfterSwap = UNI_V4.getSlot0(id);

        console.log("before init");
        TickIteratorUp memory ticks = TickIteratorLib.initUp(
            UNI_V4, id, key.tickSpacing, slot0BeforeSwap_.tick(), slot0AfterSwap.tick()
        );
        console.log("before get compensation");

        uint256 taxInEther = _getSwapTaxAmount();
        console.log("taxInEther: %s", taxInEther.fmtD());
        (int24 lastTick, uint160 pstarSqrtX96) = CompensationPriceFinder.getOneForZero(
            ticks, uint128(liquidityBeforeSwap.get()), taxInEther, slot0BeforeSwap_, slot0AfterSwap
        );

        _oneForZeroCreditRewards(
            ticks, taxInEther, slot0BeforeSwap_, slot0AfterSwap, lastTick, pstarSqrtX96
        );
    }

    function _oneForZeroCreditRewards(
        TickIteratorUp memory ticks,
        uint256 taxInEther,
        Slot0 slot0BeforeSwap_,
        Slot0 slot0AfterSwap,
        int24 lastTick,
        uint160 pstarSqrtX96
    ) internal view {
        console.log("==================== credit rewards ====================");
        ticks.reset(slot0BeforeSwap_.tick());
        uint128 liquidity = uint128(liquidityBeforeSwap.get());
        uint160 priceLowerSqrtX96 = slot0BeforeSwap_.sqrtPriceX96();
        uint160 priceUpperSqrtX96;

        uint256 pstarX96 = mulX96(pstarSqrtX96, pstarSqrtX96);

        while (ticks.hasNext()) {
            int24 tickNext = ticks.getNext();
            if (tickNext > lastTick) {
                console.log("remainder: %s", taxInEther.fmtD(18));
                console.log("==================== credit rewards end ====================");
                return;
            }

            priceUpperSqrtX96 = min(TickMath.getSqrtPriceAtTick(tickNext), pstarSqrtX96);
            {
                uint256 delta0 = SqrtPriceMath.getAmount0Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                uint256 delta1 = SqrtPriceMath.getAmount1Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                console.log("  delta0: %s", delta0.fmtD());
                console.log("  delta1: %s", delta1.fmtD());
                //console.log("  average range price: %s", delta1.divWad(delta0).fmtD());

                uint256 negativeDelta = divX96(delta1, pstarX96);
                console.log("  negativeDelta: %s", negativeDelta.fmtD());
                uint256 rangeReward = (delta0 - negativeDelta).min(taxInEther);
                console.log(
                    "  rangeReward: %s [%s]",
                    rangeReward.fmtD(18),
                    ((delta0 - negativeDelta) - rangeReward).fmtD(18)
                );
                taxInEther -= rangeReward.min(taxInEther);
            }

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, tickNext);
            liquidity = liquidity.add(liquidityNet);

            priceLowerSqrtX96 = priceUpperSqrtX96;
        }

        console.log("=> final range");

        if (lastTick < type(int24).max) {
            return;
        }

        priceUpperSqrtX96 = min(slot0AfterSwap.sqrtPriceX96(), pstarSqrtX96);

        uint256 delta0 =
            SqrtPriceMath.getAmount0Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);
        uint256 delta1 =
            SqrtPriceMath.getAmount1Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);

        uint256 rangeReward = (delta0 - divX96(delta1, pstarX96)).min(taxInEther);
        console.log(
            "  rangeReward: %s [%s]",
            rangeReward.fmtD(18),
            (delta0 - divX96(delta1, pstarX96) - rangeReward).fmtD(18)
        );
        taxInEther -= rangeReward;

        console.log("remainder: %s", taxInEther.fmtD(18));
        console.log("==================== credit rewards end ====================");
    }

    function divX96(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(numerator, FixedPoint96.Q96, denominator);
    }

    function mulX96(uint256 x, uint256 y) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivN(x, y, FixedPoint96.RESOLUTION);
    }

    function min(uint160 x, uint160 y) internal pure returns (uint160) {
        return x < y ? x : y;
    }

    function _getBlock() internal view returns (uint64) {
        // TODO
        return uint64(block.number);
    }

    function _getSwapTaxAmount() internal view returns (uint256) {
        uint256 priorityFee = tx.gasprice - block.basefee;
        return SWAP_MEV_TAX_FACTOR * SWAP_TAXED_GAS * priorityFee;
    }
}
