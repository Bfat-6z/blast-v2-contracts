# 0134: Delayed administration, pause, and a Table-backed ACL

- Status: accepted
- Date: 2026-10-31
- Amended: 2026-11-02 — owner requested a configurable, self-timelocked delay and ordinary zero-delay setup
- Amends: [0088](0088-reusable-launch-accounting-and-atomic-migration.md) (delayed migrator immutability), [0007](0007-acl-pause-and-versioning.md) (pause),
  [0032](0032-admin-authorized-upgrade-cap-custody.md) and
  [0034](0034-remove-premature-governance-cutover.md) (upgrades),
  [0097](0097-one-singleton-acl-with-typed-roles.md) (ACL storage),
  [0114](0114-launchpad-custody-before-activation.md) and
  [0117](0117-presale-versioning-and-activation.md) (one-time bootstrap and paused release)
- Supersedes: the 2026-10-28 canonical stack, which holds no user assets

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |

A `Table` keeps each entry as a dynamic field, not inline
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/table.move:26,44-45`).

## Context

An external risk register found:

- **R2:** no timelock on upgrades or on fee, treasury and creator
  administration. It asks for a 48-hour delay covering at least upgrades,
  `UpgradeAdmin` grants, fee shares, treasury destinations and creator-cap
  reassignment. The pause is exempt.
- **R3:** no pause. It asks for a pause on buy, sell and migration, which a
  hot or automated key may hold, before real assets are admitted.

Asymptotic's L-3 found the same gap for upgrades. Today every admin setter
applies in the transaction that signs it, and no package can pause.

The owner also asked for the ACL's admins to live in a `Table`.
`blast_admin` is immutable, so that needs a fresh publish of every package
that links it.

## Decision

### Ship path

Publish a fresh stack: `blast_admin`, `blast_partners`, launchpad, presale and
migrators. Blast SUI and Boosts link the new `blast_admin` at their next
publish.

### One delay type

`blast_admin::delayed` owns applied values and absolute pending deadlines.
`schedule` and `new_pending` take an explicit `delay_ms` and Clock; zero is valid.
Reads need no Clock. Rescheduling replaces the pending proposal and snapshots a
new deadline. Applying before that deadline aborts. Scheduling rejects timestamp
overflow; cancel removes the proposal. This explicit-application primitive does
not change the independent seven-day ACL root and partner timelocks.

Each consuming package's canonical PackageVersion owns `admin_delay: Delayed<u64>`,
initially zero. All governed schedules read `admin_delay_ms()` internally, including
upgrades, immutability, creator caps and policy administration. Callers cannot
supply a shorter operational notice. Existing pending deadlines never change
when the applied policy changes.

The marker's `schedule_admin_delay` requires UpgradeAdmin and schedules the new
value under the **old applied delay**; `apply_admin_delay` is permissionless once
ready; `cancel_admin_delay` requires CancelAdmin. All enforce the current version.
Same-value proposals abort. Zero is also valid later, but a reduction to zero
waits the old delay. No arbitrary minimum or maximum is imposed; the proposal
must fit a u64 deadline both when scheduled and at actual application. Changes
emit AdminDelayScheduled, AdminDelayChanged and AdminDelayCancelled events.

For example, a 48-hour policy reduced to zero still waits 48 hours. A fee proposal
already scheduled under 48 hours keeps its original deadline after that reduction.
The owner approved this design to remove privileged bootstrap setters while
retaining a practical initial configuration path.

### Delayed setters

Every `set_<x>` becomes three functions. The treasury shows the shape; every
other delayed field below follows it with its own role.

```move
public fun schedule_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    treasury: address,
    clock: &Clock,
); // emits TreasuryScheduled { treasury, ready_at_ms }

public fun apply_treasury(          // anyone, once ready
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    clock: &Clock,
); // emits TreasuryChanged { treasury }

public fun cancel_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
); // emits TreasuryCancelled { treasury }
```

`CancelAdmin` is a new role held by the multisig. Revoking a compromised role
does not clear what it scheduled, and anyone can apply, so the multisig needs
its own stop.

The delayed fields:

```move
// launchpad
public struct RuntimeConfig has key {
    id: UID,
    creator_claim_signer_public_key: Delayed<vector<u8>>, // ClaimSignerAdmin
    protocol_fee_share_bps: Delayed<Bps>,                 // FeeAdmin
    treasury: Delayed<address>,                           // TreasuryAdmin
}

public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    quotes: Table<TypeName, bool>,
    trade_fees: Delayed<TradeFees>,                       // FeeAdmin; was quote_fee_bps + meme_fee_bps
    migration_witnesses: VecSet<TypeName>,
    pending_witnesses: VecMap<TypeName, Pending<bool>>,   // AdapterAdmin admits
    protocol_allocation: Delayed<ProtocolAllocation>,     // TreasuryAdmin
    creation_fee: Delayed<u64>,                           // FeeAdmin
}

// presale
public struct FeePolicy has key {
    id: UID,
    destination: Delayed<address>,                        // TreasuryAdmin
    fees: Delayed<ProtocolFees>,                          // FeeAdmin
}

