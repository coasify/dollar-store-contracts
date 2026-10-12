# DollarStore

DollarStore is an on-chain exchange for USD stablecoins: deposit a listed stablecoin for a receipt, and swap one listed stablecoin for another one-for-one, with a queue for swaps that cannot fill immediately.

The contracts are upgradeable (UUPS): a **hub** pool backing the DLRS receipt token, **spoke** pools with LP receipt shares, and FIFO queues for swaps that cannot fill immediately. This repository holds the smart contracts only. The frontend lives in a separate repository.

- Solidity **0.8.24**, built with [Foundry](https://book.getfoundry.sh/) (`via_ir` enabled, see `foundry.toml`)
- OpenZeppelin **v5.6.1** (contracts and contracts-upgradeable)

## Documentation

| Path | Contents |
|---|---|
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | How the protocol works: pools, exits, swaps, queues, parking, spoke lifecycle, roles |
| [`SECURITY.md`](SECURITY.md) | Roles, timelocks, launch parameters, emergency playbook, vulnerability reporting |
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | Deployment runbook |
| [`docs/VERSIONING.md`](docs/VERSIONING.md) | When and how to bump `version()`, and the version history |
| [`docs/QUALITY.md`](docs/QUALITY.md) | Engineering standards for contract changes |
| [`docs/CI.md`](docs/CI.md) | CI jobs and thresholds |
| [`deployments/`](deployments) | Deployed addresses, per network |
| [`audits/`](audits) | Audit reports, with dates, audited commit and fix review commit |

## Quick start

### 1. Prerequisites

- **git**
- **Foundry** (forge/cast/anvil). Install it:

```bash
curl -L https://foundry.paradigm.xyz | bash
# then open a new shell OR `source ~/.bashrc` (or ~/.zshenv), then:
foundryup --install v1.8.3
```

Verify: `forge --version`.

> Windows: use **WSL** (Ubuntu) and run the commands above inside it.

### 2. Get the code

```bash
git clone --recurse-submodules https://github.com/coasify/dollar-store-contracts.git
cd dollar-store-contracts
```

### 3. Install dependencies

Dependencies are git submodules under `lib/`, pinned to exact commits: OpenZeppelin Contracts
`v5.6.1`, OpenZeppelin Contracts Upgradeable `v5.6.1`, and `forge-std` `v1.16.2`.

If you cloned without `--recurse-submodules`:

```bash
git submodule update --init
```

`forge update` moves the pins; do not run it.

Enable the repository's pre-commit hook, which blocks committing private keys, mnemonics and real
`.env` files. Git does not enable it on its own; run this once per clone:

```bash
git config core.hooksPath .githooks
```

### 4. Build and test

```bash
forge build
forge test           # or: forge test -vvv
```

Run a single file, or coverage:

```bash
forge test --match-path "test/HubSwapQueue.t.sol" -vvv
forge coverage --report summary --ir-minimum
forge fmt
```

> If `forge build` ever reports **"stack too deep"**, confirm `via_ir = true` is present in
> `foundry.toml` (`[profile.default]`); it already is.

## Project layout

```
├── src/
│   ├── DollarStore.sol            # core (UUPS): roles, pools, deposit/withdraw, directed swaps + queues
│   ├── DLRS.sol                   # soulbound 6-decimal receipt token
│   ├── interfaces/                # IDollarStore.sol, AggregatorV3Interface.sol (Chainlink feed)
│   ├── storage/                   # ERC-7201 namespaced storage (CoreStorage, RegistryStorage, QueueStorage)
│   └── libraries/                 # swap engine, queues, spoke lifecycle and admin (see docs/PROTOCOL.md)
├── test/                          # Foundry tests + mocks (map in test/README.md)
├── script/                        # Deploy.s.sol (local), DeployGovernance.s.sol (timelocks+Safe), CreateSpoke.s.sol,
│   │                              # Upgrade.s.sol, deploy-docker.sh
│   └── testnet/                   # testnet-only mock tokens, price feed and their deploy script
├── lib/                           # pinned dependencies (git submodules)
├── deployments/                   # deployed addresses per network, including the testnet mocks
├── docs/                          # protocol, deployment, versioning, quality and CI docs
├── audits/                        # audit reports
└── foundry.toml
```

## Continuous integration

CI (build, format check, full test suite, a coverage gate, Slither static analysis, and the exit
probe against the mainnet tokens) runs on every push to `main`, every PR, and once a day. See **[CI.md](docs/CI.md)** for the jobs, thresholds (e.g. the
`>= 90%` src coverage gate), and how to run the same checks locally.

## Deployment

The production deploy (two timelocks + a guardian Safe, wired at genesis) and the governance
rehearsal are documented step by step in **[DEPLOY.md](docs/DEPLOY.md)**. Roles: `upgrader` (UUPS
upgrade authority), `governor` (risk/registry/caps) and `guardian` (fast emergency); see
**[SECURITY.md](SECURITY.md)**.

Environment variables live in a `.env` file (see `.env.example`); never commit real keys.

## Security and license

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Licensed under [MIT](LICENSE).
