# 0134: Delayed administration, pause, and a Table-backed ACL

- Status: accepted
- Date: 2026-10-31
- Amended: 2026-11-02 — per-operation self-timelocked notices, no bypass, immediate creator-claim signer
- Amends: [0088](0088-reusable-launch-accounting-and-atomic-migration.md) (delayed migrator immutability), [0007](0007-acl-pause-and-versioning.md) (pause),
  [0032](0032-admin-authorized-upgrade-cap-custody.md) and
  [0034](0034-remove-premature-governance-cutover.md) (upgrades),
  [0097](0097-one-singleton-acl-with-typed-roles.md) (ACL storage),
  [0114](0114-launchpad-custody-before-activation.md) and
  [0117](0117-presale-versioning-and-activation.md) (one-time bootstrap and paused release)
- Supersedes: the 2026-10-28 canonical stack, which holds no user assets

## Context

The risk register requests notice before code, treasury, fee and creator-cap changes,
and immediate emergency pausing. A compromised administrator must not be able to
apply a protected change or shorten its own cancellation window in the same transaction.
The intended rollout notice is 48 hours; the owner requires operation-specific,
changeable delays rather than one package-wide duration or privileged bootstrap setters.
The immutable admin package also needs a Table-backed administrator registry, requiring
a fresh publication of the dependent stack. Existing first-party contracts hold no user assets.

## Decision

### Operation-owned notice

A delayed value owns its applied value, applied notice period and at most one pending
replacement. Each replacement binds the proposed value, proposed next notice and an
absolute deadline formed from the **old applied notice**. Application atomically commits
both proposed fields after that deadline. Cancellation changes neither applied field;
replacement restarts the full old notice. Delay-only and value-only helpers delegate to
ordinary scheduling. There is one application path and no immediate setter or bypass.

For example, with an applied 48-hour treasury notice, a proposal to redirect funds and
set the next notice to zero still waits 48 hours. The multisig can cancel it throughout
that window, including after readiness until application. Revoking the compromised
role alone does not cancel its proposal because ordinary application is permissionless.
CancelAdmin therefore remains an independent multisig power.

The primitive validates timestamp addition and that the proposed delay remains representable
at scheduling and actual application. No arbitrary duration ceiling is imposed. These
checks do not guarantee representability forever: every later schedule checks its own
then-current timestamp. Applied-value reads need no Clock. Domain setters permit an
unchanged value when the notice changes, and reject unchanged value-and-notice pairs
where applicable.

Standalone upgrade actions and cap reassignments retain their applied notice after
execution and cancellation. An explicit policy-only proposal can change the notice
without upgrading code, destroying upgrade authority or transferring a creator cap.
It follows the same old-delay rule and cannot be consumed as a different action.
Upgrades remain bound to an exact digest, live UpgradeAdmin role, package generation,
capability custody and native upgrade receipt.

Adapter admission retains a single persistent notice across witness types and separate
pending admissions. A fresh witness type cannot reopen zero-notice setup. Each accepted
admission binds its own next notice and immutable deadline. Applying an older admission
may therefore apply its older proposed notice even after a policy-only change. The
operator must settle or cancel all old admissions before completing setup; cancelling
only the policy-only proposal does not cancel independent admissions. Immediate adapter
removal clears that type's membership and pending admission without resetting its notice.

Fresh creator-cap reassignment operations and presale-vault LP-fee operations start at
48 hours. Their later notices can change independently after the current notice. A lazy
per-coin LP override inherits the accepted defaults notice; clearing and cancelling keep
the entry and its applied notice. New objects cannot reopen publication bootstrap.

### Immediate signer and administrator authority

The backend creator-claim signer is a plain key, outside the delayed-value abstraction.
ClaimSignerAdmin assignment and revocation are immediate and check the live package
version. SuperAdmin sits behind the multisig, which can disable a compromised administrator
immediately. Administrator registration, role assignment and AdminCap transfer remain
immediate. The exception does not extend to creator-cap reassignment, fees, treasury or code.

ACL administrators move from an inline map to Table storage; the total administrator cap
is removed, while the per-administrator role bound remains. Root rotation and later partner
changes retain their independent seven-day timelocks. Initial partner registration applies
the agreed share immediately.

### Publication and release

Publication retains the canonical Publisher and generation in a unique owned proof.
Wrapping consumes that proof and seals the matching never-upgraded UpgradeCap before
sharing the operational generation. The proof never authorizes policy setters. Launchpad
and presale start fully paused; migrators relies on launchpad migration gating.

Publication-owned policy operations and upgrade custody begin with zero notice. Ordinary
ACL roles may configure their values and intended notices in schedule/apply PTBs. There
are no special bootstrap setters. Before release, settle or cancel every outstanding
zero-notice proposal, configure and verify **each operation's** intended notice, then
release the selected pause bits through multisig UnpauseAdmin. Raising a notice never
rewrites an earlier proposal's deadline or proposed next notice. Setup may span transactions;
pause cycles and upgrades do not recreate publication authority or reset notices.

Nonzero compiled treasury destinations remain mandatory. Ordinary rate limits and quote
and adapter admission checks remain active during setup.

### Emergency pause and cancellation

PauseAdmin sets bits immediately and cannot unpause or move funds. UnpauseAdmin clears
selected bits immediately; pauses do not expire. Launchpad creation, trading (both buys
and sells, including opening-round admission/settlement), and migration have independent
bits. Presale creation, commitments and migration have independent bits. Claims, refunds,
presale settlement/cancellation and opening-round delivery remain reachable while paused.
Cancellation remains immediate. Quote/decimals listings, authority revocation, buybacks
that burn Meme and holder-reward round publication remain outside delayed policy.

### Replay

Scheduling events include the next notice and absolute deadline with the proposed action
or value. Application and cancellation facts identify which proposal becomes active or
is discarded. Multi-instance operations retain object identity. The indexer reads live
applied fields for current economics; readiness alone never activates a proposal.

## Alternatives considered

- A package-wide delay couples unrelated operations and prevents per-operation policy.
- A caller-selected wait permits a compromised administrator to choose zero.
- Immediate setters create a bypass for the same compromise the notice must contain.
- Delayed role grants add a second wait and impede emergency authority replacement.
- Clock-dependent reads would change trade and claim interfaces unnecessarily.
- A pause that expires needs Clock on every gated path; multisig release is explicit.

## Consequences

The fresh stack changes state layouts, signatures and event payloads. SDK, indexer and
operators must bind to the new stack. Each operation's live notice determines its real
cancellation window; zero provides none. The rollout must verify 48 hours where that
notice is required. The admin module remains generic and immutable while owner-stored
notice periods can change through their own timelocks.

## Verification

Tests cover old-delay reductions including zero, value-only/delay-only replacements,
atomic application, cancellation after readiness, replay, rescheduling, overflow at
schedule/application/later schedule, stale generations, exact action/digest matching,
fresh-object defaults, admission policy interactions and live ACL role rejection.
Native PTBs cover application followed by a failing schedule/application, proving rollback
of values, notices, proposals and events. Existing pause, custody, claims and ACL tests
remain required. Source boundary gates reject bypass APIs and missing owner persistence;
integrator guides and generated references must match source.
