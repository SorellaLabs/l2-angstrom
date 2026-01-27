// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest} from "./_helpers/BaseTest.sol";
import {RouterActor} from "./_mocks/RouterActor.sol";
import {ReentrantERC20} from "./_mocks/ReentrantERC20.sol";
import {UniV4Inspector} from "./_mocks/UniV4Inspector.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";

import {AngstromL2Factory} from "../src/AngstromL2Factory.sol";
import {AngstromL2, ReentrancyGuard} from "../src/AngstromL2.sol";
import {POOLS_MUST_HAVE_DYNAMIC_FEE} from "../src/hook-config.sol";
import {IUniV4} from "../src/interfaces/IUniV4.sol";
import {IHookAddressMiner} from "../src/interfaces/IHookAddressMiner.sol";

import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";

/// @title ReentrancyPOC
/// @notice Proof of Concept demonstrating reentrancy vulnerability in AngstromL2's afterSwap hook
/// @dev The vulnerability: During afterSwap, when UNI_V4.take() transfers tokens, a malicious
///      token with transfer hooks (like ERC777) can reenter and execute another swap.
///      This corrupts the transient storage (liquidityBeforeSwap, slot0BeforeSwapStore)
///      that the first swap's afterSwap relies on for reward distribution.
contract ReentrancyPOCTest is BaseTest {
    using FormatLib for *;
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

    ReentrantERC20 maliciousToken;

    bool constant HUFF2_INSTALLED = true;

    function setUp() public {
        vm.roll(100);
        manager = new UniV4Inspector();
        router = new RouterActor(manager);
        vm.deal(address(manager), 1_000 ether);
        vm.deal(address(router), 100 ether);

        maliciousToken = new ReentrantERC20();
        maliciousToken.mint(address(router), 1_000_000_000e18);
        maliciousToken.mint(address(maliciousToken), 1_000_000e18);
        vm.deal(address(maliciousToken), 100 ether);

        bytes memory minerCode = HUFF2_INSTALLED
            ? getMinerCode(address(manager), false)
            : getHardcodedMinerCode(address(manager));
        IHookAddressMiner newMiner;
        assembly ("memory-safe") {
            newMiner := create(0, add(minerCode, 0x20), mload(minerCode))
        }
        require(address(newMiner) != address(0), "miner deployment failed");
        miner = newMiner;

        factory = new AngstromL2Factory(factoryOwner, manager, miner);

        vm.prank(address(factory));
        bytes32 salt = miner.mineAngstromHookAddress(hookOwner);

        angstrom = factory.deployNewHook(hookOwner, salt);
    }

    function initializePoolWithMaliciousToken(int24 tickSpacing, int24 startTick)
        internal
        returns (PoolKey memory key)
    {
        return initializePoolWithMaliciousToken(tickSpacing, startTick, 0.02e6, 0.1e6);
    }

    function initializePoolWithMaliciousToken(
        int24 tickSpacing,
        int24 startTick,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(maliciousToken)),
            fee: POOLS_MUST_HAVE_DYNAMIC_FEE ? LPFeeLibrary.DYNAMIC_FEE_FLAG : 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(angstrom))
        });

        vm.prank(hookOwner);
        angstrom.initializeNewPool(
            key, TickMath.getSqrtPriceAtTick(startTick), creatorSwapFeeE6, creatorTaxFeeE6
        );

        return key;
    }

    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityAmount
    ) internal returns (BalanceDelta delta) {
        (delta,) = router.modifyLiquidity(
            key, tickLower, tickUpper, int256(uint256(liquidityAmount)), bytes32(0)
        );
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

    /// @notice Regression test: Verify reentrancy is blocked by nonReentrant modifier
    /// @dev Originally this attack corrupted reward accounting via double-tick-cross.
    ///      The fix adds nonReentrant modifiers to beforeSwap/afterSwap hooks.
    ///      This test verifies the fix prevents the attack using oneForZero swaps
    ///      where fees are collected in the malicious token, triggering the attack.
    function test_reentrancy_blocked_by_guard() public {
        // === SETUP ===
        // Start at tick -5 so we have room to swap oneForZero (price goes up)
        // Use non-zero swap fee to ensure token fees are collected
        PoolKey memory key = initializePoolWithMaliciousToken(10, -5, 0.02e6, 0);

        addLiquidity(key, -10, 0, 10_000e18);
        addLiquidity(key, 0, 10, 10_000e18);

        console.log("=== REENTRANCY GUARD TEST (oneForZero swaps) ===");
        console.log("Position A: [-10, 0]");
        console.log("Position B: [0, 10]");
        console.log("Using oneForZero swaps where token fees trigger reentrancy");
        console.log("");

        // === STEP 1: Accumulate rewards ===
        console.log("=== STEP 1: Accumulate rewards ===");

        setPriorityFee(10 gwei);
        uint256 taxPerSwap = angstrom.getSwapTaxAmount(10 gwei);
        console.log("Tax per swap (10 gwei priority):", taxPerSwap);

        // Do some swaps to accumulate rewards (alternating directions)
        for (uint256 i = 0; i < 6; i++) {
            if (i % 2 == 0) {
                router.swap(key, true, -1 ether, int24(-8).getSqrtPriceAtTick());
            } else {
                router.swap(key, false, -1 ether, int24(-2).getSqrtPriceAtTick());
            }
        }

        uint256 rewardsA_beforeClaim = getRewards(key, -10, 0);
        uint256 rewardsB_beforeClaim = getRewards(key, 0, 10);

        console.log("");
        console.log("After accumulation:");
        console.log("  Position A [-10,0] claimable:", rewardsA_beforeClaim);
        console.log("  Position B [0,10] claimable:", rewardsB_beforeClaim);

        // === STEP 2: Claim rewards from Position A ===
        console.log("");
        console.log("=== STEP 2: Claim rewards from Position A ===");

        uint256 balanceBefore = address(router).balance;
        router.modifyLiquidity(key, -10, 0, 0, bytes32(0));
        uint256 balanceAfter = address(router).balance;
        uint256 claimedFromA = balanceAfter - balanceBefore;

        console.log("  Claimed from Position A:", claimedFromA);

        uint256 rewardsA_afterClaim = getRewards(key, -10, 0);
        uint256 rewardsB_afterClaim = getRewards(key, 0, 10);

        console.log("  Position A [-10,0] claimable after:", rewardsA_afterClaim);
        console.log("  Position B [0,10] claimable after:", rewardsB_afterClaim);

        // === STEP 3: Attempt reentrancy attack - should be blocked ===
        console.log("");
        console.log("=== STEP 3: Attempt reentrancy attack (should be blocked) ===");
        console.log("  Using oneForZero swap (Token->ETH) so fees are in malicious token");

        bumpBlock();
        maliciousToken.setAttackParams(manager, key, 1);
        // Inner swap: also oneForZero to attempt reentrancy
        maliciousToken.setSwapConfig(false, -1 ether);
        maliciousToken.enableAttack();

        // Outer swap: oneForZero (token in, ETH out)
        // Fee currency = token (currency1) = malicious token
        // This triggers maliciousToken.transfer() during fee collection
        // Which attempts to reenter with another swap
        // nonReentrant modifier should catch this
        // Note: UniswapV4 wraps the Reentering() error in WrappedError, so we just check it reverts
        vm.expectRevert();
        router.swap(key, false, -1 ether, int24(2).getSqrtPriceAtTick());

        console.log("  Reentrancy attack was blocked by nonReentrant modifier");

        // === STEP 4: Verify state is NOT corrupted ===
        console.log("");
        console.log("=== STEP 4: Verify state integrity ===");

        uint256 rewardsA_afterAttack = getRewards(key, -10, 0);
        uint256 rewardsB_afterAttack = getRewards(key, 0, 10);

        console.log("  Position A [-10,0] claimable:", rewardsA_afterAttack);
        console.log("  Position B [0,10] claimable:", rewardsB_afterAttack);

        assertEq(rewardsA_afterAttack, rewardsA_afterClaim, "A rewards should be unchanged");
        assertEq(rewardsB_afterAttack, rewardsB_afterClaim, "B rewards should be unchanged");

        console.log("");
        console.log("========================================");
        console.log("=== FIX VERIFICATION PASSED ===");
        console.log("========================================");
        console.log("Reentrancy blocked, reward accounting intact");
    }
}
