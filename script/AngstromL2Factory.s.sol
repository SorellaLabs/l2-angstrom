// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseScript} from "./BaseScript.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";
import {SUB_ZERO} from "manyzeros-foundry/ISubZero.sol";
import {
    AngstromL2Factory,
    AngstromL2,
    IHookAddressMiner,
    PoolKey,
    PoolId,
    Currency,
    IHooks
} from "src/AngstromL2Factory.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";

/// @author philogy <https://github.com/philogy>
contract AngstromL2FactoryScript is BaseScript, Config {
    /// @dev Sub Zero salt owned by the deployer (first 20 bytes of the ID), so it can `mint` it directly.
    uint256 constant DEPLOY_TOKEN_ID =
        0xd3a9450753c7d15538c99c5ae061ceba7c91ac9bdf179f3780cec95c17042096;
    uint8 constant DEPLOY_TOKEN_NONCE = 79;
    address constant MULTISIG = 0x2A49fF6D0154506D0e1Eda03655F274126ceF7B6;

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

            IHookAddressMiner miner;
            {
                bytes memory minerInitcode = getMinerCode(uniV4, true);

                assembly ("memory-safe") {
                    miner := create(0, add(minerInitcode, 0x20), mload(minerInitcode))
                }
                require(address(miner) != address(0), "failed to deploy miner");
            }

            address factoryAddr =
                SUB_ZERO.computeAddress(bytes32(DEPLOY_TOKEN_ID), DEPLOY_TOKEN_NONCE);
            if (factoryAddr.code.length > 0) {
                console.log("  factory already deployed: %s", factoryAddr);
            } else {
                bool minted;
                try SUB_ZERO.getTokenData(DEPLOY_TOKEN_ID) returns (bool _minted, uint8) {
                    minted = _minted;
                } catch {
                    minted = false;
                }
                if (!minted) {
                    console.log("  token not minted, minting...");
                    SUB_ZERO.mint(msg.sender, DEPLOY_TOKEN_ID, DEPLOY_TOKEN_NONCE);
                }

                factoryAddr = SUB_ZERO.deploy(
                    DEPLOY_TOKEN_ID,
                    bytes.concat(
                        type(AngstromL2Factory).creationCode, abi.encode(msg.sender, uniV4, miner)
                    )
                );
                console.log("  factory deployed: %s", factoryAddr);
            }

            AngstromL2Factory factory = AngstromL2Factory(payable(factoryAddr));
            require(address(factory.UNI_V4()) == uniV4, "uniV4 mismatch");
            require(factory.owner() == msg.sender, "owner mismatch");
            require(factory.HOOK_ADDRESS_MINER() == miner, "miner mismatch");

            uint256 priorityFeeFloor = config.get("priority-fee-floor").toUint256();
            factory.setDefaultProtocolSwapFeeMultiple(0.25e6);
            factory.setDefaultProtocolTaxFee(0.1e6);
            factory.setDefaultPriorityFeeTaxFloor(priorityFeeFloor);
            factory.setDefaultSwapMEVTaxFactor(99);

            (uint160 sqrtPriceX96,,,) =
                StateView(stateView).getSlot0(PoolId.wrap(referencePricePool));
            PoolKey memory key = PoolKey(
                Currency.wrap(address(0)), Currency.wrap(usdc), 160, 10, IHooks(address(0))
            );
            factory.createNewHookAndPoolWithMiner(msg.sender, key, sqrtPriceX96, 0, 0);
            AngstromL2 hook = factory.allHooks(0);
            key.hooks = IHooks(address(hook));
            factory.setProtocolTaxFee(hook, key, 0);
            factory.setSwapMEVTaxFactor(hook, 200);

            vm.stopBroadcast();
        }
    }
}
