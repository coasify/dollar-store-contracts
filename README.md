# DollarStore

DollarStore is an on-chain exchange for USD stablecoins: deposit a listed stablecoin for a receipt, and swap one listed stablecoin for another one-for-one, with a queue for swaps that cannot fill immediately.

This repository holds the smart contracts only. The frontend lives in a separate repository.

| Path | Contents |
|---|---|
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | How the protocol works: pools, exits, swaps, queues, parking, spoke lifecycle, roles |
| [`contracts/README.md`](contracts/README.md) | Building, testing, and project layout |
| [`SECURITY.md`](SECURITY.md) | Roles, timelocks, launch parameters, emergency playbook, vulnerability reporting |
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | Deployment runbook |
| [`docs/VERSIONING.md`](docs/VERSIONING.md) | When and how to bump `version()`, and the version history |
| [`docs/QUALITY.md`](docs/QUALITY.md) | Engineering standards for contract changes |
| [`docs/CI.md`](docs/CI.md) | CI jobs and thresholds |
| [`contracts/src/`](contracts/src) | Contracts |
| [`contracts/deployments/`](contracts/deployments) | Deployed addresses, per network |
| [`audits/`](audits) | Audit reports, with firm, dates, scope and audited commit |

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Licensed under [MIT](LICENSE).
