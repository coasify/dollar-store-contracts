# Deploy runbook

Paths are relative to the repository root, and commands run from there.

Step by step to deploy DollarStore with the production topology: an **upgrader timelock**, a
**governor timelock**, a **guardian Safe**, a **veto Safe** that can cancel queued timelock
operations, an **unpauser Safe**, and the first **pausers**. The same procedure runs on Sepolia (rehearsal) and
mainnet (production); you only change which environment file you load. Design reference:
[SECURITY.md](../SECURITY.md).

Golden rule: the roles are wired to the timelocks/Safe at `initialize()` time, so the **deployer
keeps no power**. All later configuration (listing assets, caps) goes through the governor timelock,
and every upgrade through the upgrader timelock.

There are two deploy scripts:

- `script/Deploy.s.sol` — local / anvil only. Roles are plain addresses (default: the deployer).
- `script/DeployGovernance.s.sol` — Sepolia and mainnet. Deploys the two timelocks + the proxy,
  wired to the operator Safes. **This runbook uses `DeployGovernance`.**

---

## Decisions to make once

- How many Safes. On a testnet one address can hold everything. On mainnet the guardian must be a
  different Safe from the veto Safe and from both proposer Safes, and the upgrader and governor
  proposers may be one Safe or two.
  See SECURITY.md for the trade-off.
- Delays: short on Sepolia so the rehearsal does not wait (`UPGRADER_DELAY=60`, `GOVERNOR_DELAY=30`),
  14d (upgrader) / 7d (governor) on mainnet.
- Initial hub assets and their Chainlink feeds. Each must meet the listing precondition in
  [SECURITY.md](../SECURITY.md) (see Phase 3).
- Initial launch caps.

## Prerequisites

- Foundry `v1.8.3` and the pinned dependencies: `git submodule update --init` (OZ v5.6.1 x2 + forge-std v1.16.2).
- Green suite: `forge test`.
- A deployer EOA funded with gas on the target network (Sepolia test ETH / mainnet ETH).
- An Etherscan API key.

---

## Phase 0 - Prepare Safes and environment

1. Create the Safe(s) at https://app.safe.global on the target network. Record the address(es).
2. Fill the network env file (`.env.sepolia` or `.env.mainnet`; copy from `.env.example`):
   - `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL`
   - `DEPLOYER_PRIVATE_KEY` (with the `0x` prefix)
   - `ETHERSCAN_API_KEY`
   - `UPGRADER_SAFE` (required), `GOVERNOR_SAFE`, `GUARDIAN_SAFE` (if omitted, they default to
     `UPGRADER_SAFE`). On mainnet `GUARDIAN_SAFE` must be set and must differ from `UPGRADER_SAFE`,
     `GOVERNOR_SAFE` and `VETO_SAFE`, or the deploy script refuses to run
   - `VETO_SAFE` (required): the Safe that can cancel queued timelock operations
   - `UNPAUSER_SAFE` (required): the Safe that lifts pauses and sets who may pause
   - `PAUSERS` (required): the addresses that may pause from the first block, comma-separated with
     no spaces. At least one. Each can pause alone and can do nothing else
   - `UPGRADER_DELAY`, `GOVERNOR_DELAY` (seconds). On Sepolia use `60` and `30`; on mainnet
     `1209600` (14d) and `604800` (7d), which are also the script's defaults. The delays are fixed at
     deploy, so set them before Phase 1. Set them even when using the defaults: the `schedule`
     commands in Phases 3 and 4 read these variables.

## Phase 1 - Deploy

> [!WARNING]
> **Etherscan Verification and macOS compile mismatch:** Due to a known issue with the Solidity Yul optimizer (`via_ir = true`), compiling on macOS can produce slightly different bytecode compared to compiling on Linux. Since Etherscan's verification servers run Linux, contracts deployed directly from macOS may fail verification with a `Compiled contract deployment bytecode does NOT match the transaction deployment bytecode` error.
> 
> **Recommendation:** To guarantee verification success on Etherscan/Sourcify, always deploy from a standardized Linux Docker container (or clean Linux VM) using the helper script `script/deploy-docker.sh`.

### Option A: Deploy via Docker (Recommended for production/rehearsals)

