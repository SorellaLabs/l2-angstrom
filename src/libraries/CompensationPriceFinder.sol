// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUniV4, IPoolManager, PoolId} from "../interfaces/IUniV4.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {MixedSignLib} from "../libraries/MixedSignLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {TickIteratorUp, TickIteratorDown} from "./TickIterator.sol";

/// @author philogy <https://github.com/philogy>
library CompensationPriceFinder {
    using IUniV4 for IPoolManager;
    using MixedSignLib for *;

    /// @dev Computes the effective execution price `p*` such that we can compensate as many
    /// liquidity ranges for the difference between their actual execution price and `p*`.
    function getOneForZero(
        TickIteratorUp memory ticks,
        uint128 liquidity,
        uint256 taxInEther,
        Slot0 slot0BeforeSwap,
        Slot0 slot0AfterSwap
    ) internal view returns (int24 lastTick, uint256 pstarNumerator, uint256 pstarDenominator) {
        uint256 sumAmount0Deltas = 0; // X
        uint256 sumAmount1Deltas = 0; // Y

        uint160 priceLowerSqrtX96 = slot0BeforeSwap.sqrtPriceX96();
        uint160 priceUpperSqrtX96;
        while (ticks.hasNext()) {
            lastTick = ticks.getNext();
            priceUpperSqrtX96 = TickMath.getSqrtPriceAtTick(lastTick);

            sumAmount0Deltas += SqrtPriceMath.getAmount0Delta(
                priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
            );
            sumAmount1Deltas += SqrtPriceMath.getAmount1Delta(
                priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
            );

            if (sumAmount0Deltas > taxInEther) {
                uint256 denominator = sumAmount0Deltas - taxInEther;
                uint256 effectiveExecutionPriceX96 = divX96(sumAmount1Deltas, denominator);
                uint256 priceUpper = mulX96(priceUpperSqrtX96, priceUpperSqrtX96);
                if (effectiveExecutionPriceX96 <= priceUpper) {
                    return (lastTick, sumAmount1Deltas, denominator);
                }
            }

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, lastTick);
            liquidity = liquidity.add(liquidityNet);

            priceLowerSqrtX96 = priceUpperSqrtX96;
        }

        priceUpperSqrtX96 = slot0AfterSwap.sqrtPriceX96();

        sumAmount0Deltas +=
            SqrtPriceMath.getAmount0Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);
        sumAmount1Deltas +=
            SqrtPriceMath.getAmount1Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);

        return (type(int24).max, sumAmount1Deltas, sumAmount0Deltas - taxInEther);
    }

    function divX96(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(numerator, FixedPoint96.Q96, denominator);
    }

    function mulX96(uint256 x, uint256 y) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivN(x, y, FixedPoint96.RESOLUTION);
    }
}
