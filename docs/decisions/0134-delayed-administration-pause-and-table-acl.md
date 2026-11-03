# 0134: Delayed administration, pause, and a Table-backed ACL

- Status: accepted
- Date: 2026-10-31
- Amended: 2026-11-02 — operation-owned notices, delayed creator splits, and bonding reward custody
- Amended: 2026-11-03 — keyed delayed primitives that own lifecycle events; root transfer on `delayed`
- Amends: [0088](0088-reusable-launch-accounting-and-atomic-migration.md) (delayed migrator immutability),
  [0089](0089-migrators-own-post-migration-and-start-launches.md) (creator splits and holder-reward custody),
  [0007](0007-acl-pause-and-versioning.md) (pause),
  [0032](0032-admin-authorized-upgrade-cap-custody.md) and
  [0034](0034-remove-premature-governance-cutover.md) (upgrades),
  [0097](0097-one-singleton-acl-with-typed-roles.md) (ACL storage),
  [0114](0114-launchpad-custody-before-activation.md) and
  [0117](0117-presale-versioning-and-activation.md) (one-time bootstrap and paused release),
  [0097](0097-one-singleton-acl-with-typed-roles.md) (timelocked root transfer),
  [0058](0058-eventless-package-initialization.md) (eventless initialization)
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
Standalone action schedules accept only their action inputs: an upgrade digest,
immutability decision or creator-cap recipient. They use and preserve the operation's
applied notice. Changing its notice requires an explicit policy-only
proposal; the two proposal kinds share the operation's single pending slot.
Upgrades remain bound to an exact digest, live UpgradeAdmin role, package generation,
capability custody and native upgrade receipt.

Adapter admission retains a single persistent notice across witness types and separate
pending admissions. A fresh witness type cannot reopen zero-notice setup. Admission
schedules identify only the witness type and snapshot a deadline using the currently
applied notice. Applying an admission changes only the allowlist; it cannot
restore an older notice after an independent policy change. Only the explicit admission
policy schedule/apply path changes the shared notice. Accepted deadlines remain fixed.
The operator must settle or cancel old zero-notice admissions before completing setup;
cancelling only the policy proposal does not cancel independent admissions. Immediate
adapter removal clears that type's membership and pending admission without resetting
its notice.

Fresh creator-cap reassignment operations and presale-vault LP-fee operations start at
48 hours. Their later notices can change independently after the current notice. A lazy
per-coin LP override inherits the accepted defaults notice; clearing and cancelling keep
the entry and its applied notice. New objects cannot reopen publication bootstrap.

### Delayed migrated-vault creator splits

Both bonding `LpVault.fee_split` and presale `Vault.fee_split` store
`blast_admin::delayed::Delayed<FeeSplit>` with a named 48-hour initial notice.
The applied value remains active until explicit application. The live curve-fee cap
holder (bonding) or exact stored presale cap holder (presale) schedules and cancels.
Scheduling atomically binds a proposed split and next notice. Full old notice applies
to reductions and delay-only changes; replacements restart that wait. Unchanged
applied value and notice are rejected. Cancellation is allowed even after readiness.
Version guards precede authority and value validation. Pending decisions survive
cap reassignment; the new live cap can replace/cancel them, and ready application
remains permissionless. Standalone presale vaults have no matching creator cap.

Application accepts only the stored ready decision. For Bluefin and Cetus, public
venue adapters validate readiness before external work, collect every vault position's
fees under the applied split, compound auto-LP where applicable, and invoke a
package-only core activation. A later transaction failure rolls back collection,
payouts and activation together. No public core activation bypasses this settlement.
The shared read-only `Delayed.assert_ready` owns no-pending, readiness and application-time
representability checks without modifying pending or applied policy.

