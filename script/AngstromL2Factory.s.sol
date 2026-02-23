// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseScript} from "./BaseScript.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";
import {AngstromL2Factory, AngstromL2, IHookAddressMiner, PoolKey, PoolId, Currency, IHooks} from "src/AngstromL2Factory.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2FactoryScript is BaseScript, Config {
    function run() public {
        _loadConfigAndForks("script/config.toml", false);

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            vm.selectFork(forkOf[chainId]);
            address uniV4 = config.get("uniswap-v4-pool-manager").toAddress();
            address usdc = config.get("usdc").toAddress();
            address stateView = config.get("stateview").toAddress();
            bytes32 referencePricePool = config.get("univ4-largest-eth-usdc-pool").toBytes32();
            console.log("Chain [%s]", chainId);
            console.log("  uniV4: %s", uniV4);

            vm.startBroadcast();

            IHookAddressMiner miner = IHookAddressMiner(0x0E177118dC36B78D9cc7F018d82090208601e467);

            bytes memory creationCode = bytes.concat(
                type(AngstromL2Factory).creationCode, abi.encode(msg.sender, uniV4, miner)
            );
            AngstromL2Factory factory;
            assembly {
                factory := create(0, add(creationCode, 0x20), mload(creationCode))
            }
            require(address(factory) != address(0), "failed to deploy factory");
            console.log("  factory deployed: %s", address(factory));

            require(
                address(AngstromL2Factory(payable(factory)).UNI_V4()) == uniV4, "uniV4 mismatch"
            );
            require(factory.HOOK_ADDRESS_MINER() == miner, "miner mismatch");
            require(factory.owner() == msg.sender, "owner mismatch");

            uint256 priorityFeeFloor = config.get("priority-fee-floor").toUint256();
            factory.setDefaultProtocolSwapFeeMultiple(0.25e6);
            factory.setDefaultProtocolTaxFee(0.1e6);
            factory.setDefaultPriorityFeeTaxFloor(priorityFeeFloor);

            (uint160 sqrtPriceX96,,,) = StateView(stateView).getSlot0(PoolId.wrap(referencePricePool));
            PoolKey memory key = PoolKey( Currency.wrap(address(0)), Currency.wrap(usdc), 160, 10, IHooks(address(0)));
            factory.createNewHookAndPoolWithMiner(msg.sender, key,sqrtPriceX96, 0, 0);
            AngstromL2 hook = factory.allHooks(0);
            key.hooks = IHooks(address(hook));
            factory.setProtocolTaxFee(hook, key, 0);

            vm.stopBroadcast();
        }
    }
}
