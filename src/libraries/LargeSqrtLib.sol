// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {LibBit} from "solady/src/utils/LibBit.sol";

/// @author philogy <https://github.com/philogy>
library LargeSqrtLib {
    using FixedPointMathLib for uint256;

    error SquareRouteResultOverflow();
    error IntermediateGuessOverflow();

    function sqrtX96(uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint160 sqrtRootX96)
    {
        // sqrt(a / b) * 2^96 = sqrt(a * 2^192 / b)
        // Compute 512-bit [x1 x0] = a * 2^192 / b
        uint256 x1 = (numerator >> 64) / denominator;
        // Solady claims behavior is undefined if result doesn't fit into 256-bits but result is
        // actually just `(x * y / d) mod 2^256`.
        uint256 x0 = numerator.fullMulDivUnchecked(1 << 192, denominator);

        if (x1 == 0) {
            // sqrt(x: uint256) guaranteed to fit in 128-bit number
            return uint160(x0.sqrt());
        }

        // The square root of a value larger than 320 bits is guaranteed not to fit in 160 bits
        if (!(x1 < 1 << 64)) revert SquareRouteResultOverflow();
        uint64 sx1 = uint64(x1);
        uint64 g1;
        uint256 g0 = 1 << (128 + (LibBit.fls(sx1) / 2));
        uint256 last;
        do {
            last = g0;
            (g1, g0) = div320by256(sx1, x0, g0);
            g0 = (g0 + last) / 2;
            // Our initial guess should be close enough that this revert should never be hit
            if (g1 != 0) revert IntermediateGuessOverflow();
        } while (g0 != last);
        return uint160(g0);
    }

    /// @dev Computes `[x1 x0] / d`
    function div320by256(uint64 x1, uint256 x0, uint256 d)
        internal
        pure
        returns (uint64 y1, uint256 y0)
    {
        assembly ("memory-safe") {
            // Compute first "digit" of long division result
            y1 := div(x1, d)
            // We take the remainder to continue the long division
            let r1 := mod(x1, d)
            // We complete the long division by computing `y0 = [r1 x0] / d`. We use the "512 by
            // 256 division" logic from Solady's `fullMulDiv` (Credit under MIT license:
            // https://github.com/Vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol)

            // We need to compute `[r1 x0] mod d = r1 * 2^256 + x0 = (r1 * 2^128) * 2^128 + x0`.
            let r := addmod(mulmod(shl(128, x1), shl(128, 1), d), x0, d)

            // Same math from Solady, reference `fullMulDiv` for explanation.
            let t := and(d, sub(0, d))
            d := div(d, t)
            let inv := xor(2, mul(3, d)) // inverse mod 2**4
            inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**8
            inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**16
            inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**32
            inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**64
            inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**128
            // Edits vs Solady: `x0` replaces `z`, `r1` replaces `p1`, final 256-bit result stored in `y0`
            y0 :=
                mul(
                    or(mul(sub(r1, gt(r, x0)), add(div(sub(0, t), t), 1)), div(sub(x0, r), t)),
                    mul(sub(2, mul(d, inv)), inv) // inverse mod 2**256
                )
        }
    }
}
