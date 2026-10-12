# Deployment - Sepolia

**Network:** Sepolia (chain id 11155111)
**Date:** 2026-08-28
**Block:** 11620056
**Script:** `script/DeployGovernance.s.sol:DeployGovernance` (via `script/deploy-docker.sh`)
**Total gas paid:** ~0.024 ETH (deploy) + config/seed txs
**Topology:** one shared Safe for the three roles; short delays for rehearsal (`bytecode_hash = "none"`).
**Version:** `0.9.4-U2`

> Supersedes the Sepolia deploy at proxy `0x6794C624A83bcff87aC4efecdEdB2b2D3445445B` (block 11531648)
> and every deploy before it. **Those addresses are deprecated.**
> Reason for the redeploy: `adminCancelQueue` was removed from the protocol (version `0.9.3-U2` ->
> `0.9.4-U2`). A fresh proxy was chosen over an in-place upgrade.
>
> Deployed inside a Linux Docker container (`ghcr.io/foundry-rs/foundry:latest`) after `forge clean`,
> so the container recompiled from source in Linux and the bytecode matches Etherscan's verifier.

## Addresses

| Contract | Address | Verified | Explorer |
|---|---|---|---|
| **DollarStore proxy** (interact here) | `0xf10659961CE8c551F603370bd2f7694f60B3bC4d` | **yes** | [link](https://sepolia.etherscan.io/address/0xf10659961CE8c551F603370bd2f7694f60B3bC4d) |
| DollarStore implementation | `0x3abbf9e694237d8ecad493070ca5704a658acf36` | **yes** | [link](https://sepolia.etherscan.io/address/0x3abbf9e694237d8ecad493070ca5704a658acf36) |
| DLRS token | `0x9C7cEe1B5bdA96024F4860d1533f746492fa89a6` | **yes** | [link](https://sepolia.etherscan.io/address/0x9C7cEe1B5bdA96024F4860d1533f746492fa89a6) |
| Upgrader timelock | `0xaef68b233aD1F959108ca43C35458c2A4FE8F177` | **yes** | [link](https://sepolia.etherscan.io/address/0xaef68b233aD1F959108ca43C35458c2A4FE8F177) |
| Governor timelock | `0xf38DC70449f5FD807983b7654FEC909e223F6688` | **yes** | [link](https://sepolia.etherscan.io/address/0xf38DC70449f5FD807983b7654FEC909e223F6688) |
| Guardian / Governor / Upgrader Safe (shared) | `0x19caCb4c0A7fC25598CC44564ED0eCA01249fc31` | Safe (EOA) | [link](https://sepolia.etherscan.io/address/0x19caCb4c0A7fC25598CC44564ED0eCA01249fc31) |

### Linked libraries (reused from the prior deploy, unchanged bytecode)

The libraries were not changed by the `adminCancelQueue` removal, so CREATE2 resolved them to their
existing, already-verified addresses and they were not redeployed.

| Library | Address | Verified |
|---|---|---|
| SpokeAdminLib | `0x982aa6fe12a25cd8a6189c8ee2bda17071e74a93` | yes |
| SwapRouteLib | `0x481bd4fba3f343f339ee68df96b056ac85283929` | yes |
| SpokeLifecycleLib | `0x835d25336c77ec5fbdb64a28f8b72151b9c103d5` | yes |

## Role wiring (on the proxy)

| Role | Held by | Delay |
|---|---|---|
| `upgrader` | Upgrader timelock `0xaef68b233aD1F959108ca43C35458c2A4FE8F177` | 3600s (1h) |
| `governor` | Governor timelock `0xf38DC70449f5FD807983b7654FEC909e223F6688` | 600s (10m) |
| `guardian` | Safe `0x19caCb4c0A7fC25598CC44564ED0eCA01249fc31` (direct, no timelock) | - |

Both timelocks are proposed/cancelled by the same Safe/EOA `0x19caCb4c0A7fC25598CC44564ED0eCA01249fc31`; execution is open; no external admin.

## Deploy transactions

| What | Tx hash |
|---|---|
| Upgrader timelock | `0xacbe20f968d2d8f313c159a1c367ab2b0f977e23525447bae99b971609eff7de` |
| Governor timelock | `0x4345e861bf997a373cda8b5a3c62c77e52b3dcd6f8aad7b6f12f8d7cb8ba6bb6` |
| DollarStore implementation | `0x90ce469097b02e2316be70a4ce44830bf43da1262a2c6862e4f36fb0c95eaf5c` |
| Proxy (+ DLRS via initialize) | `0x029a8492bc8f789b6e07f218edf50c03cf8cc3248fe607a5d1743c6ae78cda8b` |

---

## Verification Status

**All 8 contracts verified on Etherscan** (proxy, implementation, DLRS, both timelocks, three reused
libraries). The `forge --verify` run reported "4/5" because the last submission was still queued when
it stopped polling; a follow-up check confirmed every address returns verified source.

## Sanity checks

```bash
PROXY=0xf10659961CE8c551F603370bd2f7694f60B3bC4d
cast call $PROXY "version()(string)"   --rpc-url sepolia   # 0.9.4-U2
cast call $PROXY "upgrader()(address)" --rpc-url sepolia   # 0xaef68b233aD1F959108ca43C35458c2A4FE8F177
cast call $PROXY "governor()(address)" --rpc-url sepolia   # 0xf38DC70449f5FD807983b7654FEC909e223F6688
cast call $PROXY "guardian()(address)" --rpc-url sepolia   # 0x19caCb4c0A7fC25598CC44564ED0eCA01249fc31
# adminCancelQueue was removed in this version: calling it reverts (no such selector).
cast call $PROXY "adminCancelQueue(uint256)" 1 --rpc-url sepolia   # execution reverted
```

Verified at deploy time: roles = timelocks/Safe, delays 3600/600, guardian is CANCELLER on both
timelocks, deployer holds no admin. `adminCancelQueue` reverts (removed).

## Hub assets + spoke (Sepolia rehearsal)

**Date:** 2026-08-28. Hub (poolId 0) = **USDC + USDS**; **USDT** listed as the first spoke (poolId 1).
All three point at one shared, always-fresh `$1` test feed. Listings/spoke went through the governor
timelock (schedule -> wait 600s -> execute). Mocks and feed are reused from the prior rehearsal.

| Contract | Address | Verified |
|---|---|---|
| **TestnetPriceFeed** (shared `$1`, 8 dp) | `0xc09183D6C4657697B94a4056a98D09345C028341` | yes |

| Asset | Address | poolId | decimals | listed |
|---|---|---|---|---|
| Mock USDC | `0x0a9479f7aff770965b3b2D28b29E40C3F6168588` | 0 (hub) | 6 | **yes** |
| Mock USDS | `0xdB82d075db6c2e30353825D78C21F472C2252D25` | 0 (hub) | 18 | **yes** |
| Mock USDT | `0x2F906e2AEE73e28C76c487912D4Aa4dDd64C2C05` | 1 (spoke) | 6 | **yes** |

USDT spoke created with `minDlrsReserve = 0`. No launch caps set (hub and spoke left uncapped).

### Governor timelock transactions

| What | Action | Tx hash |
|---|---|---|
| addHubAsset USDC | Schedule | `0x57970b1b934629906f8501b55c0efaa58f8880b22fb7a9513af4ad46f89b32c3` |
| addHubAsset USDC | Execute | `0xb5d9e575be30f90c2cf975d2d401f9ae4ea9491361c271b6c0a0e720ea4ce41c` |
| addHubAsset USDS | Schedule | `0x076058fd370c9d8fa8398632ce3292c00ff7f01cbdb138e9df3a8cca452f384e` |
| addHubAsset USDS | Execute | `0x57045f6fb92a4e4ff87bba7b082f396cf6f0f321bdd445ba49eb753aebd5cd18` |
| createSpoke USDT | Schedule | `0xbb2efe8f9fe1369440061c086e4be153505dd989ce0226873e2fdf9c80d252c2` |
| createSpoke USDT | Execute | `0x6e9d0e3abd35425c8bffc2f6fe47833bf933bdaea9e3c06487961e19ff50eab4` |

Operation ids:
*   addHubAsset USDC: `0xaaad693bfa704dda4327edc5e85e3b776fcce2d4bba69e719ddedd77ccffc782`
*   addHubAsset USDS: `0xb0956b0a859cff00b9ef12bdaeaccbfac32d32e502d70d8e2620f04daf5c7172`
*   createSpoke USDT: `0xdabc883325e7f0ca73554cc40645a23eb78434f42ead72dc06a04036e226b3a8`

### Post-listing checks (all pass)

```bash
PROXY=0xf10659961CE8c551F603370bd2f7694f60B3bC4d
USDT=0x2F906e2AEE73e28C76c487912D4Aa4dDd64C2C05
cast call $PROXY "isAssetListed(address)(bool)" $USDT --rpc-url sepolia   # true
cast call $PROXY "assetPoolId(address)(uint16)" $USDT --rpc-url sepolia   # 1
cast call $PROXY "poolCount()(uint16)"          --rpc-url sepolia         # 2
```

## Seeded liquidity + smoke swaps (2026-08-28)

Public faucet `mint` funded the deployer, then hub + spoke liquidity added and swaps exercised
end-to-end. All at the `$1` peg (1:1). USDS deposits normalize from 18 to 6 decimals internally.

| Action | Pool | Amount |
|---|---|---|
| Deposit USDC (hub) | 0 | 100,000 |
| Deposit USDS (hub) | 0 | 100,000 |
| Deposit USDT (spoke reserve) | 1 | 50,000 |
| Deposit USDC (spoke DLRS-side funding) | 1 | 50,000 |

| Swap | Route | Amount | Tx hash |
|---|---|---|---|
| USDC → USDS | hub → hub | 1,000 → 1,000 | `0xa98b16259ad43c5084c6e9e1b2548abffa19972e2e827f12fa07d264422c3110` |
| USDC → USDT | hub → spoke | 1,000 → 1,000 | `0xf018752039e85a9b1c72d80be5299f742357de7d7084d3dbc553fdefa9c5ebe6` |
| USDT → USDC | spoke → hub | 1,000 → 1,000 | `0xe67acf6ad423d062c975cf24ed786a3572e117e5b1101b358a891d82cf41b067` |

Post-state: DLRS supply `200_000_000000` (200k, minted 1:1 on the two hub deposits). Hub reserves USDC
`151_000_000000`, USDS `99_000_000000` (the hub->hub swap moved 1k of value 1:1). Spoke USDT reserve
`50_000_000000` and DLRS side `50_000_000000` (the hub<->spoke round trip netted to zero). Every swap
filled 1:1 with no slippage at peg.

See `contracts/DEPLOY.md` for the full runbook and `test/testnet-mocks/DEPLOYMENT.md` for the mocks.
