# Deployment and release records

Normalized, reviewable deployment records live under
`deployments/sui/mainnet/`. Blast deploys to Sui mainnet only (ADR 0103).
Console output and `latest` pointers are not records.

Every record must contain at least:

- schema version, network/chain ID, environment, and UTC timestamp;
- repository commit, clean/dirty state, compiler and toolchain versions;
- package/contract identifiers and dependency identifiers;
- deployer, transaction digest, status, and the created shared/admin objects,
  including the `Publisher`, `UpgradeCap`/`PackageAdmin`, and
  operational-generation object IDs, and, for `blast_admin`, the singleton `ACL`
  and its `SuperAdminCap`; each `AdminCap` granted with its holder and roles;
- constructor/init parameters and post-deploy verification results;
- for `blast_admin`, which is published immutably, the `sourceDigest` printed by
  `sui/admin/scripts/source_digest.sh` at the published commit, beside the
  package's `packageId`; its boundary gate refuses a `Published.toml` entry that
  no record carries or whose recorded digest differs from the current source.

Raw simulator or broadcast output stays generated and ignored. Public
normalized records must not contain secrets.

Package-specific procedures are loaded only for the operation being performed.
Blast SUI uses its [deployment](../sui/blast_sui/DEPLOYING.md) and
[upgrade](../sui/blast_sui/UPGRADING.md) runbooks. Other packages record the
same normalized evidence while following their accepted ADRs and verification
scripts.

ADR 0134 uses a fresh ACL, partners, launchpad, migrators, and presale stack.
The October 28 package IDs and source revisions remain in the historical
deployment records. The fresh stack receives compiler publication bindings
after its own publication.

Launchpad, presale and migrators require nonzero named-address payout defaults
before publication. Their deployer-owned Publication retains provenance only;
it authorizes no policy setters (ADR 0134). Wrap consumes it permanently, seals
native custody and creates the operational version. Launchpad and presale start
fully paused. Configure initial policies through ordinary ACL roles after wrap;
publication-owned policies initially have zero notice. Upgrade custody starts
at 48 hours.
Record the chosen fees, destinations, launchpad claim signer and allocation,
Quote and reviewed adapter allowlists, and applied-value events. Apply or cancel
every outstanding zero-notice proposal, including independent adapter admissions,
then configure and read back each operation's intended notice (48 hours for this
rollout). Raising a notice does not rewrite older proposals. Verify approved key
custody before multisig UnpauseAdmin releases selected operations. Record
Publication consumption, sealed custody, every applied notice, proposal state,
pause masks and unpause evidence. Later protected changes wait their operation's
applied notice, including while paused; notice reductions wait the old notice.

## Boosts adapter upgrades

[ADR 0123](../docs/decisions/0123-successor-activated-boosts-upgrades.md) applies
to the fresh adapter lineage, not the historical deployed package. After
publication and before the first upgrade or vault funding, seal the canonical
Publisher and raw UpgradeCap through `package_admin::wrap`. The initializer
delivers the Publisher to the publisher; wrapping uses it in a follow-up
transaction. The supported policy remains compatible.

1. Read the active operational generation from `Protocol`, the native count
   from the sealed cap, and the live UpgradeAdmin role. Compile the successor's
   `PACKAGE_VERSION` as **active generation + 1**, even after failed native
   upgrades. Review its exact digest, dependency pins and compatibility. Never
   substitute the native upgrade count for the operational generation.
2. Sign in on the immutable ACL. In one transaction, pass that witness and exact
   digest to `package_admin::authorize_upgrade`, consume the ticket with the
   native upgrade command, and consume its receipt with `package_admin::commit_upgrade`
   on the same PackageAdmin. This does not change the active generation.
3. From the newly installed package ID, in a **second transaction**, sign in
   again and call `package_admin::activate_upgrade(protocol, witness)`. It checks
   its own compiled version; no caller supplies a version number. Failure leaves
   the old generation usable. Publish a corrected successor through the same
   repair path and retry; native and operational counts can diverge.
4. Record both transaction digests, original and installed package IDs, exact
   source/toolchain/digest, dependencies, native count, operational generation,
   custody/Protocol IDs, UpgradeCommitted and OperationalVersionAdvanced events,
   and before/after checks of old rejection, new operations and required exits.
   Direct callers and dependent packages to the reviewed activated release.

Activation verifies a consecutive version, not arbitrary code health or unique
latest-package identity. Rehearse the successor and all exit/dependent routes
before activation. A retained, unactivated candidate sharing the same operational
generation remains callable; administrators must not activate an unintended
candidate. Live ACL revocation still removes repair authority, including in old
packages. Replacing governance must explicitly retire that role.
Activate only the package ID reviewed for the current cutover and record all
superseded candidate IDs: a rejected candidate compiled ahead of the active
generation can become activatable after a later cutover.

`make_immutable` is a deliberate terminal action. Keep its current-generation
check; verify intended release, dependencies and exits before burning the cap.
It checks a version match only and does not prove that no upgrade is pending or
that the latest installed code is correct. No later repair is possible once the
cap is destroyed.

## Imported utility records

The September 2026 OTC, vesting, and timelock records retain their original
repository URLs and commit IDs as historical provenance. Their full Git history
is imported here; see [utility verification](../docs/utilities.md). Consolidation
does not publish, upgrade, or replace an on-chain package.
