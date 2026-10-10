# Continuous Integration

CI runs on every push to `main`, on every pull request, and once a day. The workflow is
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). It has three jobs, and all three run on
each trigger.

## Job 1: build + test + coverage

Runs at the repository root:

1. **Install Foundry** (`foundry-rs/foundry-toolchain`, pinned to `v1.8.3`).
2. **Dependencies**: checked out as git submodules under `lib/`, pinned to exact
   commits: OpenZeppelin Contracts `v5.6.1`, OpenZeppelin Contracts Upgradeable `v5.6.1`, and
   `forge-std` `v1.16.2`.
3. **Format check**: `forge fmt --check` (fails on unformatted code).
4. **Build**: `forge build --sizes`.
5. **Test**: `forge test -vvv` (unit + fuzz + invariant suites).
6. **Coverage gate**: `forge coverage --report lcov --ir-minimum`, then
   [`.github/scripts/coverage_gate.py`](../.github/scripts/coverage_gate.py) parses `lcov.info` and fails the build if line
   coverage of `src/` is below the threshold.

## Job 2: static analysis (Slither)

Runs `crytic/slither-action` against the repository using
[`slither.config.json`](../slither.config.json). It builds the project and runs Slither with
`fail-on: high`, so the job fails only on high-severity findings (medium/low/informational are
reported but do not block).

## Job 3: exit probe vs mainnet tokens (`fork-probe`)

Runs `test/fork/` against a mainnet fork. These tests
verify that the exit probe (a zero-value `transfer` to the caller for each pool asset an exit does not
pay) answers correctly for the real contracts of every token the protocol intends to list: it must
succeed to an unrestricted wallet and, for tokens that restrict recipients, fail to a frozen one.

The job needs the `MAINNET_RPC_URL` repository secret and fails if it is missing, because the fork
tests skip silently without it. Pull requests from forks do not receive repository secrets, so the
job fails on them. The daily run is the monitor for a listed token changing its
zero-value transfer behavior; a failure there means the probe no longer answers as a real payout
would for that token, and governance should consider `setProbeExempt` for it.

## Thresholds

| Check | Threshold | Where |
|---|---|---|
| Line coverage (`src/` only) | **>= 90%** | `.github/scripts/coverage_gate.py` (`THRESHOLD`) |
| Slither | fail on **high** severity | `ci.yml` (`fail-on: high`) |
| Formatting | must match `forge fmt` | `forge fmt --check` |
| Fuzz runs | 256 per fuzz test | `foundry.toml` `[profile.default.fuzz]` |
| Invariant runs / depth | 128 runs, depth 32 | `foundry.toml` `[profile.default.invariant]` |

The coverage threshold lives in `.github/scripts/coverage_gate.py` (`THRESHOLD = 90.0`). Raise it as the suite
matures. Coverage uses `--ir-minimum` because the project builds with `via_ir = true`.

## What is tested

- **Unit tests** per module:
  - Core / governance: governance/upgrade (`DollarStore.t.sol`), storage-slot guards and round-trips
    (`CoreStorage.t.sol`, `QueueStorage.t.sol`, `RegistryStorage.t.sol`), asset registry
    (`AssetRegistry.t.sol`), risk controls (`RiskControls.t.sol`), and launch caps
    (`LaunchCaps.t.sol`).
  - Libraries: decimal normalization (`NormalizationLib.t.sol`), queue mechanics (`QueueLib.t.sol`),
    and spoke-share accounting (`SpokeShareLib.t.sol`).
  - Token: DLRS soulbound / mint-burn authority (`DLRS.t.sol`).
  - Hub flows: deposit/withdraw (`HubDepositWithdraw.t.sol`), directed swaps + queues
    (`HubSwapQueue.t.sol`), and failed-transfer / blacklist fallbacks (`HubSwapFallback.t.sol`).
  - Spoke flows: deposit (`SpokeDeposit.t.sol`), swap (`SpokeSwap.t.sol`), withdraw
    (`SpokeWithdraw.t.sol`), lifecycle wind-down / removal (`SpokeLifecycle.t.sol`), wind-down
    haircut (`SpokeWinddownHaircut.t.sol`), recovery of a fully impaired spoke
    (`SpokeImpairedRecovery.t.sol`), caps and pauses (`SpokeCapsAndPauses.t.sol`), the
    deposit-triggered queue settlement (`SpokeQueueTrigger.t.sol`), and spoke-to-spoke swaps
    (`SpokeToSpokeSwap.t.sol`).
  - Queues and exits: parking (`ParkedEscrow.t.sol`), pool-scoped queue keys
    (`PoolScopedQueues.t.sol`), the swap quote (`SwapQuote.t.sol`), and the exit probe
    (`ExitIssuerProbe.t.sol`).
  - Deployment: the governance deploy script (`DeployGovernance.t.sol`).
- **Fuzz tests**: decimal round-trip / no-inflation, and other property tests.
- **Fork tests** (`test/fork/`): the exit probe against the mainnet tokens (`IssuerProbeFork.t.sol`).
- **Invariant tests** (`test/invariant/`): randomized sequences of deposits, exits, swaps
  (including spoke-to-spoke), cancels, queue processing and spoke wind-down, removal and relisting
  assert five properties:
  1. **DLRS backing** - total DLRS supply plus every spoke's hub claim equals the sum of hub
     reserves (queue escrow is not backing).
  2. **Solvency** - the contract's token balance always covers reserves + queue escrow for every asset.
  3. **Escrow totals** - each asset's escrow total equals the sum of its positions.
  4. **Lines** - every line's depth and count match the positions linked in it.
  5. **Membership** - a live position is listed under its owner exactly once, a removed one under nobody.

## Run the same checks locally

```bash
forge fmt --check
forge build --sizes
forge test -vvv
forge coverage --report lcov --ir-minimum && python3 .github/scripts/coverage_gate.py
# static analysis (requires slither: `pipx install slither-analyzer` or `pip install slither-analyzer`)
slither . --config-file slither.config.json
```
