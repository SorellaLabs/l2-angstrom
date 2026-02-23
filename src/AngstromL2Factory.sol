// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {IPoolManager, PoolId} from "./interfaces/IUniV4.sol";
import {AngstromL2} from "./AngstromL2.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {IHookAddressMiner} from "./interfaces/IHookAddressMiner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

contract AngstromL2Factory is Ownable, IFactory {
    using SafeCastLib for *;

    error ProtocolFeeExceedsMaximum();
    error SwapMEVTaxFactorExceedsMax();
    error PriorityFeeTaxFloorExceedsMax();
    error NotVerifiedHook();
    error FlashBlockNumberProviderAlreadySet();

    event DefaultProtocolSwapFeeE6Updated(uint24 newDefaultProtocolSwapFeeE6);
    event DefaultProtocolTaxFeeE6Updated(uint24 newDefaultProtocolTaxFeeE6);
    event DefaultSwapMEVTaxFactorUpdated(uint256 newDefaultSwapMEVTaxFactor);
    event DefaultJITTaxStatusUpdated(bool newDefaultJITTaxEnabled);
    event DefaultPriorityFeeTaxFloorUpdated(uint256 newDefaultPriorityFeeTaxFloor);
    event ProtocolSwapFeeUpdated(address indexed hook, PoolKey key, uint256 newFeeE6);
    event ProtocolTaxFeeUpdated(address indexed hook, PoolKey key, uint256 newFeeE6);
    event SwapMEVTaxFactorUpdated(address indexed hook, uint256 newSwapMEVTaxFactor);
    event JITTaxStatusUpdated(address indexed hook, bool newJITTaxEnabled);
    event PriorityFeeTaxFloorUpdated(address indexed hook, uint256 newPriorityFeeTaxFloor);
    event PoolCreated(
        address hook,
        PoolKey key,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6,
        uint24 protocolSwapFeeE6,
        uint24 protocolTaxFeeE6
    );
    event WithdrawOnly();
    event ProtocolRevenueWithdrawn(Currency indexed currency, address indexed to, uint256 amount);

    IPoolManager public immutable UNI_V4;
    IHookAddressMiner public immutable HOOK_ADDRESS_MINER;
    /// @dev Separate address to store init code of hook contract to enable factory to be within
    /// code size limit.
    address public immutable HOOK_INITCODE_STORE;
    bool public override withdrawOnly;
    /// @dev Default protocol swap fee to be used for new pools, as a multiple of the final resulting swap fee (`defaultProtocolSwapFeeE6 = f_pr / (1 - (1 - f_lp) * (1 - (f_cr + f_pr)))`).
    uint24 public defaultProtocolSwapFeeAsMultipleE6;
    /// @dev Protocol fee on MEV tax from ToB swap.
    uint24 public defaultProtocolTaxFeeE6;
    /// @dev Whether or not the JIT tax is configured by default to be charged by new hooks
    bool public defaultJITTaxEnabled;
    /// @dev Value of `swapMEVTaxFactor` set on newly-deployed hooks
    uint256 public defaultSwapMEVTaxFactor;
    /// @dev Value of `priorityFeeTaxFloor` set on newly-deployed hooks
    uint256 public defaultPriorityFeeTaxFloor;

    mapping(AngstromL2 hook => bool verified) public isVerifiedHook;

    uint256 internal constant FACTOR_E6 = 1e6;
    uint24 internal constant MAX_DEFAULT_PROTOCOL_FEE_MULTIPLE_E6 = 1e6 - 1; // -1 to avoid division by zero error in extreme cases
    uint24 internal constant MAX_PROTOCOL_SWAP_FEE_E6 = 0.05e6;
    uint24 internal constant MAX_PROTOCOL_TAX_FEE_E6 = 0.75e6;
    uint256 internal constant MAX_SWAP_MEV_TAX_FACTOR = 9999;
    uint256 internal constant MAX_PRIORITY_FEE_TAX_FLOOR = 100 gwei;

    AngstromL2[] public allHooks;
    mapping(PoolId id => AngstromL2 hook) public hookPoolIds;

    // Ownable explicit constructor commented out because of weird foundry bug causing
    // "modifier-style base constructor call without arguments": https://github.com/foundry-rs/foundry/issues/11607.
    constructor(address owner, IPoolManager uniV4, IHookAddressMiner hookAddressMiner) {
        _initializeOwner(owner);
        UNI_V4 = uniV4;
        HOOK_ADDRESS_MINER = hookAddressMiner;
        HOOK_INITCODE_STORE = SSTORE2.write(type(AngstromL2).creationCode);
        withdrawOnly = false;
    }

    receive() external payable {}

    function withdrawRevenue(Currency currency, address to, uint256 amount) public {
        _checkOwner();
        emit ProtocolRevenueWithdrawn(currency, to, amount);
        currency.transfer(to, amount);
    }

    /// @dev Allows hooks to go into withdraw only mode, note this effectively deletes all liquidity
    /// provider's rewards. Only to be used in case of serious emergency.
    function setEmergencyWithdrawOnly() public {
        _checkOwner();
        withdrawOnly = true;
        emit WithdrawOnly();
    }

    function setDefaultProtocolSwapFeeMultiple(uint24 newDefaultProtocolSwapFeeE6) public {
        _checkOwner();
        if (!(newDefaultProtocolSwapFeeE6 <= MAX_DEFAULT_PROTOCOL_FEE_MULTIPLE_E6)) {
            revert ProtocolFeeExceedsMaximum();
        }
        defaultProtocolSwapFeeAsMultipleE6 = newDefaultProtocolSwapFeeE6;
        emit DefaultProtocolSwapFeeE6Updated(newDefaultProtocolSwapFeeE6);
    }

    function setDefaultProtocolTaxFee(uint24 newDefaultProtocolTaxFeeE6) public {
        _checkOwner();
        if (!(newDefaultProtocolTaxFeeE6 <= MAX_PROTOCOL_TAX_FEE_E6)) {
            revert ProtocolFeeExceedsMaximum();
        }
        defaultProtocolTaxFeeE6 = newDefaultProtocolTaxFeeE6;
        emit DefaultProtocolTaxFeeE6Updated(newDefaultProtocolTaxFeeE6);
    }

    function setDefaultSwapMEVTaxFactor(uint256 newDefaultSwapMEVTaxFactor) public {
        _checkOwner();
        if (newDefaultSwapMEVTaxFactor > MAX_SWAP_MEV_TAX_FACTOR) revert SwapMEVTaxFactorExceedsMax();
        defaultSwapMEVTaxFactor = newDefaultSwapMEVTaxFactor;
        emit DefaultSwapMEVTaxFactorUpdated(newDefaultSwapMEVTaxFactor);
    }

    function setDefaultJITTaxEnabled(bool newDefaultJITTaxEnabled) public {
        _checkOwner();
        defaultJITTaxEnabled = newDefaultJITTaxEnabled;
        emit DefaultJITTaxStatusUpdated(newDefaultJITTaxEnabled);
    }

    function setDefaultPriorityFeeTaxFloor(uint256 newDefaultPriorityFeeTaxFloor) public {
        _checkOwner();
        if (newDefaultPriorityFeeTaxFloor > MAX_PRIORITY_FEE_TAX_FLOOR) revert PriorityFeeTaxFloorExceedsMax();
        defaultPriorityFeeTaxFloor = newDefaultPriorityFeeTaxFloor;
        emit DefaultPriorityFeeTaxFloorUpdated(newDefaultPriorityFeeTaxFloor);
    }

    function setProtocolSwapFee(AngstromL2 hook, PoolKey calldata key, uint256 newFeeE6) public {
        _checkOwner();
        if (!(newFeeE6 <= MAX_PROTOCOL_SWAP_FEE_E6)) {
            revert ProtocolFeeExceedsMaximum();
        }
        hook.setProtocolSwapFee(key, newFeeE6);
        emit ProtocolSwapFeeUpdated(address(hook), key, newFeeE6);
    }

    function setProtocolTaxFee(AngstromL2 hook, PoolKey calldata key, uint256 newFeeE6) public {
        _checkOwner();
        if (!(newFeeE6 <= MAX_PROTOCOL_TAX_FEE_E6)) {
            revert ProtocolFeeExceedsMaximum();
        }
        hook.setProtocolTaxFee(key, newFeeE6);
        emit ProtocolTaxFeeUpdated(address(hook), key, newFeeE6);
    }

    function setSwapMEVTaxFactor(AngstromL2 hook, uint256 newSwapMEVTaxFactor) public {
        _checkOwner();
        if (newSwapMEVTaxFactor > MAX_SWAP_MEV_TAX_FACTOR) revert SwapMEVTaxFactorExceedsMax();
        hook.setSwapMEVTaxFactor(newSwapMEVTaxFactor);
        emit SwapMEVTaxFactorUpdated(address(hook), newSwapMEVTaxFactor);
    }

    function setJITTaxEnabled(AngstromL2 hook, bool newJITTaxEnabled) public {
        _checkOwner();
        hook.setJITTaxEnabled(newJITTaxEnabled);
        emit JITTaxStatusUpdated(address(hook), newJITTaxEnabled);
    }

    function setPriorityFeeTaxFloor(AngstromL2 hook, uint256 newPriorityFeeTaxFloor) public {
        _checkOwner();
        if (newPriorityFeeTaxFloor > MAX_PRIORITY_FEE_TAX_FLOOR) revert PriorityFeeTaxFloorExceedsMax();
        hook.setPriorityFeeTaxFloor(newPriorityFeeTaxFloor);
        emit PriorityFeeTaxFloorUpdated(address(hook), newPriorityFeeTaxFloor);
    }

    /// @dev Only one hook per block per owner can be created using this method.
    /// As the HOOK_ADDRESS_MINER uses the block number and initialOwner as part of the salt
    function createNewHookAndPoolWithMiner(
        address initialOwner,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) public returns (AngstromL2 newAngstrom) {
        bytes32 salt = HOOK_ADDRESS_MINER.mineAngstromHookAddress(initialOwner);
        newAngstrom = deployNewHook(initialOwner, salt);
        key.hooks = IHooks(address(newAngstrom));
        newAngstrom.initializeNewPool(key, sqrtPriceX96, creatorSwapFeeE6, creatorTaxFeeE6);
    }

    function createNewHookAndPoolWithSalt(
        address initialOwner,
        bytes32 salt,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) public returns (AngstromL2 newAngstrom) {
        newAngstrom = deployNewHook(initialOwner, salt);
        newAngstrom.initializeNewPool(key, sqrtPriceX96, creatorSwapFeeE6, creatorTaxFeeE6);
    }

    function deployNewHook(address owner, bytes32 salt) public returns (AngstromL2 newAngstrom) {
        if (withdrawOnly) revert WithdrawOnlyMode();

        bytes memory initcode =
            bytes.concat(SSTORE2.read(HOOK_INITCODE_STORE), abi.encode(UNI_V4, owner));

        assembly ("memory-safe") {
            newAngstrom := create2(0, add(initcode, 0x20), mload(initcode), salt)
            // Propagate initcode error if deployment fails.
            if iszero(newAngstrom) {
                returndatacopy(mload(0x40), 0, returndatasize())
                revert(mload(0x40), returndatasize())
            }
        }
        isVerifiedHook[newAngstrom] = true;
        allHooks.push(newAngstrom);
        newAngstrom.setSwapMEVTaxFactor(defaultSwapMEVTaxFactor);
        emit SwapMEVTaxFactorUpdated(address(newAngstrom), defaultSwapMEVTaxFactor);
        newAngstrom.setJITTaxEnabled(defaultJITTaxEnabled);
        emit JITTaxStatusUpdated(address(newAngstrom), defaultJITTaxEnabled);
        newAngstrom.setPriorityFeeTaxFloor(defaultPriorityFeeTaxFloor);
        emit PriorityFeeTaxFloorUpdated(address(newAngstrom), defaultPriorityFeeTaxFloor);
    }

    function recordPoolCreationAndGetStartingProtocolFee(
        PoolKey calldata key,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) public returns (uint24 protocolSwapFeeE6, uint24 protocolTaxFeeE6) {
        if (withdrawOnly) revert WithdrawOnlyMode();
        if (!isVerifiedHook[AngstromL2(payable(msg.sender))]) {
            revert NotVerifiedHook();
        }
        protocolSwapFeeE6 = getDefaultProtocolSwapFee(creatorSwapFeeE6, key.fee);
        protocolTaxFeeE6 = defaultProtocolTaxFeeE6;
        if (protocolSwapFeeE6 > MAX_PROTOCOL_SWAP_FEE_E6) {
            protocolSwapFeeE6 = MAX_PROTOCOL_SWAP_FEE_E6;
        }
        PoolId id = key.toId();
        hookPoolIds[id] = AngstromL2(payable(msg.sender));
        emit PoolCreated(
            msg.sender, key, creatorSwapFeeE6, creatorTaxFeeE6, protocolSwapFeeE6, protocolTaxFeeE6
        );
        return (protocolSwapFeeE6, protocolTaxFeeE6);
    }

    function getDefaultProtocolSwapFee(uint256 creatorSwapFeeE6, uint256 lpFeeE6)
        public
        view
        returns (uint24)
    {
        // Solve `f_pr / (1 - (1 - f_lp) * (1 - (f_cr + f_pr))) = defaultProtocolSwapFeeAsMultipleE6` for `f_pr`.
        return ((defaultProtocolSwapFeeAsMultipleE6
                    * (FACTOR_E6
                        * FACTOR_E6
                        - (FACTOR_E6 - lpFeeE6)
                        * (FACTOR_E6 - creatorSwapFeeE6)))
                / (FACTOR_E6
                    * FACTOR_E6
                    - defaultProtocolSwapFeeAsMultipleE6
                    * (FACTOR_E6 - lpFeeE6)))
        .toUint24();
    }

    function getDefaultNetPoolSafeSwapFee(uint256 creatorSwapFeeE6, uint256 lpFeeE6)
        public
        view
        returns (uint256)
    {
        uint256 defaultProtocolSwapFeeE6 = getDefaultProtocolSwapFee(creatorSwapFeeE6, lpFeeE6);
        return (FACTOR_E6
                * FACTOR_E6
                - (FACTOR_E6 - lpFeeE6)
                * (FACTOR_E6 - creatorSwapFeeE6 - defaultProtocolSwapFeeE6)) / FACTOR_E6;
    }
}
