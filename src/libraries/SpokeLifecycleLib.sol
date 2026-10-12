// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDollarStore} from "../interfaces/IDollarStore.sol";
import {RegistryStorage} from "../storage/RegistryStorage.sol";
import {QueueStorage} from "../storage/QueueStorage.sol";
import {CoreStorage} from "../storage/CoreStorage.sol";
import {QueueLib} from "./QueueLib.sol";
import {NormalizationLib} from "./NormalizationLib.sol";
import {DLRS} from "../DLRS.sol";

/// @title SpokeLifecycleLib - spoke wind-down / impairment / removal / redeem logic.
/// @notice Holds the spoke wind-down, escrow-impairment haircut, pool-removal and proportional-redeem
///         bodies. These ship in this deployment but live in an external library (deployed separately,
///         linked to DollarStore) so the DollarStore implementation stays under the EIP-170 24576-byte
///         runtime limit. Being cold, admin/emergency functions, hosting them via delegatecall costs
///         no gas on the hot swap path.
/// @dev External library: its public functions run in the DollarStore proxy storage context via
///      delegatecall (same ERC-7201 slots, msg.sender and block.timestamp preserved). The DollarStore
///      wrappers keep the access modifiers (onlyGovernor / onlyGuardian / nonReentrant) and run BEFORE
///      delegating here, so these functions assume they are already access-gated.
/// @custom:security-contact admin@dollarstore.world
library SpokeLifecycleLib {
    using SafeERC20 for IERC20;

    // Re-declared so library code can emit them; under delegatecall they log from the proxy address.
    event PoolRemoved(uint16 indexed poolId);
    event SpokeWindDownStarted(uint16 indexed poolId);
    event EscrowHaircut(address indexed asset, uint16 indexed poolId, uint256 oldEscrow, uint256 newEscrow);
    event SpokeWithdrawn(
        uint16 indexed poolId, address indexed provider, uint256 sharesBurned, uint256 spokeUnits, uint256 hubUnits
    );
    event Withdraw(
        address indexed user, uint16 indexed poolId, address indexed asset, uint256 units, uint256 nativeAmount
    );

    /// @dev Returns the spoke pool at `poolId`, reverting InvalidPool if it does not exist and
    ///      PoolNotSpoke if it is the hub.
    function _spoke(RegistryStorage.Layout storage r, uint16 poolId)
        private
        view
        returns (RegistryStorage.Pool storage p)
    {
        if (poolId >= r.pools.length) revert IDollarStore.InvalidPool(poolId);
        p = r.pools[poolId];
        if (p.kind != RegistryStorage.PoolKind.Spoke) revert IDollarStore.PoolNotSpoke(poolId);
    }

    /// @notice Enter the winding-down state for a spoke (see IDollarStore.windDownSpoke).
    function windDownSpoke(uint16 poolId) external {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        RegistryStorage.Pool storage p = _spoke(r, poolId);
        if (p.status != RegistryStorage.PoolStatus.Active) revert IDollarStore.SpokeWindingDown(poolId);
        p.status = RegistryStorage.PoolStatus.WindingDown;
        emit SpokeWindDownStarted(poolId);
    }

    /// @notice Kill a zero-reserve spoke, retaining any worthless shares as historical records (see IDollarStore.removePool).
    /// @dev Queue lines are not required to be empty. Keys are pool-scoped, so a tombstone's leftover
    ///      positions can never be reached through a replacement pool: they stay cancellable by their
    ///      owners (cancelQueue does not route-validate) and can never be filled (the asset is unlisted,
    ///      so no route touches them). Parked escrow of the spoke asset is likewise outside the pool.
    ///      Both stay subject to haircutEscrow afterwards.
    function removePool(uint16 poolId) external {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        RegistryStorage.Pool storage p = _spoke(r, poolId);
        if (p.status == RegistryStorage.PoolStatus.Killed) revert IDollarStore.PoolKilled(poolId);
        if (p.dlrsReserve != 0) revert IDollarStore.PoolNotEmpty(poolId);

        address[] storage spokeAssets = p.assets;
        for (uint256 i; i < spokeAssets.length; ++i) {
            address sa = spokeAssets[i];
            if (r.assetConfig[sa].poolId != poolId) revert IDollarStore.WrongPool(sa, poolId);
            if (r.reserves[poolId][sa] != 0) revert IDollarStore.PoolNotEmpty(poolId);
            r.assetConfig[sa].listed = false;
        }

        p.paused = true;
        p.status = RegistryStorage.PoolStatus.Killed;
        emit PoolRemoved(poolId);
    }

    /// @notice Guardian escrow-impairment haircut (see IDollarStore.haircutEscrow).
    function haircutEscrow(address asset, uint256 maxPositions) external returns (uint256 removedUnits) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        RegistryStorage.AssetConfig storage cfg = r.assetConfig[asset];
        QueueStorage.Layout storage qs = QueueStorage.layout();
        uint256 escrow = qs.totalEscrowedByAsset[asset];
        // A removed spoke's asset is unlisted but can still carry queued or parked escrow, which shares a loss
        // like any other escrow; its pool is left paused by removal.
        if (!cfg.listed && escrow == 0) revert IDollarStore.AssetNotListed(asset);
        if (!r.pools[cfg.poolId].paused) revert IDollarStore.PoolNotPaused(cfg.poolId);
        if (escrow == 0) revert IDollarStore.NoEscrowToHaircut(asset);

        uint256 actualUnits = IERC20(asset).balanceOf(address(this)) / cfg.scalingFactor;
        uint256 reserves = r.reserves[cfg.poolId][asset];
        if (actualUnits >= reserves + escrow) revert IDollarStore.AssetNotImpaired(asset);

        uint256 targetEscrow = actualUnits > reserves ? actualUnits - reserves : 0;

        // Walk every line that offers `asset`, keyed by the pool it belongs to. Hub-to-hub lines live in
        // pool 0; each spoke pool owns its own hub<->spoke lines. A killed pool whose asset was relisted
        // has distinct lines from its replacement, so each line is visited once.
        uint256 budget = maxPositions;
        address[] storage hubAssets = r.pools[0].assets;
        bool assetIsHub = cfg.poolId == 0;
        uint256 poolLen = r.pools.length;
        // Pool ids fit in uint16: createSpoke caps the pool count.
        for (uint256 pid; pid < poolLen; ++pid) {
            if (pid == 0) {
                if (!assetIsHub) continue;
                for (uint256 a; a < hubAssets.length; ++a) {
                    address want = hubAssets[a];
                    if (want == asset) continue;
                    budget = _haircutQueue(qs, asset, want, 0, targetEscrow, escrow, budget);
                }
                continue;
            }
            address[] storage passets = r.pools[pid].assets;
            if (passets.length == 0) continue;
            address sa = passets[0]; // a spoke has exactly one spoke asset
            if (sa == asset) {
                for (uint256 a; a < hubAssets.length; ++a) {
                    // forge-lint: disable-next-line(unsafe-typecast)
                    budget = _haircutQueue(qs, asset, hubAssets[a], uint16(pid), targetEscrow, escrow, budget);
                }
            } else if (assetIsHub) {
                // forge-lint: disable-next-line(unsafe-typecast)
                budget = _haircutQueue(qs, asset, sa, uint16(pid), targetEscrow, escrow, budget);
            }
        }
        // Parked positions hold escrow of `asset` too and share the loss pro-rata like any other line.
        budget = _haircutQueue(qs, asset, address(0), 0, targetEscrow, escrow, budget);

        uint256 newEscrow = qs.totalEscrowedByAsset[asset];
        removedUnits = escrow - newEscrow;
        emit EscrowHaircut(asset, cfg.poolId, escrow, newEscrow);
    }

    function _haircutQueue(
        QueueStorage.Layout storage qs,
        address offerAsset,
        address wantAsset,
        uint16 poolId,
        uint256 targetEscrow,
        uint256 escrow,
        uint256 budget
    ) private returns (uint256) {
        uint256 current = qs.queues[QueueStorage.queueKey(offerAsset, wantAsset, poolId)].head;
        while (current != 0) {
            if (budget == 0) revert IDollarStore.HaircutBudgetExceeded();
            QueueStorage.QueuePosition storage p = qs.positions[current];
            uint256 next = p.next;
            uint256 amt = p.offerAmount;
            uint256 newAmt = Math.mulDiv(amt, targetEscrow, escrow); // floor, pro-rata
            if (newAmt == 0) {
                QueueLib.remove(qs, current);
            } else if (newAmt < amt) {
                QueueLib.reduce(qs, current, amt - newAmt);
            }
            budget -= 1;
            current = next;
        }
        return budget;
    }

    // ============ Proportional exits (hub and spoke) ============

    /// @notice Hub exit: burn `units` DLRS and receive the caller's proportional slice of every hub asset.
    function withdrawHub(uint256 units, uint256 deadline) external returns (uint256 hubUnits) {
        if (block.timestamp > deadline) revert IDollarStore.DeadlineExpired(deadline, block.timestamp);
        if (units == 0) revert IDollarStore.ZeroAmount();

        RegistryStorage.Layout storage r = RegistryStorage.layout();
        // Effects before interaction: burn first (reverts on insufficient DLRS), then pay out.
        DLRS(CoreStorage.layout().dlrs).burn(msg.sender, units);
        _payHubProRata(r, msg.sender, units, r.pools[0].assets[0]);
        hubUnits = units;
    }

    /// @notice Spoke exit: burn `shares` and receive the caller's proportional slice of the spoke asset
    ///         and of the spoke's claim on hub dollars, the latter split across hub assets by reserve
    ///         weight. Burning the last shares drains both sides to exactly zero.
    function withdrawSpoke(uint16 poolId, uint256 shares, uint256 deadline)
        external
        returns (uint256 spokeUnits, uint256 hubUnits)
    {
        if (block.timestamp > deadline) revert IDollarStore.DeadlineExpired(deadline, block.timestamp);
        if (shares == 0) revert IDollarStore.ZeroAmount();

        RegistryStorage.Layout storage r = RegistryStorage.layout();
        RegistryStorage.Pool storage p = _spoke(r, poolId);

        uint256 ownerShares = r.receiptShares[poolId][msg.sender];
        if (ownerShares < shares) revert IDollarStore.InsufficientReceiptShares(shares, ownerShares);

        uint256 total = r.receiptTotalShares[poolId];
        address spokeAsset = p.assets[0];
        uint256 spokeReserve = r.reserves[poolId][spokeAsset];
        uint256 hubClaim = p.dlrsReserve;

        // Floor ONCE on total value, then split by side, so a position worth at least one unit always
        // pays at least one unit (flooring each side separately could round both legs to zero and strand
        // dust that no exit could ever clear).
        uint256 poolValue = spokeReserve + hubClaim;
        uint256 value = Math.mulDiv(shares, poolValue, total);
        if (value == 0) revert IDollarStore.ZeroAmount();
        spokeUnits = Math.mulDiv(value, spokeReserve, poolValue);
        hubUnits = value - spokeUnits;
        if (hubUnits > hubClaim) {
            // Rounding pushed the hub leg past the claim; the spoke side always has room for the excess.
            spokeUnits += hubUnits - hubClaim;
            hubUnits = hubClaim;
        }

        // Legs that pay nothing are probed; legs that pay are checked by their own transfer.
        if (spokeUnits == 0) _probeIssuer(spokeAsset, msg.sender);
        if (hubUnits == 0) _probeAllHub(r, msg.sender);

        r.receiptShares[poolId][msg.sender] = ownerShares - shares;
        r.receiptTotalShares[poolId] = total - shares;

        if (spokeUnits > 0) {
            r.reserves[poolId][spokeAsset] = spokeReserve - spokeUnits;
            IERC20(spokeAsset)
                .safeTransfer(
                    msg.sender, NormalizationLib.toNative(spokeUnits, r.assetConfig[spokeAsset].scalingFactor)
                );
        }
        if (hubUnits > 0) {
            p.dlrsReserve -= hubUnits;
            _payHubProRata(r, msg.sender, hubUnits, spokeAsset);
        }

        emit SpokeWithdrawn(poolId, msg.sender, shares, spokeUnits, hubUnits);
    }

    /// @dev Pay `units` of hub dollars to `to`, split across every hub asset in proportion to the hub's
    ///      reserves of it (floor per asset, rounding remainder distributed one unit at a time to assets
    ///      with spare reserve). Reverts if the hub's total reserves cannot cover `units`, which can only
    ///      happen after a governance write-down (`syncReserves`). `errAsset` names the pool in the error.
    function _payHubProRata(RegistryStorage.Layout storage r, address to, uint256 units, address errAsset) private {
        address[] storage hubAssets = r.pools[0].assets;
        uint256 n = hubAssets.length;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += r.reserves[0][hubAssets[i]];
        }
        if (total < units) revert IDollarStore.InsufficientReserves(errAsset, units, total);

        uint256[] memory pay = new uint256[](n);
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            pay[i] = Math.mulDiv(units, r.reserves[0][hubAssets[i]], total); // floor
            paid += pay[i];
        }
        // Floors lose at most one unit per asset; hand the remainder out where there is spare reserve.
        uint256 remainder = units - paid;
        for (uint256 i; remainder > 0; i = (i + 1) % n) {
            if (r.reserves[0][hubAssets[i]] > pay[i]) {
                pay[i] += 1;
                remainder -= 1;
            }
        }

        // Probe hub assets this exit does not pay.
        for (uint256 i; i < n; ++i) {
            if (pay[i] == 0) _probeIssuer(hubAssets[i], to);
        }

        for (uint256 i; i < n; ++i) {
            if (pay[i] == 0) continue;
            address h = hubAssets[i];
            r.reserves[0][h] -= pay[i];
            uint256 native = NormalizationLib.toNative(pay[i], r.assetConfig[h].scalingFactor);
            IERC20(h).safeTransfer(to, native);
            emit Withdraw(to, 0, h, pay[i], native);
        }
    }

    // ============ Issuer probe ============

    /// @dev Zero-value transfer probe: reverts if `asset` would not deliver to `wallet`. Answers as a real
    ///      payout would for tokens that apply their transfer controls before checking the amount; it does
    ///      not see a control that short-circuits zero-value transfers. Governance can exempt an asset
    ///      (setProbeExempt) if its token behaves that way or rejects zero-value transfers outright.
    function _probeIssuer(address asset, address wallet) private {
        if (RegistryStorage.layout().assetConfig[asset].probeExempt) return;
        (bool ok, bytes memory data) = asset.call(abi.encodeCall(IERC20.transfer, (wallet, 0)));
        bool delivered = ok && (data.length == 0 || abi.decode(data, (bool)));
        if (!delivered) revert IDollarStore.ExitBlockedByIssuer(asset, wallet);
    }

    /// @dev Probe every hub asset (a spoke exit whose hub leg is zero pays none of them).
    function _probeAllHub(RegistryStorage.Layout storage r, address wallet) private {
        address[] storage hubAssets = r.pools[0].assets;
        for (uint256 i; i < hubAssets.length; ++i) {
            _probeIssuer(hubAssets[i], wallet);
        }
    }
}
