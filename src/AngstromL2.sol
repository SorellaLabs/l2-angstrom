// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {UniConsumer} from "./modules/UniConsumer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {IAngstromL2Hook} from "./interfaces/IAngstromL2Hook.sol";
import {IUniV4, IPoolManager, PoolId} from "./interfaces/IUniV4.sol";
import {TickIteratorLib, TickIteratorUp, TickIteratorDown} from "./libraries/TickIterator.sol";
import {
    PoolKey,
    IBeforeSwapHook,
    IAfterSwapHook,
    IAfterAddLiquidityHook,
    IAfterRemoveLiquidityHook,
    IBeforeInitializeHook
} from "./interfaces/IHooks.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks, IHooks} from "v4-core/src/libraries/Hooks.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {MixedSignLib} from "./libraries/MixedSignLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {Q96MathLib} from "./libraries/Q96MathLib.sol";
import {CompensationPriceFinder} from "./libraries/CompensationPriceFinder.sol";
import {PoolRewards, PoolRewardsLib} from "./types/PoolRewards.sol";
import {PoolKeyHelperLib} from "./libraries/PoolKeyHelperLib.sol";
import {getRequiredHookPermissions} from "src/hook-config.sol";
import {tuint256, tbytes32} from "transient-goodies/TransientPrimitives.sol";
import {ReentrancyGuard} from "transient-goodies/ReentrancyGuard.sol";

struct PoolFeeConfiguration {
    bool isInitialized;
    uint24 creatorTaxFeeE6;
    uint24 protocolTaxFeeE6;
    uint24 creatorSwapFeeE6;
    uint24 protocolSwapFeeE6;
}

