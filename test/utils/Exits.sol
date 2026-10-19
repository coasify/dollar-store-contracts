// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IDollarStore} from "../../src/interfaces/IDollarStore.sol";

/// @notice Test helper: exits with no minimums and sums what was paid back into 6-decimal dollars,
///         converting each native amount with its token's decimals: the spoke asset's (spoke exits)
///         and the hub assets'.
library Exits {
    function withdraw(IDollarStore store, uint16 poolId, uint256 receiptAmount)
        internal
        returns (uint256 spokeUnits, uint256 hubUnits)
    {
        (address[] memory assets, uint256[] memory amounts) =
            store.withdraw(poolId, receiptAmount, new uint256[](0), block.timestamp);
        for (uint256 i; i < assets.length; ++i) {
            uint256 units = amounts[i] / 10 ** (IERC20Metadata(assets[i]).decimals() - 6);
            if (poolId != 0 && i == 0) spokeUnits = units;
            else hubUnits += units;
        }
    }
}