A helper script is provided to automate compilation and deployment inside a Linux-based Docker container:

```bash
# Remove build output from the host first, so the container compiles from source.
forge clean

# 1) Dry run (no tx broadcasted)
./script/deploy-docker.sh .env.sepolia

# 2) Broadcast and verify on-chain
./script/deploy-docker.sh .env.sepolia --broadcast --verify
```

### Option B: Deploy directly (Only for local VM or Linux hosts)

You pick the network here: (a) which env file you load, and (b) which `--rpc-url` you target. They must match.

```bash
# Load the network environment. IMPORTANT: `set -a` EXPORTS the variables to the forge process.
# A plain `source` sets them as shell variables but does NOT export them, so forge would not see them.
set -a; source .env.sepolia; set +a        # or: source .env.mainnet

# 1) Dry run (simulation, no tx sent).
forge script script/DeployGovernance.s.sol:DeployGovernance --rpc-url sepolia

# 2) Real deploy + explorer verification.
forge script script/DeployGovernance.s.sol:DeployGovernance \
  --rpc-url sepolia --broadcast --verify
```

### After either option: record the addresses

Both options write the same broadcast file under `broadcast/` (the Docker container works
in the repository folder). Record these addresses: `DollarStore proxy`, `DollarStore implementation`, `SpokeAdminLib`,
`SpokeLifecycleLib`, `SwapRouteLib`, `DLRS token`, `upgrader timelock`, `governor timelock`. You will
use them in every later phase. The logs print only some of them, so write all of them to a
`.deployed.sepolia` file (gitignored) that the later phases load. The implementation and the
libraries come from the broadcast file; the timelocks and DLRS are read from the proxy, so the two
timelocks cannot be swapped. For mainnet, replace `sepolia` with `mainnet` and `11155111` with `1`.

```bash
set -a; source .env.sepolia; set +a
B=broadcast/DeployGovernance.s.sol/11155111/run-latest.json
PROXY=$(jq -r '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' $B)
cat > .deployed.sepolia <<EOF
PROXY=$PROXY
IMPL=$(jq -r '.transactions[] | select(.contractName == "DollarStore") | .contractAddress' $B)
UP_TL=$(cast call $PROXY "upgrader()(address)" --rpc-url sepolia)
GOV_TL=$(cast call $PROXY "governor()(address)" --rpc-url sepolia)
DLRS=$(cast call $PROXY "dlrs()(address)" --rpc-url sepolia)
SPOKE_ADMIN_LIB=$(jq -r '.transactions[] | select(.contractName == "SpokeAdminLib") | .contractAddress' $B)
SPOKE_LIFECYCLE_LIB=$(jq -r '.transactions[] | select(.contractName == "SpokeLifecycleLib") | .contractAddress' $B)
SWAP_ROUTE_LIB=$(jq -r '.transactions[] | select(.contractName == "SwapRouteLib") | .contractAddress' $B)
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
EOF
set -a; source .deployed.sepolia; set +a
cat .deployed.sepolia
```

Every line should hold an address (`ZERO` is the empty bytes32 the timelock calls use). The block
also loads the file into this terminal. In a new terminal, and at the start of each later phase,
load both files:

```bash
set -a; source .env.sepolia; source .deployed.sepolia; set +a
```

`DollarStore` links three external libraries - `SpokeAdminLib` (spoke create + reserve write-down /
rescue), `SpokeLifecycleLib` (wind-down / haircut / removePool / withdraw), and `SwapRouteLib`
(the directed-swap routing / fill / FIFO-settle engine used by swapOrQueue / swapExactInput / swapSpokeToSpoke /
getSwapQuote / processQueue /
cancelQueue) - so the implementation stays under the EIP-170 24576-byte limit while shipping the full
feature set. `forge script` deploys all three libraries and links them automatically during the
broadcast, so no extra step is needed to deploy - but the library addresses are part of the
implementation's linked bytecode, so record them and pass them to any manual verification.

If `DLRS` was not verified (it is created inside `initialize`), verify it manually:

```bash
forge verify-contract $DLRS src/DLRS.sol:DLRS --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address)" $PROXY)
```

If the `DollarStore` implementation needs manual verification, pass the linked library so the
bytecode matches:

