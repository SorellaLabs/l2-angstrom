// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BaseTest} from "./_helpers/BaseTest.sol";
import {RouterActor} from "./_mocks/RouterActor.sol";
import {UniV4Inspector} from "./_mocks/UniV4Inspector.sol";
import {MockERC20} from "super-sol/mocks/MockERC20.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {AngstromL2Factory} from "../src/AngstromL2Factory.sol";
import {AngstromL2, PoolFeeConfiguration} from "../src/AngstromL2.sol";
import {IUniV4} from "../src/interfaces/IUniV4.sol";
import {IHookAddressMiner} from "../src/interfaces/IHookAddressMiner.sol";

/// @title FeeAsymmetryPOCTest
/// @notice Test demonstrating fee calculation asymmetry based on swap direction
contract FeeAsymmetryPOCTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using IUniV4 for UniV4Inspector;

    UniV4Inspector manager;
    RouterActor router;
    AngstromL2Factory factory;
    AngstromL2 angstrom;

    address factoryOwner = makeAddr("factory_owner");
    address hookOwner = makeAddr("hook_owner");
    IHookAddressMiner miner;

    uint24 constant LP_FEE = 10000; // 1%
    uint24 constant CREATOR_SWAP_FEE = 100000; // 10%
    uint24 constant CREATOR_TAX_FEE = 0; // all MEV tax goes to LPs

    bool constant HUFF2_INSTALLED = true;

    function setUp() public {
        vm.roll(100);
        manager = new UniV4Inspector();
        router = new RouterActor(manager);

        vm.deal(address(manager), 100_000_000 ether);
        vm.deal(address(router), 100_000_000 ether);

        bytes memory minerCode = HUFF2_INSTALLED
            ? getMinerCode(address(manager), false)
            : getHardcodedMinerCode(address(manager));
        IHookAddressMiner newMiner;
        assembly ("memory-safe") {
            newMiner := create(0, add(minerCode, 0x20), mload(minerCode))
        }
        miner = newMiner;

        factory = new AngstromL2Factory(factoryOwner, manager, miner);

        vm.prank(address(factory));
        bytes32 salt = miner.mineAngstromHookAddress(hookOwner);
        angstrom = factory.deployNewHook(hookOwner, salt);

        // sanity - both protocol tax fee and creator tax fee are zero
        assertEq(factory.defaultProtocolTaxFeeE6(), 0);
        assertEq(CREATOR_TAX_FEE, 0);
    }

    /// @notice Create pool with high liquidity for minimal price impact
    function _createHighLiquidityPool(MockERC20 tkn) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tkn)),
            fee: LP_FEE,
            tickSpacing: 10,
            hooks: IHooks(address(angstrom))
        });

        vm.prank(hookOwner);
        angstrom.initializeNewPool(
            key, TickMath.getSqrtPriceAtTick(0), CREATOR_SWAP_FEE, CREATOR_TAX_FEE
        );

        // Very high liquidity to minimize price impact
        // At tick 0, price is 1:1, so we need equal amounts
        router.modifyLiquidity(key, -10, 10, 40000000000e18, bytes32(0));
    }

    function test_allFourSwapCases() public {
        console.log("=== All Four Swap Cases: Fee Base Analysis ===\n");
        console.log("LP Fee: 1%, Creator Swap Fee: 10%, Protocol Swap Fee: 0%");
        console.log("Using HIGH liquidity to minimize price impact\n");

        //We intentionally set a very high tax, to highlight the inconsistencies impacting creator fee
        uint256 priorityFee = 100 gwei;
        uint256 tax = angstrom.getSwapTaxAmount(priorityFee);
        console.log("Tax: %d wei", tax);

        // Use larger swap to make tax relatively small
        int256 swapAmount = 1 ether; // Tax is ~0.5% of this
        console.log("Swap amount: %d (tax is ~0.5%% of this)\n", uint256(swapAmount));

        setPriorityFee(priorityFee);

        // Case 1: zeroForOne exactIn (ETH input, Token output)
        uint256 output1;
        uint256 creatorFee1;
        uint256 creatorFeeETH1;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 1: zeroForOne exactIn (ETH->Token)");

            uint256 feeBefore = tkn.balanceOf(address(angstrom));
            uint256 ETHFeeBefore = address(angstrom).balance;
            BalanceDelta delta = router.swap(key, true, -swapAmount, TickMath.MIN_SQRT_PRICE + 1);
            uint256 feeAfter = tkn.balanceOf(address(angstrom));
            uint256 ETHFeeAfter = address(angstrom).balance;
            creatorFee1 = feeAfter - feeBefore;
            creatorFeeETH1 = ETHFeeAfter - ETHFeeBefore;

            //@audit save output to reuse in exactOut swap
            output1 = uint256(int256(delta.amount1()));

            console.log("  ETH in: %d, Tokens out: %d", uint256(-int256(delta.amount0())), output1);
            console.log("  Creator swap fee (ETH): %d\n", creatorFeeETH1);
        }

        bumpBlock();

        // Case 2: zeroForOne exactOut - request same token output as Case 1
        uint256 creatorFee2;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 2: zeroForOne exactOut (want ~same tokens as Case 1)");

            uint256 feeBefore = address(angstrom).balance;
            //@audit
            BalanceDelta delta =
                router.swap(key, true, int256(output1), TickMath.MIN_SQRT_PRICE + 1);
            uint256 feeAfter = address(angstrom).balance;
            creatorFee2 = feeAfter - feeBefore;

            console.log(
                "  ETH in: %d, Tokens out: %d",
                uint256(-int256(delta.amount0())),
                uint256(int256(delta.amount1()))
            );
            console.log("  Creator swap fee (ETH): %d\n", creatorFee2);
        }

        bumpBlock();

        uint256 output3;
        // Case 3: oneForZero exactIn (Token input, ETH output)
        uint256 creatorFee3;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 3: oneForZero exactIn (Token->ETH)");

            uint256 feeBefore = tkn.balanceOf(address(angstrom));
            BalanceDelta delta = router.swap(key, false, -swapAmount, TickMath.MAX_SQRT_PRICE - 1);
            uint256 feeAfter = tkn.balanceOf(address(angstrom));
            creatorFee3 = feeAfter - feeBefore;

            //@audit save output to reuse in exactOut swap
            output3 = uint256(int256(delta.amount0()));

            console.log(
                "  Tokens in: %d, ETH out: %d",
                uint256(-int256(delta.amount1())),
                uint256(int256(delta.amount0()))
            );
            console.log("  Creator swap fee (ETH): %d\n", creatorFee3);
        }

        bumpBlock();

        // Case 4: oneForZero exactOut - request same ETH output as Case 3
        uint256 creatorFee4;
        {
            MockERC20 tkn = new MockERC20();
            tkn.mint(address(router), 1e30);
            PoolKey memory key = _createHighLiquidityPool(tkn);

            console.log("Case 4: oneForZero exactOut (want ~same ETH as Case 3)");

            uint256 feeBefore = tkn.balanceOf(address(angstrom));
            BalanceDelta delta =
                router.swap(key, false, int256(output3), TickMath.MAX_SQRT_PRICE - 1);
            uint256 feeAfter = tkn.balanceOf(address(angstrom));
            creatorFee4 = feeAfter - feeBefore;

            console.log(
                "  Tokens in: %d, ETH out: %d",
                uint256(-int256(delta.amount1())),
                uint256(int256(delta.amount0()))
            );
            console.log("  Creator swap fee (tokens): %d\n", creatorFee4);
        }

        console.log("=== Fee Comparison (at ~1:1 price, fees should be similar) ===");
        console.log("Case 1 (zeroForOne exactIn):  %d ETH", creatorFeeETH1);
        console.log("Case 2 (zeroForOne exactOut): %d ETH", creatorFee2);
        console.log("Case 3 (oneForZero exactIn):  %d token", creatorFee3);
        console.log("Case 4 (oneForZero exactOut): %d tokens", creatorFee4);

        console.log("\nIf consistent, all fees should be ~equal at 1:1 price");
        console.log("Discrepancy indicates asymmetric fee calculation");

        assertEq(creatorFeeETH1, creatorFee2, "Case 1 vs Case 2 fees differ");
        assertEq(creatorFee3, creatorFee4, "Case 3 vs Case 4 fees differ");
    }
}
