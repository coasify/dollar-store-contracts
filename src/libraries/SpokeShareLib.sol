// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SpokeShareLib - Pro-rata share math for non-transferable spoke LP receipts
/// @notice A spoke is a two-component pool: its spoke-asset reserve plus an internal DLRS-side
///         reserve (`dlrsReserve`). Both are normalized 6-decimal, par-valued dollar amounts, so the
///         pool's total value is the scalar `poolValue = spokeReserve + dlrsReserve`. LP receipts are
///         a pro-rata claim on that value. This library is the pure mint/burn conversion.
/// @dev All rounding is DOWN (against the caller): a depositor never mints more claim than the value
///      they add, and a redeemer never draws more than their share. No MINIMUM_LIQUIDITY lock is used
///      because `poolValue` is INTERNAL accounting, not `balanceOf`, so the classic donate-to-inflate
///      first-depositor attack is impossible. Fully impaired shares can remain in a killed pool as
///      historical records; restarting the asset requires a fresh poolId.
/// @custom:security-contact admin@dollarstore.world
library SpokeShareLib {
    /// @notice Deposit value must be non-zero.
    error ZeroValue();
    /// @notice Share amount must be non-zero.
    error ZeroShares();
    /// @notice A deposit was too small to mint any shares at the current share price.
    error DepositTooSmall();
    /// @notice Outstanding shares have no backing; new capital must not revive their claims.
    error PoolFullyImpaired();
    /// @notice Requested more shares than the pool has outstanding.
    error InsufficientShares(uint256 requested, uint256 available);

    /// @notice Shares to mint for depositing `valueIn` into a spoke pool.
    /// @dev First LP into an empty pool mints 1:1 with value. Otherwise shares are pro-rata against the
    ///      pool value BEFORE this deposit, rounded down. Reverts if the deposit is too small to mint a
    ///      whole share, or if outstanding shares have zero backing.
    /// @param valueIn Deposited value in normalized 6dp units.
    /// @param poolValueBefore Pool value (spokeReserve + dlrsReserve) BEFORE this deposit, 6dp.
    /// @param totalShares Outstanding shares BEFORE this deposit.
    /// @return shares Shares to mint to the depositor.
    function sharesForDeposit(uint256 valueIn, uint256 poolValueBefore, uint256 totalShares)
        internal
        pure
        returns (uint256 shares)
    {
        if (valueIn == 0) revert ZeroValue();
        if (totalShares == 0) {
            return valueIn; // first LP: 1:1
        }
        if (poolValueBefore == 0) revert PoolFullyImpaired();
        shares = Math.mulDiv(valueIn, totalShares, poolValueBefore); // floor
        if (shares == 0) revert DepositTooSmall();
    }

    /// @notice Value redeemable for burning `sharesIn` of a spoke pool.
    /// @dev Pro-rata against current pool value, rounded down. If the pool is value-impaired
    ///      (poolValue < totalShares after a write-down), each share simply pays less, sharing the loss.
    /// @param sharesIn Shares being burned.
    /// @param poolValue Current pool value (spokeReserve + dlrsReserve), 6dp.
    /// @param totalShares Outstanding shares BEFORE this burn.
    /// @return value Redeemable value in normalized 6dp units (rounded down).
    function valueForShares(uint256 sharesIn, uint256 poolValue, uint256 totalShares)
        internal
        pure
        returns (uint256 value)
    {
        if (sharesIn == 0) revert ZeroShares();
        if (sharesIn > totalShares) revert InsufficientShares(sharesIn, totalShares);
        // totalShares >= sharesIn >= 1 here, so mulDiv never divides by zero (no dead guard needed).
        value = Math.mulDiv(sharesIn, poolValue, totalShares); // floor
    }
}