```bash
forge verify-contract $IMPL src/DollarStore.sol:DollarStore --chain sepolia \
  --libraries src/libraries/SpokeAdminLib.sol:SpokeAdminLib:$SPOKE_ADMIN_LIB \
  --libraries src/libraries/SpokeLifecycleLib.sol:SpokeLifecycleLib:$SPOKE_LIFECYCLE_LIB \
  --libraries src/libraries/SwapRouteLib.sol:SwapRouteLib:$SWAP_ROUTE_LIB
```

## Phase 2 - Verify the wiring on-chain

```bash
set -a; source .env.sepolia; source .deployed.sepolia; set +a
GUARDIAN=${GUARDIAN_SAFE:-$UPGRADER_SAFE}
DEPLOYER=$(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)
cast call $PROXY "upgrader()(address)" --rpc-url sepolia
cast call $PROXY "governor()(address)" --rpc-url sepolia
cast call $PROXY "guardian()(address)" --rpc-url sepolia
cast call $PROXY "unpauser()(address)" --rpc-url sepolia
cast call $PROXY "version()(string)"   --rpc-url sepolia
for P in $(echo $PAUSERS | tr ',' ' '); do cast call $PROXY "isPauser(address)(bool)" $P --rpc-url sepolia; done

cast call $UP_TL "getMinDelay()(uint256)" --rpc-url sepolia
cast call $GOV_TL "getMinDelay()(uint256)" --rpc-url sepolia

CANC=$(cast call $UP_TL "CANCELLER_ROLE()(bytes32)" --rpc-url sepolia)
ADMIN=$(cast call $UP_TL "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url sepolia)
cast call $UP_TL "hasRole(bytes32,address)(bool)" $CANC $VETO_SAFE --rpc-url sepolia
cast call $GOV_TL "hasRole(bytes32,address)(bool)" $CANC $VETO_SAFE --rpc-url sepolia
cast call $UP_TL "hasRole(bytes32,address)(bool)" $ADMIN $DEPLOYER --rpc-url sepolia
cast call $GOV_TL "hasRole(bytes32,address)(bool)" $ADMIN $DEPLOYER --rpc-url sepolia
```

Expected: `upgrader` is `$UP_TL`, `governor` is `$GOV_TL`, `guardian` is the guardian Safe, `unpauser`
is the unpauser Safe, every `isPauser` line prints `true`, the delays match `UPGRADER_DELAY` / `GOVERNOR_DELAY`, the two CANCELLER checks print `true` for the veto
Safe, and the two admin checks print `false` (the temporary deploy admin was renounced). When the
guardian is a different address from the veto Safe and from both proposer Safes, the same CANCELLER
check with `$GUARDIAN` prints `false`. Do not proceed if anything
does not match.

## Phase 3 - Configure the protocol (via the governor timelock)

`addHubAsset` and `setLaunchCap` are governor-gated, so they are **not** called directly: they are
scheduled on the governor timelock, wait the delay, then are executed. This is driven by the
governor Safe. The hub launch cap comes first: it must be active before any asset is listed.

Before listing an asset, check it against the listing precondition in [SECURITY.md](../SECURITY.md):

1. The token must accept a zero-value transfer. If it rejects one, every exit that pays none of it
   reverts; exempt it with `setProbeExempt(asset, true)` (governor) and accept that its issuer is
   then not checked on those exits.
2. The token must not call any other address during a transfer (no transfer hook or callback). Read
   its `transfer` and `transferFrom` code, and check a bridged copy separately on each chain.

The Sepolia test tokens below are mocks and meet both.

With the Safe (production): Safe -> New transaction -> Transaction Builder, targeting the governor
timelock, function `schedule(...)` with the payload below. Collect the signatures. After the delay, another tx
to the same timelock `execute(...)` (execution is open, anyone can execute).

With an EOA operator (testnet quick rehearsal only). The governor Safe in your env file is the EOA
whose key signs the schedule; any funded key can execute. On Sepolia, use the test tokens and the
`$1` test feed listed in [deployments/sepolia.md](../deployments/sepolia.md).

Load both files into this terminal, then set the asset to list and its feed:

