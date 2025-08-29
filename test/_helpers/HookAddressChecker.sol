// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {hasAngstromHookFlags} from "src/modules/UniConsumer.sol";

/// @author philogy <https://github.com/philogy>
contract HookAddressChecker {
    function angstrom_address_valid(address addr) external pure returns (bool) {
        return hasAngstromHookFlags(addr);
    }
}
