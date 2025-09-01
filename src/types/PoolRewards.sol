// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniV4, IPoolManager, PoolId} from "../interfaces/IUniV4.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

struct PoolRewards {
    mapping(bytes32 uniPositionKey => Position position) positions;
    mapping(int24 tick => uint256 growthOutsideX128) rewardGrowthOutsideX128;
    uint256 globalGrowthX128;
}

struct Position {
    uint256 lastGrowthInsideX128;
}

using PoolRewardsLib for PoolRewards global;

library PoolRewardsLib {
    using IUniV4 for IPoolManager;

    error NegativeDeltaForAdd();

    function afterLiquidityAdd(
        PoolRewards storage self,
        IPoolManager pm,
        PoolId id,
        int24 tickSpacing,
        address sender,
        ModifyLiquidityParams calldata params
    ) internal {
        uint256 growthInside;
        {
            int24 currentTick = pm.getSlot0(id).tick();
            uint256 lowerGrowth = self.rewardGrowthOutsideX128[params.tickLower];
            uint256 upperGrowth = self.rewardGrowthOutsideX128[params.tickUpper];

            if (currentTick < params.tickLower) {
                unchecked {
                    growthInside = lowerGrowth - upperGrowth;
                }
            } else if (params.tickUpper <= currentTick) {
                // Following Uniswap's convention, if tick is below and uninitialized initialize growth
                // outside to global accumulator.
                if (!pm.isInitialized(id, params.tickLower, tickSpacing)) {
                    self.rewardGrowthOutsideX128[params.tickLower] =
                        lowerGrowth = self.globalGrowthX128;
                }
                if (!pm.isInitialized(id, params.tickUpper, tickSpacing)) {
                    self.rewardGrowthOutsideX128[params.tickUpper] =
                        upperGrowth = self.globalGrowthX128;
                }
                unchecked {
                    growthInside = upperGrowth - lowerGrowth;
                }
            } else {
                if (!pm.isInitialized(id, params.tickLower, tickSpacing)) {
                    self.rewardGrowthOutsideX128[params.tickLower] =
                        lowerGrowth = self.globalGrowthX128;
                }
                unchecked {
                    growthInside = self.globalGrowthX128 - lowerGrowth - upperGrowth;
                }
            }
        }

        (Position storage position, bytes32 positionKey) =
            self.getPosition(sender, params.tickLower, params.tickUpper, params.salt);

        uint128 newLiquidity = pm.getPositionLiquidity(id, positionKey);
        if (!(params.liquidityDelta >= 0)) revert NegativeDeltaForAdd();
        uint128 liquidityDelta = uint128(uint256(params.liquidityDelta));
        uint128 lastLiquidity = newLiquidity - liquidityDelta;

        if (lastLiquidity == 0) {
            position.lastGrowthInsideX128 = growthInside;
        } else {
            // We want to update `lastGrowthInside` such that any previously accrued rewards are
            // preserved:
            // rewards' == rewards
            // (growth_inside - last') * L' = (growth_inside - last) * L
            //  growth_inside - last' = (growth_inside - last) * L / L'
            // last' = growth_inside - (growth_inside - last) * L / L'
            unchecked {
                uint256 lastGrowthAdjustment = FixedPointMathLib.fullMulDiv(
                    growthInside - position.lastGrowthInsideX128, lastLiquidity, newLiquidity
                );
                position.lastGrowthInsideX128 = growthInside - lastGrowthAdjustment;
            }
        }
    }

    function getPosition(
        PoolRewards storage self,
        address owner,
        int24 lowerTick,
        int24 upperTick,
        bytes32 salt
    ) internal view returns (Position storage position, bytes32 positionKey) {
        assembly ("memory-safe") {
            // Compute `positionKey` as `keccak256(abi.encodePacked(owner, lowerTick, upperTick, salt))`.
            // Less efficient than alternative ordering *but* lets us reuse as Uniswap position key.
            mstore(0x06, upperTick)
            mstore(0x03, lowerTick)
            mstore(0x00, owner)
            // WARN: Free memory pointer temporarily invalid from here on.
            mstore(0x26, salt)
            positionKey := keccak256(12, add(add(3, 3), add(20, 32)))
            // Upper bytes of free memory pointer cleared.
            mstore(0x26, 0)
        }
        position = self.positions[positionKey];
    }

    function getGrowthInside(PoolRewards storage self, int24 current, int24 lower, int24 upper)
        internal
        view
        returns (uint256 growthInsideX128)
    {
        unchecked {
            uint256 lowerGrowth = self.rewardGrowthOutsideX128[lower];
            uint256 upperGrowth = self.rewardGrowthOutsideX128[upper];

            if (current < lower) {
                return lowerGrowth - upperGrowth;
            }
            if (upper <= current) {
                return upperGrowth - lowerGrowth;
            }

            return self.globalGrowthX128 - lowerGrowth - upperGrowth;
        }
    }
}
