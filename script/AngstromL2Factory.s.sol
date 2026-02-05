// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseScript} from "./BaseScript.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";
import {SUB_ZERO} from "manyzeros-foundry/ISubZero.sol";
import {AngstromL2Factory, IHookAddressMiner} from "src/AngstromL2Factory.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2FactoryScript is BaseScript, Config {
    uint256 constant DEPLOY_TOKEN_ID =
        0x2508b97b8041960cca8aabc7662f07ec8e285f6d9212c7ea19ea74be25aa4eeb;
    uint8 constant DEPLOY_TOKEN_NONCE = 127;
    address constant MULTISIG = 0x2A49fF6D0154506D0e1Eda03655F274126ceF7B6;

    // Feb 2027
    uint256 constant GIVE_UP_CLAIM_DEADLINE = 1801752092;
    bytes constant GIVE_UP_CLAIM_SIG =
        hex"1d25a58942d38130c426f464d49db8397da58827a5913a90c29b4a276ed9afd87eb6fda3ec556da2082c1d64d83dbed8bb1cba6aa74f42e4286a5a5008147e621b";

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
                    miner := create(0, add(minerInitcode, 0x20), mload(minerInitcode))
                }
                require(address(miner) != address(0), "failed to deploy miner");
            }

            address factory = SUB_ZERO.computeAddress(bytes32(DEPLOY_TOKEN_ID), DEPLOY_TOKEN_NONCE);
            if (factory.code.length > 0) {
                console.log("  factory already deployed: %s", factory);
            } else {
                bool minted;
                try SUB_ZERO.getTokenData(DEPLOY_TOKEN_ID) returns (bool _minted, uint8) {
                    minted = _minted;
                } catch {
                    minted = false;
                }
                if (!minted) {
                    console.log("  token not minted, claiming...");

                    SUB_ZERO.claimGivenUpWithSig(
                        msg.sender,
                        DEPLOY_TOKEN_ID,
                        DEPLOY_TOKEN_NONCE,
                        msg.sender,
                        GIVE_UP_CLAIM_DEADLINE,
                        GIVE_UP_CLAIM_SIG
                    );
                }

                factory = SUB_ZERO.deploy(
                    DEPLOY_TOKEN_ID,
                    bytes.concat(
                        type(AngstromL2Factory).creationCode, abi.encode(MULTISIG, uniV4, miner)
                    )
                );
                console.log("  factory deployed: %s", factory);
            }

            require(
                address(AngstromL2Factory(payable(factory)).UNI_V4()) == uniV4, "uniV4 mismatch"
            );
            require(AngstromL2Factory(payable(factory)).owner() == MULTISIG, "owner mismatch");
            require(AngstromL2Factory(payable(factory)).HOOK_ADDRESS_MINER() == miner, "miner mismatch");
            vm.stopBroadcast();
        }
    }
}
