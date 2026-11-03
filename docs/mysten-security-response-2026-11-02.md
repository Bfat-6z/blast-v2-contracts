# Mysten review: how PR 150 responds

**2 November 2026 · Draft for team review · [PR 150](https://github.com/interest-protocol/blast-v2-contracts/pull/150)**

The PR adds timelocks and emergency pauses, preserving sealed upgrade custody.
**Deployment and key-custody changes remain.** Only five of John's eight findings
were supplied; the other three still need assessment.

## What changes for each concern

| John's concern | What the PR provides | What remains |
| --- | --- | --- |
| One key controls funds | Protected changes wait; immediate role revocation. | Independent multisig custody for root, cancellation and unpause. No key should meet the threshold alone. |
| No timelock | Propose → wait → apply for upgrades, governed fees/treasuries, allocations, adapter admission and creator-cap transfers. | Verify live notices; monitor proposals. |
| No pause | Separate pause/unpause roles; launchpad and presale start paused. | Assign responders; rehearse recovery. |
| No contact / security.txt | Outside this PR. | Publish a monitored contact and `/.well-known/security.txt`; test delivery. |
| Older single-key presales | Fresh contracts do not change older sales. | Inventory authority/funds; secure custody or contain exposure while preserving claims/refunds. |

## The Move interfaces

Selected signatures; bodies/imports omitted. Types belong to each linked module.

**Revoke an administrator without possessing its cap.**
[Source: blast_acl](../sui/admin/sources/blast_acl.move).

```move
public fun revoke_admin(self: &mut ACL, root: &SuperAdminCap, admin_cap_id: ID);
```

**TreasuryAdmin proposes; CancelAdmin cancels; anyone applies once ready.**
Fees follow the same pattern:
[schedule_trade_fees / apply_trade_fees / cancel_trade_fees](../sui/launchpad/sources/launch_config.move).
[Source: runtime_config](../sui/launchpad/sources/runtime_config.move).

```move
public fun schedule_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    treasury: address,
    delay_ms: u64,
    clock: &Clock,
);

public fun apply_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    clock: &Clock,
);

public fun cancel_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
);
```

**Schedule an exact upgrade digest.** After the wait, authorize, upgrade and commit
the receipt atomically. CancelAdmin can cancel before execution.
[Source: package_admin](../sui/launchpad/sources/package_admin.move).

```move
public fun schedule_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock,
);
```

**Separate pause and unpause authority.** Same signatures in
[launchpad](../sui/launchpad/sources/blast_fun.move),
[presale](../sui/presale/sources/blast_presale_package.move).

```move
public fun pause(self: &mut PackageVersion, _: &AdminWitness<PauseAdmin>, bits: u8);
public fun unpause(self: &mut PackageVersion, _: &AdminWitness<UnpauseAdmin>, bits: u8);
```

Launchpad gates creation, trading (buys/sells) and migration; presale gates creation,
commitments and migration. Claims, refunds, presale settlement/cancellation and
opening-round delivery stay available under normal conditions. Pauses neither
expire automatically nor cancel proposals.

## What “48 hours” means

**48 hours = 172,800,000 ms** is the intended release notice, configurable per
operation. `delay_ms` sets the **next** notice; this proposal waits the **current**
notice. Shortening 48 hours to zero still waits 48 hours; later changes then have
no wait.

Setup starts at zero notice for publication-owned policies and upgrade custody,
while paused. Clear **all** old zero-notice proposals, including adapter admissions,
then set and verify notices before release. Raising a notice does not fix old proposals.

**On compromise: revoke AND cancel.** Revocation alone cannot stop permissionless
application. Emergency actions, roles, claim signers and Quote listings remain
immediate; root rotation and later partner changes retain seven-day delays.

## Other changes in this work

- **Creator splits:** 48-hour initial notice in migrated vaults. Bluefin/Cetus
  settle old-split fees first; Aftermath splits coins when received.
- **Bonding rewards:** separate gas reserve, capped one-time reimbursement to a
  treasury fixed per round, claim deadline and permissionless recovery. Checkpoint gaps allowed;
  overlaps rejected.
- **Defaults:** bonding 1.5% Quote / 0% Meme, with the fee split 50/50 between
  protocol and creator; graduation 2.5% Meme / 1.5% Quote; presale 2% raise / 1%
  token; LP protocol fee 15%. Require positive LP Quote allocation.
- **Integration:** Table ACL, clearer cap-update names, named durations,
  updated events/references and
  [SDK](https://github.com/interest-protocol/blast-v2-sdk/pull/88),
  [app/workers](https://github.com/interest-protocol/blast-v2/pull/711),
  [indexer](https://github.com/interest-protocol/blast-infra/pull/114) and
  [admin console](https://github.com/interest-protocol/admin-acl/pull/22) PRs
  include the administrative bindings. They target fresh packages; rollout still
  requires the publication manifest and a coordinated SDK release.

## Evidence and proposed dates

At `f661a03`: **1,433 Move tests + 10 changed native venue cases passed**.
Measured 100% instruction coverage covers pause functions, new vault policy
methods and the bonding reward lifecycle—not every package. On 3 Nov, both
native presale pause matrices passed again at `54c9d8c`, including 8,192
mask/generation combinations and role, revocation, event and rollback checks.

**Proposed targets, subject to team approval and named owners:**

| Date (2026, UTC) | Deliverable |
| --- | --- |
| 4 Nov | Reconcile all eight findings; approve custody; inventory older sales and start supported root rotations. |
| 6 Nov | Complete consumer bindings; publish/test the security contact; approve older-sale plans. |
| 9 Nov | Rehearse setup, cancellation, pause and exits; review deployment readiness. |
| 11 Nov | Review evidence from any approved deployment, or report blockers and revised dates. |
| **Friday 13 Nov** | Send John the approved plan, evidence and outstanding work. |

**Before real quote coins:** verify live custody, notices, pauses and consumers;
confirm reporting works; agree treatment of older sales and remaining findings.
A merge is not deployment evidence.

Details: [ADR 0134](decisions/0134-delayed-administration-pause-and-table-acl.md)
· [deployment evidence](../deployments/README.md).