```bash
set -a; source .env.sepolia; source .deployed.sepolia; set +a
USDC=<usdc>;  USDC_FEED=<usdc/usd feed>
```

Set the launch cap on the hub (poolId 0) first. The hub starts with no cap and is not paused, so once
an asset is listed anyone can deposit it, and a cap executed after the listing leaves a whole timelock
delay with no limit. The listings can be scheduled in the same waiting period, but execute none of them
until `getLaunchCap(0)` prints the cap. The cap limits DLRS supply; hub assets deposited into a spoke
count against that spoke's cap instead. It is in 6-decimal units: the dollar amount
followed by six zeros (1,000,000 dollars = `1000000000000`); 0 means no cap. Schedule:

```bash
CAP=1000000000000
DATA=$(cast calldata "setLaunchCap(uint16,uint256)" 0 $CAP)
cast send $GOV_TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $PROXY 0 $DATA $ZERO $ZERO "$GOVERNOR_DELAY" \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia
```

Wait `GOVERNOR_DELAY`, then execute and check (prints the value of `CAP`):

```bash
cast send $GOV_TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $PROXY 0 $DATA $ZERO $ZERO \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast call $PROXY "getLaunchCap(uint16)(uint256)" 0 --rpc-url sepolia
```

Schedule USDC (the proposer is the governor Safe/EOA):

```bash
DATA=$(cast calldata "addHubAsset(address,address)" $USDC $USDC_FEED)
cast send $GOV_TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $PROXY 0 $DATA $ZERO $ZERO "$GOVERNOR_DELAY" \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia
```

Wait `GOVERNOR_DELAY`, then execute (open to anyone):

```bash
cast send $GOV_TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $PROXY 0 $DATA $ZERO $ZERO \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia
```

Check USDC is listed (prints `true`):

```bash
cast call $PROXY "isAssetListed(address)(bool)" $USDC --rpc-url sepolia
```

Repeat for USDT. Schedule:

```bash
USDT=<usdt>;  USDT_FEED=<usdt/usd feed>
DATA=$(cast calldata "addHubAsset(address,address)" $USDT $USDT_FEED)
cast send $GOV_TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $PROXY 0 $DATA $ZERO $ZERO "$GOVERNOR_DELAY" \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia
```

Wait `GOVERNOR_DELAY`, then execute and check (prints `true`):

```bash
cast send $GOV_TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $PROXY 0 $DATA $ZERO $ZERO \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast call $PROXY "isAssetListed(address)(bool)" $USDT --rpc-url sepolia
```

Optionally create a spoke pool. A spoke holds one asset outside the hub, paired with a DLRS-side
reserve funded from the hub. The asset must not already be listed (an asset belongs to one pool).
`MIN_DLRS` is the protected minimum DLRS-side reserve, in 6-decimal units, that swaps cannot take the
spoke below; 0 means no floor. `CAP` is the spoke's launch cap, in 6-decimal units, set in the same
call; 0 means no cap. On Sepolia, use the mock USDS (18 decimals) from
[deployments/sepolia.md](../deployments/sepolia.md). Schedule:

```bash
SPOKE=<spoke asset>;  SPOKE_FEED=<spoke/usd feed>;  MIN_DLRS=0;  CAP=1000000000000
DATA=$(cast calldata "createSpoke(address,address,uint256,uint256)" $SPOKE $SPOKE_FEED $MIN_DLRS $CAP)
cast send $GOV_TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $PROXY 0 $DATA $ZERO $ZERO "$GOVERNOR_DELAY" \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia
```

Wait `GOVERNOR_DELAY`, then execute and check. `assetPoolId` prints the new pool id (`1` for the
first spoke) and `poolCount` prints `2`:

```bash
cast send $GOV_TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $PROXY 0 $DATA $ZERO $ZERO \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast call $PROXY "assetPoolId(address)(uint16)" $SPOKE --rpc-url sepolia &&
cast call $PROXY "poolCount()(uint256)" --rpc-url sepolia
```

The call names no pool id, so several spokes can be queued in one waiting period and executed in any
order. To change the cap later, use the launch cap blocks above with the spoke's pool id in place of
`0`. Do not queue a new spoke's `setLaunchCap` before the spoke exists: the pool id it names is only a
guess until then, and another spoke created first would take it.

