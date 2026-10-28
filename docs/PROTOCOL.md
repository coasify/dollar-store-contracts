# DollarStore

DollarStore is an on-chain exchange for USD stablecoins. Users deposit a listed stablecoin, receive a receipt for it, and swap one listed stablecoin for another one-for-one. Swaps that cannot be filled immediately wait in a queue and are paid in order as liquidity arrives. The protocol charges no fee, holds no discretion over prices, and never consults one token's issuer about another's token.

This document describes the protocol as implemented in `src/`. It is written for someone reading the contracts: an integrator, an auditor, or an issuer's risk team. Roles, timelocks, and the emergency playbook are in [SECURITY.md](../SECURITY.md); building and testing are in [README.md](../README.md); deployment is in [DEPLOY.md](DEPLOY.md).

- Solidity 0.8.24, [Foundry](https://book.getfoundry.sh/), OpenZeppelin 5.6, UUPS proxy with ERC-7201 namespaced storage.
- A listed token may have 6 to 18 decimals; the contract keeps its books in 6 decimals and converts at the edge. Units rule: token amounts a caller passes in, gets paid out, or sets as a minimum are in that token's own decimals ("native"). Receipt amounts are raw DLRS amounts or spoke-share counts. Accounting values (reserves, claims, queue amounts, caps, floors) stay in 6-decimal units, including where they appear in events and errors. The NatSpec states the units of every swap, queue, deposit and exit field; the remaining accounting views and governance events (reserves, claims, caps, floors) are always 6-decimal. [Units at the edge](#units-at-the-edge) lists the 6-decimal fields a caller meets around swaps, deposits and exits.
- Amounts in this document are in 6-decimal units unless a native token amount is stated.

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
11. [Integrating](#integrating)
12. [Views and events for integrators](#views-and-events-for-integrators)
13. [Reading the code](#reading-the-code)

## Pools, assets, and receipts

There is one **hub** pool, id 0, and any number of **spoke** pools, ids 1 and up. An asset is listed in exactly one pool at a time.

**Hub.** Holds several stablecoins side by side. Depositing a hub asset mints **DLRS**, a non-transferable 6-decimal receipt token, one for one. DLRS is a claim on the hub's reserves as a whole, not on the asset that was deposited. Total DLRS supply plus every spoke's claim on hub dollars equals total hub reserves, until governance writes hub reserves down after a loss (see [Loss events](#loss-events)).

**Spoke.** Holds one additional stablecoin, the spoke asset, plus a claim on hub dollars called its DLRS-side reserve. A spoke is owned by its liquidity providers through non-transferable **receipt shares**, minted pro rata against the spoke's total value when an LP deposits either the spoke asset or a hub asset into it. Spoke assets never back DLRS.

Each spoke has a governor-set **minimum DLRS-side reserve**. It is a floor for swaps out of the spoke asset only. LP exits are senior to it and may take the claim below it.

Every listed asset has a price feed. Inflows, meaning deposits and the offered side of a swap, are rejected if the feed is stale or the price is outside the peg tolerance. Outflows are never price-checked. Each pool may carry a launch cap, checked on deposits only. The hub's cap limits DLRS supply; a spoke's cap limits its own reserve plus its claim on hub dollars. A hub asset deposited into a spoke counts against that spoke's cap, not the hub's, so hub reserves can exceed the hub's cap by what spokes hold. The governor sets, raises, lowers or removes it; the guardian can only lower it.

## Deposits

`deposit(poolId, asset, amount, receiver, deadline)` is paid by the caller and owned by `receiver`. It pulls `amountIn = floor(amount / S) × S` of `asset` from the caller, with `S = 10^(decimals - 6)`, leaving any remainder below `S` with the caller (see [Worked examples](#worked-examples)), and credits the DLRS or receipt shares to `receiver`. It returns `(amountIn, receiptAmount)`: the native amount pulled, and the DLRS minted (6 decimals) for the hub or the receipt shares minted for a spoke. A caller depositing for itself passes its own address; the zero address and DollarStore revert `InvalidRecipient`.

A receiver lets a contract deposit for a user: a zap that swaps ETH to USDC and deposits in one transaction, a bridge that deposits on arrival, a treasury depositing for many wallets. Without it the contract would own the position, and since receipts cannot be transferred it could never hand it over. Two consequences follow:

- Anyone can deposit for any receiver, unasked. It takes nothing from the receiver, but a contract must not assume its receipt balance equals its own deposits, or is zero when it is set up.
- The position is inaccessible unless the receiver can call `withdraw`, and receipts cannot be transferred to another owner. Governance never moves positions, so a receiver that can never call `withdraw` leaves the position stuck for good. A frontend should default the receiver to the connected wallet and warn when it is changed.

- Into the hub: `asset` must be a hub asset. DLRS is minted one for one.
- Into a spoke: `asset` is the spoke asset, which enters the spoke's reserve, or a hub asset, which enters hub reserves and raises the spoke's DLRS-side claim by the same amount. Either way the depositor receives receipt shares pro rata to the value added. A deposit into a spoke also settles that spoke's queues, see [Queues](#queues).

A deposit reverts if the contract is paused, the asset is not listed, deposits of it are paused, its pool is paused, the spoke is winding down, the price check fails, the launch cap would be exceeded, or the token takes a fee on transfer. A deposit into a spoke whose shares are outstanding but whose value is zero reverts `PoolFullyImpaired`: new capital must not revive worthless shares.

## Exits

`withdraw(poolId, receiptAmount, minAmountsOut, deadline)` is the only exit, and it is proportional: an exact receipt amount in, a proportional basket out. The caller never chooses an asset. It is not ERC-4626: there are several assets, receipts cannot be transferred, and no one can exit for someone else.

- From the hub: burn `receiptAmount` DLRS and receive a slice of every hub asset, split by reserve weight.
- From a spoke: burn `receiptAmount` receipt shares and receive a slice of the spoke asset and a slice of the spoke's claim on hub dollars, the latter paid in hub assets by reserve weight.

It returns `(assets, amounts)`: every asset the exit can pay, the spoke asset first for a spoke exit and then every hub asset in listing order, and the native amount paid of each, 0 where nothing was paid. Each amount is in the decimals of the asset at the same position, so they must not be added together. For example, with a hub of 600 USDC and 400 USDS, burning 100 DLRS returns `assets = [USDC, USDS]`, `amounts = [60,000,000, 40,000,000,000,000,000,000]`. To end up entirely in one asset, withdraw and then swap; the swap respects the queue.

`minAmountsOut` is empty to accept the proportional payout, or one native minimum per entry of `assets`, in the same order. Any other length reverts `MinAmountsLength`, and an asset paying less than its minimum reverts `WithdrawMinNotMet`. What can change between quoting and executing is the mix: swaps, deposits and other exits move the hub's weights, and a write-down lowers a spoke's value. A minimum only lets the caller refuse its own exit; it never changes what the exit pays. Listing a hub asset adds a slot, so an old list reverts on length rather than being read against the wrong tokens.

`previewWithdraw(poolId, receiptAmount)` returns the same `(assets, amounts)` from the same calculation, including how rounding remainders are handed out. Anyone can preview any amount: it does not check the caller's balance. It reverts where the exit's calculation does (`ZeroAmount` for a value below one unit, `InsufficientReserves` when the hub cannot cover the payout) and on more than all outstanding DLRS or shares (`InsufficientReceiptShares`). It promises the calculation at the current state only, and it runs no transfer or issuer probe. Build minimums from its `assets`, not from `getPoolAssets`, which for a spoke lists only the spoke asset:

```solidity
(address[] memory assets, uint256[] memory quoted) = store.previewWithdraw(poolId, receiptAmount);
uint256[] memory mins = new uint256[](quoted.length);
for (uint256 i; i < quoted.length; ++i) mins[i] = quoted[i] * 99 / 100; // accept 1% less of each
(, uint256[] memory paid) = store.withdraw(poolId, receiptAmount, mins, deadline);
// paid[i] of assets[i] arrived, in that asset's decimals.
```

Exits cannot be paused and are not bounded by the minimum DLRS-side reserve. For each pool asset of which the exit pays none, because the pool holds none at the time or the holder's share of it rounds to zero, the contract first attempts a zero-value transfer of that asset to the caller and reverts `ExitBlockedByIssuer` if it fails. This gives every issuer in the pool a say on an exit that would otherwise never touch its token. The governor can exempt an asset from this probe; see [Issuer freezes](#issuer-freezes) for the limits.

## Swaps

Every swap is one for one between two listed assets, measured in 6-decimal units. Three routes exist: hub asset to hub asset, hub asset to spoke asset, and spoke asset to hub asset. A swap between two spoke assets runs as two of these, see below.

Every swap function takes `amount` as a native budget of the offered asset. With `S = 10^(decimals - 6)` for each token, it pulls `amountIn = floor(amount / S_offer) × S_offer`, and any remainder below `S_offer` stays with the caller; an `amount` below `S_offer` reverts `ZeroAmount`. The output is the filled units times `S_want`, which is exact, so a full fill delivers `floor(amount / S_offer) × S_want`. For example, 1,000.0000005 USDS (18 decimals) pulls 1,000 USDS and leaves 0.0000005 USDS with the caller; 1,000 USDC (6 decimals) swapped for USDS delivers 1,000,000,000,000,000,000,000. [Worked examples](#worked-examples) has every direction between 6 and 18 decimals. `minAmountOut` is compared with that native output exactly as passed, never converted to 6 decimals, so a minimum one wei above the output reverts.

`swapOrQueue(offerAsset, wantAsset, amount, minAmountOut, deadline)` fills what it can now and queues the rest, in this order:

1. **The opposite queue.** Positions waiting to swap `wantAsset` for `offerAsset` are paid first, oldest first, peer to peer. No reserves move.
2. **Protocol reserves.** Only if no position is waiting in the same direction as this swap. A hub-to-hub swap draws on hub reserves. A hub-to-spoke swap adds to hub reserves and the spoke's claim, and pays from the spoke's reserve. A spoke-to-hub swap does the reverse, and cannot take the spoke's claim below its minimum. Before drawing on reserves, the swap first settles up to eight older same-direction positions, so nobody jumps the line.
3. **The queue.** Any remainder is escrowed as a position owned by the caller, see below. The caller receives its later payouts and is the only address that can cancel it.

`minAmountOut` is the least native `wantAsset` that must be delivered now, else the call reverts `MinAmountNotMet`; setting it to the full output demands a full immediate fill. It returns `(amountIn, amountOut, amountInQueued, positionId)`: the native offered amount pulled, the native wanted amount delivered now, the part of `amountIn` escrowed in the queue (native offered asset), and the new position's id, 0 when nothing queued. `amountIn = (amountOut / S_want) × S_offer + amountInQueued`. Because it can leave a position owned by the caller, routers and solvers should not call it on a user's behalf.

`swapExactInput(offerAsset, wantAsset, amount, minAmountOut, recipient, deadline)` is the router path: it fills fully or reverts `InsufficientLiquidity`, never queues, and pays the output to `recipient`. A caller that wants the output passes its own address; the zero address and DollarStore itself revert `InvalidRecipient`. It returns `(amountIn, amountOut)`. `getSwapQuote` reports, in native `wantAsset`, what a `swapOrQueue` or `swapExactInput` of a given size would fill immediately. It does not quote spoke-to-spoke swaps directly; for a single hub asset, chain it over the two legs (see below).

`swapSpokeToSpoke(offerAsset, wantAsset, via, amount, recipient, deadline)` swaps one spoke asset for another through the hub assets listed in `via`, tried in order. For each, a spoke-to-hub leg fills up to what both legs can carry through that hub asset, and the hub-to-spoke leg pays it out; a hub asset that can carry nothing is skipped, and whatever is left moves on to the next one. Each leg fills by the rules above, opposite queue first and reserves only behind any same-direction queue, so a call may fill, reduce, or park other users' positions on the lines it touches, as any swap can. The call fills the full amount or reverts; it never queues. Hub assets are used greedily in list order: each carries as much as it can before the next is tried. It reverts when the list runs out before the full amount fills, or when a second leg pays out less than its first leg took: a payout to a queued owner failed, that position was parked, and the wanted spoke's reserve cannot cover the rest. Parking a position does not by itself revert the call. It pays `recipient`, with the same rules as `swapExactInput`, and returns `(amountIn, amountOut)`.

The result can depend on the order of `via`, and a list can revert when a different order or a shorter list would fill. Two hub assets share the offered spoke's hub claim and the wanted spoke's reserve, and positions already waiting on a line the call enters are paid first from them, as in any swap. For example, a trader swaps 200 of spoke asset A for spoke asset B with `via = [X, Y]`. A's spoke can hand out 200 of hub value, the hub holds enough X and Y, and B's spoke holds 200 of B. Earlier, someone queued to swap 100 A for X and is still waiting.

- `[X, Y]` reverts. On X's line the waiting position is ahead of the trader, so it is paid first and uses 100 of A's hub claim. The trader gets the other 100 through X. Y needs A's hub claim too, and none is left. The call reverts, and the waiting position's fill is undone with it.
- `[Y]` fills. No one waits on Y's line, so all 200 of A's hub claim goes to the trader. The waiting position keeps waiting.

The same happens on the second leg: a position waiting to swap X for B is paid first from B's reserve. With three or more hub assets, order can matter even when no one is queued ahead of the trader: one hub asset can use up both A's hub claim and B's reserve, when two others could each have paired one of them with a queued order. The contract keeps the caller's order, so a router should choose it: for each hub asset `X`, read the lines the call would use with `getQueueDepth`, list first those with a queued order on the other side (`getQueueDepth(X, A)` or `getQueueDepth(B, X)`), list last or drop those with positions waiting on the trader's lines (`getQueueDepth(A, X)` or `getQueueDepth(X, B)`), and simulate the call.

Before filling through each hub asset, the call works out what it can carry assuming every payout succeeds, since a failed payout is only found by trying it. A position waiting ahead on one of its lines whose owner the issuer has frozen is counted as if it will be paid, so the hub asset looks smaller by that position's amount until the position is parked. The real fill tries the payout and parks the position, so that amount is not spent, but that entry in the list cannot use it. A later entry is sized again and can, if this entry carried anything: an entry sized at 0 is skipped without trying any payout, so it parks no one. For example, A's spoke can hand out 1,000 of hub value, and a frozen owner waits ahead to swap 100 A for X:

- A trader swapping 500 or 900 through X fills. X is sized at 900, and on the way the frozen position is parked.
- A trader swapping 1,000 through X gets 900 through X. The other 100 needs a later entry in the list, another hub asset or X again (`[X, X]`), or the call reverts.
- After anyone calls `processQueue(A, X, ...)`, which parks the frozen position, the same 1,000 swap fills. `processQueue` only reaches the position when the line has something to pay it from, here A's hub claim above its minimum DLRS reserve. With nothing available it settles no one and parks nothing.
- If A's spoke could hand out only 100, the frozen position takes all of it, so X is sized at 0 and skipped without trying the payout. The position is not parked and listing X again does not help. Call `processQueue(A, X, ...)` first, or use another hub asset.

The same applies to a frozen owner waiting on a second-leg line. A router whose simulation reverts or falls short can list the hub asset again, or call `processQueue` on the lines the route uses and then swap, in one transaction from its own contract.

When both legs fill from reserves, the hub asset taken in the first leg pays the second, so hub reserves end unchanged and the offered spoke's claim on hub dollars moves to the wanted spoke. For the same reason, listing a hub asset twice can route more than its reserve. Reserve fills are bounded by the offered spoke's minimum DLRS-side reserve and the wanted spoke's reserve. To quote a single hub asset, chain `getSwapQuote(via, wantAsset, getSwapQuote(offerAsset, via, amount))`; a result equal to `floor(amount / S_offer) × S_want` means there is enough liquidity. A frozen owner on a queue the quote counts on is parked instead of paid, so the swap can get less than quoted and revert, and the swap also reverts if `recipient` cannot receive the wanted asset. For a list of hub assets, or to account for transfers, simulate the actual call with its caller and recipient. `getSwapQuote` takes and returns native units, returns 0 where the swap would revert on its route, pause or offer-price checks, takes no caller or recipient, and assumes every transfer succeeds.

The offered asset is price-checked as an inflow. In a spoke-to-spoke swap each `via` is checked too, since the second leg moves it into hub reserves, and one that fails the check is skipped. The wanted asset is not.

A skipped `via` does not report why it was skipped. If skipping leaves a spoke-to-spoke swap short, the call reverts `InsufficientLiquidity` like any other shortfall, and `fillableAmountOut` counts only what the remaining entries carried. So while the hub pool is paused, or a hub asset's deposits are paused, or its feed is stale, off peg or unreadable, a call through that hub asset alone, or through only such hub assets, reverts `InsufficientLiquidity(wantAsset, 0, requestedAmountOut)`. A smaller amount or another order of the same list fails the same way. A global pause, a paused spoke, and a failed check on the offered asset still revert with their own errors. Before treating the revert as a liquidity shortage, check each `via`: `isPoolPaused(0)`, `isDepositPaused(via)`, and its feed (from `AssetListed`, or the latest `PriceFeedUpdated`) against `maxStaleness()` and `pegTolerance()`. Pauses are also announced to integrators when they are made.

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

**Relisting.** Once removed, the asset may be listed again, as a new spoke with `createSpoke` under a new pool id or as a hub asset with `addHubAsset`. Either way its lines start empty and no shares carry over; the old pool's positions and shares stay attached to the old id. A position's pool id is returned by `getQueuePosition` and carried on `QueueJoined`, so a frontend can tell a position on a removed pool from a live one. The asset keeps its deposit pause and probe exemption: a pause set before removal stays until the unpauser lifts it.

An asset is not listed again while the contract holds less of it than the positions left behind are owed: `createSpoke` and `addHubAsset` revert `EscrowImpaired`. The guardian runs `haircutEscrow` for the asset first, or the balance is restored. The removed pool stays paused, so the haircut needs no further pause.

Relisting reads the token's decimals again. Positions left on the removed pool, and parked positions, store 6-decimal amounts and are refunded at the asset's current scaling, so governance must not relist an asset whose token changed its decimals while escrow of it remains. The contract does not check this.

A spoke cannot be relisted while it is winding down, since its asset is still listed. Reaching removal depends on every LP exiting; the protocol has no way to force that.

## Loss events

If tokens leave the contract other than through the protocol, for instance an issuer seizing them, the books exceed the balance. Two governance tools reconcile them. Both only ever write balances down; neither moves value to anyone.

- `syncReserves(poolId, asset)`, governor. Writes the pool's reserve of `asset` down to the balance minus queue escrow. Refuses to run if the balance is below the escrow alone, and reverts `ReservesNotDrifted` if there is no loss to write down. Anyone can send tokens to the contract, so anyone can repair a small deficit after a sync is scheduled and make it revert. Schedule each `syncReserves` as its own timelock operation, never in a batch with other calls: a repaired asset's sync then fails on its own, with nothing left to do, and cannot roll back the write-down of another asset.
- `haircutEscrow(asset, maxPositions)`, guardian, only while the asset's pool is paused. Reduces every position offering `asset`, across every pool that ever listed it and the parked line, by the same ratio so that escrow fits the balance minus reserves. Positions reduced to zero are removed. Reverts if more than `maxPositions` positions would be visited.

Which tool runs first decides whether reserves or queued positions absorb the loss. That is a governance decision and is not constrained by the contract.

A spoke loss written down by `syncReserves` is shared by the spoke's LPs pro rata through their shares. A hub exit redeems DLRS at par from the hub reserves, so after a hub write-down, exits are paid in full in the order they arrive until a reserve runs short, and the holders who exit last bear the loss.

## Issuer freezes

Every listed asset is issued by a party that can freeze wallets. The protocol keeps no list of its own and never asks one issuer about another's token. What it does:

- **Inflows.** A frozen wallet cannot deposit or open a swap, because the token itself refuses the transfer in.
- **Queued positions.** A position is paid by a real transfer of the wanted asset. If that transfer fails, the position is parked. The issuer of the escrowed asset is not consulted at settlement, so a wallet frozen on its escrowed asset after queueing, but not on the asset it wants, is still paid.
- **Spoke-to-spoke swaps.** The caller's offered and wanted assets are checked by their own transfers. The hub assets in `via` are never transferred to or from the caller, so their issuers are not consulted; a hub asset paid to a queued owner on the way is checked by that transfer.
- **Exits.** Every asset the exit pays is checked by its own transfer. Every pool asset the exit does not pay is probed with a zero-value transfer, so an issuer whose token the pool happens not to hold at that moment still has a say.

The probe is only as good as the token's transfer function. A token that rejects every zero-value transfer would block all exits that pay none of it; the governor exempts it with `setProbeExempt`, which disables the check for that asset. A token that short-circuits zero-value transfers before its freeze check is invisible to the probe; there is no on-chain remedy. Real transfers always run the token's own controls regardless.

## Roles

Five roles. The upgrader and the governor hand themselves off in two steps; the governor replaces the guardian (two steps) and the unpauser (one step). Details, timelocks, and the emergency playbook are in [SECURITY.md](../SECURITY.md).

- **Upgrader.** Upgrades the implementation. Nothing else.
- **Governor.** Lists assets, creates and removes spokes, sets price feeds, peg tolerance, staleness, the reserve floor, launch caps, probe exemptions, and runs `syncReserves` and `rescueTokens`. Behind a timelock.
- **Pausers.** A list of addresses. Any one of them pauses globally, per asset, or per pool, alone and with no timelock. A pauser can do nothing else: it cannot lift a pause or change the list.
- **Unpauser.** Lifts a pause globally, per asset, or per pool, and adds or removes a pauser with `setPauser`. No timelock. It has no power to pause.
- **Guardian.** Tightens launch caps; runs `haircutEscrow`. No timelock. It cannot pause or unpause.

A pause never blocks `withdraw` or `cancelQueue`. What each kind of pause blocks is tabulated in [SECURITY.md](../SECURITY.md#emergency-playbook-pause-then-fix).

What no role can do: cancel, move, reassign, or reprice a user's position other than through the pro-rata haircut after a real loss; choose which asset an exit pays; take escrow or reserves out of the contract. `rescueTokens` sweeps only balance above what the books account for, and queue escrow is always accounted for, whether or not its asset is still listed.

## Integrating

How to call DollarStore from a wallet, an app or a router contract. Every token amount below is native, in the token's own decimals; [Units at the edge](#units-at-the-edge) lists the exceptions and [Worked examples](#worked-examples) shows the numbers.

### Where funds can get stuck

> [!CAUTION]
> **No privileged role can move, cancel or reassign a position for a user.** DollarStore only rejects the zero address and its own address as a `receiver` or `recipient`. Every other address is accepted, so these mistakes are permanent:
>
> - **A deposit to a `receiver` that cannot call `withdraw` is stuck for good.** Only the receiver can exit, and receipts cannot be transferred. A typo, an address nobody holds the key to, or a contract with no way to call `withdraw` all lock the deposit.
> - **A swap's output goes to `recipient` at once and cannot be reversed.** `swapExactInput` and `swapSpokeToSpoke` pay whatever address is passed.
> - **A `swapOrQueue` sent by a contract leaves the queued part owned by that contract.** Only the owner can cancel, and later fills are paid to it. A router that cannot call `cancelQueue` or pass on what arrives later strands the user's money. Contracts should call `swapExactInput` instead.
>
> Two cases are outside the user's control. A queued or parked position, or an exit, can stay blocked while an issuer freezes the owner's wallet: a parked position's only exit is `cancelQueue`, which needs the refund transfer to succeed, and an exit cannot complete while the issuer of any asset it pays or probes refuses a transfer to the wallet (the token's own error, or `ExitBlockedByIssuer`). See [Parked positions](#parked-positions) and [Issuer freezes](#issuer-freezes).

### Approvals

Deposits and swaps pull the offered token from the caller with `transferFrom`, so the caller approves DollarStore for it first. An exit needs no approval: it burns the caller's DLRS or receipt shares directly. Receipts cannot be transferred, so a deposit's position always belongs to the `receiver` named in the call.

### Depositing

```solidity
IERC20(asset).forceApprove(address(store), amount);
(uint256 amountIn, uint256 receiptAmount) = store.deposit(poolId, asset, amount, user, deadline);
// poolId 0 is the hub. `amount - amountIn` (under one 6-decimal unit) stayed with the caller.
```

Pass the user's own address as `receiver` unless a contract is depositing for someone else. **A receiver that cannot call `withdraw` locks the deposit for good** ([Where funds can get stuck](#where-funds-can-get-stuck)). A frontend should default to the connected wallet and warn when the receiver is changed.

### Swapping

| Who is calling | Function | Why |
|---|---|---|
| A user, from their own wallet, willing to wait for part of it | `swapOrQueue` | Fills what it can now and queues the rest as a position the caller owns. Track it with the returned `positionId` |
| A router, an aggregator or any contract acting for a user | `swapExactInput` | All or nothing, never queues, pays `recipient`. A queued position would belong to the router, not the user |
| Either, between two spoke assets | `swapSpokeToSpoke` | All or nothing through the hub assets in `via`, in order; see [Swaps](#swaps) for how to order them |

**A wrong `recipient` cannot be undone, and a contract calling `swapOrQueue` owns whatever it queues** ([Where funds can get stuck](#where-funds-can-get-stuck)). The router path is the adapter under [Units at the edge](#units-at-the-edge).

### Exiting

Preview, set minimums from the preview, then withdraw; the code is under [Exits](#exits). Exits cannot be paused. Each amount returned is in the decimals of the asset at the same position.

### Simulating before sending

The views compute amounts but take no caller or recipient and move no tokens. `getSwapQuote` and `previewWithdraw` therefore cannot see a missing approval or balance, a caller or recipient frozen by an issuer, a payout to a queued owner that will fail, or an issuer blocking an exit's zero-value probe. A simulation can: run the exact call as an `eth_call` from the user's address, with the real arguments, and read what it returns or the error it reverts with. A successful simulation returns the same values the transaction would at that block.

With Foundry's `cast`, for 1,000.0000005 USDS to USDC paid to the user:

```bash
cast call "$STORE" \
  "swapExactInput(address,address,uint256,uint256,address,uint256)(uint256,uint256)" \
  "$USDS" "$USDC" 1000000000500000000000 0 "$USER" "$DEADLINE" \
  --from "$USER" --rpc-url "$RPC_URL"
# prints amountIn and amountOut: 1000000000000000000000 and 1000000000 when liquidity covers it
```

In viem, `publicClient.simulateContract({ account: user, address: store, abi, functionName: "swapExactInput", args })` does the same and returns `result`. For an exit, simulate `withdraw` itself, not only `previewWithdraw`, to include the issuer probes and transfers.

Then:

- Set `minAmountOut`, or each entry of `minAmountsOut`, from the simulated result, less the tolerance the user accepts. A minimum of 0 in the simulation shows the output without rejecting it; never send 0.
- Simulate after the approval, or with a state override that sets it; otherwise the simulation reverts on `transferFrom`.
- Use a short `deadline`. Between simulation and inclusion other swaps, deposits, exits, price updates and freezes can change the result; the minimum and the deadline are what protect the user, not the simulation.

### Reading a revert

| Error | What it means | What to do |
|---|---|---|
| `DeadlineExpired` | The transaction landed after `deadline` | Simulate again and resend |
| `ZeroAmount` | The amount is below one 6-decimal unit, or an exit is worth less than one unit | Send more |
| `MinAmountNotMet(wantAsset, amountOut, minAmountOut)` | The swap would deliver `amountOut`, below the minimum | Simulate again; the state moved |
| `InsufficientLiquidity(wantAsset, fillableAmountOut, requestedAmountOut)` | An all-or-nothing swap can deliver only `fillableAmountOut` now. On `swapSpokeToSpoke` it can also mean hub assets in `via` were skipped because the hub is paused, their deposits are paused or their price check failed; with every `via` skipped, `fillableAmountOut` is 0 (see [Swaps](#swaps)) | Check the `via` hub assets first; if they are healthy, swap a smaller amount, try another `via` order, or let the user queue with `swapOrQueue` |
| `OrderTooSmall`, `QueueFull` | The remainder `swapOrQueue` would queue is below the line's minimum, or the line is full; the whole swap reverts | Swap only what fills now, or use `swapExactInput` |
| `InvalidRecipient` | The recipient or receiver is the zero address or DollarStore | Pass the user's address |
| `MinAmountsLength`, `WithdrawMinNotMet` | The minimums list does not match the exit's assets, or an asset pays less than its minimum | Build the list from `previewWithdraw` again |
| `InsufficientReceiptShares(requested, available)` | A spoke exit of more shares than the caller holds | Withdraw less |
| `ERC20InsufficientBalance(caller, balance, needed)`, from the DLRS token | A hub exit of more DLRS than the caller holds. The exit burns the DLRS first, so the token reverts, not DollarStore. `previewWithdraw` checks only the total supply, so it does not catch this | Withdraw less |
| `InsufficientReserves` | The hub cannot cover the payout, usually after a loss | See [Loss events](#loss-events) |
| `ExitBlockedByIssuer(asset, wallet)` | An issuer refuses even a zero transfer to `wallet` | Nothing the caller can change; see [Issuer freezes](#issuer-freezes) |
| `PriceOutOfBounds`, `PriceStale`, `StaleRound`, `InvalidPrice` | The price check on the asset coming in failed | Try later or with another asset |
| `AssetNotListed(asset)` | The asset is not listed, or was removed | Use a listed asset (`isAssetListed`) |
| `WrongPool(asset, poolId)` | A spoke asset deposited into the hub or into another spoke | Deposit it into its own spoke, `assetPoolId(asset)`. Hub assets can go into the hub or any spoke |
| `LaunchCapExceeded(poolId, attempted, cap)` | The deposit would take the pool above its launch cap. `attempted` and `cap` are 6-decimal: DLRS supply for the hub, the spoke's reserve plus its hub claim for a spoke | Deposit at most `cap` minus what the pool already holds, or another pool |
| `PoolFullyImpaired` | A deposit into a spoke whose shares are outstanding but whose value is zero | Nothing the caller can change |
| `FeeOnTransferNotSupported(asset)` | The contract received less than the amount pulled: the token charged a fee | Nothing the caller can change |
| `EnforcedPause`, `PoolPaused`, `DepositsPaused`, `SpokeWindingDown` | Swaps or deposits are paused, or the spoke takes no new money | Try later; exits stay open |
| An error from the token itself | A transfer failed: no approval or balance, or a frozen caller or recipient | Fix the approval or balance, or use another recipient |

## Views and events for integrators

| Need | Use |
|---|---|
| A wallet's positions | `getUserQueuePositions(user)`, then `getQueuePosition(id)` for owner, assets, remaining amount, creation time, and pool id |
| Whether a position can still fill | `isQueuePositionParked(id)`, and `getPoolStatus` of the position's pool id: parked or on a removed pool means cancel is the only exit |
| How much a `swapOrQueue` or `swapExactInput` fills now | `getSwapQuote(offer, want, amount)`, native `want`; a full fill is `floor(amount / S_offer) × S_want` |
| Whether a spoke-to-spoke swap through one hub asset fills | Chain `getSwapQuote(via, want, getSwapQuote(offer, via, amount))`. A final quote equal to `floor(amount / S_offer) × S_want` means there is enough liquidity; the swap still needs every transfer to succeed, including payouts to queued owners and the final one to `recipient`. For a list of hub assets, simulate the call |
| What an exit would pay now | `previewWithdraw(poolId, receiptAmount)`: every asset the exit can pay and its native amount, in the order `withdraw` returns and takes minimums |
| What a new position must be at least | `getMinimumOrderSize(offer, want)` |
| Depth waiting on a route | `getQueueDepth(offer, want)`, for the pool the pair currently routes through; `getQueueDepth(asset, address(0))` is the parked escrow of `asset`, listed or not |
| Pool contents | `getPoolAssets`, `getReserves`, `getReserve`, `getDlrsReserve`, `getReceiptShares`, `getReceiptTotalShares` |
| Pool and asset configuration | `poolCount`, `poolKind`, `getPoolStatus`, `assetPoolId`, `assetDecimals`, `isAssetListed`, `getLaunchCap`, `getMinDlrsReserve`, `isProbeExempt` |
| Pauses and price limits | `paused`, `isPoolPaused`, `isDepositPaused`, `pegTolerance`, `maxStaleness` |
| Who can pause and unpause | `isPauser(account)`, `unpauser` |
| Which build is running | `version` |

Both pair views report an empty line (depth 0, base minimum) while either asset is unlisted, so a removed pool's lines never show there, before or after a relist. Positions on a removed pool are visible through `getUserQueuePositions` and `getQueuePosition` only.

Position history is reconstructable from `QueueJoined`, `QueueFilled`, `QueueParked`, and `QueueCancelled`, joined on position id, except after `haircutEscrow`: it reduces positions and emits only the aggregate `EscrowHaircut`, so read `getQueuePosition` afterwards. Pool history is on `PoolCreated`, `SpokeWindDownStarted`, `PoolPausedSet`, and `PoolRemoved`. Exits emit one `Withdraw` per asset paid, the spoke asset included, tagged with the pool exited, plus `SpokeWithdrawn` for a spoke exit. An asset paid nothing has no `Withdraw`; its slot in the return is 0. `Swap` reports one call in native units: `caller` paid `amountIn`, `recipient` received `amountOut` now, and `amountInQueued` of the input was escrowed; later payouts to that position are on `QueueFilled`, in 6-decimal units, so count them separately from the immediate output. A spoke-to-spoke swap emits one `Swap` for the whole call and one `SpokeSwapRouted` per hub asset it used, with the 6-decimal amount routed through it. Deposits emit `Deposit` (hub) or `SpokeLiquidityAdded` (spoke), never both; each indexes the `receiver` that owns the position and records the `caller` that paid. Configuration and loss handling are on `AssetListed`, `LaunchCapSet`, `MinDlrsReserveSet`, `ProbeExemptSet`, `DepositsPausedSet`, `ReservesSynced`, `EscrowHaircut` and `TokensRescued`. Changes to who may pause are on `PauserSet` and `UnpauserSet`.

### Units at the edge

Native, in the token's own decimals: every swap function's `amount`, `minAmountOut`, `amountIn`, `amountOut` and `amountInQueued`; the `Swap` event; `MinAmountNotMet` and `InsufficientLiquidity` (both name the wanted asset); `getSwapQuote`; deposit `amount` and `amountIn`; `Deposit.amountIn`; the `withdraw` and `previewWithdraw` `amounts`, `minAmountsOut` and `WithdrawMinNotMet`; and the `nativeAmount` fields of `Withdraw` and `SpokeLiquidityAdded`. Receipt amounts (`receiptAmount`, `Deposit.receiptAmount`, `SpokeLiquidityAdded.sharesMinted`, `SpokeWithdrawn.sharesBurned`) are DLRS amounts or share counts.

In 6-decimal units, and named so where they are named: the queue events (`QueueJoined`, `QueueFilled`, `QueueCancelled`, `QueueParked`) and queue views (`getQueuePosition`, `getQueueDepth`, `getMinimumOrderSize`, `processQueue`'s amount); `OrderTooSmall`; `SpokeSwapRouted`'s amount; reserves, claims, caps and floors and their events and errors, including `InsufficientReserves`, whose amounts are hub totals even though it names an asset; `Withdraw.units`; `SpokeLiquidityAdded.valueUnits`; `SpokeWithdrawn.spokeUnits` and `hubUnits`. DLRS has 6 decimals, so a DLRS amount is both. Spoke receipt shares are a count, not dollars.

### Worked examples

Every number below is the raw integer passed to or returned by the contract, with USDC and USDT (6 decimals) and USDS and DAI (18 decimals) as the example tokens. Each is pinned by a test in `test/UnitExamples.t.sol`.

**Swaps.** `swapExactInput` with enough liquidity, and `minAmountOut` set to demand the full fill:

| Swap | `amount` passed | `amountIn` pulled | Left with the caller | `amountOut` and the full-fill `minAmountOut` |
|---|---|---|---|---|
| USDC to USDS (6 to 18) | `1000000000` (1,000 USDC) | `1000000000` | nothing | `1000000000000000000000` (1,000 USDS) |
| USDS to USDC (18 to 6) | `1000000000500000000000` (1,000.0000005 USDS) | `1000000000000000000000` | `500000000000` (0.0000005 USDS) | `1000000000` (1,000 USDC) |
| USDS to DAI (18 to 18) | `1000000000500000000000` (1,000.0000005 USDS) | `1000000000000000000000` | `500000000000` (0.0000005 USDS) | `1000000000000000000000` (1,000 DAI) |
| USDC to USDT (6 to 6) | `1000000000` (1,000 USDC) | `1000000000` | nothing | `1000000000` (1,000 USDT) |

- Only an offered token with more than 6 decimals can leave dust: the part below one 6-decimal unit (`10^12` wei for USDS). The contract never pulls it, so it stays in the caller's wallet and needs no refund. `amount - amountIn` is how much stayed.
- An `amount` below one 6-decimal unit pulls nothing and reverts `ZeroAmount`: 0.0000009 USDS is `900000000000`.
- `minAmountOut` is in the wanted token's decimals. For a USDS output, `1000000000` means 0.000000001 USDS, not 1,000 USDS, so it accepts almost any fill: with 1 USDS in the hub, a 1,000 USDC `swapOrQueue` with that minimum fills 1 USDS (`1000000000000000000`) and queues 999 USDC (`amountInQueued = 999000000`).

**Deposit.** Depositing `100000000500000000000` (100.0000005 USDS) into the hub pulls `amountIn = 100000000000000000000` (100 USDS), mints `receiptAmount = 100000000` (100 DLRS), and leaves `500000000000` (0.0000005 USDS) in the caller's wallet. A USDC deposit never leaves dust.

**Withdrawal.** With a hub of 600 USDC and 400 USDS, `withdraw(0, 100000000, [], deadline)` burns 100 DLRS and returns `assets = [USDC, USDS]` and `amounts = [60000000, 40000000000000000000]`: 60 USDC and 40 USDS, each in its own decimals, so the two numbers must not be added. `previewWithdraw(0, 100000000)` returns the same. Minimums, if given, follow the same order and decimals: `[59000000, 39000000000000000000]` accepts up to 1 less of each.

A minimal exact-input adapter, for a router that holds the offered token:

```solidity
IERC20(offer).forceApprove(address(store), amount);
(uint256 amountIn, uint256 amountOut) =
    store.swapExactInput(offer, want, amount, minAmountOut, user, deadline);
// amountOut of `want` went to `user`. `amount - amountIn` (under one 6-decimal unit of `offer`)
// stayed with the router: refund it or keep it, but do not assume the whole `amount` was spent.
```

To quote it first: `getSwapQuote(offer, want, amount)` returns what fills now in native `want`. A result equal to `floor(amount / S_offer) × S_want` means there is enough liquidity for a full fill. A quote takes no caller or recipient and checks no transfer permission, so the call still needs every transfer to succeed: payouts to queued owners, and the final transfer to `recipient`. Set `minAmountOut` from the quote, and simulate the actual call, with its caller and recipient, when certainty matters.

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
