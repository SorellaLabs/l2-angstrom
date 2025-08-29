// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest} from "test/_helpers/BaseTest.sol";
import {X128MathLib} from "src/libraries/X128MathLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {PRNG} from "super-sol/collections/PRNG.sol";
import {console} from "forge-std/console.sol";

/// @author philogy <https://github.com/philogy>
contract X128MathLibTest is BaseTest {
    function check_matchesSolady_fullMulX128(uint256 x, uint256 y) public view {
        test_fuzzing_matchesSolady_fullMulX128(x, y);
    }

    function test_fuzzing_matchesSolady_fullMulX128(uint256 x, uint256 y) public view {
        bool success;
        uint256 result;

        try this.fullMulX128(x, y) returns (uint256 out) {
            success = true;
            result = out;
        } catch {
            success = false;
        }

        try this.solady_fullMulDiv128(x, y) returns (uint256 out) {
            assertTrue(success, "Solady succeeded when x128 didn't");
            assertEq(out, result, "Different results");
        } catch {
            assertFalse(success, "Solady failed when x128 didn't");
        }
    }

    function test_fuzzing_matchesNaive_fullMulX128(uint256 x, uint256 y) public view {
        (bool success, uint256 result) = naive_fullMulDiv128(x, y);

        try this.fullMulX128(x, y) returns (uint256 out) {
            assertTrue(success, "Naive failed when x128 didn't");
            assertEq(result, out, "Differnt results");
        } catch {
            assertFalse(success);
        }
    }

    function naive_fullMulDiv128(uint256 x, uint256 y)
        internal
        pure
        returns (bool success, uint256 z)
    {
        // x * y = (x0 * 2**128 + x1) * (y0 * 2**128 + y1)
        //       = x0 * y0 * 2**256 + x1 * y0 * 2**128 + x0 * y1 * 2**128 + y1 * x1
        // floor((x * y) / 2**128) = floor(x0 * y0 * 2**128 + x1 * y0 + x0 * y1 + y1 * x1 / 2**128)
        unchecked {
            uint256 x0 = x / (1 << 128);
            uint256 x1 = x % (1 << 128);
            uint256 y0 = y / (1 << 128);
            uint256 y1 = y % (1 << 128);

            uint256 top = x0 * y0;
            uint256 m1 = x1 * y0;
            uint256 m2 = x0 * y1;
            uint256 bottom = x1 * y1;

            success = top < (1 << 128);
            z = top << 128;
            uint256 prevZ = z;
            z += m1;
            success = success && (z >= prevZ);
            prevZ = z;
            z += m2;
            success = success && (z >= prevZ);
            prevZ = z;
            z += bottom >> 128;
            success = success && (z >= prevZ);
        }
    }

    function fullMulX128(uint256 x, uint256 y) external pure returns (uint256) {
        return X128MathLib.fullMulX128(x, y);
    }

    function solady_fullMulDiv128(uint256 x, uint256 y) external pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(x, y, 1 << 128);
    }
}
