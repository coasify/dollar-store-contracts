# Security

This document describes the trust model, on-chain roles, and operational
security posture for the DollarStore protocol. It is the reference for how
privileged powers are split and how emergencies are handled.

## Trust model at a glance

There are **five on-chain roles** plus a **transient deployer**. Powers are split
by blast radius: the two strongest roles (upgrades, and risk/registry params) sit
behind timelocks, and the roles that act instantly can only tighten, with one exception: lifting a
pause, which has its own role.

| Role | Who | Speed | Can do |
|---|---|---|---|
| **Upgrader** | TimelockController, long delay (proposed by a Safe) | Delayed (long timelock) | Replace the implementation (UUPS upgrade) |
| **Governor** | TimelockController, short delay (proposed by a Safe) | Delayed (short timelock) | List assets, create and retire spokes, set caps and reserve floors, oracle/risk params, reserve markdown, token rescue, role transfers |
| **Pausers** | A list of addresses, each a single key, a multisig or a contract | Instant | Pause everything, a pool, or an asset. Nothing else |
| **Unpauser** | Safe multisig, with a higher quorum than any pauser | Instant | Lift a pause; add or remove a pauser |
| **Guardian** | Safe multisig | Instant | Tighten caps, write queued positions down after a loss |
| **Veto** | Safe multisig, separate from the guardian | Instant | Cancel a queued timelock operation. Holds no role on DollarStore |
| **Deployer** | Deploy account | One-time | Deploy + initialize, then hands off. Holds no lasting power |

The upgrader, governor and guardian each have a two-step transfer (`transfer*` + `accept*`), so a
handoff requires the incoming address to explicitly accept. The governor replaces the unpauser in
one step (`setUnpauser`), which waits in the governor timelock like any other governor action.

## Upgrader (long timelock)

The upgrader holds the single most powerful authority: replacing the contract
code. It is isolated in its own role precisely because a bad or malicious upgrade
can rewrite everything, including every other control. Whoever can upgrade can
effectively become any other role, so this role gets the strongest protection:
the longest timelock delay and the best-guarded multisig.

Upgrader-gated functions:

- `upgradeToAndCall` (UUPS upgrade authority, via `_authorizeUpgrade`)
- `transferUpgrader` (self-managed: the upgrader hands itself off; the governor
  cannot rotate it, so a governor compromise cannot seize upgrade authority)

## Governor (short timelock)

The governor controls risk, registry and cap parameters. Every governor action is
subject to its timelock delay, which gives users a window to exit before a change
takes effect. It does **not** hold upgrade authority (that is the upgrader).

Governor-gated functions:

- `addHubAsset`, `setLaunchCap` (raise, lower or remove a cap)
- `createSpoke`, `setMinDlrsReserve`, `windDownSpoke`, `removePool`
- `setPriceFeed`, `setPegTolerance`, `setMaxStaleness`, `setProbeExempt`
- `syncReserves` (marks reserves down after a loss)
- `rescueTokens` (sweeps only unaccounted excess above reserves + escrow)
- `transferGovernor` (self-managed), `transferGuardian` (governor rotates the guardian),
  `setUnpauser` (governor replaces the unpauser)

What sits behind each timelock (this is what makes the delays meaningful):

- **PROPOSER** = a Safe multisig. A timelock proposed by a single EOA
  is theater; the proposer must itself be a multisig.
- **EXECUTOR** = open (`address(0)`), so execution does not depend on any single
  signer being available after the delay elapses.
- **CANCELLER** = the veto Safe, granted at deploy, so a malicious or mistaken queued proposal
  can be aborted even if a proposer Safe is compromised. Each proposer Safe also keeps cancel of its
  own queue (the OpenZeppelin constructor default). The guardian is not a canceller, as long as it is
  a different Safe from the veto Safe and from both proposer Safes.
- **Admin** = a temporary deployer admin, used only to grant the veto Safe its canceller role, then
  renounced in the same deploy, so no external admin remains and no one can silently reconfigure roles.