public struct Vault<phantom Meme, phantom Quote> has key {
    // ...
    protocol_fees: Delayed<ProtocolFees>,                 // FeeAdmin (LP-fee rates)
}

public struct CreationPolicy has key {
    // ...
    pending_witnesses: VecMap<TypeName, Pending<bool>>,   // AdapterAdmin admits
}

// migrators
public struct LpFeePolicy has key {
    id: UID,
    destination: Delayed<address>,                        // TreasuryAdmin
    defaults: Delayed<SharePair>,                         // FeeAdmin
    coins: Table<TypeName, Delayed<Option<SharePair>>>,           // FeeAdmin
}
```

Revoking the claim signer (an empty key) and removing an adapter use
`set_now` or remove at once, because they only take authority away.

`blast_presale::set_protocol_fees` stays immediate before a sale starts, but
may only set rates at or below the in-force `FeePolicy` rates.

Clearing a per-coin LP-fee override is also delayed: restoring live defaults can
increase fees. `None` denotes fallback to those defaults, and the table entry
remains available for subsequent schedules. Adapter removal and signer revocation
also cancel any pending replacement so it cannot restore revoked authority.

### Upgrades

```move
public enum UpgradeAction has copy, drop, store {
    Upgrade(vector<u8>), // the package digest
    MakeImmutable,
}

public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_FUN>,
    pending: Option<Pending<UpgradeAction>>,
}

public fun schedule_upgrade(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, digest: vector<u8>, clock: &Clock);
public fun schedule_make_immutable(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, clock: &Clock);
public fun cancel_upgrade_action(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<CancelAdmin>);

/// Aborts unless a ready Upgrade(digest) is pending.
public fun authorize_upgrade(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, digest: vector<u8>, clock: &Clock): UpgradeTicket;
/// Aborts unless a ready MakeImmutable is pending.
public fun make_immutable(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, clock: &Clock);
```

Launchpad, presale and migrators each get this. `commit_upgrade_and_advance` is
unchanged. `make_immutable` is delayed because it removes the only way to fix
code.

### Creator caps

```move
public struct Launch<phantom Meme, phantom Quote> has key {
    // ...
    pending_curve_fee_cap_recipient: Option<Pending<address>>,
    pending_metadata_cap_recipient: Option<Pending<address>>,
}

public fun schedule_curve_fee_cap_reassignment<Meme, Quote>(self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, _: &AdminWitness<CreatorAdmin>, recipient: address, clock: &Clock);
public fun reassign_curve_fee_cap<Meme, Quote>(self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, clock: &Clock, ctx: &mut TxContext); // anyone, once ready
public fun cancel_curve_fee_cap_reassignment<Meme, Quote>(self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, _: &AdminWitness<CancelAdmin>);
// the same three for the metadata cap
```

The current cap holder can still claim curve fees during the notice period.

### Partners

`blast_partners::register` initializes the agreed share and managing cap
immediately, without a `Clock` (owner, 2026-11-01). A new partner earns its
share from its first payment. Later share changes and cap replacements retain
the package's existing 7-day partner delay.

### Role grants are immediate

`grant_role` and `AdminCap` transfers are not delayed (owner, 2026-10-31).
Every change a role can make to fees, destinations, creator authority,
adapters or code is delayed where it is made, so a new `UpgradeAdmin` still
waits the applied administrative delay from scheduling a digest. A 48-hour
rollout policy meets the requested R2 notice; zero does not provide that notice.

### Pause

```move
public struct PackageVersion has key {   // launchpad; presale is the same with BLAST_PRESALE
    id: UID,
    generation: OperationalVersion<BLAST_FUN>,
    paused: u8,
    admin_delay: Delayed<u64>,
}

const CREATE: u8 = 1;
const TRADING: u8 = 2;  // launchpad: buy and sell together
const MIGRATE: u8 = 4;  // launchpad
// Presale uses BUY = 2 for commitments and MIGRATE = 8.

