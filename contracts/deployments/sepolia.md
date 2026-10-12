# Deployment - Sepolia

**Network:** Sepolia (chain id 11155111)
**Date:** 2026-10-01
**Block:** 11823702
**Script:** `script/DeployGovernance.s.sol:DeployGovernance` (via `script/deploy-docker.sh`, Foundry v1.8.3)
**Total gas paid:** ~0.0135 ETH (deploy) + config and rehearsal txs
**Topology:** one EOA holds all three roles (rehearsal only); upgrader delay 300s, governor delay 120s.
**Version:** `0.10.0`, a pre-release build. It does not include the latest changes in this repository; a fresh deploy will replace it.

> Deployed inside the Linux Docker container after `forge clean`, so the container compiled from
> source. All 8 contracts verified on Etherscan and Sourcify.

## Addresses

| Contract | Address | Verified |
|---|---|---|
| **DollarStore proxy** (interact here) | `0xE99EAdbBb325aC382c2666ae65fAc300d236ff27` | yes |
| DollarStore implementation (current, from the Phase 4 upgrade drill) | `0xB27Ee072B60d653bB13c03dA174C677426839F43` | no (rehearsal) |
| DollarStore implementation (deployed) | `0x3A11CD3A8F866d4C801Af8B7B786bea155C520A4` | yes |
| DLRS token | `0xb9394989481D2ba8FAF5E7d6BA7Ba4Fb30f2Fb60` | yes |
| Upgrader timelock | `0x702a866Ec5526105B8855Db1b8499a36250F8fD0` | yes |
| Governor timelock | `0x4c33E1047524Ee34B731078368fFd4Ef53FFa49a` | yes |
| SpokeAdminLib | `0x936edD3CDf38afc84FD84aD0B81977d1Da423A16` | yes |
| SpokeLifecycleLib | `0x38F5920Cc3029346983f620Bdd9f292Ded549daa` | yes |
| SwapRouteLib | `0x52F4A050564dc51eB2F12eAEbF55c7645C8b5164` | yes |
| Guardian / governor / upgrader operator (shared EOA) | `0xfca687014F1306466450E09A9Aa9C7f0eDA99c67` | EOA |

## Role wiring (checked on-chain, DEPLOY.md Phase 2)

| Role | Held by | Delay |
|---|---|---|
| `upgrader` | Upgrader timelock `0x702a866Ec5526105B8855Db1b8499a36250F8fD0` | 300s |
| `governor` | Governor timelock `0x4c33E1047524Ee34B731078368fFd4Ef53FFa49a` | 120s |
| `guardian` | EOA `0xfca687014F1306466450E09A9Aa9C7f0eDA99c67` (direct, no timelock) | - |

The EOA is proposer and canceller on both timelocks; execution is open; the deployer renounced its
temporary admin on both.

## Deploy transactions

| What | Tx hash |
|---|---|
| SpokeAdminLib | `0x7d37282c52bc9bbef57f0f2c85228dbbf3c0bd9f018474ae5c7c5c85d3d79488` |
| SwapRouteLib | `0x6f4a3d4789edf27a59db678df7352b99c8ac8005aa3d916b26e67de0e972ec3d` |
| SpokeLifecycleLib | `0x9ced64812dc870e709b727ab92e1b58741728ba3609bdf737be125421cc9ffb9` |
| Upgrader timelock | `0x4eadc4387371f6b1eb86606d675328dff913e8fb2910943c61974927991db75d` |
| Governor timelock | `0xfd88607347ddbe6a6b1c81a76ec584b49b24048fa0802e135723cccb490d48e7` |
| DollarStore implementation | `0x93025e8a14e3fadda090449cb640fd4e1bf87940010b57a5bd4de3c463167784` |
| Proxy (+ DLRS via initialize) | `0xe05bada48a932557aa918a3c0f56c6abf01a7a69679d846b7967ba71262eeae5` |

## Configuration (DEPLOY.md Phase 3)

Hub (poolId 0) = **USDC + USDT**, launch cap $1,000,000. One spoke (poolId 1) = **USDS**, created
after the deploy, with no launch cap and no reserve floor. All three assets use the shared `$1` test
feed.

| Contract | Address | decimals |
|---|---|---|
| Mock USDC | `0x0a9479f7aff770965b3b2D28b29E40C3F6168588` | 6 |
| Mock USDT | `0x2F906e2AEE73e28C76c487912D4Aa4dDd64C2C05` | 6 |
| Mock USDS (spoke, poolId 1) | `0xdB82d075db6c2e30353825D78C21F472C2252D25` | 18 |
| TestnetPriceFeed (shared `$1`, 8 dp, always fresh) | `0xc09183D6C4657697B94a4056a98D09345C028341` | 8 |

| What | Schedule | Execute |
|---|---|---|
| addHubAsset USDC | `0x7fdd331c5fd90377a9d2edab44f24347d15db8c2605f88b49fa041feb886b53c` | `0x67afd118924d75847917ff9cd537996ee1139d3dbe95857de74518b49559a739` |
| addHubAsset USDT | `0x13c5a48db8950f2ecf032acf693a8416a88678b01fe787f3f9bc4562894797cc` | `0x45a0a148a633b30effc7128d3b264cc53db48fbd3c5a492f3a3bf36081e4db80` |
| setLaunchCap(0, 1000000000000) | `0xade9bb1fc098bcf448b863a88ffc78b9fc4f1bc8d49e0d845dc3ea86a1dbce02` | `0xc6082ab16480a98093719898f282034bbfc333dd48b984a837d32d5d3ef65b9f` |

## Governance rehearsal (DEPLOY.md Phase 4, all passed)

| Drill | Tx hashes | Result |
|---|---|---|
| 1. Guardian pause / unpause | `0x6057d54241e09b15b0f1cfd7a612bf264a4635645a6d9c65221cdf298017dc4f` / `0x029699032ff7c80d30e1ca4955e45d44bf66a483723c0bb24019752c0432c0aa` | paused, then unpaused |
| 2. Governor `setPegTolerance(100)` | `0x9cde7e4025e7250fe56707b7a1a645ed87e8597a32a8cba8eedbfb191f3a1514` / `0x0894e31ff851f72641e197243ecb0037b6c2f71d54d874ee2f48ac37dd8e27de` | 50 -> 100 |
| 3. Upgrade to `0xB27E...9F43` via upgrader timelock | `0x18fa2723569ec688a7a369306cb782283acf79fca0907f43ceaeb4216088779d` / `0x07ecf53e1b8d85cf2a1dedd6829d8b03d49d792898316c7b3b81bd9b1d32c8e1` | version, cap and peg tolerance kept |
| 4. Schedule `setPegTolerance(75)`, then cancel | `0x94bf7d9cb4c3e603c96d14ec13f06010e61868b885081d984c81b37b455dd7eb` / `0x71883fac57fc9262d8154f5d197672abe74a710d32e2b1c556720801b096af58` | operation removed |

Drill 4 used one EOA as both proposer and guardian, so it shows the cancel path works but not that a
guardian can cancel another proposer's operation.

## Current state

Read from the proxy on 2026-10-07: two pools; peg tolerance 100 bps; launch cap $1,000,000 on pool 0
and none on pool 1; pool 1 active with a zero reserve floor; nothing paused; no liquidity (DLRS supply 0).

See [docs/DEPLOY.md](../../docs/DEPLOY.md) for the runbook and [script/testnet/DEPLOYMENT.md](../script/testnet/DEPLOYMENT.md) for the mocks.
