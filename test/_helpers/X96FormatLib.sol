// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LibString} from "solady/src/utils/LibString.sol";

/// @author philogy <https://github.com/philogy>
library X96FormatLib {
    function x96ToStr(uint256 x) internal pure returns (string memory) {
        uint256 whole = x >> 96;
        uint256 fraction = x % (1 << 96);
        return string.concat(
            LibString.toString(whole), ".", LibString.toHexStringNoPrefix(fraction, 96 / 8)
        );
    }
}
