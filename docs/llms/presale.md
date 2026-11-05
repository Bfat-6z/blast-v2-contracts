## Presale

### What it is

`blast_presale` runs standalone presales on Sui mainnet. A creator brings a new coin
with zero supply. The sale mints the whole supply once, splits it between buyers, the launch
pool, Blast, and named recipients, and gives up mint authority forever. Buyers commit a Quote coin
(for example SUI) during a commitment window. By default commitments may exceed the raise target:
everyone is then filled at one common rate and the excess is refunded. A creator may instead
hard-cap the sale, from the start or from a later point in the window, so it takes Quote first
come, first served only up to the raise; such a sale may also close as soon as its raise is full.

The creator picks the sale's venue at creation: the venue's `prepare` call records the pool tier
and returns a sealed `blast_core::migration::VenueTicket` that `blast_presale::blast_presale::new`
redeems, so the sale can migrate only to that venue. Anyone can migrate a funded sale into a new
full-range Cetus or Bluefin pool, or a 50/50 Aftermath pool behind Aftermath's DAO-fee pool; the
same transaction pays Blast (or, on a sale that names a partner, holds Blast's raise fee for a
later pay call), the raise recipients, and the token recipients, then hands the pool's balances and
the vault's terms to the venue in a sealed `blast_core::migration::Migration`. The venue creates
the pool and locks the position in a new shared `blast_vault::vault::Vault`, which has no removal
path. Buyers then claim their tokens and overflow refund. A sale that misses its raise, or that
someone cancels once its liquidity deadline passes unmigrated, refunds every commitment in full.

The vault (fee split, owner claims, partner payouts, holder-reward rounds) is described in the
vault guide, and the hand-off, owner proof, fee split, treasury, and Merkle primitives in the core
guide; both ship in this file. This guide covers what the presale does and what each call needs.

The presale is separate from the bonding-curve launchpad and reuses the shared Blast
ACL, partner registry, and operational-version/capability-custody primitives.
Publication creates an owned `blast_presale_package::Publication`; it shares no
PackageVersion. `blast_presale::package_admin::wrap` consumes Publication and the
fresh matching UpgradeCap, sealing compatible custody and sharing the version
fully paused; publication-owned policy operations start with zero notice. Ordinary ACL-authorized operations
then configure policies before release.

See ADR 0117 and ADR 0137. In this guide `SaleToken` is the sale coin; venues call it `Meme`.

Routine state-changing public calls below take `&blast_presale_package::PackageVersion`
immediately after their first object argument (as their first argument, for the venues'
`prepare`), including initializer setters, policy administration, migrations, payouts, fee
collections, and `blast_presale::blast_presale::prove_owner`. It is a read-only shared input except
during pause, unpause and upgrade commit-and-advance. A stale or future generation aborts in
`blast_admin::operational_version` before effects. Pure value constructors, the initializer's
`blast_presale::blast_presale::venue` getter and `blast_presale::blast_presale::destroy_cap` do not
take it. Venue calls that create or mutate a vault also take the vault package's own
`blast_admin::package_version::PackageVersion` (typed by `blast_vault_package::BLAST_VAULT_PACKAGE`),
because each package checks only its own generation.

### Objects and authority

Shared singletons, created once at deployment (`PackageAdmin` and `PackageVersion` by
`blast_presale::package_admin::wrap`, the others when the package is published):

- `fee_policy::FeePolicy`: Blast's current rates (`raise_bps`, `token_bps`, `lp_fee_meme_bps`,
  `lp_fee_quote_bps`, held in a `fee_policy::ProtocolFees`) that new sales snapshot, and the
  `destination` address Blast's raise and token fees go to.
- `creation_policy::CreationPolicy`: the allowlists checked once, when a sale is created: Quote
  types, venue witnesses, and Blast partners a sale may name.
