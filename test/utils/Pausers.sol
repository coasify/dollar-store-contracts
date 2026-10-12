// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Builds the pauser list that `DollarStore.initialize` takes.
library Pausers {
    function one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
