// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseScript} from "./BaseScript.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";

import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @author Philogy <https://github.com/philogy>
contract AddLiquidityScript is BaseScript, Config {
    using PoolIdLibrary for PoolKey;

    struct PoolConfig {
        address positionManager;
        address usdc;
        address stateview;
        address hook;
    }

    struct LiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint128 liquidity;
    }

    function run() public {
        _loadConfigAndForks("script/config.toml", false);

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            vm.selectFork(forkOf[chainId]);

            PoolConfig memory cfg = PoolConfig({
                positionManager: config.get("position-manager").toAddress(),
                usdc: config.get("usdc").toAddress(),
                stateview: config.get("stateview").toAddress(),
                hook: config.get("hook").toAddress()
            });

            console.log("Chain [%s]", chainId);
            console.log("  positionManager: %s", cfg.positionManager);
            console.log("  usdc: %s", cfg.usdc);

            PoolKey memory poolKey = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(cfg.usdc),
                fee: 160,
                tickSpacing: 10,
                hooks: IHooks(cfg.hook)
            });

            PoolId poolId = poolKey.toId();
            console.log("  poolId:");
            console.logBytes32(PoolId.unwrap(poolId));

            string memory mode = vm.envOr("MODE", string("both"));
            LiquidityParams memory params = _calculateLiquidityParams(cfg, poolKey, mode);

            console.log("  Mode: %s", mode);

            console.log("  Liquidity params:");
            console.log("    tickLower: %s", params.tickLower);
            console.log("    tickUpper: %s", params.tickUpper);
            console.log("    amount0Desired: %s wei", params.amount0Desired);
            console.log("    amount1Desired: %s USDC", params.amount1Desired / 1e6);
            console.log("    liquidity: %s", params.liquidity);

            bytes memory callData = _encodeModifyLiquidities(poolKey, params);

            // Simulate the transaction using the exact calldata
            uint256 ethValue = params.amount0Desired;
            vm.deal(msg.sender, ethValue);
            vm.startPrank(msg.sender);
            IPositionManager posm = IPositionManager(cfg.positionManager);
            uint256 tokenIdBefore = posm.nextTokenId();
            (bool success,) = cfg.positionManager.call{value: ethValue}(callData);
            require(success, "Simulation failed");
            uint256 newTokenId = posm.nextTokenId() - 1;
            require(newTokenId >= tokenIdBefore, "No token minted");
            require(
                IERC721(cfg.positionManager).ownerOf(newTokenId) == msg.sender,
                "Token not owned by sender"
            );
            vm.stopPrank();
            console.log("  Simulation successful! NFT tokenId=%s", newTokenId);

            // Output cast send command
            console.log("");
            console.log("  cast send %s --value %s \\", cfg.positionManager, ethValue);
            console.log("    --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> \\");
            console.logBytes(callData);
        }
    }

    function _calculateLiquidityParams(
        PoolConfig memory cfg,
        PoolKey memory poolKey,
        string memory mode
    ) internal view returns (LiquidityParams memory params) {
        (uint160 sqrtPriceX96, int24 currentTick,,) =
            StateView(cfg.stateview).getSlot0(poolKey.toId());
        console.log("  Current tick: %s", currentTick);

        int24 tickSpacing = poolKey.tickSpacing;
        bytes32 modeHash = keccak256(bytes(mode));

        if (modeHash == keccak256("lower")) {
            // Position entirely below current price — only USDC (token1) deposited
            params.tickUpper = (currentTick / tickSpacing) * tickSpacing;
            if (params.tickUpper > currentTick) params.tickUpper -= tickSpacing;
            params.tickLower = params.tickUpper - 6000;
            params.tickLower = (params.tickLower / tickSpacing) * tickSpacing;

            uint256 maxAmount1 = 1e6; // 1 USDC
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(params.tickLower);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(params.tickUpper);

            params.liquidity =
                LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, maxAmount1);
            params.amount0Desired = 0;
            params.amount1Desired = LiquidityAmounts.getAmount1ForLiquidity(
                sqrtPriceLower, sqrtPriceUpper, params.liquidity
            ) + 1;
        } else if (modeHash == keccak256("upper")) {
            // Position entirely above current price — only ETH (token0) deposited
            params.tickLower = (currentTick / tickSpacing) * tickSpacing;
            if (params.tickLower < currentTick) params.tickLower += tickSpacing;
            params.tickUpper = params.tickLower + 6000;
            params.tickUpper = (params.tickUpper / tickSpacing) * tickSpacing;

            uint256 maxAmount0 = 0.001 ether;
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(params.tickLower);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(params.tickUpper);

            params.liquidity =
                LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, maxAmount0);
            params.amount0Desired = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtPriceLower, sqrtPriceUpper, params.liquidity
            ) + 1;
            params.amount1Desired = 0;
        } else {
            // "both" — two-sided liquidity around current tick
            params.tickLower = ((currentTick - 6000) / tickSpacing) * tickSpacing;
            params.tickUpper = ((currentTick + 6000) / tickSpacing) * tickSpacing;

            uint256 maxAmount0 = 0.005 ether;
            uint256 maxAmount1 = 5e6; // ~$5 USDC (6 decimals)
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(params.tickLower);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(params.tickUpper);

            params.liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, maxAmount0, maxAmount1
            );
            // +1 to account for rounding up in the pool manager
            params.amount0Desired = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtPriceX96, sqrtPriceUpper, params.liquidity
            ) + 1;
            params.amount1Desired = LiquidityAmounts.getAmount1ForLiquidity(
                sqrtPriceLower, sqrtPriceX96, params.liquidity
            ) + 1;
        }
    }

    function _encodeActionParams(PoolKey memory poolKey, LiquidityParams memory params)
        internal
        view
        returns (bytes[] memory paramsArr)
    {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        paramsArr = new bytes[](3);
        paramsArr[0] = abi.encode(
            poolKey,
            params.tickLower,
            params.tickUpper,
            params.liquidity,
            params.amount0Desired,
            params.amount1Desired,
            msg.sender,
            bytes("")
        );
        paramsArr[1] = abi.encode(currency0, currency1);
        paramsArr[2] = abi.encode(currency0, msg.sender);
    }

    function _encodeModifyLiquidities(PoolKey memory poolKey, LiquidityParams memory params)
        internal
        view
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes memory unlockData = abi.encode(actions, _encodeActionParams(poolKey, params));
        return
            abi.encodeCall(IPositionManager.modifyLiquidities, (unlockData, block.timestamp + 300));
    }
}