The guardian Safe is a different Safe from the veto Safe and from both proposer Safes; on Ethereum
mainnet the deploy script refuses to run if it equals any of them. A Safe that could both tighten
launch caps and cancel could lower every cap and then cancel the governor operations that restore
them or replace it. Kept apart, a guardian that has been compromised is replaced through the
governor timelock after its delay, and a veto Safe that has been compromised can block governance
but cannot touch the protocol, so it keeps running.

The upgrader and governor can share the same proposer Safe; what is separated is
the mechanism and the delay per class of action, and (optionally) the signer sets.

## Pausers and the unpauser (fast, no timelock)

Pausing and lifting a pause are separate roles, because one tightens and the other loosens.

**Pausers** are a list of addresses kept in the contract. Any one of them can call, alone:

- `pause` (global)
- `pauseDeposits` (per asset)
- `pausePool`

A pauser can do nothing else. It cannot lift a pause, including its own, and cannot change the list.
The worst a pauser can do, whether by mistake or with a stolen key, is stop new deposits and swaps
until the unpauser acts; exits and queue cancels stay open under every pause. That is why one
address is allowed to do it alone, and why a monitor can be given the role: its key signs without a
person, so it must not be able to do more than pause. An entry on the list can be a single key, a
multisig with any quorum, or a contract.

**The unpauser** is one address, expected to be a Safe with a higher quorum than any pauser.
It calls:

- `unpause` (global)
- `unpauseDeposits` (per asset)
- `unpausePool`
- `setPauser` (add or remove a pauser, with no delay)

Lifting a pause is the direction that can cost money: it reopens the pool to an asset that was
paused because it lost its value or its price feed failed. A pauser that should not be pausing is
removed by the unpauser at once, without waiting for a timelock. The unpauser has no power to pause,
but it sets the list, so it could list itself. Replacing the unpauser is governor-gated
(`setUnpauser`) and waits in the governor timelock.

A fresh deploy sets the unpauser and the first pausers in `initialize`. A proxy upgraded from an
implementation where the guardian paused starts with neither: nobody can pause, or lift a pause
already set, until the governor calls `setUnpauser` and the unpauser calls `setPauser`. Such an
upgrade is scheduled with `setUnpauser` queued in the governor timelock to execute at the same
time, and is not done while the protocol is paused.

## Guardian (fast, no timelock)

The guardian is an emergency role held by a Safe multisig. It cannot pause or unpause, move funds
to anyone, repoint the oracle, or upgrade.

Guardian-gated functions:

- `lowerLaunchCap` (tighten a cap; can never loosen or remove it)
- `haircutEscrow` (after a loss, reduces every queued and parked position offering an asset by
  the same ratio, so escrow fits what the contract holds beyond reserves). It runs only while the
  asset's pool is paused and the asset's balance is below reserves plus escrow, and it never pays
  anyone.

Rationale: the worst a compromised guardian can do is slow the system by tightening caps, and,
only when an asset's balance is really short and its pool has been paused, write queued positions
down by that shortfall. It cannot move funds, repoint the oracle, or upgrade. That bounded blast
radius is why it is allowed to act instantly.

Guardian rotation is **governor-gated**, not guardian-gated: a guardian cannot hand the role to
another address. Rotation goes through the governor timelock, and a guardian that is apart from the
veto Safe and the proposer Safes cannot cancel it.

## Deployer (transient)

The deployer is the account that runs the deploy script. It:

1. Deploys the implementation and the ERC1967 proxy.
2. Calls `initialize(upgrader, governor, guardian, unpauser, pausers)` with the production
   **Timelocks** (upgrader + governor), **Safes** (guardian, unpauser) and the first pausers. The
   governance deploy script refuses an empty pauser list, so the protocol is never live with nobody
   able to pause.

The deployer holds no lasting on-chain role. If, for setup convenience,
deployment temporarily assigns a role to an EOA, that role **must** be handed off
to the Timelock / Safe (two-step `transfer*` + `accept*`) and the temporary key
retired **before the first deposit**.

