// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LargeSqrtLib} from "src/libraries/LargeSqrtLib.sol";

import {console} from "forge-std/console.sol";
import {FormatLib} from "super-sol/libraries/FormatLib.sol";

contract LargeSqrtLibTest is Test {
    // External wrapper to enable try-catch
    function sqrtX96Wrapper(uint256 numerator, uint256 denominator)
        external
        pure
        returns (uint160)
    {
        return LargeSqrtLib.sqrtX96(numerator, denominator);
    }

    function testDifferentialSqrtX96(uint256 numerator, uint256 denominator) public {
        vm.assume(denominator > 0);
        vm.assume(numerator / denominator < 1 << 128);

        uint256 pythonResult = pythonFullDivisionSquareRoot(numerator, denominator);

        // Call Solidity implementation via external wrapper
        try this.sqrtX96Wrapper{gas: 1e6}(numerator, denominator) returns (uint160 solidityResult) {
            // If Solidity succeeds, results should match
            assertEq(
                uint256(solidityResult), pythonResult, "Results should match when Solidity succeeds"
            );
        } catch {
            // If Solidity reverts, Python result should be > 160 bits (doesn't fit)
            assertTrue(
                pythonResult >= (1 << 160),
                "Solidity should only revert when result doesn't fit in 160 bits"
            );
        }
    }

    function testSpecificCases() public {
        // Test edge case: equal numerator and denominator (should give 2^96)
        assertEqPython(1000, 1000, 1 << 96);

        // Test simple cases
        assertEqPython(4, 1, 2 << 96);
        assertEqPython(9, 1, 3 << 96);
        assertEqPython(1, 4, 1 << 95); // sqrt(1/4) = 1/2

        // Test larger values
        assertEqPython(1e18, 1e12, 1000 << 96); // sqrt(1e6) = 1000
    }

    function assertEqPython(uint256 numerator, uint256 denominator, uint256 expected) internal {
        uint256 pythonResult = pythonFullDivisionSquareRoot(numerator, denominator);
        uint160 solidityResult = LargeSqrtLib.sqrtX96(numerator, denominator);

        assertEq(uint256(solidityResult), expected, "Solidity result should match expected");
        assertEq(pythonResult, expected, "Python result should match expected");
    }

    function pythonFullDivisionSquareRoot(uint256 numerator, uint256 denominator)
        internal
        returns (uint256 result)
    {
        string[] memory inputs = new string[](4);
        inputs[0] = "python3";
        inputs[1] = "script/full_div_sqrt.py";
        inputs[2] = vm.toString(numerator);
        inputs[3] = vm.toString(denominator);

        bytes memory pythonResultBytes = vm.ffi(inputs);
        result = uint256(bytes32(pythonResultBytes));
    }
}
