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
        0x2c8b14a270eb080c2662a12936bb6b2babf15bf844404871a2914f010e487329;
    uint8 constant DEPLOY_TOKEN_NONCE = 28;
    address constant MULTISIG = 0x2A49fF6D0154506D0e1Eda03655F274126ceF7B6;

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
                    miner := create(0, add(minerInitcode, 0x20), mload(minerInitcode))
                }
                require(address(miner) != address(0), "failed to deploy miner");
            }

            (bool minted,) = SUB_ZERO.getTokenData(DEPLOY_TOKEN_ID);
            if (!minted) {
                console.log("  token noted minted, claiming...");
                SUB_ZERO.claimGivenUpWithSig(
                    msg.sender,
                    DEPLOY_TOKEN_ID,
                    DEPLOY_TOKEN_NONCE,
                    msg.sender,
                    GIVE_UP_CLAIM_DEADLINE,
                    GIVE_UP_CLAIM_SIG
                );
            }

            address factory = SUB_ZERO.deploy(
                DEPLOY_TOKEN_ID,
                bytes.concat(
                    type(AngstromL2Factory).creationCode, abi.encode(MULTISIG, uniV4, miner)
                )
            );
            console.log("  factory: %s", factory);

            vm.stopBroadcast();
        }
    }

    // function deployToChain(uint256 chainId, uint deployTokenId) internal {
    // }
}