`script/CreateSpoke.s.sol` builds the same call. It reads its own variable names. Run it once to schedule
and, after the governor timelock's minimum delay, once more to execute:

```bash
export STORE_PROXY=$PROXY GOVERNOR_TIMELOCK=$GOV_TL SPOKE_ASSET=$SPOKE SPOKE_FEED=$SPOKE_FEED
export SPOKE_MIN_DLRS=0 SPOKE_LAUNCH_CAP=1000000000000
forge script script/CreateSpoke.s.sol:CreateSpoke --rpc-url sepolia --broadcast
ACTION=execute forge script script/CreateSpoke.s.sol:CreateSpoke --rpc-url sepolia --broadcast
```

If an `execute` reverts with `TimelockUnexpectedOperationState`, the delay has not passed yet; wait
and run it again. After each spoke is created, read `getLaunchCap` for its pool id and confirm the cap.

## Phase 4 - Governance rehearsal (mandatory on Sepolia)

1. Pause and unpause: from one pauser, `pause()` on the proxy; then from the unpauser Safe, `unpause()`.
   Neither waits in a timelock.
2. Governor action: a full `setPegTolerance` through the governor timelock (schedule -> wait ->
   execute), as in Phase 3.
3. Governed upgrade: deploy a new implementation and schedule `upgradeToAndCall(newImpl, "")` on the
   UPGRADER timelock (schedule -> wait UPGRADER_DELAY -> execute). Confirm the new implementation is
   active and state was preserved.
4. Veto cancel: schedule any op on a timelock, then from the veto Safe `cancel(id)` before
   the delay elapses. Confirms the veto Safe can abort a queued op even though it is not the proposer.

These rehearsals validate the three authority paths plus the veto Safe's cancel power before mainnet.

With an EOA operator (testnet quick rehearsal only), as in Phase 3: the guardian, the unpauser, a
pauser and both proposer Safes are the EOA whose key is `DEPLOYER_PRIVATE_KEY`. That needs
`PAUSERS` and `UNPAUSER_SAFE` in the env file to be that EOA's address.

```bash
set -a; source .env.sepolia; source .deployed.sepolia; set +a
```

### 1. Pause and unpause

Pause as a pauser, then check (prints `true`):

```bash
cast send $PROXY "pause()" --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast call $PROXY "paused()(bool)" --rpc-url sepolia
```

Unpause as the unpauser, then check (prints `false`):

```bash
cast send $PROXY "unpause()" --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast call $PROXY "paused()(bool)" --rpc-url sepolia
```

### 2. Governor action

Peg tolerance is in basis points, 1 to 500. Note the current value, then schedule a change:

```bash
cast call $PROXY "pegTolerance()(uint256)" --rpc-url sepolia
DATA=$(cast calldata "setPegTolerance(uint256)" 100)
cast send $GOV_TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $PROXY 0 $DATA $ZERO $ZERO "$GOVERNOR_DELAY" \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia
```

Wait `GOVERNOR_DELAY`, then execute and check (prints `100`):

```bash
cast send $GOV_TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $PROXY 0 $DATA $ZERO $ZERO \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast call $PROXY "pegTolerance()(uint256)" --rpc-url sepolia
```

### 3. Governed upgrade

For a real upgrade (not this drill), bump `version()` first, per [VERSIONING.md](VERSIONING.md), so
the check below shows the new version.

Upgrading a proxy whose current implementation has the guardian pausing: the new code starts with
no unpauser and no pausers. Queue `setUnpauser` in the governor timelock so it executes together
with the upgrade, then have the unpauser call `setPauser` for each pauser, and do not upgrade while
the protocol is paused. A fresh deploy needs none of this.

`script/Upgrade.s.sol` calls the proxy directly, so it fails once the upgrader is a timelock. Deploy
the implementation on its own instead, linked to the three libraries from Phase 1. This rehearsal
implementation does not need to be verified.