Aftermath presales retain their established collection-time fee accounting. DAO fees
arrive as separate coins at the vault address; receiving an arbitrary list cannot
prove that every earlier coin was received. After the full notice and an explicit
venue-checked application, later receipt uses the newly applied split, even when the
coin arrived before activation. Neither notice expiry nor scheduling alone changes
receipts. The API and guides make this accounting boundary explicit; the protocol
does not claim accrual-time fee attribution for Aftermath.

`FeeSplitScheduled` records proposal, threshold and next notice;
`FeeSplitCancelled` records the discarded proposal; `FeeSplitChanged` records old
and applied splits plus applied notice. Vault-created events still carry the plain
initial split; the immutable published package bytecode establishes its named 48-hour
initial notice. Replay initializes that notice from the package version, then follows
schedule/cancel/change facts. Indexers decode the stored delayed policy and treat expiry as readiness,
never as activation.

### Bonding holder-reward custody and recovery

Bonding rounds reserve holder assets separately from an optional Quote gas reserve.
The live RewardsAdmin publishes the allocation and may settle reimbursement once;
measuring attributable gas remains an off-chain responsibility. Publication checks the
caller's expected treasury against the governed LP-fee destination, even with no reserve,
and freezes that address for the round. Later treasury changes cannot redirect its
reimbursement. A zero reserve disables reimbursement; settlement is capped at the
reserved amount and immediately returns the unused reserve to the funding vault.
Holder proofs cannot spend the reserve, and bonding holder Meme remains payable to holders.

A round commits a future claim deadline. Bonding claims require a time strictly before
that deadline. From the deadline onward, anyone may consume the round and return
unclaimed holder assets and an unsettled reserve to its original vault. This recovery
needs no administrator, so role revocation cannot strand custody. Reimbursement may
still settle after the deadline while the round exists; settlement and closure serialize
through the same shared round. The first completed closure deletes it.

Round numbers remain sequential, but checkpoint intervals need only be nonempty and
nonoverlapping: `previous_end <= start < end`. Gaps allow the publisher to skip periods
with insufficient volume. Closing a round does not rewind its number or checkpoint
cursor. Publication, claims, gas settlement and closure events preserve the separate
holder and gas accounting for replay.

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

Scheduling events include the absolute deadline and notice with the proposed action
or value. For value-and-policy replacements the notice is the proposed next period;
for action-only proposals it records the unchanged notice used at scheduling. For
upgrades and adapter admissions, only explicit policy application emits a delay-change
fact. Application and cancellation identify which proposal becomes active or is
discarded. Multi-instance operations retain object identity. The indexer reads live
applied fields for current economics; readiness alone never activates a proposal.
Curve-fee and metadata-cap policy events identify their operation through distinct
payload types, keeping the event stream self-describing without a boolean discriminator.

## Alternatives considered

- A package-wide delay couples unrelated operations and prevents per-operation policy.
- A caller-selected wait permits a compromised administrator to choose zero.
- Immediate setters create a bypass for the same compromise the notice must contain.
- Delayed role grants add a second wait and impede emergency authority replacement.
- Clock-dependent reads would change trade and claim interfaces unnecessarily.
- A pause that expires needs Clock on every gated path; multisig release is explicit.

## Consequences

