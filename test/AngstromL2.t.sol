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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
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
    using TickMath for int24;

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

    function initializePool(address asset1, int24 tickSpacing, int24 startTick)
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

        manager.initialize(key, TickMath.getSqrtPriceAtTick(startTick));

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

        // console.log("delta.amount0(): %s", delta.amount0().fmtD());
        // console.log("delta.amount1(): %s", delta.amount1().fmtD());

        return delta;
    }

    function getRewards(PoolId id, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256)
    {
        return angstrom.getPendingPositionRewards(
            id, address(router), tickLower, tickUpper, bytes32(0)
        );
    }

    function setupSimpleZeroForOnePositions(PoolKey memory key) internal {
        PoolId id = key.toId();

        addLiquidity(key, -10, 20, 10e21);
        addLiquidity(key, -20, 0, 2e21);
        addLiquidity(key, -20, -10, 3e21);
        addLiquidity(key, -40, -30, 0.8e21);

        assertEq(getRewards(id, -10, 20), 0);
        assertEq(getRewards(id, -20, 0), 0);
        assertEq(getRewards(id, -20, -10), 0);
        assertEq(getRewards(id, -40, -30), 0);
    }

    function test_simpleZeroForOneSwap1() public {
        PoolKey memory key = initializePool(address(token), 10, 3);
        PoolId id = key.toId();

        setupSimpleZeroForOnePositions(key);

        setPriorityFee(0.7 gwei);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        assertEq(getRewards(id, -10, 20), 0.003099217600434384e18, "wrong rewards for [-10, 20]");
        assertEq(getRewards(id, -20, 0), 0.000330782399565614e18, "wrong rewards for [-20, 0]");
        assertEq(getRewards(id, -20, -10), 0, "wrong rewards for [-20, -10]");
        assertEq(getRewards(id, -40, -30), 0, "wrong rewards for [-40, -30]");
        assertApproxEqAbs(
            angstrom.getSwapTaxAmount(0.7 gwei),
            getRewards(id, -10, 20) + getRewards(id, -20, 0),
            10,
            "wrong tax total"
        );
    }

    function test_simpleZeroForOneSwap2() public {
        PoolKey memory key = initializePool(address(token), 10, 3);
        PoolId id = key.toId();

        setupSimpleZeroForOnePositions(key);

        setPriorityFee(1.3 gwei);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        assertEq(getRewards(id, -10, 20), 0.005602270037068238e18, "wrong rewards for [-10, 20]");
        assertEq(getRewards(id, -20, 0), 0.000734179067847244e18, "wrong rewards for [-20, 0]");
        assertEq(getRewards(id, -20, -10), 0.000033550895084515e18, "wrong rewards for [-20, -10]");
        assertEq(getRewards(id, -40, -30), 0, "wrong rewards for [-40, -30]");
        assertApproxEqAbs(
            angstrom.getSwapTaxAmount(1.3 gwei),
            getRewards(id, -10, 20) + getRewards(id, -20, 0) + getRewards(id, -20, -10),
            10,
            "wrong tax total"
        );
    }

    function test_simpleZeroForOneSwap3() public {
        PoolKey memory key = initializePool(address(token), 10, 3);
        PoolId id = key.toId();

        setupSimpleZeroForOnePositions(key);

        setPriorityFee(2.6 gwei);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        assertEq(getRewards(id, -10, 20), 0.01024433477037636e18, "wrong rewards for [-10, 20]");
        assertEq(getRewards(id, -20, 0), 0.00185381931995983e18, "wrong rewards for [-20, 0]");
        assertEq(getRewards(id, -20, -10), 0.000641845909663807e18, "wrong rewards for [-20, -10]");
        assertEq(getRewards(id, -40, -30), 0, "wrong rewards for [-40, -30]");
        assertApproxEqAbs(
            angstrom.getSwapTaxAmount(2.6 gwei),
            getRewards(id, -10, 20) + getRewards(id, -20, 0) + getRewards(id, -20, -10),
            10,
            "wrong tax total"
        );
    }

    function test_simpleZeroForOneSwap4() public {
        PoolKey memory key = initializePool(address(token), 10, 3);
        PoolId id = key.toId();

        setupSimpleZeroForOnePositions(key);

        setPriorityFee(5.4 gwei);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        assertEq(getRewards(id, -10, 20), 0.019162626216729137e18, "wrong rewards for [-10, 20]");
        assertEq(getRewards(id, -20, 0), 0.004594179393652089e18, "wrong rewards for [-20, 0]");
        assertEq(getRewards(id, -20, -10), 0.00269447311968076e18, "wrong rewards for [-20, -10]");
        assertEq(getRewards(id, -40, -30), 0.000008721269938012e18, "wrong rewards for [-40, -30]");
        assertApproxEqAbs(
            angstrom.getSwapTaxAmount(5.4 gwei),
            getRewards(id, -10, 20) + getRewards(id, -20, 0) + getRewards(id, -20, -10)
                + getRewards(id, -40, -30),
            10,
            "wrong tax total"
        );
    }
}