## Exit probe and issuer transfer controls

Exits are proportional: a holder receives their slice of every asset the pool holds. A leg that pays
is checked by the token's own transfer, which reverts if the issuer has frozen the recipient. A leg
that pays nothing, because the pool holds none of that asset at the time or the holder's share of
it rounds to zero, is probed with a zero-value
`transfer` from the contract to the caller, so the issuer of an asset the pool is backed by is still
consulted. The probe relies on the token applying its transfer controls before checking the amount.

Per token, checked against the mainnet contracts. `test/fork/IssuerProbeFork.t.sol` asserts
every row except USDG, which the fork test does not cover yet:

| Token | Restricts recipients | Zero-value transfer runs the control | Probe useful |
|---|---|---|---|
| USDC | yes | yes | yes |
| USDT | no (senders only) | n/a | consistent: a real payout to a frozen wallet also succeeds |
| PYUSD | yes | yes | yes |
| USDG | yes | yes | yes |
| RLUSD | yes (account pause) | yes | yes |
| USDS | no freeze exists | n/a | always passes |

The probe is a recipient check. A token whose freeze restricts senders only, as USDT's does, is not
covered: a frozen wallet can still receive it, so the probe passes and a payout in any asset goes
through. USDT is not on the launch list. **Listing precondition:** do not list a token with a
sender-only freeze without first adding an issuer-query adapter (for example calling the token's
`isBlackListed(address)` view) alongside the probe.

**Listing precondition:** do not list a token whose transfer calls the sender, the recipient or any
other address (a transfer hook or callback). Every function that moves tokens, plus `syncReserves`,
`addHubAsset`, `createSpoke`, `windDownSpoke` and `removePool`, is `nonReentrant`, so none of them can
run mid-transfer, but the contract is not designed or tested for tokens that run outside code during a
transfer. Check the bridged copy as well when listing on another chain.

Governance can exempt an asset from the probe (`setProbeExempt`). Exempting disables the issuer check
for exits that pay none of that asset; real transfers still run the token's controls. Use it only if a
token starts rejecting zero-value transfers (which would block such exits for everyone) or stops
applying its controls to them. The daily `fork-probe` CI job is the monitor for either change.

## Emergency playbook (pause-then-fix)

Because the dangerous knobs live behind the timelock, incidents are handled in
three moves:

1. **Any pauser pauses instantly** (global, per-pool, or per-asset). Exits (`withdraw`) and
   `cancelQueue` stay open under every pause.
2. **Governor fixes the root cause through its timelock** (repoint a broken feed,
   adjust tolerance, mark down reserves, sweep stray tokens). A code fix instead goes through the
   **upgrader** timelock.
3. **The unpauser lifts the pause.** No pauser can.

What each pause blocks:

| Pause | Blocks | Leaves open |
|---|---|---|
| Global (`pause`) | `deposit`, `swap`, `swapExactInput`, `swapSpokeToSpoke`, `processQueue`; `getSwapQuote` returns 0 | `withdraw`, `cancelQueue` |
| Per asset (`pauseDeposits`) | Deposits of the asset, swaps offering it, `swapSpokeToSpoke` routed through it, and `processQueue` on lines offering it | Swaps that pay the asset out, `withdraw`, `cancelQueue` |
| Per pool (`pausePool`), spoke | Deposits into the spoke, every swap that touches it in either direction, and `processQueue` on its lines | `withdraw`, `cancelQueue` |
| Per pool (`pausePool`), hub | Hub deposits, hub-asset deposits into spokes, swaps offering a hub asset, `swapSpokeToSpoke`, and `processQueue` on lines offering a hub asset | Spoke-to-hub `swap` and `swapExactInput` (they pay hub assets out), `withdraw`, `cancelQueue` |

Example: a Chainlink feed is deprecated. A pauser pauses the affected asset
immediately, the governor schedules `setPriceFeed`, and after the delay it is
executed and the unpauser lifts the pause on the asset.