- `blast_presale::venue_config::VenueConfig`: venue records written when a coin is prepared:
  each coin's `blast_presale::venue_config::PoolTier`, each Cetus coin's reserved pool-creation
  capability (never removed; migration only borrows it), and each Aftermath coin's
  `CreatePoolCapV2` (removed by that sale's migration).
- `blast_presale::package_admin::PackageAdmin`: holds the package's Publisher and compatible upgrade cap.
- `blast_presale::blast_presale_package::PackageVersion`: the singleton active generation and pause flags, shared by custody wrap.

Calls also take objects from other packages:

- Vault: `blast_vault_package::VaultRegistry` (migrations only; it must admit the venue's witness),
  the vault package's `PackageVersion`, and the core `blast_core::blast_treasury::Treasury` that
  Blast's LP fees go to.
- Sui: the sale coin's Coin Registry `Currency<SaleToken>` (mutable at `finalize` and in fee
  collections, which may burn Meme), the Quote's `Currency<Quote>` (Bluefin migration only), and
  `Clock` at `0x6`.
- Venues: Cetus `GlobalConfig`, `Pools`, the pair's `Pool<CoinA, CoinB>`, and Cetus LP Burn's
  `BurnManager`; Bluefin `GlobalConfig` and `Pool<Meme, Quote>`; Aftermath's `PoolRegistry` and the
  DAO-fee package's `Version`. All shared.

Per-sale objects:

- `blast_presale::blast_presale::Presale<SaleToken, Quote>`: shared. It holds every commitment, the whole minted
  supply, and the sale's terms until migration or refund. It has `key` only, so it cannot be
  transferred: it must be shared in the transaction that creates it.
- `blast_presale::blast_presale::PresaleCap`: owned by the creator (key, store). It proves sale
  ownership to the sale's vault through `blast_presale::blast_presale::prove_owner` and can be
  destroyed after a cancellation. It cannot change any sale term or move any commitment.
- `blast_vault::vault::Vault<Meme, Quote>`: shared, created by a Cetus, Bluefin, or Aftermath
  migration. It holds the Bluefin position, the Cetus LP-burn proof, or the DAO-fee pool's
  `OwnerCap` (Aftermath, whose LP coin is owned by `0x0`), and the balances its fees are split into
  (vault guide). An Aftermath vault is also the address its DAO-fee pool pays fees to.
- A vesting schedule (`Vesting<T>` from the external, immutable `blast_fun_vesting` package):
  shared, one per vested payout. See "Claiming vested tokens".

Venue witnesses: `blast_presale::cetus::Venue`, `blast_presale::bluefin::Venue`, and
`blast_presale::aftermath::Venue` are sealed witnesses only their own module constructs. A venue's
witness issues its tickets, redeems its sales' migrations, keys its position inside the vault, and
authorizes its fee collections. Blast admits each witness type twice: in `CreationPolicy` (so sales
may start on it) and in the vault's `VaultRegistry` (so it may create vaults).

Capabilities and who holds them:

| Object | Held by | Authorizes |
| --- | --- | --- |
| `blast_presale_package::Publication` | Deployer, until wrap consumes it permanently | Holds publication provenance until native custody is sealed; no policy authority. |
| `blast_acl::AdminCap` granted a presale role | Blast operations | The calls of each role it holds; see the table below. |
| `blast_presale::blast_presale::PresaleCap` | Sale creator (or a vendor treasury) | `blast_presale::blast_presale::prove_owner`, `blast_presale::blast_presale::destroy_cap`. |
| `blast_partners::blast_partners::Partner` | Shared, managed in `blast_partners` | Read by the presale and the vault to pay a partner its cut of Blast's fees. |

Blast administers presales through the one shared Blast access-control list
(`blast_admin::blast_acl`), as it does its other packages. `blast_presale_domain` declares the presale's roles; an operator's
`blast_acl::AdminCap` granted a role calls `blast_acl::sign_in<Role>` with the shared
`blast_acl::ACL` in the same PTB and passes the returned `blast_acl::AdminWitness<Role>` by
reference. Each admin call names exactly one role in its signature:

| Role | Calls |
| --- | --- |
| `blast_presale_domain::PauseAdmin` | `blast_presale_package::pause` |
| `blast_presale_domain::UnpauseAdmin` | `blast_presale::package_admin::unpause` |
| `blast_presale_domain::CancelAdmin` | `fee_policy::cancel_fees`, `fee_policy::cancel_destination`, `creation_policy::cancel_venue`, `creation_policy::cancel_venue_delay`, `blast_presale::package_admin::cancel_upgrade_action` |
| `blast_presale_domain::FeeAdmin` | `fee_policy::schedule_fees`, `blast_presale::blast_presale::set_protocol_fees`, `creation_policy::add_partner`, `creation_policy::remove_partner` |
| `blast_presale_domain::TreasuryAdmin` | `fee_policy::schedule_destination` |
| `blast_presale_domain::ListingAdmin` | `creation_policy::set_quote_allowed` |
| `blast_presale_domain::AdapterAdmin` | `creation_policy::schedule_venue`, `creation_policy::remove_venue`, `creation_policy::schedule_venue_delay` |
| `blast_presale_domain::UpgradeAdmin` | `blast_presale::package_admin::schedule_upgrade`, `blast_presale::package_admin::schedule_make_immutable`, `blast_presale::package_admin::authorize_upgrade`, `blast_presale::package_admin::commit_upgrade_and_advance`, `blast_presale::package_admin::make_immutable`, `blast_presale::package_admin::schedule_upgrade_delay` |

Holder-reward rounds are the vault's, under the core roles (vault guide). A role from another
package, such as
`blast_fun_domain::FeeAdmin`, is a different type and cannot reach these calls; the vault's own
Blast calls take the core roles in `blast_core::blast_domain`. PauseAdmin may freeze creation,
commitments or migration. No admin may cancel a sale, move commitments, change windows,
recipients, or a vault's fee split. Presale admins' power over a live sale is limited to its Blast
rates before the window starts and the destination of its raise and token fees. After migration,
Blast's per-vault LP-fee share is the vault's own delayed setting (vault guide).

### Lifecycle

`blast_presale::blast_presale::Lifecycle` is one-way:

```
Pending --share--> Open --settle (total >= raise)--> Funded --migrate--> Migrated
                     \--settle (total < raise)--> Cancelled
                                 Funded --cancel_unlaunched (at LP deadline)--> Cancelled
```

| State | Exists | Allows |
| --- | --- | --- |
| `Pending` | Only inside the creation PTB, between `finalize` and `share` | `blast_presale::blast_presale::set_protocol_fees` (admin, when the creation PTB also signs in as `FeeAdmin`), `blast_presale::blast_presale::share` |
| `Open` | From `share` until `settle` | Before `start_ms`: `blast_presale::blast_presale::set_protocol_fees` (admin), which may only keep or lower each rate. From `start_ms` until `end_ms`: commits. From `end_ms`, or earlier once the raise is full under a hard cap that closes the sale when filled: `blast_presale::blast_presale::settle` |
| `Funded` | After a settle that met the raise | Migration at any time; `blast_presale::blast_presale::cancel_unlaunched` from the LP deadline |
| `Migrated` | After migration | `blast_presale::blast_presale::claim` (tokens + overflow refund), `blast_presale::blast_presale::pay_protocol_fees_with_partner` once on a partnered sale |
| `Cancelled` | After an underfunded settle or `cancel_unlaunched` | `blast_presale::blast_presale::claim` (full refund), `blast_presale::blast_presale::destroy_cap` |

`blast_presale::blast_presale::prove_owner` works in every state, but only a migrated sale has a
vault to present the proof to. Migration and cancellation race once the LP deadline passes:
whichever transaction lands first wins. Nobody can withdraw a commitment while the sale is `Open`
or `Funded`. The vault never closes and its position is never removed.

### Flows

#### Publication and initial configuration

1. Publish the package. The deployer receives the unique `blast_presale::blast_presale_package::Publication`,
   holding its canonical Publisher and initial generation. Policy singletons are
   shared; no operational PackageVersion exists yet.
2. Call `blast_presale::package_admin::wrap` with Publication by value and the matching
   never-upgraded UpgradeCap. It consumes Publication permanently, seals native
   custody and shares PackageVersion. Publication-owned policy operations start with zero notice. All operations start paused (combined mask = 7).
3. Grant the required roles on the real Blast ACL. Configure destinations, fees
   and reviewed venue admission through the ordinary schedule/apply operations
   with Clock. At zero delay these can run in one PTB. Quote admission uses its
   ordinary ListingAdmin setter. No publication proof authorizes policy changes.
   Each presale venue, and the presale's own `blast_presale::blast_presale::PackageWitness` as
   the issuer of its vault terms, must also be listed in the vault's `VaultRegistry`
   (`blast_vault_package::schedule_witness`), or its migrations abort.
4. Apply or cancel every outstanding zero-delay proposal. Use each operation's own
   role to schedule and apply its intended value and next notice. Upgrade custody
   already holds its 48-hour notice from publication.
   Read back every operation's notice and configured value before release.
5. Sign in as UnpauseAdmin and clear the intended bits on PackageVersion (all = 7) with
   `blast_presale::package_admin::unpause`. Unpause is immediate once every notice is guarded:
   the fee destination, the fee rates, the venue set and the upgrade slot each need a nonzero
   applied notice, no pending proposal that would set it to zero, and no pending venue
   admission. Otherwise it aborts with `blast_presale::errors::EUnguardedNotice` (5).

Setup may span transactions. Pausing and upgrades never reset the administrative
policy or recreate Publication. An outstanding zero-delay proposal remains ready
after enabling positive notices, which is why setup must settle those proposals
before release. Venue admission remains checked when creating sales.

PTB conventions used below: `Clock` is the shared object `0x6`. Values such as `Bps`,
`RecipientShare`, `EligibilityPolicy`, and `FeeSplit` are structs, so build them with Move calls
and pass the results; plain numbers, booleans, addresses, and `vector<u8>` go in as pure inputs.
Build a `vector<RecipientShare>` or `vector<Route>` with the PTB `MakeMoveVec` command (a
recipient list may be empty).

#### Creating a sale

A sale is created in one PTB in four stages, the same shape as the launchpad's: the venue's
`prepare` records the coin's pool tier and returns a `VenueTicket<Meme, Quote>`;
`blast_presale::blast_presale::new` redeems the ticket and returns a
`blast_presale::blast_presale::PresaleInitializer<Meme, Quote>`; setters on the initializer record
the creator's terms; `blast_presale::blast_presale::finalize` checks them all together, mints the
supply, and returns the pending `Presale`, which `share` publishes. Neither the ticket nor the
initializer has abilities: `new` is the only way to consume the ticket and `finalize` the only way
to consume the initializer, so the PTB must do both.

The venue is fixed for good at creation. Who may call: *anyone* who owns a zero-supply
`TreasuryCap<SaleToken>` and the matching shared Coin Registry `Currency<SaleToken>`, for a Quote
type and venue the `CreationPolicy` allows. The sale currency must have confirmed `Unregulated`
status; regulated coins and legacy currencies with `Unknown` status are rejected, including legacy
coins whose deny cap has not been registered. Create the sale coin through Coin Registry without
enabling regulation. Every setter and `finalize` take the initializer value from that PTB, so only
its creator can call them.

Value constructors (*anyone*, pure):

- `blast_core::bps::new(value)` builds each rate; it aborts with
  `blast_core::errors::EInvalidBps` above 10,000.
- `blast_presale::blast_presale::vesting_terms(vesting_cliff_delay_ms, vesting_period_duration_ms, periods)` returns a
  `blast_presale::blast_presale::VestingTerms`.
- `blast_presale::blast_presale::recipient_share(recipient, bps)` or
  `blast_presale::blast_presale::vested_recipient_share(recipient, bps, terms)` build one share. Gather them with
  `MakeMoveVec` into two lists: token recipients and raise recipients.
- `blast_presale::blast_presale::open_eligibility(wallet_cap, max_participants, min_commitment)` or
  `blast_presale::blast_presale::allowlisted_eligibility(root, leaf_count)` build the eligibility policy.
- `blast_presale::blast_presale::uncapped_for_eligible(start_delay_ms)` or
  `blast_presale::blast_presale::uncapped_for_anyone(start_delay_ms, max_participants, min_commitment)` build an
  uncapped phase.
- The vault's starting LP-fee split is a `blast_core::fee_split::FeeSplit`: build each destination
  with `blast_core::fee_split::address_destination`, `blast_core::fee_split::owner_destination`,
  `blast_core::fee_split::auto_lp_destination`, `blast_core::fee_split::holder_rewards_destination`,
  or `blast_core::fee_split::burn_destination`, each route with `blast_core::fee_split::route`,
  gather the routes with `MakeMoveVec`, and call `blast_core::fee_split::new` (core guide).

Steps, type arguments `<Meme, Quote>` throughout:

1. Prepare the coin on the venue (*cap holder*: the `TreasuryCap<Meme>` holder):
   - Cetus: `blast_presale::cetus::prepare(package_version, venue_config, cetus_config, pools,
     treasury_cap, tick_spacing)`, with the `TreasuryCap` by mutable reference. It mints the coin's
     Cetus `PoolCreationCap` from the treasury cap, registers the `<Meme, Quote>` pair at
     `tick_spacing`, and stores the cap in `VenueConfig` under `blast_presale::cetus::CreationCapKey`
     with no path to remove it. It records the tick spacing and the fee rate Cetus sets for it as
     the pool tier (below). Cetus aborts if it has no fee tier for the tick spacing or refuses the
     pair (the Quote must be in Cetus's permission-pair allowlist at that tick spacing).
   - Bluefin: `blast_presale::bluefin::prepare(package_version, venue_config, treasury_cap,
     currency, tick_spacing, pool_fee_rate)`, with the `TreasuryCap` by immutable reference
     (proving the caller controls the coin) and `Currency<Meme>` read. Tick spacing must be
     1..=400 and the fee rate 1..=20,000 in Bluefin's fee unit
     (`blast_presale::errors::EInvalidTier`); the coin's symbol must be at most 32 bytes
     (`blast_presale::errors::ESymbolTooLong`). It records the pool tier (below) and needs no
     Bluefin objects.
   - Aftermath: `blast_presale::aftermath::prepare<Lp, Meme, Quote>(package_version, venue_config,
     treasury_cap, create_pool_cap, dao_fee_bps)`, with the `TreasuryCap` by immutable reference
     and the `CreatePoolCapV2` of a fresh Aftermath LP coin `Lp` by value. Beforehand, in its own
     transaction, publish that LP coin (one per sale, through Aftermath's own LP-coin flow); its
     publication yields the `CreatePoolCapV2`. `prepare` keeps the capability in `VenueConfig`
     under `blast_presale::aftermath::CreatePoolCapKey<Lp, Meme>` for the sale's migration and
     emits `blast_presale::aftermath::PoolCreationReserved` (`create_pool_cap_id`), typed
     `<Lp, Meme, Quote>`. `dao_fee_bps` (a `u16`) is the DAO fee the pool charges on every swap,
     deposit, and withdrawal and pays to the sale's vault, 1..=10,000 BPS
     (`blast_presale::errors::EInvalidDaoFee`); it is the sale's tier, recorded with tick spacing
     0. The pool's weights and fee are the module's constants (50/50, flatness 0, Aftermath's
     minimum 0.01% swap-in fee; see Migrating to Aftermath). `prepare` cannot check that the
     capability belongs to `Lp`; verify it before listing the sale.

   Each `prepare` returns a `blast_core::migration::VenueTicket<Meme, Quote>` sealed by the venue's
   witness. The pool tier belongs to the venue, not the sale: the `Presale` and `PresaleCreated`
   carry none. Every venue records a `blast_presale::venue_config::PoolTier` under
   `blast_presale::venue_config::PoolTierKey<Meme>` (each sale token has exactly one sale, so a
   coin can be prepared once) and emits `blast_presale::venue_config::PoolTierReserved<Meme, Quote,
   Venue>`, whose third type argument is `blast_presale::cetus::Venue`,
   `blast_presale::bluefin::Venue`, or `blast_presale::aftermath::Venue`.
2. `blast_presale::blast_presale::new(treasury_cap, package_version, venue_ticket,
   creation_policy, fee_policy)` takes the `TreasuryCap` by value and the ticket from step 1. In
   order it checks the package version and the create pause bit, redeems the ticket, checks that
   the `CreationPolicy` allows Quote and then the ticket's venue, that the sale coin differs from
   Quote, and that the treasury cap has minted nothing; snapshots Blast's current rates from the
   `FeePolicy`; and returns the `PresaleInitializer`.
3. Required setters, each taking the initializer by mutable reference and the `PackageVersion`:
   - `blast_presale::blast_presale::set_supply(initializer, package_version, token_supply, burnable)`.
   - `blast_presale::blast_presale::set_token_allocations(initializer, package_version,
     token_allocation_bps, liquidity_token_allocation_bps, recipient_allocations)`.
   - `blast_presale::blast_presale::set_raise(initializer, package_version, raise_target, raise_allocations)`.
   - `blast_presale::blast_presale::set_windows(initializer, package_version,
     commitment_duration_ms, liquidity_window_duration_ms)`.
   - `blast_presale::blast_presale::set_eligibility(initializer, package_version, eligibility)`.
   - `blast_presale::blast_presale::set_fee_split(initializer, package_version, fee_split)`: the
     vault's starting LP-fee split.
4. Optional setters:
   - `blast_presale::blast_presale::set_participant_vesting(initializer, package_version, vesting)`:
     each buyer's tokens vest from that buyer's claim. Without it, claims pay tokens out at once.
   - `blast_presale::blast_presale::set_uncapped_phase(initializer, package_version, phase)`: lifts
     wallet caps from the phase's start. Without it, caps hold for the whole window.
   - `blast_presale::blast_presale::set_hard_cap(initializer, package_version, start_delay_ms,
     closes_when_filled)`: holds the sale to its raise from that point (below). Without it, the
     sale overflows for its whole window.
   - `blast_presale::blast_presale::set_partner(initializer, package_version, creation_policy,
     partner, clock)`: names a `blast_partners::blast_partners::Partner` the `CreationPolicy`
     currently accepts. This is the only time a partner can be named.

   A setter called twice keeps its last value.
5. `blast_presale::blast_presale::finalize(initializer, package_version, registry, currency)`,
   with the shared `blast_presale::blast_presale::PresaleRegistry` mutable, first requires
   confirmed `Unregulated` currency status, then checks every setting together, mints the supply,
   consumes the `TreasuryCap`, and returns `(Presale<Meme, Quote>, PresaleCap)`. The Coin Registry
   supply becomes `Fixed`, or `BurnOnly` when `burnable` is true. Emits
   `blast_presale::blast_presale::PresaleCreated`.
6. Optional, Blast admin only (`FeeAdmin`): `blast_presale::blast_presale::set_protocol_fees` on the pending sale.
7. `blast_presale::blast_presale::share(presale, package_version, commitment_starts_at_ms, clock)`,
   same caller, fixes the windows and shares the sale. The start is
   `max(commitment_starts_at_ms, now)`, so a sale can be published ahead of its start. Emits
   `blast_presale::blast_presale::PresaleOpened`.
8. `TransferObjects([presale_cap], creator)`.

Settings:

| Setting | Meaning and rule |
| --- | --- |
| `token_supply` | Whole supply in atomic units, > 0. |
| `burnable` | `true`: supply becomes burn-only; `false`: fixed. |
| `token_allocation_bps` | Buyers' share of the supply, > 0. |
| `liquidity_token_allocation_bps` | Tokens seeded into the pool, > 0. |
| `recipient_allocations` | Up to 64 token recipients, distinct nonzero addresses, each > 0 BPS, optionally vested. Buyers + LP + Blast's token rate + recipients = exactly 10,000 BPS. |
| `participant_vesting` | Optional `VestingTerms` for every buyer's tokens. |
| `raise_target` | Quote the sale must raise, atomic units, > 0. |
| `raise_allocations` | Up to 64 raise recipients paid in Quote at migration, optionally vested. Their BPS plus Blast's raise rate must stay below 10,000; the LP keeps the rest. |
| `duration_ms` | Commitment window length, > 0; set with `commitment_duration_ms`. |
| `liquidity_window_ms` | Time after the window before anyone may cancel an unmigrated funded sale; at least 7 days. |
| `eligibility` | `EligibilityPolicy::Open` or `EligibilityPolicy::Allowlisted` (below). |
| uncapped phase | Optional `blast_presale::blast_presale::UncappedPhase` (below). |
| hard cap | Optional `starts_after_ms` and `closes_when_filled` (below). |
| `fee_split` | `blast_core::fee_split::FeeSplit`: up to 20 routes with distinct destinations (addresses, the vault's owner, auto-LP, holder rewards, burn), each positive, totalling exactly 10,000 BPS. The creator takes LP fees through the owner route, claimed with an owner proof, or by listing its own address. |
| tick spacing, fee rate, DAO fee | Pool tier, given to the venue's `prepare` and kept in `VenueConfig`. Cetus derives the fee rate from the tick spacing. |

A setting never set is zero (supply, raise, window lengths, token BPS), so `finalize` rejects it
with that setting's error. A missing eligibility policy or LP-fee split aborts with
`blast_presale::errors::EMissingSetting`.

Eligibility policies (`blast_presale::blast_presale::EligibilityPolicy`):

- `Open { wallet_cap, max_participants, min_commitment }`: every wallet has the same cap; at most
  `max_participants` distinct wallets (1..=65,536); each wallet's total must reach
  `min_commitment` (0 < min <= cap). `min_commitment × max_participants` must reach the raise
  (`blast_presale::errors::EUnreachableRaise`), so dust wallets cannot fill every slot and block the sale.
- `Allowlisted { root, leaf_count }`: a 32-byte Merkle root over leaves `(index, wallet,
  wallet_cap)`, 1..=65,536 leaves. Caps may be equal, tiered, or custom. Any positive commitment
  counts; there is no minimum.

Uncapped phase (`blast_presale::blast_presale::UncappedPhase`): it starts `starts_after_ms` into the window
(must be below `duration_ms`; zero means from the start) and lifts wallet caps until the end.
Whether the sale then overflows or stops at its raise is the hard cap's job.

- `uncapped_for_eligible`: only wallets the policy admits, with the policy's participant bound
  and, for an open policy, its minimum.
- `uncapped_for_anyone`: any wallet through `blast_presale::blast_presale::commit_uncapped`. `max_participants`
  must be at least the policy's bound (its `max_participants`, or the allowlist's `leaf_count`)
  and at most 65,536. `min_commitment` times the slots held to it must reach the raise: all slots
  under an open policy, only the slots beyond `leaf_count` under an allowlist.

Hard cap (`blast_presale::blast_presale::HardCap`): from `starts_after_ms` into the window (must be below
`duration_ms`, `blast_presale::errors::EInvalidHardCap`), a commitment takes only what is left of the raise and returns
the excess at once; when the raise is full, commitments abort with `blast_presale::errors::EPresaleFilled`. Before that
point the sale overflows. It does not lift wallet caps. Common shapes:

| Shape | Settings |
| --- | --- |
| Overflow for the whole window, pro-rata fill | No hard cap |
| First come, first served within wallet caps | Hard cap at `0` |
| First come, first served without caps | Uncapped phase and hard cap both at `0` |
| Capped overflow round, then a first-come uncapped round | Uncapped phase and hard cap at the same offset |

With `closes_when_filled`, anyone may settle the sale as soon as its raise is full under the hard
cap, without waiting for the window's end (see Settling). Without it, a full sale runs to its
end, so the pool can open at an announced time.

`finalize` aborts unless the LP's tokens and Quote give a seed price both CLMM venues can pool
(`blast_presale::errors::EUnseedablePrice`; see Economics).

#### Committing

Who may call: *anyone* the policy admits. The commitment is always credited to the transaction
sender, so a relayer cannot commit for someone else. Each commit returns a `Coin<Quote>`: the part
a hard cap could not accept, or a zero coin. It has no `drop`, so the PTB must transfer it (or
destroy a zero coin).

1. `coin = SplitCoins(source, [amount])`, where `source` is a `Coin<Quote>` the sender owns (the
   gas coin when Quote is SUI and the sender pays gas; under sponsored gas the gas coin is the
   sponsor's).
2. One of, with type arguments `<SaleToken, Quote>`:
   - `blast_presale::blast_presale::commit_open(presale, package_version, coin, clock)` under an open policy.
   - `blast_presale::blast_presale::commit_allowlisted(presale, package_version, coin, index,
     wallet_cap, proof, clock)` under an allowlist; `proof` is a `vector<vector<u8>>`. Also used
     by allowlisted wallets during an uncapped phase (the proof is still checked; the cap no
     longer limits).
   - `blast_presale::blast_presale::commit_uncapped(presale, package_version, coin, clock)` once a
     phase open to anyone has started.
3. `TransferObjects([returned_coin], sender)`.

Each commit emits `blast_presale::blast_presale::Committed`. Rules:

- The window is `start_ms <= now < end_ms`.
- A wallet's first commit takes a participant slot; later commits top it up by any positive
  amount. The minimum applies to the wallet's total after the commit, so the first commit must
  reach it. The commit that exactly fills a hard cap may be below the minimum.
- Before the uncapped phase, the wallet's total must stay within its cap. The cap a wallet first
  committed under is stored with its commitment; under an allowlist, later commits must present
  the same cap (`blast_presale::errors::EInvalidEligibilityProof`).
- Under an open policy, `commit_open` keeps working in either uncapped phase: caps are lifted,
  its minimum still applies, and an anyone-phase uses the phase's participant bound.

#### Allowlist proofs

The presale hashes leaves and verifies proofs with the core Merkle primitives
(`blast_core::merkle::leaf`, `blast_core::merkle::node`, `blast_core::merkle::verify`) under the
leaf domain `b"blast-presale-v1"`. Leaf digest, for the wallet at position `index` with cap
`wallet_cap`:

```
leaf = blake2b256( 0x00 || b"blast-presale-v1"            // the ASCII bytes
                   || bcs(index: u64)                  // 8 bytes, little-endian
                   || bcs(wallet: address)             // 32 bytes
                   || bcs(wallet_cap: u64) )           // 8 bytes, little-endian
node(left, right) = blake2b256( 0x01 || left || right )
```

The proof is positional: starting from the leaf digest with `i = index`, for each sibling in
order, `digest = node(digest, sibling)` when `i` is even, else `node(sibling, digest)`; then
`i = i / 2`. The result must equal the root. The proof must contain exactly
`ceil(log2(leaf_count))` siblings (zero for one leaf, where the root is the leaf itself), each 32
bytes, and `index < leaf_count`. The verifier takes each sibling as given, so the tree builder
picks one rule for an unpaired node at an odd-width level (for example, pairing it with itself)
and puts that sibling in the proof. The `wallet` in the leaf must be the transaction sender, and
`wallet_cap` must be positive.

#### Settling

Who may call: *anyone*. `blast_presale::blast_presale::settle(presale, package_version, clock)` while `Open`, once either:

- `now >= end_ms`; or
- the sale closes early: its hard cap has `closes_when_filled`, the hard cap is in force
  (`now >= start_ms + hard cap starts_after_ms`), and `total_commitments >= raise_target`. The
  sale can then take no more Quote.

If total commitments reach the raise the sale becomes `Funded` and emits
`blast_presale::blast_presale::PresaleFunded`; otherwise it becomes `Cancelled` and emits
`blast_presale::blast_presale::PresaleCancelled`. Closing early ends the window at the settle: the
stored `duration_ms` becomes the time the sale ran, so `end_ms` and the LP deadline count from the
close. `PresaleFunded` carries both. A sale without a hard cap never closes early.

Closing early and migrating can run in one PTB: `settle`, then the venue's `migrate`. Because
migration is permissionless, the wallet whose commitment fills the raise can also commit, settle,
migrate, and buy from the new pool in one transaction. The pool's seed price is the same either
way; creators who want a public start choose `closes_when_filled = false`.

#### Migrating

Every venue's `migrate` calls `blast_presale::blast_presale::migrate`, which checks the version,
the migrate pause bit, and that the sale is `Funded`; pays Blast its raise and token fees at the
`FeePolicy` destination (or, on a partnered sale, holds them for
`blast_presale::blast_presale::pay_protocol_fees_with_partner`); pays or vests each raise
recipient and each token recipient; marks the sale `Migrated`; emits
`blast_presale::blast_presale::PresaleMigrated`; and returns a sealed
`blast_core::migration::Migration<SaleToken, Quote>`. The hand-off holds the LP's tokens and Quote
and the vault's `blast_core::migration::VaultTerms`: origin = the sale's ID, the sale's
`FeeSplit`, Blast's LP-fee rates from the sale's snapshot (`lp_fee_meme_bps`, `lp_fee_quote_bps`),
the sale's partner, and migration residuals held for the owner. Only the stored venue's witness
can redeem it (`blast_core::errors::EWrongVenue` otherwise), and it cannot be dropped or stored,
so an unredeemed hand-off fails the whole transaction. Call the venue's `migrate`, never
`blast_presale::blast_presale::migrate` alone.

The venue then creates the pool, builds the vault with `blast_vault::vault::new` (which aborts
unless the `VaultRegistry` admits the venue), attaches the position with
`blast_vault::vault::share_with_position` (`blast_vault::errors::EZeroLiquidity` for a position
with no liquidity), and shares the vault. Whatever the pool did not take waits in the vault as the
owner's residuals. Nothing returns to the caller. Any venue failure rolls the whole transition
back and leaves the sale `Funded`.

#### Migrating to Cetus

Who may call: *anyone*, while `Funded`, until someone cancels. Usually one keeper PTB:

1. `blast_presale::blast_presale::settle(presale, package_version, clock)` if not yet settled.
2. `blast_presale::cetus::migrate<Meme, Quote, CoinA, CoinB>(sale, package_version, fee_policy,
   venue_config, cetus_config, pools, burn_manager, registry, vault_version, treasury, clock)`.
   `CoinA` and `CoinB` are the sale's two types in Cetus's canonical order: the order Cetus's own
   `is_right_order` check (in its `factory` module) accepts. Find it by dev-inspecting either
   order; the wrong order aborts with `blast_presale::errors::EInvalidCoinOrder`, and a pair that
   is not exactly the sale's two types aborts with `blast_presale::errors::EWrongCoinPair`. Shared
   objects: the presale (`sale`, mutable), `FeePolicy`, `VenueConfig` (read), Cetus `GlobalConfig`
   (read), Cetus `Pools` (mutable), the Cetus LP-burn `BurnManager` (mutable), `VaultRegistry`, the
   vault `PackageVersion`, and `Treasury`.
3. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(presale,
   package_version, fee_policy, partner)`.

The venue redeems the hand-off, creates the pool with the reserved `PoolCreationCap` at the tick
spacing `prepare` recorded, seeds a full-range position at the price the LP balances imply (it
never adopts an existing pool), burns the position through Cetus LP-burn for its fee-claiming
proof, and shares a new vault holding that proof and Cetus's leftover coins.

#### Migrating to Bluefin

Who may call: *anyone*, while `Funded`, until someone cancels.

1. `blast_presale::blast_presale::settle(presale, package_version, clock)` if not yet settled.
2. `creation_fee = SplitCoins(GasCoin, [amount])`, where `amount` is the fee amount (the `u64` in
   the `(bool, u64)` pair) that Bluefin's `get_pool_creation_fee_amount<SUI>` (its `config`
   module) returns at submission time; Bluefin rejects another amount.
3. `blast_presale::bluefin::migrate<Meme, Quote>(sale, package_version, fee_policy, venue_config,
   currency, quote_currency, bluefin_config, registry, vault_version, treasury, creation_fee,
   clock)`. `venue_config` is read for the tier `prepare` recorded. `currency` and
   `quote_currency` are the shared Coin Registry `Currency<Meme>` and `Currency<Quote>` (read for
   both symbols and decimals and the Quote's icon URL); the Bluefin `GlobalConfig` is mutable.
4. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The venue creates the pool `Pool<Meme, Quote>` (Meme is always coin A) named
`<Meme symbol>-<Quote symbol>` at the recorded tier, opens a full-range position aligned inward to
the tick spacing, adds the LP balances, moves the position and Bluefin's leftovers into a new
shared vault, and shares the pool.

#### Migrating to Aftermath

Who may call: *anyone*, while `Funded`, until someone cancels.

1. `blast_presale::blast_presale::settle(presale, package_version, clock)` if not yet settled.
2. `blast_presale::aftermath::migrate<Lp, Meme, Quote>(sale, package_version, fee_policy,
   venue_config, pool_registry, dao_fee_version, registry, vault_version, treasury, clock)`. `Lp`
   must be the LP coin whose capability `prepare` kept: the call first removes the capability under
   `CreatePoolCapKey<Lp, Meme>` from `VenueConfig` (mutable), which aborts in `sui::dynamic_field`
   for any other `Lp`. `pool_registry` is Aftermath's shared `PoolRegistry` (mutable);
   `dao_fee_version` is the DAO-fee package's shared `Version`. The module sorts the coins into
   Aftermath's order itself.
3. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The venue redeems the hand-off, creates the pool from all LP tokens and Quote (50/50 weights,
flatness 0, Aftermath's minimum 0.01% swap-in fee, which compounds into the LP, no other pool fees,
name "Blast Presale Pool"; no sale token circulates before the migration, so nobody can register
the sale's pool first), checks it holds every unit (`blast_presale::errors::EPoolMismatch`), builds
the vault, wraps the pool in a DAO-fee pool at the recorded `dao_fee_bps` whose fee recipient is
the vault's address (`blast_presale::errors::EDaoFeePoolMismatch` if Aftermath reports anything
else), emits `blast_presale::aftermath::DaoFeePoolCreated` (vault, base pool, DAO-fee pool, owner
cap, and LP coin IDs), attaches the DAO-fee pool's `OwnerCap` as the vault's position with the LP
coin's amount (the pool's whole liquidity) as its liquidity and no residuals, shares the vault,
shares the DAO-fee pool (the object traders use), and sends the LP coin to `0x0`, where nobody can
ever use it. Nothing in the package removes the owner cap, so the fee or its recipient cannot be
changed, and the liquidity is locked for good. If the `CreatePoolCapV2` belongs to a different LP
coin than `Lp`, or Aftermath retires the versions this package links to, migration aborts and the
sale becomes refundable at its LP deadline.

#### Paying a partnered sale's Blast fees

Who may call: *anyone*, once, after migration.
`blast_presale::blast_presale::pay_protocol_fees_with_partner(presale, package_version,
fee_policy, partner)` takes the Blast raise fee the migration held, pays the partner its cut
through `blast_partners::blast_partners::pay`, then pays Blast the rest of the raise fee and its
whole token fee at the `FeePolicy`'s current destination. Emits
`blast_partners::blast_partners::PartnerPaid` (when the cut is positive) and
`blast_presale::blast_presale::ProtocolFeesPaid`. The partner is paid as an owned coin at its
recipient address using `public_transfer`. Blast's LP fees on the sale's vault are held and paid
separately, by the vault (below).

#### Claiming tokens and refunds

Who may call: *anyone* may relay; payment always goes to `participant`.
`blast_presale::blast_presale::claim(presale, package_version, participant, clock)` while
`Migrated` or `Cancelled`. Batch many claims in one PTB. It removes the wallet's commitment record,
so each wallet claims once.

- `Migrated`: pays the wallet's pro-rata tokens and its share of the overflow refund.
- `Cancelled`: pays back the full commitment; no tokens.
- With participant vesting, the tokens go into a new shared, irrevocable schedule for the
  participant that starts at this claim; the Quote refund is always paid at once. A claim whose
  token amount is zero creates no schedule.

Emits `blast_presale::blast_presale::Claimed` with `tokens`, `quote_refund`, `remaining_participants`, and
`vesting_id`.

#### Claiming vested tokens

Vested raise shares (Quote) and token shares start at migration; vested participant tokens start
at the participant's claim. Each schedule is a shared `Vesting<T>` from the immutable
`blast_fun_vesting` package, with a fixed beneficiary and no cancellation authority. Find its ID
in the `vesting_id` field of `blast_presale::blast_presale::RaiseAllocated`, `blast_presale::blast_presale::RecipientAllocated`,
or `blast_presale::blast_presale::Claimed`.

- Claim: `blast_fun_linear_vesting::claim<T>(vesting, clock)`. *Anyone* may call; it transfers all
  newly vested value to the beneficiary as a coin and aborts with
  `blast_fun_linear_vesting::ENothingClaimable` when nothing new has vested.
- Vested amount at time `t`: zero before `start + cliff_ms`; the whole amount from
  `start + period_ms × periods`; otherwise `floor(total × floor((t − start) / period_ms) / periods)`.
  The cliff only gates: once it passes, every whole period since the start counts.
- `blast_fun_linear_vesting::close_irrevocable<T>(vesting)` deletes a drained schedule; anyone.

#### Cancelling an unlaunched sale and refunds

Who may call: *anyone*. `blast_presale::blast_presale::cancel_unlaunched(presale, package_version,
clock)` once `now >= end_ms + liquidity_window_ms` while `Funded`. The sale becomes `Cancelled`
and emits `blast_presale::blast_presale::PresaleCancelled`. Every wallet then claims a full refund
with `blast_presale::blast_presale::claim`. A sale nobody settled can be settled and cancelled in
one PTB after the LP deadline. All minted tokens stay locked in the cancelled sale forever.
`blast_presale::blast_presale::destroy_cap(presale, presale_cap)` (*cap holder*) then deletes the
`PresaleCap`; a migrated sale's cap cannot be destroyed.

#### Owner calls on the vault

The `PresaleCap` holder acts on its sale's vault with an owner proof:
`blast_presale::blast_presale::prove_owner(presale, package_version, presale_cap)` (*cap holder*)
returns a `blast_core::owner_proof::OwnerProof` naming the sale, after checking the cap
(`blast_presale::errors::EWrongPresaleCap` for another sale's cap). The proof has no abilities:
pass it in the same PTB to one vault call, which consumes it and aborts with
`blast_core::errors::EWrongOwner` when the vault belongs to another sale.

- Claim migration residuals and owner-route fees: `blast_vault::vault::claim_owner_balances(vault,
  proof, vault_version)` returns a `Coin<Meme>` and a `Coin<Quote>`; transfer both in the same PTB.
  It aborts with `blast_vault::errors::ENothingToClaim` when nothing has accrued.
- Change the fee split: `blast_vault::vault::schedule_fee_split(vault, proof, vault_version,
  proposed, clock)` with a new `blast_core::fee_split::FeeSplit`, ready after a fixed 48-hour
  notice; `blast_vault::vault::cancel_fee_split` cancels it, even once ready. The venue's
  settle-and-apply call (below) activates it.

#### Collecting LP fees

Who may call: *anyone*, as often as they like. Each collection takes the fees, then
`blast_vault::vault::split_fees` pays Blast its share of each asset (rounded up) to the
`Treasury`, or holds it for the partner on a partnered sale, and divides the rest over the vault's
fee split: address routes are paid as coins at once; owner, auto-LP, and holder-reward routes
accrue in the vault; the burn route's Meme is burned (sent to `0x0` under a fixed supply) and its
Quote kept. A collection of zero is valid and moves nothing. Shared objects only; nothing returns.

- Cetus: `blast_presale::cetus::collect_fees<Meme, Quote, CoinA, CoinB>(vault, package_version,
  vault_version, treasury, currency, cetus_config, burn_manager, pool)` where `currency` is the
  mutable `Currency<Meme>`, `burn_manager` is read, and `pool` is the vault's mutable
  `Pool<CoinA, CoinB>` (same coin order as migration; `blast_presale::errors::EWrongCoinPair` for
  other types, `blast_presale::errors::EPositionPoolMismatch` for another pool). It collects from
  the burned migration position.
- Bluefin: `blast_presale::bluefin::collect_fees<Meme, Quote>(vault, package_version,
  vault_version, treasury, currency, bluefin_config, pool, clock)` where `pool` is the vault's
  `Pool<Meme, Quote>` (`blast_presale::errors::EPositionPoolMismatch` otherwise).
- Aftermath: `blast_presale::aftermath::collect_fees<Meme, Quote>(vault, package_version,
  vault_version, treasury, currency, meme_fees, quote_fees)`. Aftermath pays the DAO fee of every
  swap, deposit, and withdrawal as a separate `Coin<Meme>` or `Coin<Quote>` sent to the vault's
  address, so the vault owns those coins. `meme_fees` and `quote_fees` are
  `vector<Receiving<Coin<Meme>>>` and `vector<Receiving<Coin<Quote>>>`: list the IDs of the coins
  the vault owns (query the vault address's owned objects) as PTB receiving inputs and gather each
  list with `MakeMoveVec`; either list may be empty. The call receives every listed coin into the
  vault, joins them, and splits the totals like any collection. A coin the vault does not own
  aborts in `sui::transfer`; a coin left unlisted waits for a later call. A vault of another venue
  aborts with `blast_vault::errors::EWrongVenue`.

Each nonzero collection emits `blast_vault_events::FeesCollected`. Neither CLMM venue collects
venue incentive rewards. Presale venues do not add auto-LP or buy back yet: auto-LP Meme and Quote
and the burn route's Quote accrue in the vault, and no presale call spends them, until shared
venues that compound and buy back ship (ADR 0137, step 5).

On a partnered sale's vault, follow with `blast_vault::vault::pay_protocol_fees_with_partner(vault,
vault_version, treasury, partner)`: *anyone*; it pays the partner its cut of each held asset and
the `Treasury` the rest. Holding nothing is valid and moves nothing, so it can follow every
collection.

Applying a ready fee split (*anyone*, once the owner's proposal is ready):

- Cetus and Bluefin: `blast_presale::cetus::settle_and_apply_fee_split` (`<Meme, Quote, CoinA,
  CoinB>`, the `collect_fees` objects plus `Clock`) and
  `blast_presale::bluefin::settle_and_apply_fee_split` (`<Meme, Quote>`, the `collect_fees`
  objects). Each checks the proposal is ready (`blast_vault::vault::assert_fee_split_ready`),
  collects every position fee under the current split, then activates the stored split with
  `blast_vault::vault::apply_fee_split`, so each fee follows the split it accrued under. It takes
  no split of its own.
- Aftermath: `blast_presale::aftermath::apply_fee_split(vault, package_version, vault_version,
  clock)` checks readiness and activates the stored split. Aftermath sends DAO-fee coins separately
  to the vault address, and a collection receives only its listed coins, so those coins follow the
  split applied **when received**, including coins sent before activation but received afterward.
  This is collection-time accounting rather than accrual-time allocation; indexers must expose
  that boundary.

Holder-reward rounds funded by the holder-reward route, Blast's per-vault LP-fee share changes,
and buybacks are the vault's own calls (vault guide).

#### Blast admin operations

Integrators cannot call these; they explain state changes. Each takes the
`blast_acl::AdminWitness` of the role listed in "Objects and authority" (*Blast admin*).

| Call | Effect |
| --- | --- |
| `fee_policy::schedule_fees` | Rates new sales snapshot. Raise and token rates at most 1,000 BPS each; each LP-fee rate at most 3,000 (`blast_presale::errors::EInvalidFees`). Compiled maximums: raising one needs a package upgrade. Anyone applies it once ready with `fee_policy::apply_fees`, which emits `delayed::DelayedApplied<fee_policy::FeesKey, fee_policy::ProtocolFees>`. |
| `fee_policy::schedule_destination` | Redirects every later Blast raise and token payout, existing sales included; rejects `0x0` (`blast_presale::errors::EInvalidDestination`). Anyone applies it with `fee_policy::apply_destination`, which emits `delayed::DelayedApplied<fee_policy::DestinationKey, address>`. Blast's LP fees go to the core `Treasury` instead (core guide). |
| `blast_presale::blast_presale::set_protocol_fees` | Takes the live `FeePolicy`; each proposed rate must be at or below its applied rate (`blast_presale::errors::EAboveFeePolicy`). Replaces one sale's four rates in its creation PTB before `share` (`Pending`), where a rate may rise, or while `Open` and before `start_ms`, where each rate may only stay or fall (`blast_presale::errors::EProtocolFeesIncreased` otherwise). Emits `blast_presale::blast_presale::ProtocolFeesChanged`. |
| `creation_policy::set_quote_allowed` | Allows or disallows a Quote type for later sales. Emits `creation_policy::QuoteSet`. |
| `creation_policy::schedule_venue` | Schedules admission of a venue witness; rejects primitives, vectors, and `0x1`/`0x2` types (`blast_presale::errors::EInvalidVenue`). Anyone applies it once ready with `creation_policy::apply_venue`, which emits `delayed_set::SetApplied<creation_policy::VenueKey, TypeName>`. `creation_policy::remove_venue` removes immediately (emitting `delayed_set::MemberRemoved` for an admitted venue) and cancels a pending admission. |
| `creation_policy::add_partner` | Lets new sales name a partner at once (also cancels a pending removal). Emits `creation_policy::PartnerAdded`. |
| `creation_policy::remove_partner` | New sales may still name the partner for `blast_partners::blast_partners::delay_ms` (7 days). Sales that already name it keep paying it. Emits `creation_policy::PartnerRemoved`. |
| `blast_presale::package_admin::schedule_upgrade`, `blast_presale::package_admin::authorize_upgrade`, `blast_presale::package_admin::commit_upgrade_and_advance` | Compatible upgrades with atomic operational-version cutover (below). |

`blast_presale::package_admin::wrap` consumes the publication Publication and never-upgraded matching cap once. Each upgrade increments both compiled generation constants and commits/advances in one PTB; old bytecode then rejects the advanced version. Existing dependency-only deployments require a fresh publication to adopt this design.

### Delayed administration

Each treasury, fee or upgrade operation owns its applied notice period. A delayed-value
schedule accepts a proposed value and **next** `delay_ms`, but its execution deadline is
`ready_at_ms = now + currently_applied_delay_ms`. Passing zero cannot shorten the
current wait. The proposed value and next notice become active together only after
explicit application with the current version and canonical Clock. A value-only
change supplies the applied delay; a delay-only change supplies the applied value.
Different operations, including operations in the same package, can use different delays.

Rescheduling replaces the proposal and restarts the full currently applied notice.
`CancelAdmin` can cancel even a ready proposal, preserving the applied value and delay.
Ordinary value applications need no role; code authorization and immutability execution
still need UpgradeAdmin. Overflow is rejected at scheduling and actual application;
later schedules check their own timestamp addition too. A value proposal that changes neither
value nor notice, or a notice-only proposal equal to the applied notice, aborts with code 20
(`EUnchanged`) from Blast admin's `delayed` module (`delayed_action` for the upgrade notice,
`delayed_set` for the admission notice).
Read the live notice before relying on a cancellation window.

Each delayed field is a Blast admin delayed value: a `delayed::Delayed` setting, the
`delayed_action::DelayedAction` upgrade slot, or the `delayed_set::DelayedSet` of venues. The
module of each type emits every schedule, cancel and apply event; the presale package emits none
of its own. The events are generic in the operation's key and value type and carry `owner` (the
ID of the object that stores the field) and `key`. A value schedule emits
`delayed::DelayedScheduled` (after `delayed::DelayedCancelled` for a replaced proposal), a cancel
emits `delayed::DelayedCancelled`, and an application emits `delayed::DelayedApplied` with the
previous and new value and the applied notice. Creating a setting emits
`delayed::DelayedCreated`, the upgrade slot `delayed_action::ActionCreated`, and the admission set
`delayed_set::SetCreated`. Upgrade actions and their notice changes emit
`delayed_action::ActionScheduled`, `delayed_action::ActionCancelled` and
`delayed_action::ActionApplied`, whose `change` is `Action(...)` or `Delay` (a notice change).
Venue admissions and their notice changes emit `delayed_set::SetScheduled`,
`delayed_set::SetCancelled` and `delayed_set::SetApplied`, whose `change` is `Admission(...)` or
`Delay`. Their `delay_ms` is the proposed next notice for a notice change and the applied notice
for an action or admission. `delayed_set::MemberRemoved` records an immediate venue removal.

| Operation | Object and field | Key | Value or action type |
| --- | --- | --- | --- |
| Blast's rates | `FeePolicy.fees` | `fee_policy::FeesKey` | `fee_policy::ProtocolFees` |
| Blast's payee | `FeePolicy.destination` | `fee_policy::DestinationKey` | `address` |
| Upgrades and immutability | `PackageAdmin.upgrade` | `blast_presale::package_admin::UpgradeKey` | `blast_presale::package_admin::UpgradeAction` |
| Venue admissions | `CreationPolicy.venues` | `creation_policy::VenueKey` | `TypeName` |

A vault's fee split and Blast's per-vault LP-fee share are the vault's own delayed fields, each
with a fixed 48-hour notice (vault guide).

`blast_presale::package_admin::schedule_upgrade` takes only the digest in addition to
its state, authority and Clock inputs, and uses the stored upgrade notice.
`blast_presale::package_admin::authorize_upgrade` consumes only a ready matching digest;
its ticket must feed the native upgrade command and its receipt the ordinary finalizer.
`blast_presale::package_admin::schedule_make_immutable` and
`blast_presale::package_admin::make_immutable` govern destruction of upgrade authority.
These action schedules accept no delay argument and their execution preserves the notice.
`blast_presale::package_admin::schedule_upgrade_delay` uses UpgradeAdmin to propose only the
notice period, replacing any pending action. Anyone applies it with
`blast_presale::package_admin::apply_upgrade_delay`; it cannot authorize code or immutability.
`blast_presale::package_admin::cancel_upgrade_action` cancels any of these proposals.

Publication-owned policy singletons start with zero notice for ordinary
role-authorized setup; package upgrade custody starts at 172,800,000 ms (48 hours), so
no upgrade or immutability action can run without notice, even during setup. Configure
and apply each other operation's intended notice, and drain or cancel all earlier setup
proposals before release. `blast_presale::package_admin::unpause` enforces the minimum: it
aborts unless the fee destination, fee rates, venue set and upgrade slot each have a nonzero
applied notice, no pending proposal that would set one to zero, and no pending venue admission.
Raising a notice never changes previously scheduled deadlines or next delays.
Pausing and upgrades cannot reset notices. This source requires a fresh stack.

Venue admissions share one applied notice across witness types, held in the
`delayed_set::DelayedSet` `CreationPolicy.venues`; a fresh type cannot reopen setup.
`creation_policy::schedule_venue` accepts only the witness type in addition to its state,
authority and Clock inputs. It snapshots the applied notice and deadline; application only admits
that witness and preserves the live notice. `creation_policy::schedule_venue_delay` proposes a new
notice under AdapterAdmin; anyone calls `creation_policy::apply_venue_delay`, and CancelAdmin uses
`creation_policy::cancel_venue_delay`. Existing admission deadlines remain fixed; settle or cancel
all zero-notice admissions before completing setup. Immediate venue removal cancels that type's
pending admission and preserves the applied notice. Scheduling an admitted venue, or removing one
that is neither admitted nor pending, aborts with code 20 from `delayed_set`.

### Emergency pause

A `PauseAdmin` calls `blast_presale_package::pause` to set selected bits on the shared
package version. Only `UnpauseAdmin` may clear bits, with `blast_presale::package_admin::unpause`,
which takes the shared PackageAdmin, PackageVersion, FeePolicy and CreationPolicy and first checks
that every policy notice is guarded (see above). Bits: create is 1, commit is 2, migrate is 4.
Pauses never expire; a paused call aborts with `blast_presale::errors::EPaused`.
`blast_presale::blast_presale::new` and `blast_presale::blast_presale::share` check the create bit,
all three commitment paths the commit bit, and `blast_presale::blast_presale::migrate` (so every
venue's migration) the migrate bit. Settlement, claims, refunds, `cancel_unlaunched`, partner
payouts, owner proofs, and fee collections stay open.

`blast_presale::blast_presale::set_protocol_fees` remains immediate before the
sale starts, but takes the live `FeePolicy`; every rate must be at or below
its applied rates. Scheduled increases cannot authorize larger sale overrides.
Once a sale is shared it is public, so an override there may only keep or lower
each of its four rates; only the creation PTB may raise one.
AdapterAdmin may immediately remove a venue with `creation_policy::remove_venue`.
Genesis treasury is configured before publication, never defaulted to the publisher.

### Economics

Publication defaults follow the [Blast visual map](https://map.blast.fun/#fees): 200 BPS (2%) of the successful raise target, 100 BPS (1%) of total Meme supply, and 1,500 BPS (15%) of each collected LP-fee asset. Administrators can change the policy; sales snapshot their rates. Changing source defaults does not update an existing policy, sale or vault.

All amounts are atomic units. All rates are BPS out of 10,000. `floor` rounds down.

#### Largest-remainder apportionment

Supply, raise, and every LP-fee split use one method (`blast_core::bps::apportion`). For shares
`s_i` summing to 10,000 and a total `X`: each share gets `floor(X × s_i / 10,000)`; the leftover
units (fewer than the number of shares) go one each to the shares with the largest remainder
`(X × s_i) mod 10,000`; ties go to the earlier share. Every unit lands in exactly one share.

- Supply, at creation, in order: buyers (`token_allocation_bps`), LP, Blast (`token_bps`), then
  token recipients in list order. Buyers, LP, and every recipient must get > 0
  (`blast_presale::errors::EInvalidTokenAllocation`); Blast may get 0.
- Raise, at creation, in order: raise recipients, Blast (`raise_bps`), then the LP with
  `10,000 − recipients − Blast`. Every recipient and the LP must get > 0
  (`blast_presale::errors::EInvalidRaiseAllocation`).
- These amounts are fixed at creation, except that a per-sale rate change before the start
  replaces Blast's amounts (below). Migration pays them from exactly `raise_target`; the LP
  Quote is `raise_target − Blast's Quote − raise recipients' Quote`.

#### Fill rate, claims, and dust

Let `T` be total commitments, `R` the raise target, `A` the buyers' token allocation, and `c` one
wallet's commitment. A migrated sale requires `T >= R`. The common fill rate is `R / T`.

- Tokens: `floor(A × c / T)`.
- Overflow refund: `floor((T − R) × c / T)`.
- Cancelled sale: refund `floor(T × c / T) = c`; no tokens.
- The last wallet to claim, whichever it is, takes everything left of the tokens and Quote
  instead, so no rounding dust is stranded. Its extra is under one atomic unit per other
  claimant, per asset.
- Buyers together pay `R` for `A` tokens: the presale price is `R / A` Quote per atomic token.
  The pool opens at `LP Quote / LP tokens`.

Worked example: supply 20,001 at 5,000 / 1,000 / 0 / 2,500 / 1,500 BPS (buyers, LP, Blast,
recipient A, recipient B) apportions to 10,001 / 2,000 / 0 / 5,000 / 3,000 (the buyers' 0.5
remainder is the largest). Raise 1,000; Alice commits 1,000 and Bob 3,000, so `T = 4,000`. Alice
claims first: `floor(10,001 × 1,000 / 4,000) = 2,500` tokens and `floor(3,000 × 1,000 / 4,000) =
750` Quote. Bob claims last and takes the rest: 7,501 tokens and 2,250 Quote.

When the raise fills under a hard cap, `T` equals `R` and every refund is zero. If the sale
already overflowed before its hard cap started, the hard cap accepts nothing (`blast_presale::errors::EPresaleFilled`)
and the earlier overflow fills pro rata as usual.

#### Blast's fees

Blast takes three fees, all from the sale's snapshot (`Presale.protocol_fees`), copied from
`FeePolicy` at creation. Later `fee_policy::schedule_fees` calls never touch existing sales. Nothing is
charged at creation, on commitment, on refund, or when a sale does not migrate.

- Raise fee: Blast's Quote, apportioned with the raise at creation, paid at migration to
  `FeePolicy.destination` as it is when paid. Overflow refunds are never charged.
- Token fee: Blast's tokens, apportioned with the supply at creation, paid at migration to the
  same destination.
- LP fees: migration seals the sale's `lp_fee_meme_bps` and `lp_fee_quote_bps` into the vault's
  terms. At each collection the vault takes `ceil(gross × bps / 10,000)` of each asset at its
  current share and pays it to the core `Treasury`. Blast can change one vault's share only
  through the vault's own delayed call, `blast_vault::vault::schedule_protocol_bps` (core
  `FeeAdmin`, fixed 48-hour notice, at most 3,000 BPS per asset; vault guide).

Per-sale changes before the start (`blast_presale::blast_presale::set_protocol_fees`): a rate may rise
only in the creation PTB; on a shared sale each rate may only stay or fall. A changed raise rate
becomes `floor(R × raise_bps / 10,000)` and takes from or gives to the LP's Quote; a changed token
rate becomes `floor(supply × token_bps / 10,000)` and takes from or gives to the buyers'
allocation `A`. A rate equal to the sale's current one keeps its current amount (the creation
amount unless an earlier change replaced it). Recipients keep their amounts. The
new amounts must leave the LP some Quote and the buyers some tokens, and the LP must still seed a
poolable price.

#### Partners

A sale may name one `blast_partners::blast_partners::Partner`, named on the initializer and fixed
at `finalize`. The partner earns a cut of Blast's raise fee and, through the sale's vault, of
Blast's LP fees, never of Blast's token fee. The cut is `floor(fee × share_bps / 10,000)` using the
partner's share applied when paid (at most 8,000 BPS; a change Blast proposes can be applied by
anyone 7 days later). Blast keeps the rest. On a partnered sale, migration holds Blast's raise fee
and tokens in the sale until `blast_presale::blast_presale::pay_protocol_fees_with_partner` runs;
the vault inherits the partner and holds Blast's LP fees until
`blast_vault::vault::pay_protocol_fees_with_partner` runs.

#### LP-fee split and residuals

After Blast's LP fees, the rest of each asset is apportioned by largest remainder over the vault's
fee-split routes, in route order (the sale's `fee_split` until the owner changes it). Address
routes are paid as coins in the same transaction; owner, auto-LP, and holder-reward routes accrue
in the vault; the burn route burns its Meme and keeps its Quote. On presale vaults, auto-LP
balances and burn Quote currently only accrue (see Collecting LP fees). Migration residuals,
whatever Cetus or Bluefin did not take when seeding, wait in the vault for the owner, who claims
them with `blast_vault::vault::claim_owner_balances`; Aftermath leaves none. The vault guide has
the details.

#### Seed price bound

Creation (and any per-sale rate change) aborts with `blast_presale::errors::EUnseedablePrice` unless the LP's Quote per
LP token, in atomic units, lies inside both CLMM venues' price range with a margin: roughly 2^-62 to
2^62 (about 2.2e-19 to 4.6e18). A huge raise against a tiny LP-token allocation, or the reverse,
fails this check. The CLMM seed's opening sqrt price is `floor(sqrt(coin_b / coin_a) × 2^64)`
from the atomic amounts; display decimals never enter it.

### Time rules

All times are Unix milliseconds from `Clock`.

- `start_ms = max(requested start, time of share)`; `end_ms = start_ms + duration_ms`; LP deadline
  `= end_ms + liquidity_window_ms`; uncapped phase from `start_ms + starts_after_ms`, or `end_ms`
  when the sale has none; hard cap from `start_ms + starts_after_ms`. `share` aborts with
  `blast_presale::errors::EInvalidWindow` if these overflow u64. An early close sets `end_ms` to the settle time, which
  moves the LP deadline forward too.
- Commits: allowed for `start_ms <= now < end_ms`. Before the start: `blast_presale::errors::EPresaleNotStarted`. At or
  after the end: `blast_presale::errors::EPresaleEnded`.
- Caps lift at `now >= uncapped start`.
- `blast_presale::blast_presale::set_protocol_fees`: in the creation PTB before `share`, or after it while
  `now < start_ms`, when it may only lower rates. A sale shared with a start in the past can be
  repriced only in its creation PTB. After the start, `blast_presale::errors::EPresaleStarted` precedes the rate checks.
- `blast_presale::blast_presale::settle`: from `now >= end_ms`, at any later time, or earlier once the sale can close
  early.
- Migration: any time while `Funded`, including after the LP deadline, until someone cancels.
- `blast_presale::blast_presale::cancel_unlaunched`: from `now >= LP deadline`. The 7-day minimum means a funded
  sale stays migratable for at least a week after its end.
- Vesting starts at migration for recipients and at each claim for participants.
- `blast_presale::blast_presale::set_partner` needs `now < accepted_until_ms` for that partner.
- Hard cap: commitments are held to the raise from `now >= hard cap start`.
- Vault fee-split and Blast-share changes wait a fixed 48 hours; collections have no deadline or
  cooldown (vault guide).

### Reading state

- Find a coin's presale without an indexer: its object ID is derived from the shared
  `blast_presale::blast_presale::PresaleRegistry` and the key
  `blast_presale::blast_presale::PresaleKey<SaleToken>`, a field-less struct whose BCS is the single
  byte `0x00` (Move gives it a `dummy_field: bool`): `0x2::dynamic_field::hash_type_and_key(registry_id,
  0x2::derived_object::DerivedObjectKey<PresaleKey<SaleToken>>, [0])`, with types named by original
  package IDs. A coin has at most one presale.

The package exposes no public read functions on its shared objects (the initializer's
`blast_presale::blast_presale::venue` is the only getter). Read object fields over RPC (object
content and dynamic fields), and use events for history.

`Presale<SaleToken, Quote>` fields:

- Lifecycle and timing: `lifecycle`, `start_ms` (zero until shared), `duration_ms` (the time the
  sale ran, once it closed early), `liquidity_window_ms`, `uncapped` (with `starts_after_ms`,
  `access`), `hard_cap` (with `starts_after_ms`, `closes_when_filled`).
- Raise progress: `raise_target`, `total_commitments`, `participants` (wallets that have
  committed and not yet claimed), `quote` (Quote held).
- Terms: `eligibility`, `token_allocation` (buyers' tokens), `participant_vesting`,
  `recipient_payouts` and `raise_payouts` (each recipient's exact amount and vesting),
  `fee_split` (the vault's starting `FeeSplit`), `venue` (the type name, with original package IDs,
  of `blast_presale::cetus::Venue`, `blast_presale::bluefin::Venue`,
  `blast_presale::aftermath::Venue`, or a vendor venue's witness).
- Blast: `protocol_fees` (the snapshot), `protocol_quote`, `protocol_tokens`, `partner_id`,
  `unpaid_protocol_quote` (`some` only between a partnered migration and its pay call).
- Custody balances: `sale_tokens`, `liquidity_tokens`, `recipient_tokens`.
- `presale_cap_id`: the ID of the sale's `PresaleCap`.

One wallet's commitment is a dynamic field on the presale's ID: name type
`blast_presale::blast_presale::CommitmentKey` (a positional struct wrapping the wallet address; BCS is the
32-byte address), value `blast_presale::blast_presale::Commitment` with `quote` and `wallet_cap`. The field is
absent before the first commit and after the claim.

Common answers:

- Is it open? `lifecycle == Open` and `start_ms <= now < start_ms + duration_ms`.
- Fill rate? `raise_target / total_commitments` once `total_commitments >= raise_target`.
- Has a wallet claimed? After `Migrated`/`Cancelled`, its commitment field is gone (and a
  `blast_presale::blast_presale::Claimed` names it).
- Preview a claim: apply the formulas in Economics to `token_allocation`, `total_commitments`,
  `raise_target`, and the wallet's `quote`; the last claimant gets the remainder.
- Which vault? The `blast_vault_events::VaultCreated` whose `terms` has the sale's ID as its
  `origin`, emitted in the migration transaction; on Aftermath also
  `blast_presale::aftermath::DaoFeePoolCreated`'s `vault_id`.

Other objects:

Delayed policy fields are Blast admin `delayed::Delayed` values. A `Delayed<K, T>` contains `owner` (the ID of
the object that stores it), `key`, the applied `value`, applied `delay_ms`, and an optional `pending`
proposal with the proposed `value`, next `delay_ms`, and `ready_at_ms` (Unix milliseconds). Read the applied value even after a
pending proposal becomes ready; only a successful apply call changes it. Each `Bps` is a
positional struct wrapping one u64.

- `FeePolicy`: `destination` is `Delayed<DestinationKey, address>`, so `destination.value` is the
  current payee. `fees` is `Delayed<FeesKey, ProtocolFees>`; `fees.value` holds the applied `raise_bps`, `token_bps`,
  `lp_fee_meme_bps` and `lp_fee_quote_bps`, each a `Bps`.
- `CreationPolicy`: `allowed_quotes` (a set of type names with original package IDs) and
  `venues`, a `DelayedSet<VenueKey, TypeName>`. Its `members` holds the admitted venue type names
  (original package IDs), `delay_ms` the applied admission notice, `admissions` maps each pending
  type name to its snapshotted `delay_ms` and `ready_at_ms`, and `pending_delay` holds a proposed
  next notice. An admission becomes active only when applied into `members`, which preserves the
  applied notice. Accepted partners are dynamic fields keyed by `creation_policy::PartnerKey` (the
  partner's ID) whose `u64` value is the time the partner stops being accepted (the maximum u64
  while accepted).
- `VenueConfig`: a coin's tier is the `blast_presale::venue_config::PoolTier` (`tick_spacing`,
  `pool_fee_rate`) in the dynamic field keyed by `PoolTierKey<Meme>`; a Cetus coin's
  `PoolCreationCap` is the dynamic object field keyed by `blast_presale::cetus::CreationCapKey<Meme>`;
  an Aftermath coin's `CreatePoolCapV2` is the dynamic object field keyed by
  `blast_presale::aftermath::CreatePoolCapKey<Lp, Meme>` until its migration removes it.
- The sale's `Vault` (terms, fee split, Blast's share, balances, positions): vault guide. On
  Aftermath, the vault's pending DAO fees are the coins owned by the vault's address.
- `Vesting<T>`: `balance`, `beneficiary`, `start_ms`, `cliff_ms`, `period_ms`, `periods`,
  `released`.

### Events

Sale events carry the type arguments `<SaleToken, Quote>`. Filter by the full generic type or by
the emitting module. Payloads are emitted directly (no envelope).

| Flow | Event | Indexer use |
| --- | --- | --- |
| Prepare | `blast_presale::venue_config::PoolTierReserved`, then on Aftermath `blast_presale::aftermath::PoolCreationReserved` | The venue's pool tier (`tick_spacing`, `pool_fee_rate`: on Cetus and Bluefin the swap fee in millionths, on Aftermath 0 and the DAO fee in BPS), typed `<Meme, Quote, Venue>` with the venue's witness; on Aftermath the kept `create_pool_cap_id`, typed `<Lp, Meme, Quote>`. Cetus emits its own pair-registration events. |
| Create | `blast_presale::blast_presale::PresaleCreated` | All terms: supply split (BPS), recipients and vesting, raise split (BPS), window lengths, eligibility, uncapped phase, hard cap, `venue`, `fee_split`, Blast's snapshot rates and amounts, `treasury_cap_id`, `presale_cap_id`. |
| Share | `blast_presale::blast_presale::PresaleOpened` | `start_ms`, scheduled `end_ms` and `liquidity_deadline_ms`, `uncapped_from_ms`, `hard_cap_from_ms` (`none` without a hard cap), `partner_id`. |
| Per-sale rates | `blast_presale::blast_presale::ProtocolFeesChanged` | New rates, Blast amounts, and new buyer `token_allocation`. |
| Commit | `blast_presale::blast_presale::Committed` | `quote` accepted, `wallet_commitment` (new total), `total_commitments`, `participants`. It has no wallet field: the wallet is the transaction sender. |
| Settle | `blast_presale::blast_presale::PresaleFunded` / `blast_presale::blast_presale::PresaleCancelled` | Funded: `accepted_quote`, `refundable_quote`, `token_allocation`, and the actual `end_ms` and `liquidity_deadline_ms`, earlier than `PresaleOpened`'s after an early close. Cancelled: total refundable. |
| Migrate | `blast_presale::blast_presale::ProtocolFeesPaid` (unpartnered), `blast_presale::blast_presale::RaiseAllocated` (per raise recipient), `blast_presale::blast_presale::RecipientAllocated` (per token recipient), `blast_presale::blast_presale::PresaleMigrated`, then on Aftermath `blast_presale::aftermath::DaoFeePoolCreated`, then `blast_vault_events::VaultCreated` | Payouts with `vesting_id`; `venue` and LP amounts; vault, pool, position, liquidity, sealed terms, and residuals. The vault event's third type argument is the venue witness. On Aftermath the vault's `pool_id` is the base pool, `position_id` the DAO-fee pool's owner cap, and the DAO-fee event adds the shared DAO-fee pool, owner cap, and LP coin (owned by `0x0`) IDs. |
| Partner pay | `blast_partners::blast_partners::PartnerPaid`, `blast_presale::blast_presale::ProtocolFeesPaid` | `partner_quote` is the partner's cut. |
| Claim | `blast_presale::blast_presale::Claimed` | `tokens`, `quote_refund`, `remaining_participants`, `vesting_id`. |
| Collect | `blast_vault_events::FeesCollected` | Gross amounts, Blast's cut, each route's amounts in route order. |
| Apply split | `delayed::DelayedApplied` keyed by `blast_vault::vault::FeeSplitKey` | The previous and new split. |
| Vesting | `VestingCreated`, `VestingClaimed` (from `blast_fun_vesting`) | Schedule terms and releases. |

Owner claims, partner LP payouts, and holder-reward rounds emit the vault's events (vault guide).
Admin events are listed in "Blast admin operations" and "Delayed administration".

### Aborts

Errors are Move clever errors: the abort names the module and constant, and the message explains
it. Common ones by flow (module `blast_presale` unless named):

- Any call: `blast_admin::operational_version` aborts for a stale package ID (call the current
  presale or vault package); `blast_presale::errors::EPaused` while the call's pause bit is set.
- Prepare: `blast_presale::errors::EInvalidTier`; `blast_presale::errors::ESymbolTooLong`;
  `blast_presale::errors::EInvalidDaoFee` (1..=10,000 BPS); Cetus's own aborts for an
  unregistered tick spacing or refused pair.
- Start (`new`): `blast_presale::errors::EQuoteNotAllowed` / `blast_presale::errors::EVenueNotAllowed`
  (ask Blast to list it); `blast_presale::errors::EInvalidAssetPair` (sale coin equals Quote);
  `blast_presale::errors::EInitialSupplyNotZero`.
- Value constructors: `blast_core::errors::EInvalidBps`; `blast_presale::errors::EInvalidEligibilityPolicy`,
  `blast_presale::errors::EInvalidUncappedPhase`, `blast_presale::errors::EInvalidVestingTerms`;
  `blast_core::errors::EInvalidRoute` and `blast_core::errors::EInvalidFeeSplit` from the fee-split
  builders (core guide).
- Finalize: `blast_presale::errors::ESaleTokenNotUnregulated` (regulated or unknown legacy currency; use a new
  Coin Registry currency created without regulation); `blast_presale::errors::EMissingSetting` (no eligibility policy or LP-fee split); `blast_presale::errors::EInvalidRaiseTarget`
  (raise unset or zero); `blast_presale::errors::EInvalidTokenAllocation` (BPS not exactly 10,000 with Blast's token rate, duplicate or zero
  recipient, more than 64, or a zero apportioned amount); `blast_presale::errors::EInvalidRaiseAllocation` (no LP share
  left after Blast, duplicates, zero amounts); `blast_presale::errors::EInvalidWindow` (zero duration or LP window under
  7 days); `blast_presale::errors::EUnreachableRaise` (minimum × slots below raise); `blast_presale::errors::EInvalidEligibilityPolicy`;
  `blast_presale::errors::EInvalidUncappedPhase`; `blast_presale::errors::EInvalidHardCap` (hard cap starts at or after the window's end);
  `blast_presale::errors::EInvalidVestingTerms`; `blast_presale::errors::EUnseedablePrice`. A PTB
  that leaves the `VenueTicket` or the `PresaleInitializer` unconsumed fails at its end with Sui's
  unused-value error, not a Move abort.
- Partner: `blast_presale::errors::EPartnerNotAccepted`.
- Share: `blast_presale::errors::EInvalidLifecycle` (already shared); `blast_presale::errors::EInvalidWindow`.
- Commit: `blast_presale::errors::EPresaleNotStarted`, `blast_presale::errors::EPresaleEnded` (check the window); `blast_presale::errors::EZeroCommitment`;
  `blast_presale::errors::EWrongEligibilityPolicy` (wrong commit function for the policy); `blast_presale::errors::EInvalidEligibilityProof`
  (wrong index, cap, proof, sender, or a different cap than the wallet's first commit);
  `blast_presale::errors::EWalletCapExceeded` (lower the amount, or wait for the uncapped phase);
  `blast_presale::errors::EBelowMinimumCommitment` (first commit must reach the minimum); `blast_presale::errors::EParticipantCapacityReached`;
  `blast_presale::errors::EUncappedPhaseNotOpen` (no anyone-phase, or not started); `blast_presale::errors::EPresaleFilled` (hard cap reached);
  `blast_presale::errors::ETotalCommitmentOverflow`.
- Settle: `blast_presale::errors::EPresaleNotEnded` (the window has not ended and the sale cannot close early);
  `blast_presale::errors::EInvalidLifecycle` (already settled).
- Migrate: `blast_presale::errors::EInvalidLifecycle` (not `Funded`: unsettled, underfunded,
  cancelled, or migrated); `blast_core::errors::EWrongVenue` in `blast_core::migration` (another
  venue's `migrate`), or, on Aftermath, a `sui::dynamic_field` abort when no capability is kept
  under that `Lp` (a wrong `Lp`, or another venue's sale); `blast_presale::errors::EInvalidCoinOrder` (swap `CoinA`/`CoinB`);
  `blast_presale::errors::EWrongCoinPair`; `blast_vault::errors::EUnadmittedVenue` (the
  `VaultRegistry` does not admit the venue); `blast_vault::errors::EZeroLiquidity`;
  `blast_presale::errors::EPoolMismatch` and `blast_presale::errors::EDaoFeePoolMismatch`
  (Aftermath did not take every unit or did not record the vault as the recipient at the recorded
  fee; nothing to fix by retrying); venue aborts (Bluefin creation fee amount, a Cetus pool that
  already exists, an Aftermath `CreatePoolCapV2` of another LP coin, which no retry fixes, so the
  sale refunds at its liquidity deadline).
- Collect and apply: `blast_presale::errors::EPositionPoolMismatch` (pass the vault's own pool);
  `blast_presale::errors::EWrongCoinPair` (Cetus); `blast_vault::errors::EWrongVenue` (Aftermath
  call on another venue's vault); an abort in `sui::transfer` means a listed coin is not owned by
  the vault. Settle-and-apply and `blast_presale::aftermath::apply_fee_split`: 18 `ENoPending` or
  17 `ENotReady` from Blast admin's `delayed` module (no proposal, or not yet ready).
- Partner pay: `blast_presale::errors::EWrongPartner`; `blast_presale::errors::ENoPartnerPayout` (not migrated yet, or already paid).
- Claim: `blast_presale::errors::EInvalidLifecycle` (not `Migrated`/`Cancelled`); `blast_presale::errors::ENoCommitment` (never committed or
  already claimed).
- Cancel: `blast_presale::errors::ELiquidityDeadlineNotReached`; `blast_presale::errors::EInvalidLifecycle` (not `Funded`).
- Cap and owner: `blast_presale::errors::EWrongPresaleCap` (`prove_owner`, `destroy_cap`);
  `blast_presale::errors::EInvalidLifecycle` on `destroy_cap` before cancellation;
  `blast_core::errors::EWrongOwner` (proof presented to another sale's vault);
  `blast_vault::errors::ENothingToClaim`.
- Admin-only: `blast_acl::sign_in` aborts for a revoked `AdminCap` or one without the role;
  then `blast_presale::errors::EPresaleStarted`, `blast_presale::errors::EProtocolFeesIncreased` (a shared sale's override raises a rate),
  `blast_presale::errors::EAboveFeePolicy`, `blast_presale::errors::EProtocolFeesUnchanged`, `blast_presale::errors::EInvalidFees`, `blast_presale::errors::EInvalidDestination`,
  `blast_presale::errors::EAllowanceUnchanged`, `blast_presale::errors::EInvalidVenue`,
  `blast_presale::errors::EInvalidPauseBits`, `blast_presale::errors::EPauseUnchanged`,
  `blast_presale::errors::EUnguardedNotice`, `blast_presale::errors::EWrongUpgradeAction`,
  `blast_presale::errors::EInvalidDigest`.
- Delayed administration (policy fees and payee, venue admission, upgrades): Blast admin's
  delayed modules abort with plain codes. 17 `ENotReady`: applied before `ready_at_ms` (from
  `delayed_set` for an early admission, otherwise from `delayed`). 18 `ENoPending`: applied or
  cancelled with nothing pending (from the type's own module: `delayed` for a setting,
  `delayed_action` for an upgrade, `delayed_set` for an admission). 19 `EInvalidDelay`: a deadline
  or notice would overflow (from `delayed`). 20 `EUnchanged`: the proposal changes nothing, the
  venue is already admitted, or the removed venue is unknown (from the type's own module). 22
  `EWrongChange` (from `delayed_action`): `authorize_upgrade` or `make_immutable` while a notice
  change is pending, or `apply_upgrade_delay` while an action is pending.

### Pitfalls

- Prepare, `new`, set, `finalize`, and `share` in one PTB. The `VenueTicket` and the
  `PresaleInitializer` must be consumed and the `Presale` cannot be transferred, so a PTB that
  skips a step fails. The partner can be named only on the initializer.
- Passing the `TreasuryCap` by value to `prepare`. Cetus takes it by mutable reference, Bluefin
  and Aftermath by immutable reference; `new` takes it by value afterwards.
- Choosing a Cetus tick spacing Cetus does not register, or a Bluefin tier outside its bounds:
  creation aborts, and the tier can never change after creation.
- An early close needs a hard cap with `closes_when_filled`. A sale without a hard cap always
  runs to `end_ms`, even when it reached its raise on day one.
- Every commit returns a coin. Transfer it back to the sender, even when it is zero.
- Commits always credit the sender. Sponsored transactions work (the user stays the sender), but
  take Quote from the user's coins, not the sponsor's gas coin.
- A keeper PTB of `settle` then `migrate` aborts as a whole when the sale is underfunded
  (`settle` cancels, then `migrate` hits `blast_presale::errors::EInvalidLifecycle`). Compare `total_commitments` with
  `raise_target` first and send `settle` alone when it falls short.
- Calling `blast_presale::blast_presale::migrate` directly: its `Migration` must be redeemed by the
  venue. Call the venue's `migrate`, which calls it.
- A venue missing from the vault's `VaultRegistry` cannot migrate even though `CreationPolicy`
  admitted it at creation.
- Cetus calls need `CoinA`/`CoinB` in Cetus's order, both for `migrate` and for the pool type in
  `collect_fees`. Bluefin always has Meme as coin A. Aftermath takes `<Lp, Meme, Quote>` and
  orders the coins itself.
- Bluefin migration needs a `Coin<SUI>` of exactly Bluefin's current pool-creation fee.
- An Aftermath sale needs a fresh LP coin published before creation, whose `CreatePoolCapV2` goes
  to `blast_presale::aftermath::prepare`. `prepare` cannot check the capability against `Lp`, so
  verify the capability's coin before listing the sale. Its DAO fees are not in a position: they
  sit as coins at the vault's address until someone lists them in
  `blast_presale::aftermath::collect_fees`.
- Routing LP fees to auto-LP or burn on a presale vault: until shared venues that compound and
  buy back ship, auto-LP balances and burn Quote only accrue in the vault.
- Partnered sales and vaults hold Blast's fees until the pay calls run. Add
  `blast_presale::blast_presale::pay_protocol_fees_with_partner` after migration and
  `blast_vault::vault::pay_protocol_fees_with_partner` after each collection.
- An `OwnerProof` cannot be stored or dropped: call `blast_presale::blast_presale::prove_owner` in
  the PTB that uses it.
- The last claimant takes the rounding remainder. Show earlier previews as exact and the last one
  as "at least".
- Participant vesting starts when the claim lands, and anyone may relay a claim. Claiming late
  delays the schedule.
- The minimum commitment applies to a wallet's running total; top-ups below it are fine.
- `min_commitment × max_participants` must reach the raise; size the policy before creating.
- A cancelled sale's tokens are locked forever and its supply is already fixed or burn-only; the
  coin type cannot run another sale.
- Payouts are pushed to recipients in the same transaction. If a regulated Quote's issuer blocks a
  recipient, the paying transaction can abort: a blocked raise recipient can stall migration until
  the LP deadline, and a blocked address route stalls that vault's collections.
- `Committed` has no wallet field; take the wallet from the transaction sender.

### Vendor venues: the Aftermath DAO-pool presale

#### How a vendor venue works

`blast_presale::blast_presale::new` and `blast_presale::blast_presale::migrate` are public, and
the hand-off types are in the core package. Any module can be a venue if it defines a `drop`
witness struct only it can construct. It issues a ticket with `blast_core::migration::issue_ticket`
and passes it to `blast_presale::blast_presale::new`; the sale records the witness type in
`venue`. At migration, only `blast_core::migration::redeem` called with the same witness opens the
sale's `Migration` (`blast_core::errors::EWrongVenue` otherwise); the venue receives the LP's
`Balance<SaleToken>` and `Balance<Quote>` and the `VaultTerms`, and must put the balances into its
pool in the same call. `blast_presale::blast_presale::migrate` pays Blast, raise recipients, and
token recipients exactly as for the package's own venues. Blast must first admit the witness with
`creation_policy::schedule_venue`; removing it later never blocks existing sales. A venue creates a
vault only if the vault's `VaultRegistry` admits it; a vendor sale without a vault has no Blast LP
fees, no holder-reward rounds, and no owner claims. Every other sale rule (eligibility, claims,
refunds, LP deadline, the seed-price check) applies unchanged.

#### `blast_aftermath_dao_presale`

A one-off, immutable package for one partner: a plain venue over `blast_core` that imports no
product, so a presale upgrade never strands it. Its sales migrate into a new 50/50 Aftermath
weighted pool wrapped in Aftermath's DAO-fee pool, which charges 2% (200 BPS) on every swap,
deposit, and withdrawal and sends it straight to the partner treasury compiled into the module. It
creates no vault.

Objects:

- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::Venue`: the sealed venue witness. It
  issues the ticket `prepare` returns and redeems that sale's migration hand-off.
- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::AdminCap`: the vendor's own admin, sent
  to the publisher. Its one power is preparing sale tokens through `prepare`. It is not Blast's
  `blast_acl::AdminCap`.
- `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreation<Lp, SaleToken>`: shared;
  reserves one sale token's pool creation with the Aftermath `CreatePoolCapV2` of a freshly
  published LP coin `Lp`.

Create (*cap holder*, `blast_aftermath_dao_presale::blast_aftermath_dao_presale::AdminCap`, who also
holds the sale token's `TreasuryCap`), one PTB:

1. Beforehand, in its own transaction, publish a fresh Aftermath LP coin `Lp` (one per sale); its
   publication yields the `CreatePoolCapV2` that the `AdminCap` holder passes in.
2. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::prepare<Lp, SaleToken,
   Quote>(admin_cap, create_pool_cap)` shares the `PoolCreation<Lp, SaleToken>`, emits
   `blast_aftermath_dao_presale::blast_aftermath_dao_presale::PoolCreationReserved`
   (`pool_creation_id`), and returns the venue's `VenueTicket<SaleToken, Quote>`. Its pool's weights
   and fees are the module's constants, so it records no tier.
3. `blast_presale::blast_presale::new` with the `TreasuryCap` and the ticket, as for any sale. The
   `CreationPolicy` must admit the vendor's `Venue`.
4. The `blast_presale::blast_presale` setters as for any sale, including the optional
   `blast_presale::blast_presale::set_partner`. The sale's LP-fee split never applies, because no
   vault exists.
5. `blast_presale::blast_presale::finalize`, the optional
   `blast_presale::blast_presale::set_protocol_fees(...)` (which needs Blast's presale `FeeAdmin`
   signed in within the same transaction), then `blast_presale::blast_presale::share`.

Migrate (*anyone*, while `Funded`), one PTB:

1. `blast_presale::blast_presale::settle` if needed.
2. `blast_presale::blast_presale::migrate`, which returns the sale's `Migration<SaleToken, Quote>`.
3. `blast_aftermath_dao_presale::blast_aftermath_dao_presale::migrate<Lp, SaleToken,
   Quote>(migration, pool_creation, pool_registry, dao_fee_version)`. `migration` is the
   result of step 2; `pool_creation` is the sale token's shared `PoolCreation<Lp, SaleToken>`, passed
   by value and deleted; `pool_registry` is Aftermath's shared `PoolRegistry` (mutable);
   `dao_fee_version` is the DAO-fee package's shared `Version`.
   Type arguments are always `<Lp, SaleToken, Quote>`; the module sorts the coins into Aftermath's
   order itself.
4. On a partnered sale, `blast_presale::blast_presale::pay_protocol_fees_with_partner(...)`.

The call redeems the hand-off with its `Venue` (`blast_core::errors::EWrongVenue` for a hand-off
sealed for any other venue), keeping only the sale's ID from the vault terms (no vault exists for
its pools), creates the pool from all LP tokens and Quote (50/50 weights, flatness 0, a 0.01%
swap-in fee that compounds into the LP, no other pool fees, name "Blast Presale Pool"), checks it
holds every unit (`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EPoolMismatch`, code
0), wraps it in a DAO-fee pool at 200 BPS paying the treasury
(`blast_aftermath_dao_presale::blast_aftermath_dao_presale::EDaoFeePoolMismatch`, code 1), shares
the DAO-fee pool (the object traders use), sends its `OwnerCap` to the treasury, and
sends the whole LP coin to `0x0`, where nobody can ever use it. Emits
`blast_aftermath_dao_presale::blast_aftermath_dao_presale::Migrated` with the sale ID, the pool,
DAO-fee pool, owner cap, and LP coin IDs and the LP amount.

With the `OwnerCap` the treasury can change its pool's DAO fee or recipient directly through
Aftermath. If the `CreatePoolCapV2` belongs to a different LP coin than `Lp`, or Aftermath retires the
versions this package links to, migration aborts and the sale becomes refundable at its LP
deadline.

### Q&A

**How many tokens will a buyer get?** After migration, `floor(token_allocation × commitment /
total_commitments)`, plus an overflow refund of `floor((total_commitments − raise_target) ×
commitment / total_commitments)` Quote. Every wallet gets the same fill rate,
`raise_target / total_commitments`. The last wallet to claim also receives the rounding
remainder.

**Can a buyer withdraw before the sale ends?** No. Quote stays locked while the sale is `Open` or
`Funded`. It comes back only as the overflow refund after migration, or in full after a
cancellation.

**Can a sale end before its window does?** Only a hard-capped sale whose hard cap has
`closes_when_filled`, once its raise is full under the hard cap. Anyone may then call
`blast_presale::blast_presale::settle`, and the LP deadline counts from that moment. An overflowing sale always
runs its full window, since later wallets can still join at the common fill rate.

**What happens if the raise is not met?** From `end_ms` anyone calls `blast_presale::blast_presale::settle`,
which cancels the sale. Each wallet (or a relayer) then calls `blast_presale::blast_presale::claim` for a full
refund. Blast charges nothing, and the minted tokens stay locked forever.

**Who migrates a funded sale, and what if nobody does?** Anyone, through the venue whose ticket
started the sale, at any time until the sale is cancelled. From the LP deadline (`end_ms +
liquidity_window_ms`, at least 7 days) anyone may call `blast_presale::blast_presale::cancel_unlaunched` instead,
which makes every commitment fully refundable.

**What is the PTB to start a sale on Cetus?** `blast_presale::cetus::prepare` with the
`TreasuryCap` by mutable reference (returns the `VenueTicket`), `blast_presale::blast_presale::new`
with the `TreasuryCap` by value and the ticket, the setters, `blast_presale::blast_presale::finalize`,
`blast_presale::blast_presale::share`, and a transfer of the `PresaleCap`, in that order.

**What does Blast charge?** A snapshot, taken at creation, of a raise rate, a token rate, and two
LP-fee rates. The raise and token fees are paid at migration to the `FeePolicy` destination; the
LP-fee rates pass to the vault, which takes them at each fee collection, rounded up, for the core
`Treasury`. Nothing is charged on commitments, refunds, or failed sales.

**How does the creator get its LP fees and the migration residuals?** Through the vault's fee
split: an address route is paid at each collection, and an owner route accrues. The `PresaleCap`
holder calls `blast_presale::blast_presale::prove_owner` and
`blast_vault::vault::claim_owner_balances` in one PTB to take owner fees and residuals, and uses
the same proof with `blast_vault::vault::schedule_fee_split` to change the split after 48 hours.

**Can Blast or the creator change a sale after it opens?** The creator cannot. Blast's presale
`FeeAdmin` can change the sale's four rates only before `start_ms` (raising one only in its
creation transaction), and `TreasuryAdmin` can redirect the raise and token fee destination after
its notice. Windows, recipients and eligibility never change. After migration, Blast's per-vault
LP share changes only through the vault's own 48-hour delayed call.

**How is an allowlist leaf built?** `blake2b256(0x00 || "blast-presale-v1" || u64 LE index ||
32-byte wallet || u64 LE cap)`, as `blast_core::merkle::leaf` hashes it. Internal nodes are
`blake2b256(0x01 || left || right)`. The proof is positional with exactly
`ceil(log2(leaf_count))` siblings. The wallet must be the transaction sender.

**Where is the liquidity, and can anyone withdraw it?** A Cetus position is burned through
Cetus LP-burn and the vault keeps only its fee-claiming proof. A Bluefin position sits in the
vault under the venue's key, which only borrows it to collect fees and never removes it. An
Aftermath sale's LP coin, the pool's whole liquidity, is sent to `0x0`, on the package's own route
and the vendor's alike, and the package's vault keeps the DAO-fee owner cap as its position, which
no function removes.
