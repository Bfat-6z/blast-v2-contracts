# 0135: Consolidate utility contracts into Blast V2 contracts

- Status: accepted
- Date: 2026-11-03

## Decision

Maintain OTC, vesting, timelock, and their utility SDK in `blast-v2-contracts`.
Import `blast-util-contracts` main at
`8049353ec356f659e2d53ee535f6881b2d703308` as a second Git parent, retaining the original commits,
published-source revisions, and release provenance. Merge this change with a
merge commit, not squash or rebase: external consumers and published-source
verification must retain access to the imported commits.

The independent on-chain package boundaries remain. Internal consumers resolve
`sui/timelock` and `sui/vesting` through local dependencies. External consumers
pin a full commit in this repository. The existing `Published.toml` files,
contract sources and tests, SDK package name, ABI fixtures, and deployment
records are preserved. No publication, upgrade, or state migration occurs.

The imported `sui/otc/`, `sui/vesting/`, `sui/timelock/`, `sdk/`, ADRs 0052 and
0055, `docs/move-module-layout.md`, `docs/research/vesting-contract-patterns-2026.md`,
`docs/vectors/vesting.json`, and the three September 2026 utility deployment
records retain their original MIT terms. Each package and the SDK include the
original license text. The root BUSL license continues to govern other
first-party code.

## Consequences

`blast-v2-contracts` becomes the maintenance location. After this change is
merged and dependent repository references are updated, replace the old
repository's README with a pointer here and archive it. Retain the old
repository for existing pinned URLs and historical links; deleting it would
break those consumers. Existing release records keep their original provenance.

Published utility source is exempt from greenfield API and error-renumbering
rules. Future work must preserve its immutable ABI and abort identities.
The [utility guide](../utilities.md) owns integration and source-verification
instructions.
