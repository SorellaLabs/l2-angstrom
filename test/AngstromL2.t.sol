// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./_helpers/BaseTest.sol";
import {RouterActor} from "./_mocks/RouterActor.sol";
import {MockERC20} from "super-sol/mocks/MockERC20.sol";
import {UniV4Inspector} from "./_mocks/UniV4Inspector.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";

import {AngstromL2} from "../src/AngstromL2.sol";
import {getRequiredHookPermissions, POOLS_MUST_HAVE_DYNAMIC_FEE} from "../src/hook-config.sol";
import {IUniV4} from "../src/interfaces/IUniV4.sol";

import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2Test is BaseTest {
    using FormatLib for *;
    using PoolIdLibrary for PoolKey;
    using IUniV4 for UniV4Inspector;

    UniV4Inspector manager;
    RouterActor router;
    AngstromL2 angstrom;

    MockERC20 token;

    uint160 constant INIT_SQRT_PRICE = 1 << 96; // 1:1 price

    function setUp() public {
        vm.roll(100);
        manager = new UniV4Inspector();
        router = new RouterActor(manager);
        vm.deal(address(router), 100 ether);

        token = new MockERC20();
        token.mint(address(router), 1_000_000_000e18);

        angstrom = AngstromL2(
            deployAngstromL2(
                type(AngstromL2).creationCode,
                IPoolManager(address(manager)),
                address(this),
                getRequiredHookPermissions()
            )
        );
    }

    /// @notice Helper to initialize a pool with given token and native ETH
    /// @param asset1 The ERC20 token to pair with ETH
    /// @return key The pool key for the initialized pool
    function initializePool(address asset1, int24 tickSpacing)
        internal
        returns (PoolKey memory key)
    {
        require(asset1 != address(0), "Token cannot be address(0)");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(asset1),
            fee: POOLS_MUST_HAVE_DYNAMIC_FEE ? LPFeeLibrary.DYNAMIC_FEE_FLAG : 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(angstrom))
        });

        manager.initialize(key, INIT_SQRT_PRICE);

        return key;
    }

    /// @notice Helper to add liquidity on a given tick range
    /// @param key The pool key
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @param liquidityAmount The amount of liquidity to add
    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityAmount
    ) internal returns (BalanceDelta delta) {
        require(tickLower % key.tickSpacing == 0, "Lower tick not aligned");
        require(tickUpper % key.tickSpacing == 0, "Upper tick not aligned");
        require(tickLower < tickUpper, "Invalid tick range");

        (delta,) = router.modifyLiquidity(
            key, tickLower, tickUpper, int256(uint256(liquidityAmount)), bytes32(0)
        );

        console.log("delta.amount0(): %s", delta.amount0().fmtD());
        console.log("delta.amount1(): %s", delta.amount1().fmtD());

        return delta;
    }

    /// @notice Test pool initialization
    function test_initializePool() public {
        PoolKey memory key = initializePool(address(token), 60);

        PoolId id = key.toId();
        Slot0 slot0 = manager.getSlot0(id);
        assertEq(slot0.sqrtPriceX96(), INIT_SQRT_PRICE, "Pool not initialized at expected price");
    }

    /// @notice Test adding liquidity
    function test_addLiquidity() public {
        PoolKey memory key = initializePool(address(token), 60);
        PoolId id = key.toId();

        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidityAmount = 1e18;

        addLiquidity(key, tickLower, tickUpper, liquidityAmount);

        uint128 liquidity = manager.getPoolLiquidity(id);
        assertGt(liquidity, 0, "No liquidity added to pool");
    }

    function test_simpleSwap() public {
        PoolKey memory key = initializePool(address(token), 10);
        PoolId id = key.toId();

        addLiquidity(key, -10, 10, 10e21);
        addLiquidity(key, 10, 20, 2e21);
        addLiquidity(key, 240, 300, 0.8e21);

        Slot0 slot0 = manager.getSlot0(id);
        console.log("slot0.tick():", slot0.tick().toStr());

        setPriorityFee(0.7 gwei);
        BalanceDelta swapOut = router.swap(key, false, 7.2e18);

        console.log("swapOut.amount0(): %s", swapOut.amount0().fmtD());
        console.log("swapOut.amount1(): %s", swapOut.amount1().fmtD());

        slot0 = manager.getSlot0(id);
        console.log("slot0.tick():", slot0.tick().toStr());
    }
}