The fresh stack changes state layouts, signatures and event payloads. SDK, indexer and
operators must bind to the new stack. The fresh interfaces are implemented in
[SDK88](https://github.com/interest-protocol/blast-v2-sdk/pull/88),
[app/workers711](https://github.com/interest-protocol/blast-v2/pull/711),
[indexer114](https://github.com/interest-protocol/blast-infra/pull/114) and
[admin22](https://github.com/interest-protocol/admin-acl/pull/22). These source
changes require a fresh publication manifest and coordinated release.
Each operation's live notice determines its real
cancellation window; zero provides none. The rollout must verify 48 hours where that
notice is required. The admin module remains generic and immutable while owner-stored
notice periods can change through their own timelocks.

## Verification

Tests cover old-delay reductions including zero, value-only/delay-only replacements,
atomic application, cancellation after readiness, replay, rescheduling, overflow at
schedule/application/later schedule, stale generations, exact action/digest matching,
fresh-object defaults, admission policy interactions and live ACL role rejection.
Creator-split tests cover notice boundaries, replacement, cancellation, live-cap binding,
permissionless venue activation and old-split settlement. Bonding reward tests cover
separate gas custody, frozen treasury, capped and disabled reimbursement, checkpoint
gaps, exact claim/closure deadlines, authority revocation and conservation on recovery.
Native PTBs cover application followed by a failing schedule/application, proving rollback
of values, notices, proposals and events. Existing pause, custody, claims and ACL tests
remain required. Source boundary gates reject bypass APIs and missing owner persistence;
integrator guides and generated references must match source.

## Amendment 2026-11-03: keyed primitives that own their events

### Context

Owners re-implemented the delayed state machine around a bare `Pending` record,
encoded notice-only proposals with placeholder values (`DelayOnly`, `false`,
`option::none()`), passed the same notice twice, persisted the next notice by hand
under source-gate protection, and each emitted its own scheduled, cancelled and
changed events. The ACL root transfer used the separate immutable
`blast_fun_timelock` package, whose values switch by themselves at a deadline,
only as a deadline holder.

### Decision

`blast_admin::delayed` provides three types, each storing its `owner` object ID
and an owner-defined key `K`. Constructors take the owner's `&UID` rather than an
`ID`, so only code that creates or holds an object can attribute delayed values
and events to it:

- `Delayed<K, T>`: a setting with its notice and one proposal (unchanged rules).
- `DelayedAction<K, A>`: a notice and one proposal that is either `Action(A)` or
  a notice change. `take_action` hands a ready action to the owner;
  `apply_delay` applies a ready notice change; each rejects the other kind. The
  primitive persists notice changes itself.
- `DelayedSet<K, E>`: an allowlist whose admissions each snapshot a deadline from
  the applied notice; a notice change never moves accepted deadlines; removal is
  immediate.

Only the module that defines `K` can pack it, so only that module can create a
value keyed by it. The primitive emits every lifecycle fact, generic in `K` and
the value or action type: `DelayedCreated`, `DelayedScheduled`,
`DelayedCancelled`, `DelayedApplied`, `ActionCreated`, `ActionScheduled`,
`ActionCancelled`, `ActionApplied`, `MemberRemoved`, `DelayedDestroyed` and
`ActionDestroyed`. A replacement emits `Cancelled` for the displaced proposal
before `Scheduled`, so every proposal ends in exactly one `Applied` or
`Cancelled`. Destroying a value with a pending proposal aborts, and destruction
emits its own event, so no proposal or membership ends silently. Owners emit only their own side
effects. The primitive rejects proposals that change nothing.

Upgrade custody, creator-cap reassignment and the ACL root transfer use
`DelayedAction`; migration-witness admission uses `DelayedSet`; settings use
`Delayed`. The raw `Pending` API is removed. The root transfer is a
`DelayedAction` with a fixed seven-day notice and no notice-change path, and
`blast_admin` no longer depends on `blast_fun_timelock`. Zero-notice bootstrap is
unchanged: configure with schedule-and-apply pairs, then raise each notice.

### Consequences

Package initialization is no longer eventless: every delayed value created in
`init` emits `DelayedCreated` or `ActionCreated`. This is deliberate. Each
operation's stream then starts with its own initial value and notice, so replay
no longer reads initial notices from published bytecode. Consumer `init`
functions still emit no events of their own.

Every delayed field gains `owner` and `key`; delayed, consumer and event layouts
change, and the replay stream for delay lifecycle moves to `blast_admin::delayed`
event types. SDK, indexer and admin console decoders must follow, with a fresh
publication of the stack. Keys must be structs without public constructors, and
owner objects must not expose their `&UID`; otherwise another package could emit
events under that key or owner.