public fun pause(self: &mut PackageVersion, _: &AdminWitness<PauseAdmin>, bits: u8);     // sets bits only
public fun unpause(self: &mut PackageVersion, _: &AdminWitness<UnpauseAdmin>, bits: u8); // clears bits only
public(package) fun assert_not_paused(self: &PackageVersion, bit: u8);
// events: Paused { bits, paused }, Unpaused { bits, paused }
```

| Bit | Launchpad | Presale |
| --- | --- | --- |
| `CREATE` | `new`, `finalize`, `share` | `new`, `share` |
| `TRADING` (2) | `buy`, `sell`, `join_opening_round`, `settle_opening_round` | — |
| `BUY` (2) | — | `commit_open`, `commit_allowlisted`, `commit_uncapped` |
| `MIGRATE` | `migrate` (4) | `migrate` (8) |
| Never paused | `deliver_opening_round`, fee claims | `claim`, `cancel_unlaunched`, `settle` |

`PauseAdmin` may be a hot or automated key; it can freeze but never move funds.
`UnpauseAdmin` is held by the multisig. A pause does not expire.

### Roles

Each package's `*_domain` module adds three roles:

```move
public struct PauseAdmin()
public struct UnpauseAdmin()
public struct CancelAdmin()
```

Migrators use the launchpad's roles and are not paused.

### ACL

```move
public struct ACL has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: Table<ID, VecSet<TypeName>>, // was VecMap<ID, VecSet<TypeName>>
    pending_super_admin: Timelocked<Option<address>>,
}
```

Only storage changes. The functions, `AdminCap` and events keep their
behavior. `MAX_ADMINS` and its abort are removed; `MAX_ROLES_PER_ADMIN`
stays.

### Genesis

```move
// Move.toml [addresses], set before publish; 0x0 aborts init
blast_treasury = "0x…"           // RuntimeConfig.treasury, FeePolicy.destination
blast_lp_fee_destination = "0x…" // LpFeePolicy.destination
```

These nonzero destinations are safe publication defaults. Launchpad, presale
and migrators retain their Publisher and initial generation in a unique owned
Publication. It authorizes only validated wrapping of the matching never-upgraded
UpgradeCap. No policy setters accept it. Custody wrap consumes Publication
permanently and shares PackageVersion with administrative delay zero. Launchpad
and presale start fully paused; migrators relies on launchpad's migration pause.

The multisig grants ordinary ACL roles and configures policy using schedule/apply
and Clock. With zero delay, scheduling and application can share a PTB. Quote
admission uses the ordinary immediate ListingAdmin setter. Launch and sale
creation continue checking actual quote and adapter admission; wrap no longer
requires preconfigured policy. Normal rate bounds and nonzero destinations apply.

Apply or cancel all outstanding zero-delay setup proposals, then schedule and
apply the chosen administrative delay (48 hours for the R2 rollout). Enabling it
waits the old zero delay. Read back configuration and policy before immediate
UnpauseAdmin release. Existing zero-delay proposals remain ready after enabling
a positive delay; raising the policy is not a substitute for settling them.
Setup can span transactions. Pause cycles and upgrades cannot reset delay or
recreate Publication. There is no privileged bootstrap setter or reusable bypass.

### Never delayed

Claims of fees, rewards and refunds; pause, unpause and cancel; revocations;
quote and decimals allowlists; buybacks (their Meme is burned); reward rounds.

## Alternatives considered

- **Upgrade the 2026-10-28 stack.** Cannot change the immutable ACL.
  Rejected; the stack holds no assets.
- **`Timelocked<T>` for these fields.** Its reads need a `Clock`, which would
  change `buy`, `sell` and claims.
- **Delayed role grants.** Adds a second wait to powers that are already
  delayed, and holds back a new `PauseAdmin` in an incident. Rejected by the
  owner.
- **Pause that expires.** Needs a `Clock` on every paused path; the multisig's
  unpause is the release instead.

## Consequences

- Governed changes snapshot the applied package delay. Operators must enable and
  verify the chosen notice before release; the initial zero policy provides no notice.
- Later delay reductions wait the old policy, including reductions to zero.
  Existing proposals retain their deadlines. Emergency policy changes follow
  the same notice; pause and cancellation remain immediate.


- Pausing `TRADING` stops both buys and sells until unpause; claims and refunds stay open.
- The indexer reads `*Scheduled`, `*Cancelled`, `Paused` and `Unpaused`. The
  admin console reads the ACL's table entries instead of an inline map.
- SDK, indexer, web, workers and MVR rebind to the new packages; partners
  register again.

## Rollout

| Date | Milestone |
| --- | --- |
| 2026-11-02 | ADR accepted; `PauseAdmin` worker owner named |
| 2026-11-05 | `blast_admin` (`delayed`, Table ACL) and `blast_partners` |
| 2026-11-10 | Launchpad, presale, migrators |
| 2026-11-12 | `docs/llms`, SDK, indexer, admin console; pause worker; multisig signers |
| 2026-11-13 to 11-18 | Independent review of the diff |
| 2026-11-19 | Mainnet publish |
| 2026-11-20 | Rebind; first launch or presale may open |

Nothing opens before the rebind date; if a date slips, so does that gate.

## Verification

- `delayed`: apply before `ready_at_ms` aborts; reschedule restarts the delay;
  cancel clears it; `value` never changes before apply.
- Delay policy: production zero initial state, old-delay reductions and increases,
  zero and positive pending snapshots, replacement, cancellation, no-op and overflow,
  stale generations, real-ACL role rejection and same-PTB rollback.
- Every delayed setter: schedule, early apply, apply, cancel, old package
  generation.
- `authorize_upgrade` and `make_immutable` abort without a ready matching
  action.
- Every pause bit stops its entry points; every never-paused path works with
  all bits set; `pause` cannot clear and `unpause` cannot set.
- ACL works past 32 admins.
- Publish aborts on a `0x0` destination.
- `check_move_style.py`, package gates and `gen_llms.py` pass.
