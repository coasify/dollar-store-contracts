# DollarStore

DollarStore is an on-chain exchange for USD stablecoins. Users deposit a listed stablecoin, receive a receipt for it, and swap one listed stablecoin for another one-for-one. Swaps that cannot be filled immediately wait in a queue and are paid in order as liquidity arrives. The protocol charges no fee, holds no discretion over prices, and never consults one token's issuer about another's token.

This document describes the protocol as implemented in `src/`. It is written for someone reading the contracts: an integrator, an auditor, or an issuer's risk team. Roles, timelocks, and the emergency playbook are in [SECURITY.md](../SECURITY.md); building and testing are in [README.md](../README.md); deployment is in [DEPLOY.md](DEPLOY.md).

- Solidity 0.8.24, [Foundry](https://book.getfoundry.sh/), OpenZeppelin 5.6, UUPS proxy with ERC-7201 namespaced storage.
- Amounts in this document are in normalized 6-decimal units unless a native token amount is stated. A listed token may have 6 to 18 decimals; the contract scales every amount to 6 decimals internally and back on the way out.

## Contents

1. [Pools, assets, and receipts](#pools-assets-and-receipts)
2. [Deposits](#deposits)
3. [Exits](#exits)
4. [Swaps](#swaps)
5. [Queues](#queues)
6. [Parked positions](#parked-positions)
7. [Spoke lifecycle](#spoke-lifecycle)
8. [Loss events](#loss-events)
9. [Issuer freezes](#issuer-freezes)
10. [Roles](#roles)
11. [Views and events for integrators](#views-and-events-for-integrators)
12. [Reading the code](#reading-the-code)

## Pools, assets, and receipts

There is one **hub** pool, id 0, and any number of **spoke** pools, ids 1 and up. An asset is listed in exactly one pool at a time.

**Hub.** Holds several stablecoins side by side. Depositing a hub asset mints **DLRS**, a non-transferable 6-decimal receipt token, one for one. DLRS is a claim on the hub's reserves as a whole, not on the asset that was deposited. Total DLRS supply plus every spoke's claim on hub dollars equals total hub reserves, until governance writes hub reserves down after a loss (see [Loss events](#loss-events)).

**Spoke.** Holds one additional stablecoin, the spoke asset, plus a claim on hub dollars called its DLRS-side reserve. A spoke is owned by its liquidity providers through non-transferable **receipt shares**, minted pro rata against the spoke's total value when an LP deposits either the spoke asset or a hub asset into it. Spoke assets never back DLRS.

Each spoke has a governor-set **minimum DLRS-side reserve**. It is a floor for swaps out of the spoke asset only. LP exits are senior to it and may take the claim below it.

Every listed asset has a price feed. Inflows, meaning deposits and the offered side of a swap, are rejected if the feed is stale or the price is outside the peg tolerance. Outflows are never price-checked. Each pool may carry a launch cap on total value, checked on deposits only. The governor sets, raises, lowers or removes it; the guardian can only lower it.

## Deposits

`deposit(poolId, asset, amount, deadline)` pulls `amount` native units of `asset`. A hub deposit returns the DLRS minted, in 6-decimal units; a spoke deposit returns the receipt shares minted.

- Into the hub: `asset` must be a hub asset. DLRS is minted one for one.
- Into a spoke: `asset` is the spoke asset, which enters the spoke's reserve, or a hub asset, which enters hub reserves and raises the spoke's DLRS-side claim by the same amount. Either way the depositor receives receipt shares pro rata to the value added. A deposit into a spoke also settles that spoke's queues, see [Queues](#queues).

A deposit reverts if the contract is paused, the asset is not listed, deposits of it are paused, its pool is paused, the spoke is winding down, the price check fails, the launch cap would be exceeded, or the token takes a fee on transfer. A deposit into a spoke whose shares are outstanding but whose value is zero reverts `PoolFullyImpaired`: new capital must not revive worthless shares.

## Exits

`withdraw(poolId, units, deadline)` is the only exit, and it is proportional. The caller never chooses an asset.

- From the hub: burn `units` DLRS and receive a slice of every hub asset, split by reserve weight.
- From a spoke: burn `units` receipt shares and receive a slice of the spoke asset and a slice of the spoke's claim on hub dollars, the latter paid in hub assets by reserve weight.

The return value is `(spokeUnits, hubUnits)` in 6-decimal units, `spokeUnits` being zero for a hub exit. Native amounts of each hub asset paid are on the `Withdraw` events; the spoke-asset leg of a spoke exit is reported in 6-decimal units on `SpokeWithdrawn`. To end up entirely in one asset, withdraw and then swap; the swap respects the queue.

Exits cannot be paused and are not bounded by the minimum DLRS-side reserve. For each pool asset of which the exit pays none, because the pool holds none at the time or the holder's share of it rounds to zero, the contract first attempts a zero-value transfer of that asset to the caller and reverts `ExitBlockedByIssuer` if it fails. This gives every issuer in the pool a say on an exit that would otherwise never touch its token. The governor can exempt an asset from this probe; see [Issuer freezes](#issuer-freezes) for the limits.

## Swaps

Every swap is one for one in 6-decimal units between two listed assets. Three routes exist: hub asset to hub asset, hub asset to spoke asset, and spoke asset to hub asset. A swap between two spoke assets runs as two of these, see below.

`swap(offerAsset, wantAsset, amount, minAmountOut, tip, deadline)` pulls `amount` native units of the offered asset and fills in this order:

1. **The opposite queue.** Positions waiting to swap `wantAsset` for `offerAsset` are paid first, oldest first, peer to peer. No reserves move.
2. **Protocol reserves.** Only if no position is waiting in the same direction as this swap. A hub-to-hub swap draws on hub reserves. A hub-to-spoke swap adds to hub reserves and the spoke's claim, and pays from the spoke's reserve. A spoke-to-hub swap does the reverse, and cannot take the spoke's claim below its minimum. Before drawing on reserves, the swap first settles up to eight older same-direction positions, so nobody jumps the line.
3. **The queue.** Any remainder is escrowed as a position, see below.

`minAmountOut` is the least that must fill immediately, in 6-decimal units, else the call reverts; setting it to `amount` expressed in 6-decimal units demands a full immediate fill. `tip` is reserved and must be zero. The return value is `(amountFilled, amountQueued)`.

`swapExactInput(offerAsset, wantAsset, amount, minAmountOut, deadline)` is the router path: it fills fully or reverts, never queues, and returns the native amount delivered. `getSwapQuote` reports what a `swap` or `swapExactInput` of a given size would fill immediately. It does not quote spoke-to-spoke swaps directly; for a single hub asset, chain it over the two legs (see below).

`swapSpokeToSpoke(offerAsset, wantAsset, via, amount, deadline)` swaps one spoke asset for another through the hub assets listed in `via`, tried in order. For each, a spoke-to-hub leg fills what it can and a hub-to-spoke leg pays that amount out. Each leg fills by the rules above, opposite queue first and reserves only behind any same-direction queue, so a call may fill, reduce, or park other users' positions on the lines it touches, as any swap can. The call fills the full amount or reverts; it never queues. It returns the native amount delivered.

When both legs fill from reserves, the hub asset taken in the first leg pays the second, so hub reserves end unchanged and the offered spoke's claim on hub dollars moves to the wanted spoke. For the same reason, listing a hub asset twice can route more than its reserve. Reserve fills are bounded by the offered spoke's minimum DLRS-side reserve and the wanted spoke's reserve. To quote a single hub asset, chain `getSwapQuote(via, wantAsset, getSwapQuote(offerAsset, via, amount))`; the swap fills if the result, converted from the wanted asset's decimals to 6, equals `amount` converted from the offered asset's decimals to 6. For a list of hub assets, simulate the call. `getSwapQuote` takes and returns native units, returns 0 where the swap would revert on its route, pause or offer-price checks, and assumes every payout transfer succeeds.

The offered asset is price-checked as an inflow, and so is every `via` in a spoke-to-spoke swap, since the second leg moves it into hub reserves. The wanted asset is not.

## Queues

A **line** is the queue of positions waiting to swap one asset for another in one direction. Lines are keyed by offer asset, want asset, and pool: hub-to-hub lines belong to pool 0, and each spoke owns its own hub-to-spoke and spoke-to-hub lines. A spoke that is removed and later listed again therefore starts with empty lines; see [Spoke lifecycle](#spoke-lifecycle).

A **position** records its owner, offer asset, want asset, remaining amount, creation time, and pool. The offered tokens are held in escrow by the contract; nothing is minted against them and they back nothing.

Positions are paid in order, oldest first, by four things: a swap in the opposite direction; a later swap in the same direction, which settles up to 8 earlier positions from reserves before it fills itself; a deposit into the position's spoke that adds the side the line is waiting for (up to 8 positions per line); and `processQueue(offerAsset, wantAsset, maxPositions)`, which anyone may call to settle up to `maxPositions` positions from available reserves. `processQueue` reverts while the offered asset fails the inflow check (paused, off-peg or stale), because settling a position moves its escrow into reserves. A position may be filled in parts.

Lines have limits that make them expensive to abuse. A line holds at most 150 positions. The minimum is 500 (`500e6` in 6-decimal units) and rises tenfold for every 25 positions already in the line. It applies to the remainder a swap would queue, not to the swap's size, and the first position in an empty line is exempt. A swap whose remainder is below the minimum, or would join a full line, reverts as a whole (`OrderTooSmall`, `QueueFull`), including the part that could have filled.

`cancelQueue(positionId)` returns the escrowed asset to the owner and removes the position. Only the owner can cancel. No privileged role can cancel, move, or reassign a position.

## Parked positions

Paying a position means transferring the wanted asset to its owner. If that transfer fails, most often because the owner's wallet has been frozen by the wanted asset's issuer, the position is **parked**: unlinked from its line and appended to a per-asset parked line, with its escrow, owner, and amount untouched. The line it left keeps moving. Nothing is minted or moved.

A parked position cannot be filled. Its only exit is `cancelQueue`, which returns the escrowed asset once the transfer succeeds; a cancel that fails on an already parked position reverts `EscrowTransferFailed`. Cancelling a queued position whose refund fails parks it the same way. `QueueParked` is emitted on every park, and `isQueuePositionParked` reports the state.

The escrow of a parked position stays in the asset it was deposited as. It is never converted into DLRS, shares, or another token.

## Spoke lifecycle

A spoke has three states and can never move backwards. Removal does not require winding down first: any spoke with zero reserves can be removed.

| | Active | Winding down | Removed |
|---|---|---|---|
| Set by | `createSpoke` | `windDownSpoke`, governor | `removePool`, governor |
| Deposit into the spoke | yes | no | no |
| Buy the spoke asset with a hub asset | yes | yes, so the spoke can drain | no |
| Sell the spoke asset for a hub asset | yes, above the reserve floor | no | no |
| LP exit | yes | yes | nothing left to pay |
| Cancel a position | yes | yes | yes |

**Winding down** stops new value entering the spoke while letting value leave: LPs exit and buyers draw down the spoke asset. A buyer's unfilled remainder still queues during wind-down. The spoke's reserve can no longer grow, so it fills only from what remains; its owner can cancel at any time.

**Removal** requires the spoke asset reserve and the DLRS-side claim to be zero. Outstanding shares do not block it: a spoke whose value is gone can be retired with its worthless shares left on record. Positions still queued against the spoke do not block it either. They stay where they are, can never be filled, and remain cancellable by their owners. Removal pauses the pool, marks it removed, and unlists its asset. A removed pool cannot be unpaused or removed again.

**Relisting.** Once removed, the asset may be listed again, as a new spoke with `createSpoke` under a new pool id or as a hub asset with `addHubAsset`. Either way its lines start empty and no shares carry over; the old pool's positions and shares stay attached to the old id. A position's pool id is returned by `getQueuePosition` and carried on `QueueJoined`, so a frontend can tell a position on a removed pool from a live one.

An asset is not listed again while the contract holds less of it than the positions left behind are owed: `createSpoke` and `addHubAsset` revert `EscrowImpaired`. The guardian runs `haircutEscrow` for the asset first, or the balance is restored. The removed pool stays paused, so the haircut needs no further pause.

Relisting reads the token's decimals again. Positions left on the removed pool, and parked positions, store 6-decimal amounts and are refunded at the asset's current scaling, so governance must not relist an asset whose token changed its decimals while escrow of it remains. The contract does not check this.

A spoke cannot be relisted while it is winding down, since its asset is still listed. Reaching removal depends on every LP exiting; the protocol has no way to force that.

## Loss events

If tokens leave the contract other than through the protocol, for instance an issuer seizing them, the books exceed the balance. Two governance tools reconcile them. Both only ever write balances down; neither moves value to anyone.

- `syncReserves(poolId, asset)`, governor. Writes the pool's reserve of `asset` down to the balance minus queue escrow. Refuses to run if the balance is below the escrow alone.
- `haircutEscrow(asset, maxPositions)`, guardian, only while the asset's pool is paused. Reduces every position offering `asset`, across every pool that ever listed it and the parked line, by the same ratio so that escrow fits the balance minus reserves. Positions reduced to zero are removed. Reverts if more than `maxPositions` positions would be visited.

Which tool runs first decides whether reserves or queued positions absorb the loss. That is a governance decision and is not constrained by the contract.

## Issuer freezes

Every listed asset is issued by a party that can freeze wallets. The protocol keeps no list of its own and never asks one issuer about another's token. What it does:

- **Inflows.** A frozen wallet cannot deposit or open a swap, because the token itself refuses the transfer in.
- **Queued positions.** A position is paid by a real transfer of the wanted asset. If that transfer fails, the position is parked. The issuer of the escrowed asset is not consulted at settlement, so a wallet frozen on its escrowed asset after queueing, but not on the asset it wants, is still paid.
- **Spoke-to-spoke swaps.** The caller's offered and wanted assets are checked by their own transfers. The hub assets in `via` are never transferred to or from the caller, so their issuers are not consulted; a hub asset paid to a queued owner on the way is checked by that transfer.
- **Exits.** Every asset the exit pays is checked by its own transfer. Every pool asset the exit does not pay is probed with a zero-value transfer, so an issuer whose token the pool happens not to hold at that moment still has a say.

The probe is only as good as the token's transfer function. A token that rejects every zero-value transfer would block all exits that pay none of it; the governor exempts it with `setProbeExempt`, which disables the check for that asset. A token that short-circuits zero-value transfers before its freeze check is invisible to the probe; there is no on-chain remedy. Real transfers always run the token's own controls regardless.

## Roles

Three roles, each transferred in two steps. The upgrader and the governor hand themselves off; the guardian is replaced by the governor. Details, timelocks, and the emergency playbook are in [SECURITY.md](../SECURITY.md).

- **Upgrader.** Upgrades the implementation. Nothing else.
- **Governor.** Lists assets, creates and removes spokes, sets price feeds, peg tolerance, staleness, the reserve floor, launch caps, probe exemptions, and runs `syncReserves` and `rescueTokens`. Behind a timelock.
- **Guardian.** Pauses and unpauses globally, per asset, and per pool; tightens launch caps; runs `haircutEscrow`. No timelock.

A pause never blocks `withdraw` or `cancelQueue`. What each kind of pause blocks is tabulated in [SECURITY.md](../SECURITY.md#emergency-playbook-pause-then-fix).

What no role can do: cancel, move, reassign, or reprice a user's position other than through the pro-rata haircut after a real loss; choose which asset an exit pays; take escrow or reserves out of the contract. `rescueTokens` sweeps only balance above what the books account for, and queue escrow is always accounted for, whether or not its asset is still listed.

## Views and events for integrators

| Need | Use |
|---|---|
| A wallet's positions | `getUserQueuePositions(user)`, then `getQueuePosition(id)` for owner, assets, remaining amount, creation time, and pool id |
| Whether a position can still fill | `isQueuePositionParked(id)`, and `getPoolStatus` of the position's pool id: parked or on a removed pool means cancel is the only exit |
| How much a `swap` or `swapExactInput` fills now | `getSwapQuote(offer, want, amount)` |
| Whether a spoke-to-spoke swap through one hub asset fills | Chain `getSwapQuote(via, want, getSwapQuote(offer, via, amount))`. The swap fills if the final quote, converted to 6-decimal units, equals `amount` converted to 6-decimal units. For a list of hub assets, simulate the call |
| What a new position must be at least | `getMinimumOrderSize(offer, want)` |
| Depth waiting on a route | `getQueueDepth(offer, want)`, for the pool the pair currently routes through; `getQueueDepth(asset, address(0))` is the parked escrow of `asset`, listed or not |
| Pool contents | `getPoolAssets`, `getReserves`, `getReserve`, `getDlrsReserve`, `getReceiptShares`, `getReceiptTotalShares` |
| Pool and asset configuration | `poolCount`, `poolKind`, `getPoolStatus`, `assetPoolId`, `assetDecimals`, `isAssetListed`, `getLaunchCap`, `getMinDlrsReserve`, `isProbeExempt` |
| Pauses and price limits | `paused`, `isPoolPaused`, `isDepositPaused`, `pegTolerance`, `maxStaleness` |
| Which build is running | `version` |

Both pair views report an empty line (depth 0, base minimum) while either asset is unlisted, so a removed pool's lines never show there, before or after a relist. Positions on a removed pool are visible through `getUserQueuePositions` and `getQueuePosition` only.

Position history is reconstructable from `QueueJoined`, `QueueFilled`, `QueueParked`, and `QueueCancelled`, joined on position id, except after `haircutEscrow`: it reduces positions and emits only the aggregate `EscrowHaircut`, so read `getQueuePosition` afterwards. Pool history is on `PoolCreated`, `SpokeWindDownStarted`, `PoolPausedSet`, and `PoolRemoved`. Exits emit one `Withdraw` per hub asset paid plus `SpokeWithdrawn` for a spoke exit. A spoke-to-spoke swap emits one `Swap` for the whole call and one `SpokeSwapRouted` per hub asset it used, with the amount routed through it. Deposits emit `Deposit` (hub) or `SpokeLiquidityAdded` (spoke). Configuration and loss handling are on `AssetListed`, `LaunchCapSet`, `MinDlrsReserveSet`, `ProbeExemptSet`, `DepositsPausedSet`, `ReservesSynced`, `EscrowHaircut` and `TokensRescued`.

## Reading the code

```
src/
├── DollarStore.sol            entry point: roles, pools, deposit, withdraw, swap, queue, admin
├── DLRS.sol                   hub receipt token, non-transferable, 6 decimals
├── interfaces/IDollarStore.sol every external function and event, and most errors, with its contract
├── storage/                   ERC-7201 layouts: CoreStorage (roles), RegistryStorage (pools, assets),
│                              QueueStorage (lines, positions, escrow totals)
└── libraries/
    ├── SwapRouteLib.sol       route classification, fills, settlement, enqueue, cancel, parking
    ├── QueueLib.sol           the doubly linked line: enqueue, reduce, remove, park
    ├── SpokeLifecycleLib.sol  exits and the issuer probe, wind-down, removal, haircut
    ├── SpokeAdminLib.sol      spoke creation, reserve sync, token rescue
    ├── SpokeShareLib.sol      receipt-share math
    ├── PegLib.sol             price feed checks
    └── NormalizationLib.sol   decimal scaling
```

`DollarStore` sits close to the EIP-170 size limit, so the swap engine, exits, and the spoke lifecycle live in external libraries called by `delegatecall` over the same storage. The wrappers in `DollarStore` apply the access modifiers, and on user-facing calls the reentrancy guard, before delegating. A few errors are declared in the libraries that raise them: `PoolFullyImpaired`, `DepositTooSmall` and `ZeroValue` in `SpokeShareLib`, and `UnsupportedDecimals` in `NormalizationLib`.

Tests are in `test/`, one file per area, plus `test/invariant/` for randomized sequences and `test/fork/` for checks against the live tokens.
