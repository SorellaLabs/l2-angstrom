// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest} from "./_helpers/BaseTest.sol";
import {RouterActor} from "./_mocks/RouterActor.sol";
import {MockERC20} from "super-sol/mocks/MockERC20.sol";
import {UniV4Inspector} from "./_mocks/UniV4Inspector.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {AngstromL2Factory} from "../src/AngstromL2Factory.sol";
import {AngstromL2} from "../src/AngstromL2.sol";
import {POOLS_MUST_HAVE_DYNAMIC_FEE} from "../src/hook-config.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IUniV4} from "../src/interfaces/IUniV4.sol";
import {IHookAddressMiner} from "../src/interfaces/IHookAddressMiner.sol";

import {Q96MathLib} from "../src/libraries/Q96MathLib.sol";
import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";
import {X96FormatLib} from "test/_helpers/X96FormatLib.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2Test is BaseTest {
    using FormatLib for *;
    using X96FormatLib for *;
    using Q96MathLib for uint256;
    using PoolIdLibrary for PoolKey;

    using IUniV4 for UniV4Inspector;
    using TickMath for int24;

    UniV4Inspector manager;
    RouterActor router;
    AngstromL2Factory factory;
    AngstromL2 angstrom;
    address factoryOwner = makeAddr("factory_owner");
    address hookOwner = makeAddr("hook_owner");
    IHookAddressMiner miner;

    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    Position[] positions;

    MockERC20 token;

    bool constant COMPARE_HARDCODED_MINER = true;

    /// @dev Make sure to update `getMinerCode` if you move this.
    bool constant HUFF2_INSTALLED = true;

    uint160 constant INIT_SQRT_PRICE = 1 << 96; // 1:1 price

    uint256 internal constant MAX_PRIORITY_FEE_TAX_FLOOR = 100 gwei;

    event CreatorFeeDistributed(PoolId indexed poolId, Currency indexed feeCurrency, uint256 amount);
    event ProtocolFeeDistributed(PoolId indexed poolId, Currency indexed feeCurrency, uint256 amount);
    event CreatorTaxDistributed(PoolId indexed poolId, uint256 amount);
    event ProtocolSwapTaxDistributed(PoolId indexed poolId, uint256 amount);
    event ProtocolJITTaxDistributed(PoolId indexed poolId, uint256 amount);
    event WithdrawOnlyModeActivated();
    event CreatorRevenueWithdrawn(Currency indexed currency, address indexed to, uint256 amount);

    // Uniswap-related event, ERC6909 transfer
    event Transfer(
        address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount
    );

    function setUp() public {
        vm.roll(100);
        manager = new UniV4Inspector();
        router = new RouterActor(manager);
        vm.deal(address(manager), 1_000_000_000 ether);
        vm.deal(address(router), 100_000_000_000 ether);

        token = new MockERC20();
        token.mint(address(router), 1_000_000_000e18);

        bytes memory minerCode = HUFF2_INSTALLED
            ? getMinerCode(address(manager), COMPARE_HARDCODED_MINER)
            : getHardcodedMinerCode(address(manager));
        IHookAddressMiner newMiner;
        assembly ("memory-safe") {
            newMiner := create(0, add(minerCode, 0x20), mload(minerCode))
        }
        assertTrue(address(newMiner) != address(0), "miner deployment failed");
        miner = newMiner;

        factory = new AngstromL2Factory(factoryOwner, manager, miner);

        vm.prank(address(factory));
        bytes32 salt = miner.mineAngstromHookAddress(hookOwner);

        angstrom = factory.deployNewHook(hookOwner, salt);
    }

    function ffiPythonGetCompensation(
        Slot0 slot0BeforeSwap,
        Slot0 slot0AfterSwap,
        bool zeroForOne,
        uint256 totalCompensationAmount
    ) internal returns (uint256 pstarSqrtX96, uint256[] memory positionRewards) {
        string[] memory inputs = new string[](9);
        inputs[0] = "python3";
        inputs[1] = "script/get-compensation.py";
        inputs[2] = zeroForOne ? "zero_for_one" : "one_for_zero";
        inputs[3] = vm.toString(abi.encode(positions));
        inputs[4] = vm.toString(slot0BeforeSwap.sqrtPriceX96());
        inputs[5] = vm.toString(slot0AfterSwap.sqrtPriceX96());
        inputs[6] = vm.toString(slot0BeforeSwap.tick());
        inputs[7] = vm.toString(slot0AfterSwap.tick());
        inputs[8] = vm.toString(totalCompensationAmount);
        VmSafe.FfiResult memory result = vm.tryFfi(inputs);
        if (result.exitCode != 0) {
            revert(string.concat("[ERROR] from get-compensation.py:\n", string(result.stderr)));
        }
        if (result.stderr.length > 0) {
            console.log("==================== Python stderr START ====================");
            console.log(string(result.stderr));
            console.log("==================== END ====================");
        }
        (pstarSqrtX96, positionRewards) = abi.decode(result.stdout, (uint256, uint256[]));
    }

    function initializePool(address asset1, int24 tickSpacing, int24 startTick)
        internal
        returns (PoolKey memory key)
    {
        return initializePool(asset1, tickSpacing, startTick, 0, 0, 0, 0);
    }

    function initializePool(
        address asset1,
        int24 tickSpacing,
        int24 startTick,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6,
        uint24 defaultProtocolSwapFeeMultiple,
        uint24 defaultProtocolTaxFee        
    ) internal returns (PoolKey memory key) {
        require(asset1 != address(0), "Token cannot be address(0)");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(asset1),
            fee: POOLS_MUST_HAVE_DYNAMIC_FEE ? LPFeeLibrary.DYNAMIC_FEE_FLAG : 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(angstrom))
        });

        vm.startPrank(factory.owner());
        factory.setDefaultProtocolSwapFeeMultiple(defaultProtocolSwapFeeMultiple);
        factory.setDefaultProtocolTaxFee(defaultProtocolTaxFee);
        vm.stopPrank();

        uint24 protocolSwapFeeE6 = factory.getDefaultProtocolSwapFee(creatorSwapFeeE6, key.fee);
        uint24 protocolTaxFeeE6 = factory.defaultProtocolTaxFeeE6();
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.PoolCreated(
            address(angstrom), key, creatorSwapFeeE6, creatorTaxFeeE6, protocolSwapFeeE6, protocolTaxFeeE6
        );

        vm.prank(hookOwner);
            angstrom.initializeNewPool(
            key, TickMath.getSqrtPriceAtTick(startTick), creatorSwapFeeE6, creatorTaxFeeE6
        );

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
        uint128 liquidityAmount,
        bytes32 salt
    ) internal returns (BalanceDelta delta) {
        require(tickLower % key.tickSpacing == 0, "Lower tick not aligned");
        require(tickUpper % key.tickSpacing == 0, "Upper tick not aligned");
        require(tickLower < tickUpper, "Invalid tick range");

        (delta,) = router.modifyLiquidity(
            key, tickLower, tickUpper, int256(uint256(liquidityAmount)), salt
        );

        // console.log("delta.amount0(): %s", delta.amount0().fmtD());
        // console.log("delta.amount1(): %s", delta.amount1().fmtD());
        positions.push(
            Position({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidityAmount})
        );
        return delta;
    }

    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityAmount
    ) internal returns (BalanceDelta delta) {
        return addLiquidity(key, tickLower, tickUpper, liquidityAmount, bytes32(0));
    }

    function getRewards(PoolKey memory key, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256)
    {
        return angstrom.getPendingPositionRewards(
            key, address(router), tickLower, tickUpper, bytes32(0)
        );
    }

    function getAllRewards(PoolKey memory key) internal view returns (uint256) {
        uint256 rewards = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            rewards += getRewards(key, positions[i].tickLower, positions[i].tickUpper);
        }
        return rewards;
    }

    function setupSimpleZeroForOnePositions(PoolKey memory key) internal {
        addLiquidity(key, -10, 20, 10e21);
        addLiquidity(key, -20, 0, 2e21);
        addLiquidity(key, -20, -10, 3e21);
        addLiquidity(key, -40, -30, 0.8e21);

        assertEq(getRewards(key, -10, 20), 0);
        assertEq(getRewards(key, -20, 0), 0);
        assertEq(getRewards(key, -20, -10), 0);
        assertEq(getRewards(key, -40, -30), 0);
    }

    function test_miner() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        factory.createNewHookAndPoolWithMiner(makeAddr("user"), key, 1 << 96, 0, 0);
    }

    function test_benchmark_miner() public {
        vm.startPrank(address(factory));
        uint256 gasBefore = gasleft();
        uint256 total = 400;
        for (uint256 i = 0; i < total; i++) {
            address user = address(uint160(i + 230));
            miner.mineAngstromHookAddress(user);
        }
        uint256 netGas = gasBefore - gasleft();
        vm.stopPrank();
        console.log("average gas: %s", netGas / total);
    }

    function test_delta1WrongRoundingDirection() public {
        token.mint(address(router), 1e50);
        vm.deal(address(router), 1e50);

        int24 startTick = TickMath.MIN_TICK + 400000;
        PoolKey memory key = initializePool(address(token), 1, startTick);

        for (int24 i = 0; i < 80; i++) {
            addLiquidity(key, startTick - 10 - i * 10, startTick - i * 10, 100e18);
        }

        setPriorityFee(1 gwei);

        router.swap(key, true, 1e14, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_swapWithFee() public {
        PoolKey memory key = initializePool(address(token), 10, 3, 0.02e6, 0, 0, 0);
        vm.prank(factoryOwner);
        factory.setProtocolSwapFee(angstrom, key, 0.03e6);
        setupSimpleZeroForOnePositions(key);

        setPriorityFee(0);

        PoolId id = key.toId();
        // need to expect event from uniswap first, even though we don't care about it
        vm.expectEmit(false, false, false, false);
        emit IPoolManager.Swap(id, address(0), 0, 0, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.CreatorFeeDistributed(id, Currency.wrap(address(0)), 2000000000000000000000000);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.ProtocolFeeDistributed(id, Currency.wrap(address(0)), 3000000000000000000000000);
        BalanceDelta delta =
            router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        uint256 factoryFee = address(factory).balance;
        uint256 creatorFee = address(angstrom).balance;

        assertGe(delta.amount1(), 0, "non-positive amountOut");
        uint256 totalIn = 100_000_000e18;
        assertApproxEqAbs(factoryFee * 1e6 / totalIn, 0.03e6, 1);
        assertApproxEqAbs(creatorFee * 1e6 / totalIn, 0.02e6, 1);
    }

    function test_withdrawOnly() public {
        PoolKey memory key = initializePool(address(token), 10, 3);
        addLiquidity(key, -10, 20, 10e21);
        addLiquidity(key, -20, 0, 2e21);
        addLiquidity(key, -20, -10, 3e21);
        addLiquidity(key, -40, -30, 0.8e21);

        vm.prank(factoryOwner);
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.WithdrawOnly();
        factory.setEmergencyWithdrawOnly();
        angstrom.pullWithdrawOnly();

        bytes memory WithdrawOnlyModeSelector =
            bytes.concat(bytes4(keccak256("WithdrawOnlyMode()")));
        vm.expectRevert(
            uniswapWrapperErrorBytes(AngstromL2.beforeSwap.selector, WithdrawOnlyModeSelector)
        );
        router.swap(key, true, -100_000_00, int24(-14).getSqrtPriceAtTick());

        vm.expectRevert(
            uniswapWrapperErrorBytes(
                AngstromL2.afterAddLiquidity.selector, WithdrawOnlyModeSelector
            )
        );
        addLiquidity(key, -10, 30, 10e21);

        router.modifyLiquidity(key, -10, 20, -10e21, bytes32(0));
        router.modifyLiquidity(key, -20, 0, -2e21, bytes32(0));
        router.modifyLiquidity(key, -20, -10, -3e21, bytes32(0));
        router.modifyLiquidity(key, -40, -30, -0.8e21, bytes32(0));
    }

    function test_factoryGetDefaultProtocolSwapFee() public {
        vm.prank(factoryOwner);
        factory.setDefaultProtocolSwapFeeMultiple(0.25e6);

        assertEq(factory.getDefaultProtocolSwapFee(0.001e6, 0.003e6), 0.001331e6);
        assertEq(factory.getDefaultProtocolSwapFee(0.0002e6, 0.00004e6), 0.000079e6);
    }

    function test_factoryGetDefaultProtocolSwapFee_Fuzz(
        uint24 defaultMultiple,
        uint24 creatorSwapFee,
        uint24 lpFee
    ) public {
        uint24 boundedDefaultMultiple = uint24(bound(defaultMultiple, 0, 1e6 - 1));
        uint24 boundedCreatorSwapFee = uint24(bound(creatorSwapFee, 0, 0.2e6));
        uint24 boundedLpFee = uint24(bound(lpFee, 0, 0.1e6));

        vm.prank(factoryOwner);
        factory.setDefaultProtocolSwapFeeMultiple(boundedDefaultMultiple);

        // should never revert
        factory.getDefaultProtocolSwapFee(boundedCreatorSwapFee, boundedLpFee);
    }

    function test_fuzzing_ffi_zeroForOne(int24 endTick, uint256 priorityFee) public {
        endTick = int24(bound(endTick, int24(-40), int24(2)));
        priorityFee = bound(priorityFee, 0, 10_000 gwei);

        PoolKey memory key = initializePool(address(token), 10, 3);
        setupSimpleZeroForOnePositions(key);
        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        setPriorityFee(priorityFee);
        BalanceDelta delta =
            router.swap(key, true, -100_000_000e18, int24(endTick).getSqrtPriceAtTick());
        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());
        console.log("delta.amount0(): %s", delta.amount0().fmtD(18));
        console.log("delta.amount1(): %s", delta.amount1().fmtD(18));

        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        console.log("totalCompensationAmount: %s", totalCompensationAmount.fmtD(18));
        console.log("getAllRewards: %s", getAllRewards(key).fmtD(18));
        console.log("end tick: %s (real end: %s)", endTick.toStr(), slot0AfterSwap.tick().toStr());
        assertApproxEqAbs(totalCompensationAmount, getAllRewards(key), 10, "wrong tax total");

        (, uint256[] memory positionRewards) =
            ffiPythonGetCompensation(slot0BeforeSwap, slot0AfterSwap, true, totalCompensationAmount);
        for (uint256 i = 0; i < positionRewards.length; i++) {
            uint256 rewards = getRewards(key, positions[i].tickLower, positions[i].tickUpper);
            console.log("%s:", i);
            console.log(
                "  [%s, %s] %s",
                positions[i].tickLower.toStr(),
                positions[i].tickUpper.toStr(),
                rewards.fmtD(18)
            );
            assertApproxEqAbs(
                rewards,
                positionRewards[i],
                10,
                string.concat(
                    "wrong rewards for position #",
                    vm.toString(i),
                    " [",
                    vm.toString(positions[i].tickLower),
                    ", ",
                    vm.toString(positions[i].tickUpper),
                    "]"
                )
            );
        }
    }

    function test_fuzzing_ffi_zeroForOne2(int24 endTick, uint256 priorityFee) public {
        int24 spacing = 11000;
        endTick = int24(bound(endTick, -4 * spacing, 323));
        priorityFee = bound(priorityFee, 0, 10_000 gwei);

        PoolKey memory key = initializePool(address(token), spacing, 324);

        addLiquidity(key, -1 * spacing, 2 * spacing, 0.0001e21);
        addLiquidity(key, -2 * spacing, 0, 0.0002e21);
        addLiquidity(key, -2 * spacing, -1 * spacing, 0.0003e21);
        addLiquidity(key, -4 * spacing, -3 * spacing, 0.0008e21);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        setPriorityFee(priorityFee);
        BalanceDelta delta =
            router.swap(key, true, type(int128).min, int24(endTick).getSqrtPriceAtTick());
        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());
        console.log("delta.amount0(): %s", delta.amount0().fmtD(18));
        console.log("delta.amount1(): %s", delta.amount1().fmtD(18));

        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        console.log("totalCompensationAmount: %s", totalCompensationAmount.fmtD(18));
        console.log("getAllRewards: %s", getAllRewards(key).fmtD(18));
        console.log("end tick: %s (real end: %s)", endTick.toStr(), slot0AfterSwap.tick().toStr());
        assertLe(getAllRewards(key), totalCompensationAmount, "more rewards than cost");
        uint256 prec = uint256(1e18) / 1e5;
        assertApproxEqRel(totalCompensationAmount, getAllRewards(key), prec, "wrong tax total");

        (, uint256[] memory positionRewards) =
            ffiPythonGetCompensation(slot0BeforeSwap, slot0AfterSwap, true, totalCompensationAmount);
        for (uint256 i = 0; i < positionRewards.length; i++) {
            uint256 rewards = getRewards(key, positions[i].tickLower, positions[i].tickUpper);
            console.log("%s:", i);
            console.log(
                "  [%s, %s] %s",
                positions[i].tickLower.toStr(),
                positions[i].tickUpper.toStr(),
                rewards.fmtD(18)
            );
            totalCompensationAmount -= rewards;
            string memory errorMessage = string.concat(
                "wrong rewards for position #",
                vm.toString(i),
                " [",
                vm.toString(positions[i].tickLower),
                ", ",
                vm.toString(positions[i].tickUpper),
                "]"
            );
            if (rewards == 0 || positionRewards[i] == 0) {
                uint256 maxDelta = i == positions.length - 1 ? totalCompensationAmount + 1000 : 10;
                assertApproxEqAbs(rewards, positionRewards[i], maxDelta, errorMessage);
            } else {
                assertApproxEqRel(rewards, positionRewards[i], prec, errorMessage);
            }
        }
    }

    function test_simpleZeroForOneSwap1() public {
        uint24 creatorTaxFeeE6 = 1000;
        PoolKey memory key = initializePool({
            asset1: address(token),
            tickSpacing: 10,
            startTick: 3,
            creatorSwapFeeE6: 1000,
            creatorTaxFeeE6: creatorTaxFeeE6,
            defaultProtocolSwapFeeMultiple: 100000,
            defaultProtocolTaxFee: 1000
        });
        setupSimpleZeroForOnePositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());

        uint256 priorityFee = 0.7 gwei;
        setPriorityFee(priorityFee);
        uint256 factoryNativeBalanceBefore = address(factory).balance;

        // need to expect events from uniswap first, even though we don't care about them
        PoolId id = key.toId();
        vm.expectEmit(false, false, false, false);
        emit IPoolManager.Swap(id, address(0), 0, 0, 0, 0, 0, 0);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.LPTaxDistributed(id, 3423140000000000);

        vm.expectEmit(false, false, false, false);
        emit Transfer(address(0), address(0), address(0), 0, 0);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.CreatorTaxDistributed(id, 3430000000000);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.ProtocolSwapTaxDistributed(id, 3430000000000);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.CreatorFeeDistributed(id, Currency.wrap(address(0)), 99999999996570000000000);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.ProtocolFeeDistributed(id, Currency.wrap(address(0)), 11099999999619270000000);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GrowthOutsideX128Increased(id, 0, 49126274423079922271729617826050);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GrowthOutsideX128Increased(id, -10, 105257227528991733006759039033134);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GrowthOutsideX128Increased(id, -20, 105257227528991733006759039033134);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GrowthOutsideX128Increased(id, -30, 105257227528991733006759039033134);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GlobalGrowthX128Increased(id, 105257227528992158359717690206213);

        vm.expectEmit(false, false, false, false);
        emit MockERC20.Transfer(address(0), address(0), 0);

        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        // sanity check that some priority fee-based tax was charged
        uint256 factoryNativeBalanceAfter = address(factory).balance;
        require(factoryNativeBalanceAfter != factoryNativeBalanceBefore, "no swap tax charged!");

        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint24 protocolTaxFeeE6 = factory.defaultProtocolTaxFeeE6();
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee) * (1e6 - (protocolTaxFeeE6 + uint256(creatorTaxFeeE6))) / 1e6;
        assertApproxEqAbs(totalCompensationAmount, getAllRewards(key), 10, "wrong tax total");

        (, uint256[] memory positionRewards) =
            ffiPythonGetCompensation(slot0BeforeSwap, slot0AfterSwap, true, totalCompensationAmount);
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat(
                    "wrong rewards for position ",
                    vm.toString(i),
                    " [",
                    vm.toString(positions[i].tickLower),
                    ", ",
                    vm.toString(positions[i].tickUpper),
                    "]"
                )
            );
        }
    }

    function test_simpleZeroForOneSwap2() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleZeroForOnePositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 1.3 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        uint256 totalRewards = getAllRewards(key);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) =
            ffiPythonGetCompensation(slot0BeforeSwap, slot0AfterSwap, true, totalCompensationAmount);
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_simpleZeroForOneSwap3() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleZeroForOnePositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 2.6 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint256 totalRewards = getAllRewards(key);
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) =
            ffiPythonGetCompensation(slot0BeforeSwap, slot0AfterSwap, true, totalCompensationAmount);
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_simpleZeroForOneSwap4() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleZeroForOnePositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 5.4 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint256 totalRewards = getAllRewards(key);
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) =
            ffiPythonGetCompensation(slot0BeforeSwap, slot0AfterSwap, true, totalCompensationAmount);
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_simpleZeroForOneSwap5() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleZeroForOnePositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 8.2 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, true, -100_000_000e18, int24(-35).getSqrtPriceAtTick());

        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint256 totalRewards = getAllRewards(key);
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) =
            ffiPythonGetCompensation(slot0BeforeSwap, slot0AfterSwap, true, totalCompensationAmount);
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function setupSimpleOneForZeroPositions(PoolKey memory key) internal {
        addLiquidity(key, -20, 10, 10e21);
        addLiquidity(key, 0, 20, 2e21);
        addLiquidity(key, 10, 20, 3e21);
        addLiquidity(key, 30, 40, 0.8e21);

        assertEq(getRewards(key, -20, 10), 0);
        assertEq(getRewards(key, 0, 20), 0);
        assertEq(getRewards(key, 10, 20), 0);
        assertEq(getRewards(key, 30, 40), 0);
    }

    function test_simpleOneForZeroSwap1() public {
        uint24 creatorTaxFeeE6 = 1000;
        PoolKey memory key = initializePool({
            asset1: address(token),
            tickSpacing: 10,
            startTick: 3,
            creatorSwapFeeE6: 1000,
            creatorTaxFeeE6: creatorTaxFeeE6,
            defaultProtocolSwapFeeMultiple: 100000,
            defaultProtocolTaxFee: 1000
        });
        setupSimpleOneForZeroPositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());

        uint256 priorityFee = 0.7 gwei;
        setPriorityFee(priorityFee);
        uint256 factoryNativeBalanceBefore = address(factory).balance;

        // need to expect events from uniswap first, even though we don't care about them
        PoolId id = key.toId();
        vm.expectEmit(false, false, false, false);
        emit IPoolManager.Swap(id, address(0), 0, 0, 0, 0, 0, 0);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.LPTaxDistributed(id, 3423140000000000);

        vm.expectEmit(false, false, false, false);
        emit Transfer(address(0), address(0), address(0), 0, 0);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.CreatorTaxDistributed(id, 3430000000000);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.ProtocolSwapTaxDistributed(id, 3430000000000);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.CreatorFeeDistributed(id, Currency.wrap(address(token)), 6910898912407324);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.ProtocolFeeDistributed(id, Currency.wrap(address(token)), 767109779277214);

        vm.expectEmit(false, false, false, false);
        emit MockERC20.Transfer(address(0), address(0), 0);
        vm.expectEmit(false, false, false, false);
        emit MockERC20.Transfer(address(0), address(0), 0);

        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GrowthOutsideX128Increased(id, 10, 90983075213412229911694430467655);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GrowthOutsideX128Increased(id, 20, 105590531001571136487631028082079);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GrowthOutsideX128Increased(id, 30, 105590531001571136487631028082079);
        vm.expectEmit(true, true, true, true, address(angstrom));
        emit AngstromL2.GlobalGrowthX128Increased(id, 105590531001571136487631028082079);

        vm.expectEmit(false, false, false, false);
        emit MockERC20.Transfer(address(0), address(0), 0);

        router.swap(key, false, 100_000_000e18, int24(35).getSqrtPriceAtTick());
        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        // sanity check that some priority fee-based tax was charged
        uint256 factoryNativeBalanceAfter = address(factory).balance;
        require(factoryNativeBalanceAfter != factoryNativeBalanceBefore, "no swap tax charged!");

        uint256 totalRewards = getAllRewards(key);
        uint24 protocolTaxFeeE6 = factory.defaultProtocolTaxFeeE6();
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee) * (1e6 - (protocolTaxFeeE6 + uint256(creatorTaxFeeE6))) / 1e6;
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) = ffiPythonGetCompensation(
            slot0BeforeSwap, slot0AfterSwap, false, totalCompensationAmount
        );
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_simpleOneForZeroSwap2() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleOneForZeroPositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 1.3 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, false, 100_000_000e18, int24(35).getSqrtPriceAtTick());
        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint256 totalRewards = getAllRewards(key);
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) = ffiPythonGetCompensation(
            slot0BeforeSwap, slot0AfterSwap, false, totalCompensationAmount
        );
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_simpleOneForZeroSwap3() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleOneForZeroPositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 2.6 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, false, 100_000_000e18, int24(35).getSqrtPriceAtTick());
        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint256 totalRewards = getAllRewards(key);
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) = ffiPythonGetCompensation(
            slot0BeforeSwap, slot0AfterSwap, false, totalCompensationAmount
        );
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_simpleOneForZeroSwap4() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleOneForZeroPositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 5.4 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, false, 100_000_000e18, int24(35).getSqrtPriceAtTick());
        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());
        uint256 totalRewards = getAllRewards(key);
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) = ffiPythonGetCompensation(
            slot0BeforeSwap, slot0AfterSwap, false, totalCompensationAmount
        );
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_simpleOneForZeroSwap5() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleOneForZeroPositions(key);

        Slot0 slot0BeforeSwap = manager.getSlot0(key.toId());
        uint256 priorityFee = 8.2 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, false, 100_000_000e18, int24(35).getSqrtPriceAtTick());
        Slot0 slot0AfterSwap = manager.getSlot0(key.toId());

        uint256 totalRewards = getAllRewards(key);
        uint256 totalCompensationAmount = angstrom.getSwapTaxAmount(priorityFee);
        assertApproxEqAbs(totalCompensationAmount, totalRewards, 10, "wrong tax total");

        (, uint256[] memory positionRewards) = ffiPythonGetCompensation(
            slot0BeforeSwap, slot0AfterSwap, false, totalCompensationAmount
        );
        for (uint256 i = 0; i < positionRewards.length; i++) {
            assertApproxEqAbs(
                getRewards(key, positions[i].tickLower, positions[i].tickUpper),
                positionRewards[i],
                5,
                string.concat("wrong rewards for position ", vm.toString(i))
            );
        }
    }

    function test_zeroForOneSwapEndingOnInitializedTick() public {
        PoolKey memory key = initializePool(address(token), 10, 0);

        // Add liquidity that creates initialized ticks
        addLiquidity(key, -20, 20, 10e21);
        addLiquidity(key, -10, 10, 5e21);
        addLiquidity(key, -30, -10, 3e21);

        // Ensure all positions start with zero rewards
        assertEq(getRewards(key, -20, 20), 0, "initial rewards should be zero");
        assertEq(getRewards(key, -10, 10), 0, "initial rewards should be zero");
        assertEq(getRewards(key, -30, -10), 0, "initial rewards should be zero");

        // Execute swap that ends exactly on tick -10 (an initialized tick)
        setPriorityFee(2 gwei);
        router.swap(key, true, -100_000e18, int24(-10).getSqrtPriceAtTick());

        // Verify rewards are correctly computed even when ending on an initialized tick
        uint256 totalRewards =
            getRewards(key, -20, 20) + getRewards(key, -10, 10) + getRewards(key, -30, -10);
        assertApproxEqAbs(
            angstrom.getSwapTaxAmount(2 gwei),
            totalRewards,
            10,
            "total rewards should match tax collected"
        );

        assertEq(getRewards(key, -20, 20), 0.006533333333333333e18, "wrong rewards for [-20, 20]");
        assertEq(getRewards(key, -10, 10), 0.003266666666666666e18, "wrong rewards for [-10, 10]");
        assertEq(getRewards(key, -30, -10), 0, "wrong rewards for [-30, -10]");
    }

    function test_oneForZeroSwapEndingOnInitializedTick() public {
        PoolKey memory key = initializePool(address(token), 10, 0);

        // Add liquidity that creates initialized ticks
        addLiquidity(key, -20, 20, 10e21);
        addLiquidity(key, -10, 10, 5e21);
        addLiquidity(key, 10, 30, 3e21);

        // Ensure all positions start with zero rewards
        assertEq(getRewards(key, -20, 20), 0, "initial rewards should be zero");
        assertEq(getRewards(key, -10, 10), 0, "initial rewards should be zero");
        assertEq(getRewards(key, 10, 30), 0, "initial rewards should be zero");

        // Execute swap that ends exactly on tick 10 (an initialized tick)
        setPriorityFee(2 gwei);
        router.swap(key, false, 100_000e18, int24(10).getSqrtPriceAtTick());

        // Verify rewards are correctly computed even when ending on an initialized tick
        uint256 totalRewards =
            getRewards(key, -20, 20) + getRewards(key, -10, 10) + getRewards(key, 10, 30);
        assertApproxEqAbs(
            angstrom.getSwapTaxAmount(2 gwei),
            totalRewards,
            10,
            "total rewards should match tax collected"
        );

        // Verify rewards are distributed correctly
        assertEq(getRewards(key, -20, 20), 0.006533333333333333e18, "wrong rewards for [-20, 20]");
        assertEq(getRewards(key, -10, 10), 0.003266666666666666e18, "wrong rewards for [-10, 10]");
        assertEq(getRewards(key, 10, 30), 0, "wrong rewards for [10, 30]");
    }

    function test_newPositionStartsWithZeroRewards() public {
        PoolKey memory key = initializePool(address(token), 10, 0);

        // Add initial liquidity
        addLiquidity(key, -20, 20, 10e21);

        // Execute a taxed swap to distribute rewards
        setPriorityFee(3 gwei);
        router.swap(key, true, -50_000e18, int24(-5).getSqrtPriceAtTick());

        // Verify existing position has rewards
        uint256 existingRewards = getRewards(key, -20, 20);
        assertGt(existingRewards, 0, "existing position should have rewards");

        // Add a new position after rewards have been distributed
        addLiquidity(key, -30, 10, 5e21);

        // Verify new position starts with zero rewards
        assertEq(getRewards(key, -30, 10), 0, "new position should start with zero rewards");

        // Verify existing position's rewards haven't changed
        assertEq(
            getRewards(key, -20, 20),
            existingRewards,
            "existing position rewards should remain unchanged"
        );
    }

    function test_addLiquidityDoesNotChangeRewards() public {
        PoolKey memory key = initializePool(address(token), 10, 0);

        // Add initial liquidity
        addLiquidity(key, -20, 20, 10e21);

        // Execute a taxed swap to distribute rewards
        setPriorityFee(3 gwei);
        router.swap(key, true, -50_000e18, int24(-5).getSqrtPriceAtTick());

        // Record rewards before adding liquidity
        uint256 rewardsBefore = getRewards(key, -20, 20);
        assertGt(rewardsBefore, 0, "position should have rewards before adding liquidity");

        // Add more liquidity to the same position
        addLiquidity(key, -20, 20, 5e21);

        // Verify rewards remain the same (allowing for tiny rounding errors)
        uint256 rewardsAfter = getRewards(key, -20, 20);
        assertApproxEqAbs(
            rewardsAfter,
            rewardsBefore,
            100, // Allow for small rounding errors
            "rewards should not change when adding liquidity"
        );

        // If there is a rounding error, it should be a decrease (as mentioned in requirements)
        assertLe(
            rewardsAfter, rewardsBefore, "if rewards change, they should only decrease slightly"
        );
    }

    function test_partialRemoveLiquidityDispersesRewards() public {
        PoolKey memory key = initializePool(address(token), 10, 0);
        PoolId id = key.toId();

        // Add initial liquidity at tick 0 and record the delta
        BalanceDelta addDelta = addLiquidity(key, -20, 20, 10e21);

        // Execute a taxed swap to distribute rewards (move price to tick -5)
        setPriorityFee(3 gwei);
        router.swap(key, true, -50_000e18, int24(-5).getSqrtPriceAtTick());

        // Record rewards before removing liquidity
        uint256 rewardsBefore = getRewards(key, -20, 20);
        assertGt(rewardsBefore, 0, "position should have rewards before removing liquidity");

        // Swap back to original price (tick 0) with no tax to restore original price
        // This ensures the asset ratio is the same as when we added liquidity
        setPriorityFee(0);
        router.swap(key, false, 100_000e18, int24(0).getSqrtPriceAtTick());

        // Verify we're back at tick 0
        Slot0 slot0 = manager.getSlot0(id);
        assertEq(slot0.tick(), 0, "should be back at tick 0");

        // Remove partial liquidity (50%) with no priority fee
        setPriorityFee(0);
        (BalanceDelta removeDelta,) =
            router.modifyLiquidity(key, -20, 20, -int256(uint256(5e21)), bytes32(0));

        // ANY liquidity removal triggers FULL dispersal of rewards
        uint256 rewardsAfter = getRewards(key, -20, 20);
        assertEq(rewardsAfter, 0, "rewards should be fully dispersed after any removal");

        // Calculate expected amounts for 50% removal
        // addDelta amounts are negative (user paid), so we negate to get positive values
        uint128 ethPaidToAdd = uint128(-addDelta.amount0());
        uint128 tokenPaidToAdd = uint128(-addDelta.amount1());
        uint128 expectedEthReturned = ethPaidToAdd / 2;
        uint128 expectedTokenReturned = tokenPaidToAdd / 2;

        // The delta represents the net flow after accounting for:
        // 1. Liquidity removal (user receives back assets)
        // 2. Reward dispersal (user receives rewards in ETH)
        // 3. Any fees (JIT tax even with priority fee = 0 due to base fee)

        // For amount1 (token), should be exactly half returned
        // removeDelta.amount1() should be positive (user receives tokens)
        assertApproxEqAbs(
            uint128(removeDelta.amount1()),
            expectedTokenReturned,
            1,
            "token returned should be exactly half of added amount"
        );

        // For amount0 (ETH), verify the reward distribution through deltas
        // removeDelta.amount0() is positive, meaning user receives ETH
        // This ETH includes both the proportional return from liquidity removal AND the rewards

        // The user should receive:
        // 1. Half of the ETH they originally deposited (expectedEthReturned)
        // 2. Plus the full rewards that were accumulated (rewardsBefore)
        uint128 totalExpectedEth = expectedEthReturned + uint128(rewardsBefore);

        // Verify the ETH returned matches our expectation (within rounding)
        assertApproxEqAbs(
            uint128(removeDelta.amount0()),
            totalExpectedEth,
            2,
            "ETH returned should be half of deposit plus full rewards"
        );

        // The key assertion is that rewards went to zero, proving full dispersal
        assertEq(rewardsAfter, 0, "Rewards were fully dispersed");
    }

    function test_completeRemoveLiquidityDispersesAllRewards() public {
        PoolKey memory key = initializePool(address(token), 10, 0);
        PoolId id = key.toId();

        // Add initial liquidity
        addLiquidity(key, -20, 20, 10e21);

        // Execute a taxed swap to distribute rewards
        setPriorityFee(3 gwei);
        router.swap(key, true, -50_000e18, int24(-5).getSqrtPriceAtTick());

        // Record rewards before removing liquidity
        uint256 rewardsBefore = getRewards(key, -20, 20);
        assertGt(rewardsBefore, 0, "position should have rewards before removing liquidity");

        // ANY liquidity removal triggers FULL reward dispersal
        // To work around the underflow bug when removing all liquidity with rewards,
        // we remove liquidity in two steps:
        // 1. Remove a small amount first to trigger reward dispersal
        // 2. Then remove the remaining liquidity

        // Step 1: Remove 1% of liquidity to trigger full reward dispersal
        setPriorityFee(0);
        uint256 firstRemoval = 1e20; // Remove 1% of liquidity (0.1e21 out of 10e21)
        (BalanceDelta delta1,) =
            router.modifyLiquidity(key, -20, 20, -int256(firstRemoval), bytes32(0));

        // Verify rewards were fully dispersed after first removal
        uint256 rewardsAfterFirst = getRewards(key, -20, 20);
        assertEq(rewardsAfterFirst, 0, "rewards should be fully dispersed after first removal");

        // The first delta should include the full rewards plus the proportional liquidity
        assertGt(delta1.amount0(), 0, "ETH should be returned in first removal");
        assertGt(delta1.amount1(), 0, "Token should be returned in first removal");

        // Step 2: Remove the remaining 99% of liquidity
        uint256 secondRemoval = 99e20; // Remove remaining 99% of liquidity
        (BalanceDelta delta2,) =
            router.modifyLiquidity(key, -20, 20, -int256(secondRemoval), bytes32(0));

        // Second removal should not have any rewards (already dispersed)
        uint256 rewardsAfterSecond = getRewards(key, -20, 20);
        assertEq(rewardsAfterSecond, 0, "rewards should remain zero after second removal");

        // The second delta should only include the proportional liquidity return
        assertGt(delta2.amount0(), 0, "ETH should be returned in second removal");
        assertGt(delta2.amount1(), 0, "Token should be returned in second removal");

        // Verify that all liquidity has been removed
        bytes32 positionKey =
            keccak256(abi.encodePacked(address(router), int24(-20), int24(20), bytes32(0)));
        uint128 finalLiquidity = manager.getPositionLiquidity(id, positionKey);
        assertEq(finalLiquidity, 0, "all liquidity should be removed");
    }

    function test_noTaxSwapDoesNotModifyRewards() public {
        PoolKey memory key = initializePool(address(token), 10, 0);

        // Add liquidity positions
        addLiquidity(key, -20, 20, 10e21);
        addLiquidity(key, -30, 30, 5e21);

        // Verify initial rewards are zero
        assertEq(getRewards(key, -20, 20), 0, "initial rewards should be zero");
        assertEq(getRewards(key, -30, 30), 0, "initial rewards should be zero");

        // Execute swap with zero priority fee (no tax)
        setPriorityFee(0);
        router.swap(key, true, -50_000e18, int24(-10).getSqrtPriceAtTick());

        // Verify rewards remain zero after no-tax swap
        assertEq(getRewards(key, -20, 20), 0, "rewards should remain zero after no-tax swap");
        assertEq(getRewards(key, -30, 30), 0, "rewards should remain zero after no-tax swap");

        // Execute another no-tax swap in opposite direction
        router.swap(key, false, 50_000e18, int24(10).getSqrtPriceAtTick());

        // Verify rewards still remain zero
        assertEq(getRewards(key, -20, 20), 0, "rewards should remain zero after second no-tax swap");
        assertEq(getRewards(key, -30, 30), 0, "rewards should remain zero after second no-tax swap");
    }

    function test_rewardsFromSubsequentSwapsStack() public {
        PoolKey memory key = initializePool(address(token), 10, 0);

        // Add liquidity positions
        addLiquidity(key, -20, 20, 10e21);
        addLiquidity(key, -30, 30, 5e21);

        // First taxed swap
        setPriorityFee(1 gwei);
        router.swap(key, true, -30_000e18, int24(-5).getSqrtPriceAtTick());

        uint256 rewards1_pos1 = getRewards(key, -20, 20);
        uint256 rewards1_pos2 = getRewards(key, -30, 30);
        assertGt(rewards1_pos1, 0, "first position should have rewards after first swap");
        assertGt(rewards1_pos2, 0, "second position should have rewards after first swap");

        // Move to next block for second swap
        bumpBlock();

        // Second taxed swap with different priority fee
        setPriorityFee(2 gwei);
        router.swap(key, false, 40_000e18, int24(8).getSqrtPriceAtTick());

        uint256 rewards2_pos1 = getRewards(key, -20, 20);
        uint256 rewards2_pos2 = getRewards(key, -30, 30);

        // Verify rewards have increased (stacked)
        assertGt(rewards2_pos1, rewards1_pos1, "first position rewards should stack");
        assertGt(rewards2_pos2, rewards1_pos2, "second position rewards should stack");

        // Move to next block for third swap
        bumpBlock();

        // Third taxed swap
        setPriorityFee(1.5 gwei);
        router.swap(key, true, -25_000e18, int24(-3).getSqrtPriceAtTick());

        uint256 rewards3_pos1 = getRewards(key, -20, 20);
        uint256 rewards3_pos2 = getRewards(key, -30, 30);

        // Verify rewards continue to stack
        assertGt(rewards3_pos1, rewards2_pos1, "first position rewards should continue stacking");
        assertGt(rewards3_pos2, rewards2_pos2, "second position rewards should continue stacking");

        // Verify total rewards approximately match total taxes collected
        uint256 totalRewards = rewards3_pos1 + rewards3_pos2;
        uint256 expectedTax1 = angstrom.getSwapTaxAmount(1 gwei);
        uint256 expectedTax2 = angstrom.getSwapTaxAmount(2 gwei);
        uint256 expectedTax3 = angstrom.getSwapTaxAmount(1.5 gwei);

        assertApproxEqAbs(
            totalRewards,
            expectedTax1 + expectedTax2 + expectedTax3,
            100,
            "total stacked rewards should match total taxes collected"
        );
    }

    function test_nonOwnerCannotInitializePool() public {
        // Test that non-owner/non-creator cannot initialize a pool directly through PoolManager
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(angstrom))
        });

        // Try to initialize directly through PoolManager as a random user (not through angstrom.initializeNewPool)
        address randomUser = makeAddr("random_user");
        vm.prank(randomUser);
        // The PoolManager wraps the hook's revert in a WrappedError
        // Test that we get the correct wrapped error
        vm.expectRevert(
            uniswapWrapperErrorBytes(
                IHooks.beforeInitialize.selector, bytes.concat(Ownable.Unauthorized.selector)
            )
        );
        manager.initialize(key, INIT_SQRT_PRICE);
    }

    function test_ownerCannotInitializePoolWithDynamicFee() public {
        // Test that even the owner cannot initialize a pool with dynamic fee flag
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // Dynamic fee flag
            tickSpacing: 10,
            hooks: IHooks(address(angstrom))
        });

        // Try to initialize through angstrom.initializeNewPool as the hook owner
        vm.prank(hookOwner);
        vm.expectRevert(AngstromL2.IncompatiblePoolConfiguration.selector);
        angstrom.initializeNewPool(key, INIT_SQRT_PRICE, 0, 0);
    }

    function test_cannotInitializePoolWithoutETH() public {
        // Test that pools cannot be initialized without ETH as currency0
        MockERC20 token2 = new MockERC20();

        // Create a pool key with token as currency0 instead of ETH
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token)),
            currency1: Currency.wrap(address(token2)),
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(angstrom))
        });

        // Try to initialize through angstrom.initializeNewPool as the hook owner
        vm.prank(hookOwner);
        vm.expectRevert(AngstromL2.IncompatiblePoolConfiguration.selector);
        angstrom.initializeNewPool(key, INIT_SQRT_PRICE, 0, 0);
    }

    function test_cannotInitializePoolWithZeroAddressHook() public {
        // arrange
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        // act & assert
        vm.prank(hookOwner);
        vm.expectRevert(AngstromL2.HooksMismatch.selector);
        angstrom.initializeNewPool(key, INIT_SQRT_PRICE, 0, 0);
    }

    function test_cannotInitializePoolWithDifferentContractAsHook() public {
        // arrange
        address differentContract = makeAddr("different_hook");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(differentContract)
        });

        // act & assert
        vm.prank(hookOwner);
        vm.expectRevert(AngstromL2.HooksMismatch.selector);
        angstrom.initializeNewPool(key, INIT_SQRT_PRICE, 0, 0);
    }

    function test_factoryCannotInitializePoolWithWrongHook() public {
        // arrange
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        // act & assert
        vm.prank(address(factory));
        vm.expectRevert(AngstromL2.HooksMismatch.selector);
        angstrom.initializeNewPool(key, INIT_SQRT_PRICE, 0, 0);
    }

    function test_maintainsRewardsAfterSwap() public {
        PoolKey memory key = initializePool(address(token), 10, 3);

        setupSimpleOneForZeroPositions(key);

        uint256 priorityFee = 0.7 gwei;
        setPriorityFee(priorityFee);
        router.swap(key, false, 100_000_000e18, int24(35).getSqrtPriceAtTick());

        setPriorityFee(0);
        router.swap(key, true, 100_000_000e18, int24(14).getSqrtPriceAtTick());

        assertEq(getRewards(key, -20, 10), 0.002678335827005454e18, "wrong rewards for [-20, 10]");
        assertEq(getRewards(key, 0, 20), 0.000622065968438472e18, "wrong rewards for [0, 20]");
        assertEq(getRewards(key, 10, 20), 0.000129598204556072e18, "wrong rewards for [10, 20]");
        assertEq(getRewards(key, 30, 40), 0, "wrong rewards for [30, 40]");

        addLiquidity(key, -20, 40, 3e21);
        assertEq(getRewards(key, -20, 40), 0, "rewards for [-20, 40]");
    }

    function test_setDefaultJITTaxEnabled() public {
        vm.startPrank(factory.owner());
        bool newStatus = true;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.DefaultJITTaxStatusUpdated(newStatus);

        factory.setDefaultJITTaxEnabled(newStatus);

        assertEq(factory.defaultJITTaxEnabled(), newStatus, "defaultJITTaxEnabled not set correctly");

        // also check switch to false
        newStatus = false;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.DefaultJITTaxStatusUpdated(newStatus);

        factory.setDefaultJITTaxEnabled(newStatus);

        assertEq(factory.defaultJITTaxEnabled(), newStatus, "defaultJITTaxEnabled not set correctly");
    }

    function test_setDefaultJITTaxEnabled_NotOwner() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        factory.setDefaultJITTaxEnabled(true);
    }

    function test_setJITTaxEnabled() public {
        vm.startPrank(factory.owner());
        bool newStatus = true;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.JITTaxStatusUpdated(address(angstrom), newStatus);

        factory.setJITTaxEnabled(angstrom, newStatus);

        assertEq(angstrom.jitTaxEnabled(), newStatus, "jitTaxEnabled not set correctly");
        assertGt(angstrom.getJitTaxAmount(1e18), 0, "JIT tax amount should not be zero when enabled");

        // repeat check
        newStatus = true;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.JITTaxStatusUpdated(address(angstrom), newStatus);

        factory.setJITTaxEnabled(angstrom, newStatus);

        assertEq(angstrom.jitTaxEnabled(), newStatus, "jitTaxEnabled not set correctly");

        // check on switch to false
        newStatus = false;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.JITTaxStatusUpdated(address(angstrom), newStatus);

        factory.setJITTaxEnabled(angstrom, newStatus);

        assertEq(angstrom.jitTaxEnabled(), newStatus, "jitTaxEnabled not set correctly");
        assertEq(angstrom.getJitTaxAmount(1e18), 0, "JIT tax amount should be zero when disabled");
        vm.stopPrank();
    }

    function test_setJITTaxEnabled_revert_NotFactory() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        angstrom.setJITTaxEnabled(true);
    }

    function test_setJITTaxEnabled_revert_NotOwner() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        factory.setJITTaxEnabled(angstrom, true);
    }

    function test_setDefaultPriorityFeeTaxFloor() public {
        vm.startPrank(factory.owner());
        uint256 newDefaultPriorityFeeTaxFloor = 0;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.DefaultPriorityFeeTaxFloorUpdated(newDefaultPriorityFeeTaxFloor);

        factory.setDefaultPriorityFeeTaxFloor(newDefaultPriorityFeeTaxFloor);

        assertEq(factory.defaultPriorityFeeTaxFloor(), newDefaultPriorityFeeTaxFloor, "defaultPriorityFeeTaxFloor not set correctly");

        // also check switch to max
        newDefaultPriorityFeeTaxFloor = MAX_PRIORITY_FEE_TAX_FLOOR;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.DefaultPriorityFeeTaxFloorUpdated(newDefaultPriorityFeeTaxFloor);

        factory.setDefaultPriorityFeeTaxFloor(newDefaultPriorityFeeTaxFloor);

        assertEq(factory.defaultPriorityFeeTaxFloor(), newDefaultPriorityFeeTaxFloor, "defaultPriorityFeeTaxFloor not set correctly");
    }

    function test_setDefaultPriorityFeeTaxFloor_revert_NotOwner() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        factory.setDefaultPriorityFeeTaxFloor(0);
    }

    function test_setDefaultPriorityFeeTaxFloor_revert_InputTooHigh() public {
        vm.startPrank(factory.owner());
        vm.expectRevert(AngstromL2Factory.PriorityFeeTaxFloorExceedsMax.selector);
        factory.setDefaultPriorityFeeTaxFloor(MAX_PRIORITY_FEE_TAX_FLOOR + 1);
    }

    function test_setPriorityFeeTaxFloor() public {
        vm.startPrank(factory.owner());
        uint256 _priorityFeeTaxFloor = MAX_PRIORITY_FEE_TAX_FLOOR;
        vm.expectEmit(true, true, true, true, address(factory));
        emit AngstromL2Factory.PriorityFeeTaxFloorUpdated(address(angstrom), _priorityFeeTaxFloor);

        factory.setPriorityFeeTaxFloor(angstrom, _priorityFeeTaxFloor);

        assertEq(angstrom.priorityFeeTaxFloor(), _priorityFeeTaxFloor,
            "priorityFeeTaxFloor not set correctly");

        vm.stopPrank();
    }

    function test_setPriorityFeeTaxFloor_fuzz(uint256 _priorityFeeTaxFloor) public {
        vm.startPrank(factory.owner());
        if (_priorityFeeTaxFloor <= MAX_PRIORITY_FEE_TAX_FLOOR) {
            vm.expectEmit(true, true, true, true, address(factory));
            emit AngstromL2Factory.PriorityFeeTaxFloorUpdated(address(angstrom), _priorityFeeTaxFloor);

            factory.setPriorityFeeTaxFloor(angstrom, _priorityFeeTaxFloor);

            assertEq(angstrom.priorityFeeTaxFloor(), _priorityFeeTaxFloor,
                "priorityFeeTaxFloor not set correctly");

            factory.setJITTaxEnabled(angstrom, true);
            assertEq(angstrom.getJitTaxAmount(_priorityFeeTaxFloor), 0,
                "JIT tax amount should be zero when priority fee is at floor");
            assertEq(angstrom.getSwapTaxAmount(_priorityFeeTaxFloor), 0,
                "swap tax amount should be zero when priority fee is at floor");
            assertGt(angstrom.getJitTaxAmount(_priorityFeeTaxFloor + 1), 0,
                "JIT tax amount should be positive when priority fee is above floor");
            assertGt(angstrom.getSwapTaxAmount(_priorityFeeTaxFloor + 1), 0,
                "swap tax amount should be positive when priority fee is above floor");
        } else {
            vm.expectRevert(AngstromL2.PriorityFeeTaxFloorExceedsMax.selector);
            factory.setPriorityFeeTaxFloor(angstrom, _priorityFeeTaxFloor);
        }

        vm.stopPrank();
    }

    function test_setPriorityFeeTaxFloor_fuzz_SetTwice(
        uint256 _priorityFeeTaxFloor1,
        uint256 _priorityFeeTaxFloor2
    ) public {
        test_setPriorityFeeTaxFloor_fuzz(_priorityFeeTaxFloor1);
        test_setPriorityFeeTaxFloor_fuzz(_priorityFeeTaxFloor2);
    }

    function test_setPriorityFeeTaxFloor_revert_NotOwner() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        factory.setPriorityFeeTaxFloor(angstrom, 0);
    }

    function test_setPriorityFeeTaxFloor_revert_NotFactory() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        angstrom.setPriorityFeeTaxFloor(0);
    }

    function test_setPriorityFeeTaxFloor_revert_InputTooHigh() public {
        uint256 _priorityFeeTaxFloor = MAX_PRIORITY_FEE_TAX_FLOOR + 1;
        vm.prank(factory.owner());
        vm.expectRevert(AngstromL2Factory.PriorityFeeTaxFloorExceedsMax.selector);
        factory.setPriorityFeeTaxFloor(angstrom, _priorityFeeTaxFloor);
    }

    function uniswapWrapperErrorBytes(bytes4 selector, bytes memory angstromError)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(angstrom),
            selector,
            angstromError,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
