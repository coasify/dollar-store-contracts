# Test map

Where each `src/` module is tested. The small pure libraries have a dedicated `*.t.sol` named after
them. The three large linked libraries (`SwapRouteLib`, `SpokeAdminLib`, `SpokeLifecycleLib`) run via
`delegatecall` over the proxy's ERC-7201 storage, so they are exercised through the proxy by the
feature-named integration suites listed below rather than by a same-named unit file.

## Core

| Module | Test file(s) |
|---|---|
| `DollarStore.sol` (init / roles / upgrade) | `DollarStore.t.sol` |
| `script/DeployGovernance.s.sol` | `DeployGovernance.t.sol` |
| `DollarStore.sol` (hub deposit / withdraw) | `HubDepositWithdraw.t.sol` |
| `DollarStore.withdraw` (exit issuer probe, in `SpokeLifecycleLib`) | `ExitIssuerProbe.t.sol`, `fork/IssuerProbeFork.t.sol` (needs `MAINNET_RPC_URL`) |
| `DollarStore.sol` (asset registry) | `AssetRegistry.t.sol` |
| `DollarStore.sol` (risk controls: pauses, peg, staleness) | `RiskControls.t.sol` |
| `DollarStore.sol` (who may pause and unpause: pausers, unpauser) | `PauseRoles.t.sol` |
| `DollarStore.sol` (launch caps) | `LaunchCaps.t.sol` |
| `DollarStore.createSpoke` with a launch cap, and `script/CreateSpoke.s.sol` (spokes created through the timelock, several queued at once) | `CreateSpoke.t.sol` |
| `DollarStore.sol` (governor operations run through the open timelock executor from a token callback) | `GovernorReentrancy.t.sol` |
| `DLRS.sol` (soulbound token, mint/burn authority) | `DLRS.t.sol` |

## Storage

| Module | Test file(s) |
|---|---|
| `storage/CoreStorage.sol` | `CoreStorage.t.sol` |
| `storage/QueueStorage.sol` | `QueueStorage.t.sol` |
| `storage/RegistryStorage.sol` | `RegistryStorage.t.sol` |

## Libraries

Small pure/internal libraries — dedicated unit files:

| Library | Test file(s) |
|---|---|
| `libraries/NormalizationLib.sol` | `NormalizationLib.t.sol` |
| `libraries/QueueLib.sol` | `QueueLib.t.sol` |
| `libraries/SpokeShareLib.sol` | `SpokeShareLib.t.sol` |
| `libraries/PegLib.sol` (oracle peg + inflow gate) | `RiskControls.t.sol`, `SpokeQueueTrigger.t.sol` |

Large linked libraries — tested through the proxy by the integration suites:

| Library | Responsibilities | Test file(s) |
|---|---|---|
| `libraries/SwapRouteLib.sol` | directed swap engine, FIFO fill/settle, processQueue, cancelQueue, parking, spoke-queue trigger, getSwapQuote, swapSpokeToSpoke | `HubSwapQueue.t.sol`, `HubSwapFallback.t.sol`, `SpokeSwap.t.sol`, `SpokeQueueTrigger.t.sol`, `RiskControls.t.sol`, `ParkedEscrow.t.sol`, `PoolScopedQueues.t.sol`, `SwapQuote.t.sol`, `SpokeToSpokeSwap.t.sol` |
| `libraries/SpokeAdminLib.sol` | createSpoke, syncReserves, rescueTokens | `SpokeDeposit.t.sol`, `SpokeCapsAndPauses.t.sol`, `SpokeLifecycle.t.sol` (createSpoke); `RiskControls.t.sol`, `HubDepositWithdraw.t.sol`, `SpokeWinddownHaircut.t.sol`, `SpokeImpairedRecovery.t.sol` (syncReserves); `RiskControls.t.sol`, `ParkedEscrow.t.sol` (rescueTokens) |
| `libraries/SpokeLifecycleLib.sol` | windDownSpoke, removePool, haircutEscrow, withdrawHub, withdrawSpoke, exit probe | `SpokeLifecycle.t.sol`, `SpokeWinddownHaircut.t.sol`, `SpokeWithdraw.t.sol`, `SpokeImpairedRecovery.t.sol`, `PoolScopedQueues.t.sol`, `ExitIssuerProbe.t.sol` |

## Invariants

`test/invariant/` (`DollarStoreInvariants.t.sol`, `Handler.sol`) drives randomized
deposit/withdraw/swap/cancel/process/spoke sequences and asserts five invariants across the whole
system: DLRS backing, solvency, escrow totals, line contents and position membership. The handler also winds down, retires and relists one spoke, so
positions from several pool generations coexist; escrow and per-line invariants are checked across them.
A second spoke stays active so spoke-to-spoke swaps always have a partner.

## Mocks and untested scripts

`test/utils/Pausers.sol` builds the pauser list that `initialize` takes. `test/mocks/` holds the test doubles: a plain ERC-20, one that blocks chosen senders or recipients,
one that takes a fee on transfer, one that re-enters the store on transfer, and a Chainlink-style
price feed.

`script/Upgrade.s.sol` has no test of its own. The upgrade path is exercised through the proxy in
`DollarStore.t.sol`.