```bash
NEW_IMPL=$(forge create src/DollarStore.sol:DollarStore --broadcast --json \
  --libraries src/libraries/SpokeAdminLib.sol:SpokeAdminLib:$SPOKE_ADMIN_LIB \
  --libraries src/libraries/SpokeLifecycleLib.sol:SpokeLifecycleLib:$SPOKE_LIFECYCLE_LIB \
  --libraries src/libraries/SwapRouteLib.sol:SwapRouteLib:$SWAP_ROUTE_LIB \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia | jq -r .deployedTo)
echo $NEW_IMPL
```

Schedule the upgrade on the upgrader timelock:

```bash
DATA=$(cast calldata "upgradeToAndCall(address,bytes)" $NEW_IMPL 0x)
cast send $UP_TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $PROXY 0 $DATA $ZERO $ZERO "$UPGRADER_DELAY" \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia
```

Wait `UPGRADER_DELAY`, then execute and check. The implementation slot prints `$NEW_IMPL` (padded to
32 bytes), and the settings from Phase 3 and drill 2 are unchanged (launch cap and peg tolerance):

```bash
cast send $UP_TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $PROXY 0 $DATA $ZERO $ZERO \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast storage $PROXY 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url sepolia &&
cast call $PROXY "version()(string)" --rpc-url sepolia &&
cast call $PROXY "getLaunchCap(uint16)(uint256)" 0 --rpc-url sepolia &&
cast call $PROXY "pegTolerance()(uint256)" --rpc-url sepolia
```

### 4. Veto cancel

Schedule an operation, then cancel it before the delay passes. The last check prints `false` (the
operation no longer exists):

```bash
DATA=$(cast calldata "setPegTolerance(uint256)" 75)
cast send $GOV_TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $PROXY 0 $DATA $ZERO $ZERO "$GOVERNOR_DELAY" \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
ID=$(cast call $GOV_TL "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
  $PROXY 0 $DATA $ZERO $ZERO --rpc-url sepolia) &&
cast send $GOV_TL "cancel(bytes32)" $ID --private-key $DEPLOYER_PRIVATE_KEY --rpc-url sepolia &&
cast call $GOV_TL "isOperation(bytes32)(bool)" $ID --rpc-url sepolia
```

On Sepolia with one EOA this only proves the cancel path works; it cannot show that the veto Safe
cancels without being the proposer, because they are the same key. With separate Safes, send the
`cancel` from the veto Safe.

## Phase 5 - Pre-mainnet checklist and mainnet

Before mainnet:

- Full Sepolia rehearsal completed and green.
- External review closed (fixes merged + re-tested).
- `security.txt` ready to publish (contact admin@dollarstore.world).
- `version()` bumped for this release and recorded, per [VERSIONING.md](VERSIONING.md).
- Every asset to be listed meets the listing precondition in SECURITY.md, with `setProbeExempt` set
  where a token rejects zero-value transfers.

Mainnet is the same sequence with `.env.mainnet` (real Safes, 14d/7d delays). Anyone can deposit once
an asset is listed, so the hub cap must be active before the first listing executes (Phase 3), not
merely checked before the first deposit. Before announcing the deployment, confirm on-chain: roles =
timelocks/Safe, timelock delays (`getMinDelay`), assets listed, caps active on every pool, and the
expected `version()`.

---

## Operational notes

- The Safe operates the timelocks: each `schedule` / `execute` is a Safe transaction (Transaction
  Builder), with its signatures. The pausers, the unpauser and the guardian act without a timelock.
  On one EOA this drill cannot show that a pauser is unable to unpause; with separate keys, try
  `unpause()` from a pauser and confirm it reverts.
- `execute` is open: after the delay, anyone can execute. `schedule` requires the proposer Safe.
  `cancel` can be done by the proposer Safe or the veto Safe (the veto Safe is granted CANCELLER
  on both timelocks; the guardian is not, unless it is also a proposer Safe or the veto Safe, which
  the script refuses on mainnet).
- The deployer is not a lasting trust anchor: during the deploy it holds a temporary timelock admin
  only to grant the veto Safe its CANCELLER role, then renounces it in the same run. The on-chain
  roles are the timelocks/Safe from genesis.
- Initial configuration is timelocked: listing the first assets goes through the governor timelock,
  so on mainnet it takes GOVERNOR_DELAY (7d) from the schedule. Plan it into the launch calendar.
