// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseScript} from "./BaseScript.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";
import {SUB_ZERO} from "manyzeros-foundry/ISubZero.sol";
import {AngstromL2Factory, AngstromL2, IHookAddressMiner, PoolKey, PoolId, Currency, IHooks} from "src/AngstromL2Factory.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2FactoryScript is BaseScript, Config {
    uint256 constant DEPLOY_TOKEN_ID =
        0x2508b97b8041960cca8aabc7662f07ec8e285f6d0af37978e9add4c8397a16bf;
    uint8 constant DEPLOY_TOKEN_NONCE = 94;
    address constant MULTISIG = 0x2A49fF6D0154506D0e1Eda03655F274126ceF7B6;

    // Feb 2027
    uint256 constant GIVE_UP_CLAIM_DEADLINE = 1801752092;
    bytes constant GIVE_UP_CLAIM_SIG =
        hex"fde82cc31e1ddd10a7139a490d5a7b30a826ba24eb780609eac611b71084a3fe0ac58482dc844490e19e0411577d33cb468133b0a335a3fffb0705f77d577f8e1b";

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
            IHookAddressMiner miner;
            {
                bytes memory minerInitcode = getMinerCode(uniV4, true);

                vm.startBroadcast();
                assembly ("memory-safe") {
                    miner := create(0, add(minerInitcode, 0x20), mload(minerInitcode))
                }
                require(address(miner) != address(0), "failed to deploy miner");
            }

            AngstromL2Factory factory = AngstromL2Factory(payable(SUB_ZERO.computeAddress(bytes32(DEPLOY_TOKEN_ID), DEPLOY_TOKEN_NONCE)));
            if (address(factory).code.length > 0) {
                console.log("  factory already deployed: %s", address(factory));
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

                factory = AngstromL2Factory(payable(SUB_ZERO.deploy(
                    DEPLOY_TOKEN_ID,
                    bytes.concat(
                        type(AngstromL2Factory).creationCode, abi.encode(msg.sender, uniV4, miner)
                    )
                )));
                console.log("  factory deployed: %s", address(factory));
            }

            require(
                address(AngstromL2Factory(payable(factory)).UNI_V4()) == uniV4, "uniV4 mismatch"
            );
            require(factory.HOOK_ADDRESS_MINER() == miner, "miner mismatch");
            require(factory.owner() == msg.sender, "owner mismatch");

            factory.setDefaultProtocolSwapFeeMultiple(0.25e6);
            factory.setDefaultProtocolTaxFee(0.1e6);

            (uint160 sqrtPriceX96,,,) = StateView(stateView).getSlot0(PoolId.wrap(referencePricePool));
            PoolKey memory key = PoolKey( Currency.wrap(address(0)), Currency.wrap(usdc), 160, 10, IHooks(address(0)));
            AngstromL2 hook = factory.createNewHookAndPoolWithMiner(msg.sender, key,sqrtPriceX96, 0, 0);
            key.hooks = IHooks(address(hook));
            factory.setProtocolTaxFee(hook, key, 0);

            vm.stopBroadcast();
        }
    }
}
