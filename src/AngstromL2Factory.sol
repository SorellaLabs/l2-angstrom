// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {IUniV4, IPoolManager, PoolId} from "./interfaces/IUniV4.sol";
import {AngstromL2} from "./AngstromL2.sol";
import {IFlashBlockNumber} from "./interfaces/IFlashBlockNumber.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {IHookAddressMiner} from "./interfaces/IHookAddressMiner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract AngstromL2Factory is Ownable, IFactory {
    IFlashBlockNumber public immutable FLASH_BLOCK_NUMBER_PROVIDER;
    IPoolManager public immutable UNI_V4;

    // Ownable explicit constructor commented out because of weird foundry bug causing
    // "modifier-style base constructor call without arguments": https://github.com/foundry-rs/foundry/issues/11607.
    constructor(address owner, IPoolManager uniV4, IFlashBlockNumber flashBlockNumberProvider) 
    /* Ownable() */
    {
        _initializeOwner(owner);
        FLASH_BLOCK_NUMBER_PROVIDER = flashBlockNumberProvider;
        UNI_V4 = uniV4;
    }

    receive() external payable {}

    function setProtocolSwapFee(AngstromL2 hook, PoolKey calldata key, uint256 newFeeE6) public {
        _checkOwner();
        hook.setProtocolSwapFee(key, newFeeE6);
    }

    function setProtocolTaxFee(AngstromL2 hook, PoolKey calldata key, uint256 newFeeE6) public {
        _checkOwner();
        hook.setProtocolTaxFee(key, newFeeE6);
    }

    function createNewHookAndPoolWithMiner(
        address initialOwner,
        IHookAddressMiner miner,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) public {
        bytes32 salt = miner.mineAngstromHookAddress(initialOwner);
        AngstromL2 newAngstrom = deployNewHook(initialOwner, salt);
        newAngstrom.initializeNewPool(key, sqrtPriceX96, creatorSwapFeeE6, creatorTaxFeeE6);
    }

    function createNewHookAndPoolWithSalt(
        address initialOwner,
        bytes32 salt,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint24 creatorSwapFeeE6,
        uint24 creatorTaxFeeE6
    ) public {
        AngstromL2 newAngstrom = deployNewHook(initialOwner, salt);
        newAngstrom.initializeNewPool(key, sqrtPriceX96, creatorSwapFeeE6, creatorTaxFeeE6);
    }

    function deployNewHook(address owner, bytes32 salt) public returns (AngstromL2 newAngstrom) {
        newAngstrom = new AngstromL2{salt: salt}(UNI_V4, FLASH_BLOCK_NUMBER_PROVIDER, owner);
    }
}
