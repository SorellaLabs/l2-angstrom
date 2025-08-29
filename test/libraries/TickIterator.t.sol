// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {
    TickIteratorLib, TickIteratorUp, TickIteratorDown
} from "../../src/libraries/TickIterator.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUniV4} from "../../src/interfaces/IUniV4.sol";
import {BaseTest} from "../_helpers/BaseTest.sol";
import {RouterActor} from "../_mocks/RouterActor.sol";
import {UniV4Inspector} from "../_mocks/UniV4Inspector.sol";
import {MockERC20} from "super-sol/mocks/MockERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract TickIteratorTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using IUniV4 for IPoolManager;

    UniV4Inspector manager;
    RouterActor router;
    PoolId pid;
    PoolKey key;

    MockERC20 token0;
    MockERC20 token1;

    int24 constant TICK_SPACING = 10;
    uint160 constant INIT_SQRT_PRICE = 79228162514264337593543950336; // 1:1 price

    function setUp() public {
        // Deploy UniV4Inspector (which is a PoolManager with view functions)
        manager = new UniV4Inspector();
        router = new RouterActor(manager);

        // Deploy and sort tokens
        token0 = new MockERC20();
        token1 = new MockERC20();

        if (address(token1) < address(token0)) {
            (token0, token1) = (token1, token0);
        }

        // Set up pool key
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        pid = key.toId();

        // Initialize pool
        manager.initialize(key, INIT_SQRT_PRICE);

        // Fund the router with tokens for liquidity operations
        token0.mint(address(router), 1e30);
        token1.mint(address(router), 1e30);
    }

    // Helper to add liquidity at specific tick range
    function addLiquidityAtTicks(int24 tickLower, int24 tickUpper) internal {
        require(tickLower % TICK_SPACING == 0, "Lower tick not aligned");
        require(tickUpper % TICK_SPACING == 0, "Upper tick not aligned");
        require(tickLower < tickUpper, "Invalid range");

        // Calculate liquidity amount (simplified - just use a fixed amount)
        uint128 liquidity = 1e18;

        // Use RouterActor to add liquidity
        router.modifyLiquidity(key, tickLower, tickUpper, int256(uint256(liquidity)), bytes32(0));
    }

    // ============ Upward Iteration Tests ============

    function test_iterateUp_simple() public {
        // Add liquidity at specific ticks: -100, -50, 0, 50, 100
        addLiquidityAtTicks(-100, -50);
        addLiquidityAtTicks(-50, 0);
        addLiquidityAtTicks(0, 50);
        addLiquidityAtTicks(50, 100);
        addLiquidityAtTicks(100, 150);

        TickIteratorUp memory iter = TickIteratorLib.initUp(manager, pid, TICK_SPACING, -100, 100);

        // Should iterate through initialized ticks
        assertTrue(iter.hasNext(), "Should have first tick");
        assertEq(iter.getNext(), -100, "First tick should be -100");

        assertTrue(iter.hasNext(), "Should have second tick");
        assertEq(iter.getNext(), -50, "Second tick should be -50");

        assertTrue(iter.hasNext(), "Should have third tick");
        assertEq(iter.getNext(), 0, "Third tick should be 0");

        assertTrue(iter.hasNext(), "Should have fourth tick");
        assertEq(iter.getNext(), 50, "Fourth tick should be 50");

        assertTrue(iter.hasNext(), "Should have fifth tick");
        assertEq(iter.getNext(), 100, "Fifth tick should be 100");

        assertFalse(iter.hasNext(), "Should have no more ticks");
    }

    function test_iterateUp_inclusiveBoundaries() public {
        // Test that boundaries are inclusive
        addLiquidityAtTicks(-200, -100);
        addLiquidityAtTicks(-100, 0);
        addLiquidityAtTicks(0, 100);
        addLiquidityAtTicks(100, 200);

        TickIteratorUp memory iter = TickIteratorLib.initUp(manager, pid, TICK_SPACING, -100, 100);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -100, "Should include start boundary");

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 0);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 100, "Should include end boundary");

        assertFalse(iter.hasNext(), "Should not go beyond end boundary");
    }

    function test_iterateUp_acrossWords() public {
        // Test iteration across word boundaries (256 ticks per word when compressed)
        // Word boundary is at compressed tick 256, which is tick 2560 with spacing 10
        addLiquidityAtTicks(-2560, -2550);
        addLiquidityAtTicks(-10, 0);
        addLiquidityAtTicks(0, 10);
        addLiquidityAtTicks(2550, 2560);
        addLiquidityAtTicks(2560, 2570);

        TickIteratorUp memory iter = TickIteratorLib.initUp(manager, pid, TICK_SPACING, -3000, 3000);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -2560);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -2550);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -10);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 0);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 10);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 2550);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 2560);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 2570);

        assertFalse(iter.hasNext());
    }

    function test_iterateUp_noInitializedTicks() public view {
        // No liquidity added, so no initialized ticks
        TickIteratorUp memory iter = TickIteratorLib.initUp(manager, pid, TICK_SPACING, -100, 100);

        assertFalse(iter.hasNext(), "Should have no ticks in empty range");
    }

    function test_iterateUp_singleTick() public {
        addLiquidityAtTicks(40, 60);

        // Test iteration over position boundaries
        // When adding liquidity from 40 to 60, ticks 40 and 60 are initialized
        // Note: If current pool tick is 0 and within range, tick 50 might also be initialized

        // Check what ticks are actually initialized in the full range
        TickIteratorUp memory iter = TickIteratorLib.initUp(manager, pid, TICK_SPACING, 40, 60);

        // Collect all initialized ticks
        int24[] memory initializedTicks = new int24[](10);
        uint256 count = 0;
        while (iter.hasNext() && count < 10) {
            initializedTicks[count] = iter.getNext();
            count++;
        }

        // Verify we have the expected ticks
        // At minimum, ticks 40 and 60 should be initialized (position boundaries)
        assertEq(count, 2, "Should have at least 2 initialized ticks");
        assertEq(initializedTicks[0], 40, "First tick should be 40");
        assertEq(initializedTicks[1], 60, "Last tick should be 60");
    }

    function test_iterateUp_maxTick() public view {
        // Test near maximum tick (must be aligned to tick spacing)
        int24 maxAlignedTick = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        int24 nearMaxTick = maxAlignedTick - TICK_SPACING;

        // Can't actually add liquidity at MAX_TICK, so test iteration behavior
        TickIteratorUp memory iter =
            TickIteratorLib.initUp(manager, pid, TICK_SPACING, nearMaxTick, maxAlignedTick);

        // No liquidity there, so should have no ticks
        assertFalse(iter.hasNext());
    }

    // ============ Downward Iteration Tests ============

    function test_iterateDown_simple() public {
        // Add liquidity at specific ticks
        addLiquidityAtTicks(-100, -50);
        addLiquidityAtTicks(-50, 0);
        addLiquidityAtTicks(0, 50);
        addLiquidityAtTicks(50, 100);
        addLiquidityAtTicks(100, 150);

        TickIteratorDown memory iter =
            TickIteratorLib.initDown(manager, pid, TICK_SPACING, 100, -100);

        // Should iterate through ticks in reverse
        assertTrue(iter.hasNext(), "Should have first tick");
        assertEq(iter.getNext(), 100, "First tick should be 100");

        assertTrue(iter.hasNext(), "Should have second tick");
        assertEq(iter.getNext(), 50, "Second tick should be 50");

        assertTrue(iter.hasNext(), "Should have third tick");
        assertEq(iter.getNext(), 0, "Third tick should be 0");

        assertTrue(iter.hasNext(), "Should have fourth tick");
        assertEq(iter.getNext(), -50, "Fourth tick should be -50");

        assertTrue(iter.hasNext(), "Should have fifth tick");
        assertEq(iter.getNext(), -100, "Fifth tick should be -100");

        assertFalse(iter.hasNext(), "Should have no more ticks");
    }

    function test_iterateDown_inclusiveBoundaries() public {
        // Test that boundaries are inclusive
        addLiquidityAtTicks(-200, -100);
        addLiquidityAtTicks(-100, 0);
        addLiquidityAtTicks(0, 100);
        addLiquidityAtTicks(100, 200);

        TickIteratorDown memory iter =
            TickIteratorLib.initDown(manager, pid, TICK_SPACING, 100, -100);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 100, "Should include start boundary");

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 0);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -100, "Should include end boundary");

        assertFalse(iter.hasNext(), "Should not go beyond end boundary");
    }

    function test_iterateDown_acrossWords() public {
        // Test iteration across word boundaries
        addLiquidityAtTicks(-2560, -2550);
        addLiquidityAtTicks(-10, 0);
        addLiquidityAtTicks(0, 10);
        addLiquidityAtTicks(2550, 2560);
        addLiquidityAtTicks(2560, 2570);

        TickIteratorDown memory iter =
            TickIteratorLib.initDown(manager, pid, TICK_SPACING, 3000, -3000);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 2570);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 2560);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 2550);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 10);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 0);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -10);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -2550);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), -2560);

        assertFalse(iter.hasNext());
    }

    function test_iterateDown_noInitializedTicks() public view {
        // No liquidity added
        TickIteratorDown memory iter =
            TickIteratorLib.initDown(manager, pid, TICK_SPACING, 100, -100);

        assertFalse(iter.hasNext(), "Should have no ticks in empty range");
    }

    function test_iterateDown_singleTick() public {
        addLiquidityAtTicks(40, 60);

        // Iterate over range that includes boundaries
        TickIteratorDown memory iter = TickIteratorLib.initDown(manager, pid, TICK_SPACING, 60, 40);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 60);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 40);

        assertFalse(iter.hasNext());
    }

    function test_iterateDown_minTick() public view {
        // Test near minimum tick (must be aligned to tick spacing)
        int24 minAlignedTick = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 nearMinTick = minAlignedTick + TICK_SPACING;

        TickIteratorDown memory iter =
            TickIteratorLib.initDown(manager, pid, TICK_SPACING, nearMinTick, minAlignedTick);

        // No liquidity there, so should have no ticks
        assertFalse(iter.hasNext());
    }

    // ============ Edge Cases ============

    function test_iterateUp_startAfterEnd() public view {
        // Invalid range: start > end
        TickIteratorUp memory iter = TickIteratorLib.initUp(manager, pid, TICK_SPACING, 100, -100);

        assertFalse(iter.hasNext(), "Invalid range should have no ticks");
    }

    function test_iterateDown_startBeforeEnd() public view {
        // Invalid range: start < end (for down iteration)
        TickIteratorDown memory iter =
            TickIteratorLib.initDown(manager, pid, TICK_SPACING, -100, 100);

        assertFalse(iter.hasNext(), "Invalid range should have no ticks");
    }

    function test_iterateUp_partialRange() public {
        addLiquidityAtTicks(-200, -100);
        addLiquidityAtTicks(-100, 0);
        addLiquidityAtTicks(0, 100);
        addLiquidityAtTicks(100, 200);

        // Only iterate middle portion
        TickIteratorUp memory iter = TickIteratorLib.initUp(manager, pid, TICK_SPACING, -50, 50);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 0, "Should only get tick within range");

        assertFalse(iter.hasNext());
    }

    function test_iterateDown_partialRange() public {
        addLiquidityAtTicks(-200, -100);
        addLiquidityAtTicks(-100, 0);
        addLiquidityAtTicks(0, 100);
        addLiquidityAtTicks(100, 200);

        // Only iterate middle portion
        TickIteratorDown memory iter = TickIteratorLib.initDown(manager, pid, TICK_SPACING, 50, -50);

        assertTrue(iter.hasNext());
        assertEq(iter.getNext(), 0, "Should only get tick within range");

        assertFalse(iter.hasNext());
    }
}