/// @author philogy <https://github.com/philogy>
contract AngstromL2 is
    UniConsumer,
    Ownable,
    ReentrancyGuard,
    IBeforeInitializeHook,
    IBeforeSwapHook,
    IAfterSwapHook,
    IAfterAddLiquidityHook,
    IAfterRemoveLiquidityHook,
    IAngstromL2Hook
{
    using IUniV4 for IPoolManager;
    using PoolKeyHelperLib for PoolKey;
    using Hooks for IHooks;
    using MixedSignLib for *;
    using FixedPointMathLib for *;
    using Q96MathLib for uint256;
    using SafeCastLib for *;

    error CreatorFeeExceedsMaximum();
    error IncompatiblePoolConfiguration();
    error HooksMismatch();
    error PoolNotInitialized();
    error PoolAlreadyInitialized();
    error TotalFeeAboveOneHundredPercent();
    error SwapMEVTaxFactorExceedsMax();
    error PriorityFeeTaxFloorExceedsMax();

    // @notice Emitted when `rewards[poolId].globalGrowthX128` increases by `growthX128`
    event GlobalGrowthX128Increased(PoolId indexed poolId, uint256 growthX128);
    // @notice Emitted when `rewards[.poolId].rewardGrowthOutsideX128[tick]` increases by `growthX128`
    event GrowthOutsideX128Increased(PoolId indexed poolId, int24 tick, uint256 growthX128);
    // @notice Emitted when `amount` of `feeCurrency` is taken for the pool creator, as fee on `poolId`
    event CreatorFeeDistributed(PoolId indexed poolId, Currency indexed feeCurrency, uint256 amount);
    // @notice Emitted when `amount` of `feeCurrency` is taken for the protocol, as fee on `poolId`
    event ProtocolFeeDistributed(PoolId indexed poolId, Currency indexed feeCurrency, uint256 amount);
    // @notice Emitted when `amount` of native currency is taken for the pool LPs, as tax on `poolId`
    event LPTaxDistributed(PoolId indexed poolId, uint256 amount);
    // @notice Emitted when `amount` of native currency is taken for the pool creator, as tax on `poolId`
    event CreatorTaxDistributed(PoolId indexed poolId, uint256 amount);
    // @notice Emitted when `amount` of native currency is taken for the protocol, as tax on `poolId`, during a swap
    event ProtocolSwapTaxDistributed(PoolId indexed poolId, uint256 amount);
    /// @notice Emitted when `amount` of native currency is taken for the protocol, as tax on `poolId`,
    /// during adding or removing liquidity
    event ProtocolJITTaxDistributed(PoolId indexed poolId, uint256 amount);
    // @notice Emitted when this contract enters withdraw-only mode
    event WithdrawOnlyModeActivated();
    // @notice Emitted when `amount` of `currency` is withdrawn to `to` from accrued creator revenue
    event CreatorRevenueWithdrawn(Currency indexed currency, address indexed to, uint256 amount);

    /// @dev The `TAXED_GAS` is the abstract estimated gas cost for a swap or liquidity modification.
    /// We want it to be a constant so that competing searchers have a bid cost independent of how much gas swap
    /// actually uses, the overall tax just needs to scale proportional to `priority_fee * swap_fixed_cost`.
    uint256 internal constant TAXED_GAS = 100_000;
    uint256 internal constant MAX_SWAP_MEV_TAX_FACTOR = 9999;
    uint256 internal constant NATIVE_CURRENCY_ID = 0;
    Currency internal constant NATIVE_CURRENCY = CurrencyLibrary.ADDRESS_ZERO;
    uint256 internal constant FACTOR_E6 = 1e6;
    uint256 internal constant MAX_CREATOR_SWAP_FEE_E6 = 0.2e6;
    uint256 internal constant MAX_CREATOR_TAX_FEE_E6 = 0.5e6; // 50%
    uint256 internal constant MAX_PRIORITY_FEE_TAX_FLOOR = 100 gwei;

    address public immutable FACTORY;

    mapping(PoolId id => PoolRewards) internal rewards;

    bool internal _cachedWithdrawOnly = false;

    mapping(PoolId id => PoolFeeConfiguration) internal _poolFeeConfiguration;

    tuint256 internal liquidityBeforeSwap;
    tuint256 internal swapFee;
    tbytes32 internal slot0BeforeSwapStore;

    PoolKey[] public poolKeys;

    /// @dev MEV tax charged is `priority_fee * swapMEVTaxFactor` meaning the tax rate is
    /// `swapMEVTaxFactor / (swapMEVTaxFactor + 1)`
    uint256 public swapMEVTaxFactor;
    /// @dev Swaps and liquidity modifications with priority fees at or below this value pay no tax
    uint256 public priorityFeeTaxFloor;
    /// @notice Whether or not the JIT tax is currently charged by this contract
    bool public jitTaxEnabled;

    // Ownable explicit constructor commented out because of weird foundry bug causing
    // "modifier-style base constructor call without arguments": https://github.com/foundry-rs/foundry/issues/11607.
    constructor(IPoolManager uniV4, address owner) UniConsumer(uniV4) /* Ownable() */  {
        _initializeOwner(owner);
        FACTORY = msg.sender;
        Hooks.validateHookPermissions(IHooks(address(this)), getRequiredHookPermissions());
    }

    receive() external payable {}

    function pullWithdrawOnly() public {
        bool _withdrawOnly = IFactory(FACTORY).withdrawOnly();
        if (_cachedWithdrawOnly != _withdrawOnly) {
            emit WithdrawOnlyModeActivated();
            _cachedWithdrawOnly = _withdrawOnly;
        }
    }

    function withdrawCreatorRevenue(Currency currency, address to, uint256 amount) public {
        _checkOwner();
        emit CreatorRevenueWithdrawn(currency, to, amount);
        currency.transfer(to, amount);
    }

    function setSwapMEVTaxFactor(uint256 newSwapMEVTaxFactor) public {
        _checkCallerIsFactory();
        if (newSwapMEVTaxFactor > MAX_SWAP_MEV_TAX_FACTOR) revert SwapMEVTaxFactorExceedsMax();
        swapMEVTaxFactor = newSwapMEVTaxFactor;
    }

    function setJITTaxEnabled(bool newStatus) public {
        _checkCallerIsFactory();
        jitTaxEnabled = newStatus;
    }

    function setPriorityFeeTaxFloor(uint256 _priorityFeeTaxFloor) public {
        _checkCallerIsFactory();
        if (_priorityFeeTaxFloor > MAX_PRIORITY_FEE_TAX_FLOOR) revert PriorityFeeTaxFloorExceedsMax();
        priorityFeeTaxFloor = _priorityFeeTaxFloor;
    }

    function setProtocolSwapFee(PoolKey calldata key, uint256 newFeeE6) public {
        _checkCallerIsFactory();
        PoolFeeConfiguration storage feeConfiguration = _poolFeeConfiguration[key.calldataToId()];
        if (!feeConfiguration.isInitialized) revert PoolNotInitialized();
        feeConfiguration.protocolSwapFeeE6 = newFeeE6.toUint24();
        _checkFeeConfiguration(feeConfiguration);
    }

    function setProtocolTaxFee(PoolKey calldata key, uint256 newFeeE6) public {
        _checkCallerIsFactory();
        PoolFeeConfiguration storage feeConfiguration = _poolFeeConfiguration[key.calldataToId()];
        if (!feeConfiguration.isInitialized) revert PoolNotInitialized();
        feeConfiguration.protocolTaxFeeE6 = newFeeE6.toUint24();
        _checkFeeConfiguration(feeConfiguration);
    }

    function getSwapTaxAmount(uint256 priorityFee) public view returns (uint256) {
        if (priorityFee <= priorityFeeTaxFloor) {
            return 0;
        }
        return swapMEVTaxFactor * TAXED_GAS * (priorityFee - priorityFeeTaxFloor);
    }

    function getJitTaxAmount(uint256 priorityFee) public view returns (uint256) {
        if (!jitTaxEnabled) {
            return 0;
        }
        if (priorityFee <= priorityFeeTaxFloor) {
            return 0;
        }
        return jitMEVTaxFactor() * TAXED_GAS * (priorityFee - priorityFeeTaxFloor);
    }

    /// @dev Slightly higher LP JIT liquidity tax to encourage it to be lower in the block.
    function jitMEVTaxFactor() public view returns (uint256) {
        return swapMEVTaxFactor * 3 / 2;
    }

    function getPendingPositionRewards(
        PoolKey calldata key,
        address owner,
        int24 lowerTick,
        int24 upperTick,
        bytes32 salt
    ) public view returns (uint256 rewards0) {
        PoolId id = key.calldataToId();
        rewards0 =
            rewards[id].getPendingPositionRewards(UNI_V4, id, owner, lowerTick, upperTick, salt);
    }

    function getPoolFeeConfiguration(PoolKey calldata key)
        public
        view
        returns (PoolFeeConfiguration memory)
    {
        return _poolFeeConfiguration[key.calldataToId()];
    }

    function initializeNewPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) public {
        if (!(msg.sender == owner() || msg.sender == FACTORY)) {
            revert Unauthorized();
        }
        if (key.hooks != IHooks(address(this))) {
            revert HooksMismatch();
        }
        if (key.currency0.toId() != NATIVE_CURRENCY_ID) revert IncompatiblePoolConfiguration();
        if (LPFeeLibrary.isDynamicFee(key.fee)) revert IncompatiblePoolConfiguration();
        PoolFeeConfiguration storage feeConfiguration = _poolFeeConfiguration[key.calldataToId()];
        if (feeConfiguration.isInitialized) revert PoolAlreadyInitialized();
        if (!(creatorSwapFeeE6 <= MAX_CREATOR_SWAP_FEE_E6)) revert CreatorFeeExceedsMaximum();
        if (!(creatorTaxFeeE6 <= MAX_CREATOR_TAX_FEE_E6)) revert CreatorFeeExceedsMaximum();
        feeConfiguration.isInitialized = true;
        UNI_V4.initialize(key, sqrtPriceX96);
        feeConfiguration.creatorSwapFeeE6 = creatorSwapFeeE6.toUint24();
        feeConfiguration.creatorTaxFeeE6 = creatorTaxFeeE6.toUint24();
        (feeConfiguration.protocolSwapFeeE6, feeConfiguration.protocolTaxFeeE6) =
            IFactory(FACTORY)
                .recordPoolCreationAndGetStartingProtocolFee(key, creatorSwapFeeE6, creatorTaxFeeE6);
        _checkFeeConfiguration(feeConfiguration);

        poolKeys.push(key);
    }

    function _checkFeeConfiguration(PoolFeeConfiguration storage feeConfiguration) internal view {
        if (!(feeConfiguration.creatorSwapFeeE6 + feeConfiguration.protocolSwapFeeE6 <= FACTOR_E6))
        {
            revert TotalFeeAboveOneHundredPercent();
        }
        if (!(feeConfiguration.creatorTaxFeeE6 + feeConfiguration.protocolTaxFeeE6 <= FACTOR_E6)) {
            revert TotalFeeAboveOneHundredPercent();
        }
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert Unauthorized();
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external nonReentrant returns (bytes4, BalanceDelta) {
        _onlyUniV4();

        if (_cachedWithdrawOnly) revert IFactory.WithdrawOnlyMode();

        PoolId id = key.calldataToId();
        rewards[id].updateAfterLiquidityAdd(UNI_V4, id, sender, params);
        uint256 taxAmountInEther = _getJitTaxAmount();
        if (taxAmountInEther > 0) {
            // Protocol collects 100% of the JIT MEV tax
            emit ProtocolJITTaxDistributed(id, taxAmountInEther);
            UNI_V4.take(NATIVE_CURRENCY, FACTORY, taxAmountInEther);
        }
        return (this.afterAddLiquidity.selector, toBalanceDelta(taxAmountInEther.toInt128(), 0));
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external nonReentrant returns (bytes4, BalanceDelta) {
        _onlyUniV4();

        if (_cachedWithdrawOnly) return (this.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));

        PoolId id = key.calldataToId();
        uint256 rewardAmount0 = rewards[id].updateAfterLiquidityRemove(UNI_V4, id, sender, params);
        uint256 taxAmountInEther = params.liquidityDelta == 0 ? 0 : _getJitTaxAmount();
        if (taxAmountInEther > 0) {
            // Protocol collects 100% of the JIT MEV tax
            emit ProtocolJITTaxDistributed(id, taxAmountInEther);
            UNI_V4.take(NATIVE_CURRENCY, FACTORY, taxAmountInEther);
        }
        if (rewardAmount0 > 0) {
            UNI_V4.burn(address(this), NATIVE_CURRENCY_ID, rewardAmount0);
        }
        return (
            this.afterRemoveLiquidity.selector,
            toBalanceDelta(taxAmountInEther.toInt128() - rewardAmount0.toInt128(), 0)
        );
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyUniV4();
        if (_cachedWithdrawOnly) revert IFactory.WithdrawOnlyMode();

        PoolId id = key.calldataToId();
        slot0BeforeSwapStore.set(Slot0.unwrap(UNI_V4.getSlot0(id)));
        liquidityBeforeSwap.set(UNI_V4.getPoolLiquidity(id));

        int128 swapTax = _getSwapTaxAmount().toInt128();
        bool exactIn = params.amountSpecified < 0;
        bool etherIsInput = params.zeroForOne;

        PoolFeeConfiguration storage feeConfiguration = _poolFeeConfiguration[id];
        uint256 totalSwapFeeRateE6 =
            feeConfiguration.protocolSwapFeeE6 + feeConfiguration.creatorSwapFeeE6;

        // For exactIn, compute fee on input amount (minus tax if ETH input)
        uint256 feeAmount = 0;
        if (exactIn) {
            uint256 inputAmount = params.amountSpecified.abs();
            if (etherIsInput) inputAmount -= uint256(int256(swapTax));
            feeAmount = inputAmount * totalSwapFeeRateE6 / FACTOR_E6;
        }
        swapFee.set(feeAmount);

        // Tax always comes from ETH; swap fee comes from specified currency for exactIn.
        // For exactOut swapFee is calculated in the `afterSwap` hook)
        BeforeSwapDelta delta;
        if (etherIsInput && exactIn) {
            delta = toBeforeSwapDelta(swapTax + feeAmount.toInt128(), 0);
        } else if (!etherIsInput && !exactIn) {
            delta = toBeforeSwapDelta(swapTax, 0);
        } else {
            delta = toBeforeSwapDelta(feeAmount.toInt128(), swapTax);
        }

        return (this.beforeSwap.selector, delta, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) external override nonReentrant returns (bytes4, int128 hookDeltaUnspecified) {
        _onlyUniV4();

        PoolId id = key.calldataToId();
        (uint256 feeInUnspecified, uint256 lpCompensationAmount) =
            _computeAndCollectProtocolSwapFee(key, id, params, swapDelta, _getSwapTaxAmount());
        hookDeltaUnspecified = feeInUnspecified.toInt128();

        PoolKey calldata key_ = key;
        Slot0 slot0BeforeSwap = Slot0.wrap(slot0BeforeSwapStore.get());
        Slot0 slot0AfterSwap = UNI_V4.getSlot0(id);
        rewards[id].updateAfterTickMove(
            id, UNI_V4, slot0BeforeSwap.tick(), slot0AfterSwap.tick(), key_.tickSpacing
        );

        if (lpCompensationAmount == 0) {
            return (this.afterSwap.selector, hookDeltaUnspecified);
        }

        if (params.zeroForOne) {
            _zeroForOneDistributeTax(
                id, key_.tickSpacing, slot0BeforeSwap, slot0AfterSwap, lpCompensationAmount
            );
        } else {
            _oneForZeroDistributeTax(
                id, key_.tickSpacing, slot0BeforeSwap, slot0AfterSwap, lpCompensationAmount
            );
        }

        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    function _computeAndCollectProtocolSwapFee(
        PoolKey calldata key,
        PoolId id,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        uint256 totalTaxInEther
    ) internal returns (uint256 exactOutFeeInUnspecified, uint256 lpCompensationAmountInEther) {
        PoolFeeConfiguration storage feeConfiguration = _poolFeeConfiguration[id];
        uint256 totalSwapFeeRateE6 =
            feeConfiguration.protocolSwapFeeE6 + feeConfiguration.creatorSwapFeeE6;

        bool exactIn = params.amountSpecified < 0;

        // Compute total fee amount
        uint256 totalFeeAmount = 0;
        if (totalSwapFeeRateE6 != 0) {
            if (exactIn) {
                // For exactIn, fee was pre-computed in beforeSwap
                totalFeeAmount = swapFee.get();
            } else {
                // For exactOut, compute fee on unspecified (input) amount
                int128 unspecifiedDelta =
                    params.zeroForOne ? swapDelta.amount0() : swapDelta.amount1();
                uint256 absAmount = unspecifiedDelta.abs();
                totalFeeAmount = absAmount * totalSwapFeeRateE6 / (FACTOR_E6 - totalSwapFeeRateE6);
                exactOutFeeInUnspecified = totalFeeAmount;
            }
        }

        // Split fee between creator and protocol
        uint256 creatorSwapFeeAmount = totalSwapFeeRateE6 != 0
            ? totalFeeAmount * feeConfiguration.creatorSwapFeeE6 / totalSwapFeeRateE6
            : 0;
        uint256 protocolSwapFeeAmount = totalFeeAmount - creatorSwapFeeAmount;

        Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        if (totalTaxInEther == 0) {
            emit CreatorFeeDistributed(id, feeCurrency, creatorSwapFeeAmount);
            emit ProtocolFeeDistributed(id, feeCurrency, protocolSwapFeeAmount);
            UNI_V4.take(feeCurrency, address(this), creatorSwapFeeAmount);
            UNI_V4.take(feeCurrency, FACTORY, protocolSwapFeeAmount);
            return (exactOutFeeInUnspecified, 0);
        }

        uint256 creatorTaxShareInEther =
            totalTaxInEther * feeConfiguration.creatorTaxFeeE6 / FACTOR_E6;
        uint256 protocolTaxShareInEther =
            totalTaxInEther * feeConfiguration.protocolTaxFeeE6 / FACTOR_E6;
        lpCompensationAmountInEther =
            totalTaxInEther - creatorTaxShareInEther - protocolTaxShareInEther;
        emit LPTaxDistributed(id, lpCompensationAmountInEther);
        UNI_V4.mint(address(this), NATIVE_CURRENCY_ID, lpCompensationAmountInEther);

        if (feeCurrency == NATIVE_CURRENCY) {
            emit CreatorTaxDistributed(id, creatorTaxShareInEther);
            emit ProtocolSwapTaxDistributed(id, protocolTaxShareInEther);
            emit CreatorFeeDistributed(id, NATIVE_CURRENCY, creatorSwapFeeAmount);
            emit ProtocolFeeDistributed(id, NATIVE_CURRENCY, protocolSwapFeeAmount);
            UNI_V4.take(
                NATIVE_CURRENCY, address(this), creatorSwapFeeAmount + creatorTaxShareInEther
            );
            UNI_V4.take(NATIVE_CURRENCY, FACTORY, protocolSwapFeeAmount + protocolTaxShareInEther);
        } else {
            emit CreatorTaxDistributed(id, creatorTaxShareInEther);
            emit ProtocolSwapTaxDistributed(id, protocolTaxShareInEther);
            UNI_V4.take(NATIVE_CURRENCY, address(this), creatorTaxShareInEther);
            UNI_V4.take(NATIVE_CURRENCY, FACTORY, protocolTaxShareInEther);
            emit CreatorFeeDistributed(id, feeCurrency, creatorSwapFeeAmount);
            emit ProtocolFeeDistributed(id, feeCurrency, protocolSwapFeeAmount);
            UNI_V4.take(feeCurrency, address(this), creatorSwapFeeAmount);
            UNI_V4.take(feeCurrency, FACTORY, protocolSwapFeeAmount);
        }
    }

    function _zeroForOneDistributeTax(
        PoolId id,
        int24 tickSpacing,
        Slot0 slot0BeforeSwap,
        Slot0 slot0AfterSwap,
        uint256 lpCompensationAmount
    ) internal {
        TickIteratorDown memory ticks = TickIteratorLib.initDown(
            UNI_V4, id, tickSpacing, slot0BeforeSwap.tick(), slot0AfterSwap.tick()
        );

        uint128 liquidity = liquidityBeforeSwap.get().toUint128();
        (int24 lastTick, uint160 pstarSqrtX96) = CompensationPriceFinder.getZeroForOne(
            ticks, liquidity, lpCompensationAmount, slot0BeforeSwap.sqrtPriceX96(), slot0AfterSwap
        );

        ticks.reset(slot0BeforeSwap.tick());
        _zeroForOneCreditRewards(
            ticks,
            liquidity,
            lpCompensationAmount,
            slot0BeforeSwap.sqrtPriceX96(),
            lastTick,
            pstarSqrtX96
        );
    }

    function _oneForZeroDistributeTax(
        PoolId id,
        int24 tickSpacing,
        Slot0 slot0BeforeSwap,
        Slot0 slot0AfterSwap,
        uint256 lpCompensationAmount
    ) internal {
        TickIteratorUp memory ticks = TickIteratorLib.initUp(
            UNI_V4, id, tickSpacing, slot0BeforeSwap.tick(), slot0AfterSwap.tick()
        );

        uint128 liquidity = liquidityBeforeSwap.get().toUint128();
        (int24 lastTick, uint160 pstarSqrtX96) = CompensationPriceFinder.getOneForZero(
            ticks, liquidity, lpCompensationAmount, slot0BeforeSwap.sqrtPriceX96(), slot0AfterSwap
        );

        ticks.reset(slot0BeforeSwap.tick());
        _oneForZeroCreditRewards(
            ticks,
            liquidity,
            lpCompensationAmount,
            slot0BeforeSwap.sqrtPriceX96(),
            lastTick,
            pstarSqrtX96
        );
    }

    function _zeroForOneCreditRewards(
        TickIteratorDown memory ticks,
        uint128 liquidity,
        uint256 lpCompensationAmount,
        uint160 priceUpperSqrtX96,
        int24 lastTick,
        uint160 pstarSqrtX96
    ) internal {
        uint256 pstarX96 = uint256(pstarSqrtX96).mulX96(pstarSqrtX96).max(1);
        uint256 cumulativeGrowthX128 = 0;
        uint160 priceLowerSqrtX96;

        while (ticks.hasNext()) {
            int24 tickNext = ticks.getNext();

            priceLowerSqrtX96 = max(TickMath.getSqrtPriceAtTick(tickNext), pstarSqrtX96);
            uint256 rangeReward = 0;
            if (tickNext >= lastTick && liquidity != 0) {
                uint256 delta0 = SqrtPriceMath.getAmount0Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                uint256 delta1 = SqrtPriceMath.getAmount1Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                rangeReward =
                    delta1.divX96(pstarX96).saturatingSub(delta0).min(lpCompensationAmount);

                unchecked {
                    lpCompensationAmount -= rangeReward;
                    cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(rangeReward, liquidity);
                }
            }

            unchecked {
                rewards[ticks.poolId].rewardGrowthOutsideX128[tickNext] += cumulativeGrowthX128;
            }
            emit GrowthOutsideX128Increased(ticks.poolId, tickNext, cumulativeGrowthX128);

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, tickNext);
            liquidity = liquidity.sub(liquidityNet);

            priceUpperSqrtX96 = priceLowerSqrtX96;
        }

        // Distribute remainder to last range and update global accumulator.
        unchecked {
            cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(lpCompensationAmount, liquidity);
            rewards[ticks.poolId].globalGrowthX128 += cumulativeGrowthX128;
        }
        emit GlobalGrowthX128Increased(ticks.poolId, cumulativeGrowthX128);
    }

    function _oneForZeroCreditRewards(
        TickIteratorUp memory ticks,
        uint128 liquidity,
        uint256 lpCompensationAmount,
        uint160 priceLowerSqrtX96,
        int24 lastTick,
        uint160 pstarSqrtX96
    ) internal {
        uint256 pstarX96 = uint256(pstarSqrtX96).mulX96(pstarSqrtX96).max(1);
        uint256 cumulativeGrowthX128 = 0;
        uint160 priceUpperSqrtX96;

        while (ticks.hasNext()) {
            int24 tickNext = ticks.getNext();

            priceUpperSqrtX96 = min(TickMath.getSqrtPriceAtTick(tickNext), pstarSqrtX96);

            uint256 rangeReward = 0;
            if (tickNext <= lastTick && liquidity != 0) {
                uint256 delta0 = SqrtPriceMath.getAmount0Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                uint256 delta1 = SqrtPriceMath.getAmount1Delta(
                    priceLowerSqrtX96, priceUpperSqrtX96, liquidity, false
                );
                rangeReward =
                    delta0.saturatingSub(delta1.divX96(pstarX96)).min(lpCompensationAmount);

                unchecked {
                    lpCompensationAmount -= rangeReward;
                    cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(rangeReward, liquidity);
                }
            }

            unchecked {
                rewards[ticks.poolId].rewardGrowthOutsideX128[tickNext] += cumulativeGrowthX128;
            }
            emit GrowthOutsideX128Increased(ticks.poolId, tickNext, cumulativeGrowthX128);

            (, int128 liquidityNet) = ticks.manager.getTickLiquidity(ticks.poolId, tickNext);
            liquidity = liquidity.add(liquidityNet);

            priceLowerSqrtX96 = priceUpperSqrtX96;
        }

        // Distribute remainder to last range and update global accumulator.
        unchecked {
            cumulativeGrowthX128 += PoolRewardsLib.getGrowthDelta(lpCompensationAmount, liquidity);
            rewards[ticks.poolId].globalGrowthX128 += cumulativeGrowthX128;
        }
        emit GlobalGrowthX128Increased(ticks.poolId, cumulativeGrowthX128);
    }

    function min(uint160 x, uint160 y) internal pure returns (uint160) {
        return x < y ? x : y;
    }

    function max(uint160 x, uint160 y) internal pure returns (uint160) {
        return x > y ? x : y;
    }

    function _getSwapTaxAmount() internal view returns (uint256) {
        uint256 priorityFee = tx.gasprice - block.basefee;
        return getSwapTaxAmount(priorityFee);
    }

    function _getJitTaxAmount() internal view returns (uint256) {
        uint256 priorityFee = tx.gasprice - block.basefee;
        return getJitTaxAmount(priorityFee);
    }

    function _checkCallerIsFactory() internal view {
        if (msg.sender != FACTORY) revert Unauthorized();
    }
}