Each price feed call may use at most 100,000 gas. A feed that answers with bad data or runs out of
that gas, for example one that never answers, reads as unhealthy: deposits that settle queues, quotes
and spoke-to-spoke routing skip the asset, and a swap or deposit of it reverts. A Chainlink feed read
costs a small fraction of the budget. A feed that ever needs more reads as unhealthy until the
governor repoints it or an upgrade raises the budget.

## Recommended launch parameters

- **Upgrader timelock delay**: 14 days. Upgrades are the highest-impact action, so
  they get the longest exit window.
- **Governor timelock delay**: 7 days. A full working week, so a queued operation
  cannot pass unseen over a weekend or a holiday. The instant pause is
  what covers true emergencies, so the governor delay does not need to be short.
- **Safe thresholds**: every Safe needs more than one signer. Each Safe's owners and threshold are
  readable on-chain.
- **Peg controls**: `pegTolerance` 0.5% (50 bps) default.
- **`maxStaleness`**: 25 hours (90,000s), the value a deploy now starts with.
  Chainlink's mainnet stablecoin feeds are heartbeat-driven at 24h and only update
  sooner on a deviation, so a healthy feed is routinely hours old: measured on
  2026-09-23, USDC/USD had last updated 1.1h earlier and USDT/USD 18.1h earlier.
  A window at or below the heartbeat marks a healthy feed as stale and reverts
  every swap. `setMaxStaleness` accepts up to 3 days, a ceiling with room for a
  48h heartbeat feed rather than a value anything runs with. Tighten the live
  value per deployment when every listed asset has a faster feed.

## Key hygiene

- Hardware wallets, independent seeds, and on-device verification of the
  transaction hash before signing. No blind signing (this class of mistake is
  what has broken other multisig setups).
- Publish signer addresses and the threshold for public review.

## Upgrades and storage

The protocol is UUPS-upgradeable; upgrade authority is the **upgrader** (a
long-delay timelock), separate from the governor. Storage uses ERC-7201 namespaced
layouts and is frozen for the v1 launch: upgrades are append-only and must not
reorder or retype existing fields.

## Reserve accounting

DLRS is fully backed: `totalSupply()` plus every spoke's claim on hub dollars (`dlrsReserve`)
equals the sum of hub reserves, and queue escrow is not counted as backing. `syncReserves` only ever decreases reserves,
to true them up to the real balance after an external loss. Because that
acknowledges a shortfall against outstanding DLRS claims, it is a governor
(timelock) decision, not a guardian one.

## Responsible disclosure

Report suspected vulnerabilities privately to **admin@dollarstore.world**. A
`/.well-known/security.txt` with the same contact will be published alongside the
deployment. Please do not disclose publicly until a fix has been deployed.

## Fully impaired spoke recovery

When recorded spoke reserves and DLRS-side reserves are zero but receipt shares remain,
`PoolFullyImpaired` rejects deposits. Governance can retire the pool with `removePool` once
its spoke reserve and DLRS-side reserve are zero. Outstanding worthless shares remain
recorded under the permanently killed poolId; they do not claim reserves in a replacement pool.
Governance can then call `createSpoke` for the same asset, which receives a fresh poolId and
starts with zero shares. Update integrations that cache poolIds to use the new asset registration.
No storage migration or holder enumeration is required.

Queued and parked positions do not block removal. Queue keys are pool-scoped, so positions left
in the killed pool's lines can never be filled and stay cancellable by their owners. If a token
blocks an escrow refund, the position is parked with its escrow untouched until the token allows
the transfer. This recovery path does not bypass token restrictions.
If the contract holds less of the asset than the positions left behind are owed, `createSpoke` and
`addHubAsset` revert `EscrowImpaired`. Run `haircutEscrow` for the asset first (the removed pool
stays paused, so no further pause is needed) or restore the balance, then relist.
Killed pools cannot be unpaused or removed again, including after the asset is relisted.
