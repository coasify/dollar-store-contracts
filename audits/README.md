# Audits

| Report | Firm | Report date | Review dates | Audited commit | Fix review commit | Findings |
|---|---|---|---|---|---|---|
| [2026-08-openzeppelin-dollarstore-v3.pdf](2026-08-openzeppelin-dollarstore-v3.pdf) | OpenZeppelin | 2026-08-05 | 2026-07-21 to 2026-07-24 | `d4cea9a` | `5e2e241` | 8: 2 medium, 2 low, 4 notes. 5 resolved |
| [2026-03-openzeppelin-dollarstore.pdf](2026-03-openzeppelin-dollarstore.pdf) | OpenZeppelin | 2026-03-10 | 2026-02-16 to 2026-02-19 | `091852e` | `591a4ac` | 13: 1 high, 2 medium, 4 low, 6 notes. 12 resolved, 1 partially resolved |

Each report cites the fix for a finding by its own pull request. The fix review commit is the first
commit on `main` that contains every fix the report reviewed. For the v3 report the fix pull requests
were stacked and merged into `main` as one commit, so the commits the report names (such as
`eb61b18`) are not ancestors of `main`; `5e2e241` has the same contract source as the last of them.

The reports cite files under `contracts/`, where the project lived at the audited commits. The same
files are now at the repository root: `contracts/src/DollarStore.sol` is `src/DollarStore.sol`.

Files are named `YYYY-MM-firm-scope.pdf`, using the report's date. Newest first.
