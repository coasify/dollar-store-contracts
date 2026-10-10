# Testnet mocks

Testnet-only tokens, price feed and the script that deploys them. They are not part of the protocol
and must never be deployed to mainnet. They live under `script/` because `forge --verify` only
resolves contracts inside the paths forge indexes (`src`, `test`, `script`).

Contents:

- `MockStableERC20.sol` - ERC20 with a public `mint` (faucet: anyone can mint) and configurable
  decimals.
- `TestnetPriceFeed.sol` - a Chainlink-style feed that reports a settable price, always freshly
  timestamped; `setAnswer` simulates a depeg. The Sepolia deploy uses one `$1` feed for every asset.
- `DeployMockStables.s.sol` - deploys the mocks simulating USDC, USDT and USDS. Each token is gated by
  a `DEPLOY_USDC` / `DEPLOY_USDT` / `DEPLOY_USDS` env flag so already-deployed mocks are not redeployed
  (defaults: only USDS on, USDC/USDT off).

## Decimals

Real USDC and USDT use **6 decimals** on Ethereum; Sky USDS uses **18**. The mocks match: USDC/USDT
deployed with 6, USDS with 18.

## Deployed on Sepolia

| Token | Address | Decimals | Deployed |
|---|---|---|---|
| Mock USDC | `0x0a9479f7aff770965b3b2D28b29E40C3F6168588` | 6 | 2026-07-10 |
| Mock USDT | `0x2F906e2AEE73e28C76c487912D4Aa4dDd64C2C05` | 6 | 2026-07-10 |
| Mock USDS | `0xdB82d075db6c2e30353825D78C21F472C2252D25` | 18 | 2026-08-20 |

Which mocks sit in the hub and which is a spoke differs per deploy; the current one is recorded in
[deployments/sepolia.md](../../deployments/sepolia.md).

## Deploy + verify (Sepolia)

From `contracts/`, with the environment loaded (use the same `.env.sepolia` as the main deploy):

```bash
cd contracts
set -a; source .env.sepolia; set +a

forge script script/testnet/DeployMockStables.s.sol:DeployMockStables \
  --rpc-url sepolia --broadcast --verify
```

## Verify already-deployed contracts (without redeploying)

The mocks are already on-chain; they just need verification. From `contracts/`:

```bash
cd contracts
set -a; source .env.sepolia; set +a

# Mock USDC - constructor("USD Coin (Mock)","USDC",6)
forge verify-contract 0x0a9479f7aff770965b3b2D28b29E40C3F6168588 \
  script/testnet/MockStableERC20.sol:MockStableERC20 --chain sepolia --watch \
  --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "USD Coin (Mock)" "USDC" 6)

# Mock USDT - constructor("Tether USD (Mock)","USDT",6)
forge verify-contract 0x2F906e2AEE73e28C76c487912D4Aa4dDd64C2C05 \
  script/testnet/MockStableERC20.sol:MockStableERC20 --chain sepolia --watch \
  --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "Tether USD (Mock)" "USDT" 6)
```

## Using the faucet

```bash
# mint 1000 USDC (6 decimals) to an address
cast send 0x0a9479f7aff770965b3b2D28b29E40C3F6168588 "mint(address,uint256)" <YOUR_ADDR> 1000000000 \
  --rpc-url sepolia --private-key $DEPLOYER_PRIVATE_KEY

# or mint to yourself
cast send 0x0a9479f7aff770965b3b2D28b29E40C3F6168588 "mint(uint256)" 1000000000 \
  --rpc-url sepolia --private-key $DEPLOYER_PRIVATE_KEY
```
