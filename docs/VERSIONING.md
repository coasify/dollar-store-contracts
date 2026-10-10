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

Versions follow semantic versioning. Before 1.0:

| Change since the last release | Bump | Example |
|---|---|---|
| New function, event or error, or any change in behavior or storage | Minor | `0.11.0` → `0.12.0` |
| Fixes only, with no change to the external interface | Patch | `0.11.0` → `0.11.1` |

`1.0.0` is the first mainnet release. After it, a change that breaks integrators (a removed or
changed function, event or error) bumps the major number.

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
| `0.11.0` | Spoke-to-spoke swaps (`swapSpokeToSpoke`), `getSwapQuote` matching the swap's fill, proportional exits, pool-scoped queue keys, parking. Pausing and unpausing as their own roles (pausers, unpauser). Dependencies pinned as submodules. | Not yet |
| `0.10.0` | Pre-release integration build: proportional exits, pool-scoped queue keys and parking. No spoke-to-spoke swaps, and `getSwapQuote` returns 0 whenever a same-direction position is waiting. | Sepolia, block 11823702 |
