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
import {Math512Lib} from "./Math512Lib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";

/// @author philogy <https://github.com/philogy>
library CompensationPriceFinder {
    using IUniV4 for IPoolManager;
    using MixedSignLib for *;
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    using FormatLib for *;

    /// @dev Computes the effective execution price `p*` such that we can compensate as many
    /// liquidity ranges for the difference between their actual execution price and `p*`.
    function getOneForZero(
        TickIteratorUp memory ticks,
        uint128 liquidity,
        uint256 taxInEther,
        Slot0 slot0BeforeSwap,
        Slot0 slot0AfterSwap
    ) internal view returns (int24 lastTick, uint160 pstarSqrtX96) {
        uint256 sumAmount0Deltas = 0; // X
        uint256 sumAmount1Deltas = 0; // Y

        uint160 priceLowerSqrtX96 = slot0BeforeSwap.sqrtPriceX96();
        uint160 priceUpperSqrtX96;
        while (ticks.hasNext()) {
            lastTick = ticks.getNext();
            priceUpperSqrtX96 = TickMath.getSqrtPriceAtTick(lastTick);

            {
                uint256 delta0 = SqrtPriceMath.getAmount0Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                uint256 delta1 = SqrtPriceMath.getAmount1Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                sumAmount0Deltas += delta0;
                sumAmount1Deltas += delta1;
            }

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, lastTick);
            liquidity = liquidity.add(liquidityNet);

            priceLowerSqrtX96 = priceUpperSqrtX96;
        }

        priceUpperSqrtX96 = slot0AfterSwap.sqrtPriceX96();

        uint256 delta0 =
            SqrtPriceMath.getAmount0Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);
        uint256 delta1 =
            SqrtPriceMath.getAmount1Delta(priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false);
        sumAmount0Deltas += delta0;
        sumAmount1Deltas += delta1;

        uint256 simplePstarX96 = divX96(sumAmount1Deltas, sumAmount0Deltas - taxInEther);
        if (simplePstarX96 <= mulX96(priceUpperSqrtX96, priceUpperSqrtX96)) {
            pstarSqrtX96 = _oneForZeroGetFinalCompensationPrice(
                liquidity,
                priceLowerSqrtX96,
                priceUpperSqrtX96,
                taxInEther,
                sumAmount0Deltas - delta0,
                sumAmount1Deltas - delta1
            );

            return (type(int24).max, pstarSqrtX96);
        }

        (uint256 p1, uint256 p0) = Math512Lib.checkedMul2Pow96(0, simplePstarX96);

        return (type(int24).max, (p1 == 0 ? p0.sqrt() : Math512Lib.sqrt512(p1, p0)).toUint160());
    }

    function _oneForZeroGetFinalCompensationPrice(
        uint128 liquidity,
        uint160 priceLowerSqrtX96,
        uint160 priceUpperSqrtX96,
        uint256 compensationAmount0,
        uint256 sumUpToThisRange0,
        uint256 sumUpToThisRange1
    ) internal pure returns (uint160) {
        (bool multiplePrices, uint256 p1, uint256 p2) = _oneForZeroGetFinalCompensationPriceInner(
            liquidity, priceLowerSqrtX96, compensationAmount0, sumUpToThisRange0, sumUpToThisRange1
        );
        if (!multiplePrices) {
            return p1.toUint160();
        }

        bool inRange1 = priceLowerSqrtX96 <= p1 && p1 <= priceUpperSqrtX96;
        bool inRange2 = priceLowerSqrtX96 <= p2 && p2 <= priceUpperSqrtX96;
        if (inRange1 != inRange2) {
            return (inRange1 ? p1 : p2).toUint160();
        }

        if (inRange1) {
            return p1.max(p2).toUint160();
        }

        return (p1.dist(priceLowerSqrtX96) < p2.dist(priceLowerSqrtX96) ? p1 : p2).toUint160();
    }

    function _oneForZeroGetFinalCompensationPriceInner(
        uint128 liquidity,
        uint160 priceLowerSqrtX96,
        uint256 compensationAmount0,
        uint256 sumUpToThisRange0,
        uint256 sumUpToThisRange1
    ) internal pure returns (bool, uint256, uint256) {
        uint256 a;
        uint256 d1;
        uint256 d0;
        {
            uint256 rangeVirtualReserves0 = divX96(liquidity, priceLowerSqrtX96);
            uint256 rangeVirtualReserves1 = mulX96(liquidity, priceLowerSqrtX96);
            a = rangeVirtualReserves0 + sumUpToThisRange0 - compensationAmount0;

            {
                (uint256 x1, uint256 x0) = Math512Lib.fullMul(sumUpToThisRange1, a);
                if (sumUpToThisRange0 >= compensationAmount0) {
                    (d1, d0) = Math512Lib.fullMul(
                        rangeVirtualReserves1, sumUpToThisRange0 - compensationAmount0
                    );
                    (d1, d0) = Math512Lib.checkedSub(x1, x0, d1, d0);
                } else {
                    (d1, d0) = Math512Lib.fullMul(
                        rangeVirtualReserves1, compensationAmount0 - sumUpToThisRange0
                    );
                    (d1, d0) = Math512Lib.checkedAdd(x1, x0, d1, d0);
                }
            }
        }
        (d1, d0) = Math512Lib.checkedMul2Pow192(d1, d0);
        uint256 sqrtD = Math512Lib.sqrt512(d1, d0);

        uint256 liquidityX96 = uint256(liquidity) << 96;
        if (liquidityX96 < sqrtD) {
            // `(-b - sqrt(D)) / (2a)` solution is negative, don't compute.
            (d1, d0) = Math512Lib.checkedAdd(0, liquidityX96, 0, sqrtD);
            (uint256 upperBits, uint256 p1) = Math512Lib.div512by256(d1, d0, a);
            assert(upperBits == 0);
            return (false, p1, 0);
        }

        (d1, d0) = Math512Lib.checkedAdd(0, liquidityX96, 0, sqrtD);
        (uint256 upperBits, uint256 p1) = Math512Lib.div512by256(d1, d0, a);
        assert(upperBits == 0);

        uint256 p2 = (liquidityX96 - sqrtD) / a;
        return (true, p1, p2);
    }

    function divX96(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(numerator, FixedPoint96.Q96, denominator);
    }

    function mulX96(uint256 x, uint256 y) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivN(x, y, FixedPoint96.RESOLUTION);
    }
}
