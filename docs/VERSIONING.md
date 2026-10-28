# Versioning

Paths are relative to the repository root, and commands run from there.

`DollarStore.version()` names the implementation a proxy runs. Anyone can call it on a deployed
proxy to tell which build is live, so each deployed build must report a version no other build has
used.

## When to bump

Bump once per release, in the last change merged before a deploy or an upgrade. Do not bump in
every pull request: builds that are merged but never deployed do not need their own version, and in
a stack of pull requests every bump conflicts on the same line.

A release is any of:

- a fresh deploy, on any network, testnet included;
- an upgrade of a deployed proxy to a new implementation.

Redeploying a linked library (`SpokeAdminLib`, `SpokeLifecycleLib`, `SwapRouteLib`) changes the
implementation that links to it, so it is a release as well.

## Which number

Versions follow semantic versioning, starting at `1.0.0`, the first mainnet release:

| Change since the last release | Bump | Example |
|---|---|---|
| A change that breaks integrators: a removed or changed function, event or error | Major | `1.0.0` → `2.0.0` |
| A new function, event or error, or any other change in behavior or storage | Minor | `1.0.0` → `1.1.0` |
| Fixes only, with no change to the external interface | Patch | `1.0.0` → `1.0.1` |

Use plain `MAJOR.MINOR.PATCH`, with no suffixes.

## How to bump

1. Change the string returned by `version()` in `src/DollarStore.sol`.
2. Change the matching assertion in `test/DollarStore.t.sol`.
3. Add a row to the table below.
4. Confirm the new version differs from the one the target proxy reports:
   `cast call $PROXY "version()(string)" --rpc-url <network>`.
5. After the deploy or upgrade, confirm the proxy reports the new version (DEPLOY.md checks this),
   and record it in `deployments/<network>.md` and `deployments/<network>.json`.

## Versions

| Version | Contents | Deployed |
|---|---|---|
| `1.0.0` | The first mainnet release of DollarStore. Fully audited by Guardian, building on earlier audits by OpenZeppelin. | Not yet |
