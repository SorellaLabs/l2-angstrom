// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickLib} from "./TickLib.sol";
import {IUniV4} from "../interfaces/IUniV4.sol";

struct TickIteratorUp {
    IPoolManager manager;
    PoolId poolId;
    int24 tickSpacing;
    int24 currentTick;
    int24 endTick;
    int16 currentWordPos;
    uint256 currentWord;
    bool wordInitialized;
}

struct TickIteratorDown {
    IPoolManager manager;
    PoolId poolId;
    int24 tickSpacing;
    int24 currentTick;
    int24 endTick;
    int16 currentWordPos;
    uint256 currentWord;
    bool wordInitialized;
}

using TickIteratorLib for TickIteratorDown global;
using TickIteratorLib for TickIteratorUp global;

/// @author philogy <https://github.com/philogy>
library TickIteratorLib {
    using TickLib for int24;
    using TickLib for uint256;
    using IUniV4 for IPoolManager;

    // ============ Upward Iterator (Low to High) ============

    /// @notice Initialize an upward tick iterator
    /// @param manager The pool manager contract
    /// @param poolId The ID of the pool to iterate
    /// @param tickSpacing The tick spacing of the pool
    /// @param startTick The starting tick (inclusive)
    /// @param endTick The ending tick (inclusive)
    /// @return iter The initialized iterator
    function initUp(
        IPoolManager manager,
        PoolId poolId,
        int24 tickSpacing,
        int24 startTick,
        int24 endTick
    ) internal view returns (TickIteratorUp memory iter) {
        iter.manager = manager;
        iter.poolId = poolId;
        iter.tickSpacing = tickSpacing;
        iter.endTick = endTick;

        // For invalid ranges, set currentTick beyond endTick
        if (startTick > endTick) {
            iter.currentTick = endTick + tickSpacing;
            return iter;
        }

        int24 compressed = startTick.compress(tickSpacing);
        (iter.currentWordPos,) = TickLib.position(compressed);
        iter.currentTick = compressed * tickSpacing;

        iter.currentWord = manager.getPoolBitmapInfo(poolId, iter.currentWordPos);
        iter.wordInitialized = true;

        _advanceToNextUp(iter);
    }

    /// @notice Check if the iterator has more ticks
    /// @param self The iterator
    /// @return True if there are more ticks to iterate
    function hasNext(TickIteratorUp memory self) internal pure returns (bool) {
        return self.currentTick <= self.endTick;
    }

    /// @notice Get the next tick and advance the iterator
    /// @param self The iterator
    /// @return tick The next initialized tick
    function getNext(TickIteratorUp memory self) internal view returns (int24 tick) {
        require(hasNext(self), "No more ticks");
        tick = self.currentTick;
        _moveToNextUp(self);
    }

    function _moveToNextUp(TickIteratorUp memory self) private view {
        self.currentTick += self.tickSpacing;
        _advanceToNextUp(self);
    }

    function _advanceToNextUp(TickIteratorUp memory self) private view {
        while (self.currentTick <= self.endTick) {
            int24 compressed = self.currentTick.compress(self.tickSpacing);
            (int16 wordPos, uint8 bitPos) = TickLib.position(compressed);

            if (wordPos != self.currentWordPos) {
                self.currentWordPos = wordPos;
                self.currentWord = self.manager.getPoolBitmapInfo(self.poolId, wordPos);
            }

            if (self.currentWord.isInitialized(bitPos)) {
                return;
            }

            (bool found, uint8 nextBitPos) = self.currentWord.nextBitPosGte(bitPos + 1);

            if (found) {
                self.currentTick = TickLib.toTick(wordPos, nextBitPos, self.tickSpacing);
            } else {
                self.currentTick = TickLib.toTick(wordPos + 1, 0, self.tickSpacing);
            }
        }

        // Went beyond end tick - set sentinel value
        self.currentTick = self.endTick + self.tickSpacing;
    }

    // ============ Downward Iterator (High to Low) ============

    /// @notice Initialize a downward tick iterator
    /// @param manager The pool manager contract
    /// @param poolId The ID of the pool to iterate
    /// @param tickSpacing The tick spacing of the pool
    /// @param startTick The starting tick (inclusive, should be higher)
    /// @param endTick The ending tick (inclusive, should be lower)
    /// @return iter The initialized iterator
    function initDown(
        IPoolManager manager,
        PoolId poolId,
        int24 tickSpacing,
        int24 startTick,
        int24 endTick
    ) internal view returns (TickIteratorDown memory iter) {
        iter.manager = manager;
        iter.poolId = poolId;
        iter.tickSpacing = tickSpacing;
        iter.endTick = endTick;

        // For invalid ranges, set currentTick beyond endTick
        if (startTick < endTick) {
            iter.currentTick = endTick - tickSpacing;
            return iter;
        }

        int24 compressed = startTick.compress(tickSpacing);
        (iter.currentWordPos,) = TickLib.position(compressed);
        iter.currentTick = compressed * tickSpacing;

        iter.currentWord = manager.getPoolBitmapInfo(poolId, iter.currentWordPos);
        iter.wordInitialized = true;

        _advanceToNextDown(iter);
    }

    /// @notice Check if the iterator has more ticks
    /// @param self The iterator
    /// @return True if there are more ticks to iterate
    function hasNext(TickIteratorDown memory self) internal pure returns (bool) {
        return self.currentTick >= self.endTick;
    }

    /// @notice Get the next tick and advance the iterator
    /// @param self The iterator
    /// @return tick The next initialized tick
    function getNext(TickIteratorDown memory self) internal view returns (int24 tick) {
        require(hasNext(self), "No more ticks");

        tick = self.currentTick;

        // Move to next tick
        _moveToNextDown(self);
    }

    function _moveToNextDown(TickIteratorDown memory self) private view {
        self.currentTick -= self.tickSpacing;
        _advanceToNextDown(self);
    }

    function _advanceToNextDown(TickIteratorDown memory self) private view {
        while (self.currentTick >= self.endTick) {
            int24 compressed = self.currentTick.compress(self.tickSpacing);
            (int16 wordPos, uint8 bitPos) = TickLib.position(compressed);

            if (wordPos != self.currentWordPos) {
                self.currentWordPos = wordPos;
                self.currentWord = self.manager.getPoolBitmapInfo(self.poolId, wordPos);
            }

            if (self.currentWord.isInitialized(bitPos)) {
                return;
            }

            if (bitPos > 0) {
                (bool found, uint8 nextBitPos) = self.currentWord.nextBitPosLte(bitPos - 1);

                if (found) {
                    self.currentTick = TickLib.toTick(wordPos, nextBitPos, self.tickSpacing);
                } else {
                    self.currentTick = TickLib.toTick(wordPos - 1, 255, self.tickSpacing);
                }
            } else {
                self.currentTick = TickLib.toTick(wordPos - 1, 255, self.tickSpacing);
            }
        }

        // Went beyond end tick - set sentinel value
        self.currentTick = self.endTick - self.tickSpacing;
    }
}
