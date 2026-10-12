# DollarStore — Contracts

Upgradeable (UUPS) one-for-one stablecoin exchange: a **hub** pool backing the DLRS receipt token,
**spoke** pools with LP receipt shares, and FIFO queues for swaps that cannot fill immediately. Built
with [Foundry](https://book.getfoundry.sh/). How the protocol works is in [PROTOCOL.md](../docs/PROTOCOL.md);
this file covers building, testing, and deploying.

- Solidity **0.8.24**
- OpenZeppelin **v5.6.x** (contracts + contracts-upgradeable) — **not** v4
- `via_ir` is enabled (see `foundry.toml`)

---

## Quick start (clean laptop → running tests)

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
cd dollar-store-contracts/contracts
```

### 3. Install dependencies

Dependencies are git submodules under `contracts/lib/`, pinned to exact commits: OpenZeppelin
Contracts `v5.6.1`, OpenZeppelin Contracts Upgradeable `v5.6.1`, and `forge-std` `v1.16.2`.

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

### 4. Build & test

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

### Continuous Integration

CI (build, format check, full test suite, a coverage gate, Slither static analysis, and the exit
probe against the mainnet tokens) runs on every push to `main`, every PR, and once a day. See **[CI.md](../docs/CI.md)** for the jobs, thresholds (e.g. the
`>= 90%` src coverage gate), and how to run the same checks locally.

### Security

The trust model, on-chain roles (governor timelock vs guardian Safe), the emergency
pause-then-fix playbook, and responsible disclosure are documented in **[SECURITY.md](../SECURITY.md)**.

---

## Project layout

```
contracts/
├── src/
│   ├── DollarStore.sol            # core (UUPS): roles, pools, deposit/withdraw, directed swaps + queues
│   ├── DLRS.sol                   # soulbound 6-decimal receipt token
│   ├── interfaces/                # IDollarStore.sol, AggregatorV3Interface.sol (Chainlink feed)
│   ├── storage/                   # ERC-7201 namespaced storage (CoreStorage, RegistryStorage, QueueStorage)
│   └── libraries/                 # swap engine, queues, spoke lifecycle and admin (see docs/PROTOCOL.md)
├── script/                        # Deploy.s.sol (local), DeployGovernance.s.sol (timelocks+Safe), CreateSpoke.s.sol,
│   │                              # Upgrade.s.sol, deploy-docker.sh
│   └── testnet/                   # testnet-only mock tokens, price feed and their deploy script
├── lib/                           # pinned dependencies (git submodules)
├── test/                          # Foundry tests + mocks (map in test/README.md)
├── deployments/                   # deployed addresses per network
├── foundry.toml
└── remappings.txt
```

## Deployment

The production deploy (two timelocks + a guardian Safe, wired at genesis) and the governance
rehearsal are documented step by step in **[DEPLOY.md](../docs/DEPLOY.md)**. Roles: `upgrader` (UUPS
upgrade authority), `governor` (risk/registry/caps) and `guardian` (fast emergency) — see
**[SECURITY.md](../SECURITY.md)**.

## Notes

- **OpenZeppelin must be v5.6.x.** With v4 the build fails (custom errors, `upgradeToAndCall`
  signature, and `ReentrancyGuard` differ). In v5.6 `ReentrancyGuard` is stateless (imported from
  `@openzeppelin/contracts`, no initializer).
- Environment variables live in a `.env` (see `.env.example`); never commit real keys.
```
