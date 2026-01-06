// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseScript} from "./BaseScript.sol";
import {Config} from "forge-std/Config.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {console} from "forge-std/console.sol";
import {SUB_ZERO} from "manyzeros-foundry/ISubZero.sol";
import {AngstromL2Factory, IHookAddressMiner} from "src/AngstromL2Factory.sol";
import {IPoolManager} from "src/interfaces/IUniV4.sol";

/// @author philogy <https://github.com/philogy>
contract TestL2Factory is BaseScript, Config {
    address constant OWNER = 0x3Ac66Ac9EdDa9D19DeEEdEDf0F6cb8924E032A6c;

    uint256 constant GIVE_UP_CLAIM_DEADLINE = 1760109589;
    bytes constant GIVE_UP_CLAIM_SIG =
        hex"ab2d6d71e7add2db6bdaf118e134b750a1417a0ec218cd94f3162be8f2370e0310f796e96c8e806f3fbbf8922054fd230b6ab8bf6810f0d5584f069d757f486c";

    function run() public {
        _loadConfigAndForks("script/config.toml", false);

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            vm.selectFork(forkOf[chainId]);
            address uniV4 = config.get("uniswap-v4-pool-manager").toAddress();
            console.log("Chain [%s]", chainId);
            console.log("  uniV4: %s", uniV4);
            IHookAddressMiner miner;
            {
                bytes memory minerInitcode = getMinerCode(uniV4, true);

                vm.startBroadcast();
                assembly ("memory-safe") {
                    miner := create(
                        0,
                        add(minerInitcode, 0x20),
                        mload(minerInitcode)
                    )
                }
                require(address(miner) != address(0), "failed to deploy miner");
            }

            AngstromL2Factory factory = new AngstromL2Factory(
                OWNER,
                IPoolManager(uniV4),
                miner
            );

            console.log("  factory: %s", address(factory));

            vm.stopBroadcast();
        }
    }
}
