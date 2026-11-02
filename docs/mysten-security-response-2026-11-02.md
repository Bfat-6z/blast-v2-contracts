# Mysten security review: what PR 150 changes

Prepared **2 November 2026** for the Blast team. This is a draft response brief,
with proposed dates for team approval, not a deployment announcement or a message
already sent to Mysten.

[PR 150](https://github.com/interest-protocol/blast-v2-contracts/pull/150)
adds delayed administration and emergency pauses to the new contract stack.
It preserves sealed upgrade custody. **Merging it does not change deployed
contracts, transfer keys, or resolve the older presales automatically.**

This brief covers the five concerns pasted from John's message. The other three
items in the attached eight-item brief still need to be reconciled before we
claim a complete response.

## 1. One key controls fund-affecting administration

The contracts support separate roles for fees, treasury, upgrades, pausing,
unpausing and cancelling proposals. The root administrator can immediately revoke
an administrator or its roles. PR 150 puts protected changes behind notice periods,
giving an independent responder time to stop a compromised administrator's proposal.

**Still required:** agree and deploy the custody arrangement. The root
(`SuperAdminCap`), cancellation and unpause powers should be held by an independently
controlled multisig. Verify its actual signer weights and threshold so the Ledger
key cannot authorize it alone. Separate routine administration from the quorum
responsible for stopping it. The PR does not change signer weights or enforce
multisig ownership by itself.

Revoking a compromised administrator is only half the response: **also cancel its
pending proposals**. Ordinary ready proposals can be applied by anyone, so revocation
alone does not invalidate them.

## 2. No timelock on upgrades, fees or treasury changes

Protected operations now follow: **propose → wait → explicitly apply**, with
cancellation available until application. This covers upgrades and immutability,
governed fees and destinations, protocol allocations, adapter admission and
creator-cap reassignment. Migrated bonding and presale vault creator-fee splits
also become delayed. Upgrade approval remains bound to the exact code digest,
live authority and package generation, with the native capability sealed in custody.

The intended release notice is **48 hours = 172,800,000 milliseconds**. Each
operation owns its notice; 48 hours is not an immutable protocol minimum.
Reducing a notice must itself wait the old notice. For example, redirecting the
treasury while proposing a zero-hour future notice still waits the existing
48 hours. After that reduction applies, later changes would have no wait.
Notice reductions therefore need monitoring and cancellation too.

**Still required:** verify every operation's live notice before release and monitor
proposals. Publication-owned policies and upgrade custody initially have zero
notice for setup while launchpad and presale are paused. Apply or cancel every
outstanding zero-notice proposal, including independent adapter admissions, then
set and read back the intended notices before unpausing. Raising a notice does
not repair an older proposal's deadline.

Some actions deliberately remain immediate: emergency pause/cancellation,
administrator grants/revocations, claim-signer changes and Quote listings, among
others. This is not a timelock on every privileged action. Root rotation and
later partner changes retain their separate seven-day delays.

## 3. No pause

Launchpad and presale start fully paused after upgrade custody is sealed.
Authorized responders can immediately pause selected operations:

- Launchpad: creation, trading (both buys and sells), and migration.
- Presale: creation, commitments, and migration.

`PauseAdmin` cannot unpause or move funds. `UnpauseAdmin` must explicitly release
the selected operations; there is no automatic expiry. Claims, refunds, presale
settlement/cancellation and opening-round delivery remain reachable while paused.
An existing exit's normal conditions still apply.

**Still required:** assign the response roles, rehearse pause and recovery with
the approved keys, and record the deployed pause state. A pause does not cancel
administrative proposals or restore a shortened notice.

## 4. No security contact or security.txt

This contract PR does not establish a monitored contact or publish `security.txt`.

**Still required:** select the responsible people and reporting address, publish
the contact on the security page and `/.well-known/security.txt` on the public
site, and test that a report reaches the responders. Record the published URLs
and the successful delivery check. Do not mark this item resolved from a contract
merge alone.

## 5. Older single-key root controls presales with open sales

PR 150 requires a fresh admin/dependent contract stack because storage and APIs
change. It does not migrate existing sales or modify an older package's root.
The new stack's paused release does not pause those older packages.

**Still required:** inventory each older package, root, administrator, open sale
and balance on chain. For each, choose and document a supported custody rotation,
migration or containment plan that preserves users' claims and refunds. Verify
the older deployment's actual capabilities and delays before scheduling anything;
the new code cannot add missing controls to immutable historical code. Include
transaction evidence and any remaining exposure in the response to John.

## Other changes included in the work

- **Safer creator-fee changes:** both migrated vault types start with a 48-hour
  split-change notice. Bluefin/Cetus settle collected fees under the old split
  before activating the new one, atomically. Aftermath continues to split fee
  coins when received; it does not promise attribution by when fees accrued.
- **Bonding holder rewards:** a separate optional gas reserve, capped one-time
  reimbursement to the treasury fixed at publication, a claim deadline, and
  permissionless recovery of unclaimed funds and unused gas after that deadline.
  Holder claims cannot spend the gas reserve. Nonoverlapping checkpoint gaps
  are allowed for low-volume periods; overlapping intervals remain rejected.
- **Fee and allocation corrections:** bonding defaults use a 1.5% Quote fee,
  zero Meme fee and a 50/50 division of that fee between protocol and creator;
  50% is a share of the fee, not an additional trading charge. Graduation defaults
  are 2.5% Meme / 1.5% Quote; presale defaults are 2% raise / 1% token;
  the LP protocol-fee default is 15%. Allocation plans now also require a
  positive LP Quote allocation.
- **Clearer administration:** named 48-hour constants, cap-update API names
  that also describe delay-only updates, and a Table-backed role registry.
  Guides, events and generated contract references follow the new APIs.

Consumer changes are prepared separately in
[SDK PR 88](https://github.com/interest-protocol/blast-v2-sdk/pull/88),
[application PR 711](https://github.com/interest-protocol/blast-v2/pull/711) and
[infrastructure PR 114](https://github.com/interest-protocol/blast-infra/pull/114).
The remaining broader admin/ACL SDK bindings are tracked in
[SDK issue 89](https://github.com/interest-protocol/blast-v2-sdk/issues/89).
These must be completed and verified for the chosen release; the consumer PRs
alone do not complete the fresh-stack rollout.

## Evidence available now

At contract revision `f661a03462d557dbf6d57c5b82a5ede98519643d`, the recorded
combined verification has **1,433 passing Move tests** and **10 passing changed
native venue cases**. Tests exercise delay boundaries and reductions, cancellation,
role revocation, stale versions, atomic rollback, fee settlement and reward recovery.
Earlier native pause matrices exercised both launchpad and presale, with 100%
instruction coverage measured for their pause, unpause and pause-guard functions.
The two unchanged large pause matrices were not rerun in the final combined run.

The new vault policy methods and bonding reward lifecycle also have measured
100% instruction coverage. This is scoped coverage, not a claim that every package
or external venue has complete coverage. Passing local tests are not evidence
that the new controls are deployed or configured correctly on chain.

Technical detail: [ADR 0134](decisions/0134-delayed-administration-pause-and-table-acl.md).
Release evidence requirements: [testing](testing.md) and
[deployment records](../deployments/README.md).

## Proposed dated plan

These are planning targets for team approval. Assign named owners before sending
them to Mysten; the responsibilities below do not constitute accepted commitments.

| Target (2026, UTC) | Proposed responsibility | Deliverable |
| --- | --- | --- |
| **4 Nov** | Protocol lead and security responders | Reconcile all eight findings; approve the role/custody matrix and independently controlled multisig threshold; inventory older roots and open sales. Start supported root rotations early and record their actual earliest execution dates. |
| **6 Nov** | Engineering and security responders | Finish remaining consumer bindings and review gates; publish and test the approved security contact and security.txt; approve a plan for each older presale deployment. |
| **9 Nov** | Engineering and operators | Complete local/native transaction rehearsals for paused setup, notice verification, compromised-key revocation plus cancellation, pause/unpause and user exits. Review the deployment evidence checklist and request deployment approval. |
| **11 Nov** | Operators and reviewers | Review approved deployment/custody evidence if deployment has occurred; otherwise report the blocker. Include live notices, pending proposals, pause state, signer threshold and the status of older sales. Do not infer completion from merged code. |
| **Friday 13 Nov** | Protocol lead | Send John the approved dated plan, evidence links, outstanding work and revised dates for anything incomplete. Deployment completion is a separate milestone from this response deadline. |

**Before admitting a real quote coin:** finish and independently verify the new
stack's authority, notices, custody, emergency controls and consumers; publish the
working reporting channel; and explicitly resolve or agree the treatment of older
presale exposure and the remaining brief items with Mysten. Record release approval
and on-chain evidence. This document authorizes no deployment or transaction.
