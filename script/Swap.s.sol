// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseScript} from "./BaseScript.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @author Sorella Labs
contract SwapScript is BaseScript, Config {
    using PoolIdLibrary for PoolKey;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() public {
        _loadConfigAndForks("script/config.toml", false);

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            vm.selectFork(forkOf[chainId]);

            address universalRouter = config.get("universal-router").toAddress();
            address usdc = config.get("usdc").toAddress();
            address hook = config.get("hook").toAddress();

            console.log("Chain [%s]", chainId);
            console.log("  universalRouter: %s", universalRouter);
            console.log("  usdc: %s", usdc);
            console.log("  hook: %s", hook);

            PoolKey memory poolKey = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(usdc),
                fee: 160,
                tickSpacing: 10,
                hooks: IHooks(hook)
            });

            bool zeroForOne =
                keccak256(bytes(vm.envOr("DIRECTION", string("0for1")))) == keccak256("0for1");

            uint256 amountIn;
            if (zeroForOne) {
                amountIn = vm.envOr("AMOUNT", uint256(0.001 ether));
            } else {
                amountIn = vm.envOr("AMOUNT", uint256(1e6));
            }

            console.log("  direction: %s", zeroForOne ? "ETH -> USDC" : "USDC -> ETH");
            console.log("  amountIn: %s", amountIn);

            bytes memory callData = _encodeSwap(poolKey, zeroForOne, amountIn);

            vm.startPrank(msg.sender);
            if (zeroForOne) {
                vm.deal(msg.sender, amountIn);
            } else {
                deal(usdc, msg.sender, amountIn);
                // need this line else the balance of msg.sender will be type(uint256).max which will cause payments to it to overflow
                vm.deal(msg.sender, 1 ether);
                IERC20(usdc).approve(PERMIT2, type(uint256).max);
                IPermit2(PERMIT2)
                    .approve(usdc, universalRouter, type(uint160).max, type(uint48).max);
            }
            uint256 ethValue = zeroForOne ? amountIn : 0;
            (bool success,) = universalRouter.call{value: ethValue}(callData);
            require(success, "Swap simulation failed");
            vm.stopPrank();

            console.log("  Simulation successful!");
            console.log("");

            if (zeroForOne) {
                console.log("  cast send %s --value %s \\", universalRouter, ethValue);
            } else {
                console.log("  cast send %s \\", universalRouter);
            }
            console.log("    --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> \\");
            console.logBytes(callData);
        }
    }

    function _encodeSwap(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (bytes memory)
    {
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency outputCurrency = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(inputCurrency, type(uint256).max);
        params[2] = abi.encode(outputCurrency, uint256(0));

        bytes memory v4SwapInput = abi.encode(actions, params);

        bytes memory commands = abi.encodePacked(uint8(0x10));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = v4SwapInput;

        return abi.encodeWithSelector(
            IUniversalRouter.execute.selector, commands, inputs, block.timestamp + 300
        );
    }

    // to receive ETH payments
    receive() payable external {}

    fallback() payable external {}
}
