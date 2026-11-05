## Cetus and Bluefin venues

### What it is

Package `blast_fun_migrators` holds the two venues a Blast launch can graduate to: Cetus
(`blast_fun_migrators::cetus`) and Bluefin (`blast_fun_migrators::bluefin`). A venue takes part in a
launch twice. At creation its `prepare` call records the coin's pool tier and returns a sealed
`blast_core::migration::VenueTicket` that `launch::new` redeems, so the launch can migrate only to
that venue. When the curve fills and the launch is `MigrationReady`, anyone calls the venue's
`migrate`: it takes the launch's sealed hand-off, creates a new full-range pool seeded with the
pool's Meme and Quote, and locks the position in a new shared `blast_vault::vault::Vault`, which has
no removal path. Afterwards anyone collects the position's trading fees through the venue; the vault
pays Blast its share and splits the rest by the vault's fee split. The vault itself (fee split,
owner claims, partner payouts, holder rewards) is described in the vault guide; this guide covers
what the venues do and what each call needs.

### Objects and authority

#### Shared objects

| Object | How many | What it does |
| --- | --- | --- |
| `blast_fun_migrators::venue_config::VenueConfig` | singleton | Venue-owned records, written once per coin and never removed: each Cetus coin's `PoolCreationCap` and tick spacing, and each Bluefin coin's tier. |
| `blast_fun_migrators::blast_fun_migrators::PackageVersion` | singleton | This package's operational generation; every venue call checks it first. |
| `blast_fun_migrators::package_admin::PackageAdmin` | singleton | Sealed custody of this package's `Publisher` and `UpgradeCap`. |
| `blast_vault::vault::Vault<Meme, Quote>` | one per migrated launch | Created and shared by `migrate`; holds the venue position and the fee balances (vault guide). |

Calls also take objects from other packages:

- Launchpad: the shared `launch::Launch` (`Launch<Meme, Quote>`, migrate only), the launchpad's
  `package_version::PackageVersion<BLAST_FUN>` (typed by `blast_fun::blast_fun::BLAST_FUN`), and `launch_config::LaunchConfig` (migrate only). At
  creation the launcher also passes its owned `TreasuryCap<Meme>` to `prepare`.
- Vault: `blast_vault_package::VaultRegistry` (migrate only), the vault package's
  `blast_admin::package_version::PackageVersion` (typed by `blast_vault_package::BLAST_VAULT_PACKAGE`),
  and the shared `blast_core::blast_treasury::Treasury` that Blast's LP fees go to.
- Sui: the Meme's Coin Registry `Currency<Meme>` (shared; mutable because migration and collections
  burn Meme), the Quote's `Currency<Quote>` (Bluefin migration only), and `Clock` at `0x6`.
- Cetus: `GlobalConfig`, `Pools`, the pair's `Pool<CoinA, CoinB>`, and Cetus LP Burn's
  `BurnManager`, all shared.
- Bluefin: its `GlobalConfig` and the pair's `Pool<Meme, Quote>`, both shared.

#### Venue witnesses

`blast_fun_migrators::cetus::Venue` and `blast_fun_migrators::bluefin::Venue` are the venues'
sealed witnesses; only their own module constructs them. A venue's witness issues its tickets,
redeems its launches' migrations, keys its position inside the vault, and authorizes its fee
collections. Blast admits each witness type twice: in `LaunchConfig` (so launches may start on it)
and in the vault's `VaultRegistry` (so it may create vaults), which must also list the launchpad's
`blast_fun::blast_fun::PackageWitness` as the issuer of every launch's vault terms.

#### Who may call what

| Call | Who |
| --- | --- |
| `blast_fun_migrators::cetus::prepare`, `blast_fun_migrators::bluefin::prepare` | holder of the coin's `TreasuryCap<Meme>` (the launcher), in the launch's creation PTB |
| `blast_fun_migrators::cetus::migrate`, `blast_fun_migrators::bluefin::migrate` | anyone, once the launch is `MigrationReady` |
| `blast_fun_migrators::cetus::collect_fees`, `blast_fun_migrators::bluefin::collect_fees` | anyone |
| `blast_fun_migrators::cetus::settle_and_apply_fee_split`, `blast_fun_migrators::bluefin::settle_and_apply_fee_split` | anyone, once the vault's proposed split is ready |
| `blast_fun_migrators::cetus::buyback_and_burn`, `blast_fun_migrators::bluefin::buyback_and_burn` | Blast admin: `blast_core::blast_domain::BuybackAdmin` |
| `blast_fun_migrators::package_admin::schedule_upgrade`, `blast_fun_migrators::package_admin::schedule_make_immutable`, `blast_fun_migrators::package_admin::schedule_upgrade_delay`, `blast_fun_migrators::package_admin::authorize_upgrade`, `blast_fun_migrators::package_admin::commit_upgrade_and_advance`, `blast_fun_migrators::package_admin::make_immutable` | Blast admin: the launchpad's `blast_fun_domain::UpgradeAdmin` |
| `blast_fun_migrators::package_admin::cancel_upgrade_action` | Blast admin: the launchpad's `blast_fun_domain::CancelAdmin` |
| `blast_fun_migrators::package_admin::apply_upgrade_delay` | anyone, once the notice change is ready |
| `blast_fun_migrators::package_admin::wrap` | holder of the package's `blast_fun_migrators::blast_fun_migrators::Publication` and native `UpgradeCap` (once, at deployment) |

The vault's own calls (owner claims, fee-split proposals, partner payouts, holder rewards) are listed
in the vault guide; the owner acts there with an owner proof from `launch::prove_owner`. A Blast
admin signs in with `blast_acl::sign_in` on the shared `blast_acl::ACL` to get the role's
`blast_acl::AdminWitness`. Integrators cannot call admin functions.

#### Trust assumptions

- **Upgradeable package.** `UpgradeAdmin` can authorize compatible upgrades of this package after
  the upgrade notice (48 hours at publication). Positions are held by the vault package, under the
  venue's key: the Cetus migration liquidity is also burned through Cetus LP Burn, whose
  `CetusLPBurnProof` can only collect fees.
- **Venue operators.** Cetus's pool-manager role can create a reserved pair's pool without the
  coin's `PoolCreationCap`. If it does so first, Cetus migration aborts, and only a migrators
  upgrade could recover the launch. If Cetus stops registering the launch's tick spacing, migration
  aborts and the launch stays `MigrationReady`.
- **Auto-LP price-move skim.** Auto-LP adds at the pool's current price. A caller can move the price
  in the same transaction, collect, and move it back, skimming part of that call's auto-LP amount.
  Frequent collection keeps each slice small. Buybacks are admin-only with a minimum output for the
  same reason.
- **Buyback timing.** The burn route's Quote waits until a `BuybackAdmin` acts; nothing forces a
  buyback.

### Lifecycle

1. **Prepare** (creation PTB): the venue records the coin's tier in `VenueConfig` and returns a
   `VenueTicket<Meme, Quote>`; `launch::new` redeems it and stores the venue. A coin is prepared
   once: its records are write-once.
2. **Curve**: the launch trades until `MigrationReady` (launchpad guide).
3. **Migrate**: the venue redeems the launch's `Migration`, creates the pool, and creates and shares
   the vault. The launch becomes `Migrated`. A failed migration aborts the whole transaction and
   leaves the launch `MigrationReady`.
4. **Collect**: any number of fee collections, fee-split changes, and buybacks through the venue.
   The vault never closes and its positions are never removed.

### Flows

Every venue call takes the migrators `PackageVersion` (shared) and checks it before anything else.
Calls that also mutate the launchpad or the vault take that package's version too, because each
package checks only its own generation.

#### Prepare a coin on Cetus (launcher, inside the launch's creation PTB)

`blast_fun_migrators::cetus::prepare` (type arguments `<Meme, Quote>`) takes, in order: the migrators
`PackageVersion`, `VenueConfig` (mutable), Cetus `GlobalConfig`, Cetus `Pools` (mutable), the
`TreasuryCap<Meme>` (owned, by mutable reference), and `tick_spacing: u32`. It:

1. Checks that Cetus registers a fee rate for `tick_spacing` (Cetus aborts otherwise).
2. Mints the Meme type's single Cetus `PoolCreationCap` from the treasury cap and registers the pair
   at `tick_spacing`. Cetus aborts if it refuses the pair there.
3. Stores the cap under `blast_fun_migrators::cetus::CreationCapKey` and the tick spacing under
   `blast_fun_migrators::cetus::PoolTierKey` in `VenueConfig`, with no path to remove either, and
   emits `blast_fun_migrators::blast_events::CetusPoolReserved`.
4. Returns a `blast_core::migration::VenueTicket<Meme, Quote>` sealed by
   `blast_fun_migrators::cetus::Venue`.

After this, only that cap (or Cetus's pool-manager role) can create the pair's Cetus pool at that
tick spacing, so no buyer can pre-create the migration pool at a price of their choosing. The fee
rate is whatever Cetus registers for the tick spacing.

#### Prepare a coin on Bluefin (launcher, inside the launch's creation PTB)

`blast_fun_migrators::bluefin::prepare` (type arguments `<Meme, Quote>`) takes, in order: the
migrators `PackageVersion`, `VenueConfig` (mutable), the `TreasuryCap<Meme>` (owned, by immutable
reference, proving the caller controls the coin), `tick_spacing: u32`, and `fee_rate: u64`. It aborts
with `blast_fun_migrators::bluefin::EInvalidTier` unless `tick_spacing` is in 1..=400 and `fee_rate`
in 1..=20,000 (Bluefin's own pool-creation bounds, checked here because Bluefin checks them only at
pool creation). It stores a `blast_fun_migrators::bluefin::PoolTier` under
`blast_fun_migrators::bluefin::PoolTierKey` in `VenueConfig` and returns a `VenueTicket<Meme, Quote>`
sealed by `blast_fun_migrators::bluefin::Venue`. It needs no Bluefin objects.

Either way, pass the ticket to `launch::new` in the same PTB, then pass the same `TreasuryCap` to
`launch::new` by value (launchpad guide, Flow 3). The ticket cannot be stored or dropped.

#### Migrate to Cetus (anyone)

Nothing requires a separate transaction, so the PTB that graduates the curve can migrate too.

1. Work out Cetus's coin order. Cetus orders a pool's coins `CoinA` and `CoinB` by type name, and
   the venue checks the order with Cetus's own `is_right_order<CoinA, CoinB>` (in Cetus's `factory`
   module). Dev-inspect it, or dry-run `migrate` with either order: the wrong one aborts with
   `blast_fun_migrators::cetus::EInvalidCoinOrder`.
2. Call `blast_fun_migrators::cetus::migrate` with type arguments `<Meme, Quote, CoinA, CoinB>` and,
   in order: the `Launch<Meme, Quote>` (mutable), the migrators `PackageVersion`, the launchpad
   `PackageVersion`, `LaunchConfig`, `Currency<Meme>` (mutable), `VenueConfig`, Cetus
   `GlobalConfig`, Cetus `Pools` (mutable), LP Burn `BurnManager` (mutable), `VaultRegistry`, the
   vault `PackageVersion`, `Treasury`, and `Clock`. It returns nothing; the caller receives no
   object.

Inside the call, in order:

1. Checks the coin order (`blast_fun_migrators::cetus::EInvalidCoinOrder`) and that `{CoinA, CoinB}`
   is exactly `{Meme, Quote}` (`blast_fun_migrators::cetus::EWrongCoinPair`).
2. Reads the coin's tick spacing from `VenueConfig` and Cetus's full-range ticks for it.
3. Calls `launch::migrate`, which pays the allocation's recipients, accrues Blast's one-time fee in
   the launch, disposes of the unsold Meme, marks the launch `Migrated`, and returns the sealed
   `Migration` (launchpad guide). The venue redeems it with its witness, receiving the pool's Meme
   and Quote and the vault's terms; any other venue's witness aborts.
4. Computes the opening price from those atomic amounts (see Economics), creates the pool with the
   reserved `PoolCreationCap` at the recorded tick spacing, and seeds full-range liquidity with
   exactly the handed-off balances. It never adopts an existing pool.
5. Burns the position through Cetus LP Burn; Cetus records the liquidity as permanently locked.
6. Creates the vault from the terms with `blast_vault::vault::new` (aborts unless the registry
   admits `blast_fun_migrators::cetus::Venue`), attaches the `CetusLPBurnProof` and Cetus's leftover
   coins with `blast_vault::vault::share_with_position`, and shares the vault. The leftovers are
   migration residuals and go to Blast.

#### Migrate to Bluefin (anyone)

Bluefin pools always have Meme as coin A: `Pool<Meme, Quote>`.

1. Split a `Coin<SUI>` worth exactly the SUI pool-creation fee Bluefin currently configures. Bluefin
   aborts on any other amount, and the whole coin is paid.
2. Call `blast_fun_migrators::bluefin::migrate` with type arguments `<Meme, Quote>` and, in order:
   the `Launch` (mutable), the migrators `PackageVersion`, the launchpad `PackageVersion`,
   `LaunchConfig`, `Currency<Meme>` (mutable), `Currency<Quote>`, `VenueConfig`, Bluefin
   `GlobalConfig` (mutable), `VaultRegistry`, the vault `PackageVersion`, `Treasury`, the `Coin<SUI>`
   fee (by value), and `Clock`.

Inside the call: it reads the coin's tier from `VenueConfig`; runs `launch::migrate` and redeems the
`Migration` as above; creates `Pool<Meme, Quote>` at the tier, named `MEME-QUOTE` from the two Coin
Registry symbols, with no Meme icon and the Quote's icon; opens a position across the widest tick
range Bluefin's configured bounds allow at that spacing; seeds it with the handed-off balances;
creates the vault with the position and Bluefin's leftovers (residuals to Blast) and shares it; and
shares the pool. The caller receives no object, but Bluefin records the caller as the new pool's
manager, a Bluefin role limited to the pool's reward emissions and to handing the role on.

#### Collect LP fees (anyone)

Anyone may collect, as often as they like. A collection that finds no fees is valid.

- Cetus: `blast_fun_migrators::cetus::collect_fees`, type arguments `<Meme, Quote, CoinA, CoinB>`,
  with the `Vault<Meme, Quote>` (mutable), migrators `PackageVersion`, vault `PackageVersion`,
  `Treasury`, `Currency<Meme>` (mutable), Cetus `GlobalConfig`, LP Burn `BurnManager`, the vault's
  Cetus `Pool<CoinA, CoinB>` (mutable), and `Clock`.
- Bluefin: `blast_fun_migrators::bluefin::collect_fees`, type arguments `<Meme, Quote>`, with the
  `Vault<Meme, Quote>` (mutable), migrators `PackageVersion`, vault `PackageVersion`, `Treasury`,
  `Currency<Meme>` (mutable), Bluefin `GlobalConfig`, the vault's `Pool<Meme, Quote>` (mutable), and
  `Clock`.

Order of operations:

1. On Cetus, prove the coin pair (`blast_fun_migrators::cetus::EWrongCoinPair`). Check the pool is
   the vault's own (`EPositionPoolMismatch` in the venue's module).
2. Collect fees. Cetus: from the burned position through LP Burn, plus the auto-LP position's fees
   once it exists. Bluefin: from the migration position.
3. Split through `blast_vault::vault::split_fees`: Blast's share of each asset (rounded up) is paid to
   the `Treasury` at once, or held for the partner when the launch named one; the rest is apportioned
   over the vault's fee split. Address routes are paid as coins; the owner, auto-LP, and
   holder-reward routes accrue in the vault; the burn route's Meme is burned and its Quote kept for
   buybacks. A zero collection moves and emits nothing.
4. Auto-LP: take every waiting auto-LP Meme and Quote (this collection's part plus anything left from
   earlier calls) and add what the pool takes at its current price; keep the rest in the vault.

Auto-LP per venue:

- Cetus burned the migration position, so it cannot take liquidity. The first time both auto-LP
  balances are nonzero, the vault opens a second full-range position in the same pool (emitting
  `blast_vault_events::AutoLpPositionOpened`) and keeps it with no removal path. Each add fixes all
  of coin A if Cetus's liquidity math says the coin B balance covers it, else all of coin B if the
  coin A balance covers that, else adds nothing.
- Bluefin adds to the migration position. The venue picks the fixed side from the pool price and the
  position's bound prices, keeping a 2-atom margin on the other side (see Economics).
- Both add nothing while either side is empty, so a one-sided auto-LP balance waits until the other
  asset arrives.

#### Settle and apply a new fee split (anyone)

The owner proposes a split on the vault with an owner proof (`launch::prove_owner`, then
`blast_vault::vault::schedule_fee_split`; launchpad and vault guides). It is ready after a fixed
48-hour notice. Once ready, anyone calls
`blast_fun_migrators::cetus::settle_and_apply_fee_split` (`<Meme, Quote, CoinA, CoinB>`) or
`blast_fun_migrators::bluefin::settle_and_apply_fee_split` (`<Meme, Quote>`) with the same arguments
as `collect_fees`. It checks the proposal is ready (`blast_vault::vault::assert_fee_split_ready`),
collects and splits every position's fees under the current split, adds auto-LP, and then applies
the new split (`blast_vault::vault::apply_fee_split`), so each fee follows the split it accrued
under. The call takes no split of its own: it applies only the stored proposal.

#### Buyback and burn (Blast admin: `blast_core::blast_domain::BuybackAdmin`)

A `BuybackAdmin` calls `blast_fun_migrators::cetus::buyback_and_burn` (`<Meme, Quote, CoinA, CoinB>`)
or `blast_fun_migrators::bluefin::buyback_and_burn` (`<Meme, Quote>`) with the vault, the migrators
`PackageVersion`, the vault `PackageVersion`, the `AdminWitness` for `BuybackAdmin`,
`Currency<Meme>`, the venue's `GlobalConfig`, the vault's pool, `quote_in` (atomic Quote),
`min_meme_out` (atomic Meme), and `Clock`. It checks the pool is the vault's
(`EPositionPoolMismatch`), takes exactly `quote_in` of the vault's burn Quote, swaps it for Meme in
the vault's pool up to the widest price limit, burns the Meme bought (or sends it to `@0x0` when the
supply is fixed), keeps any Quote the pool did not take for the next buyback, and emits
`blast_vault_events::BuybackBurned`. The admin sets `min_meme_out` from an off-chain price, because
anyone can move the pool price inside a transaction.

#### Package upgrades (Blast admin: `UpgradeAdmin`)

`blast_fun_migrators::package_admin::schedule_upgrade` announces an exact 32-byte digest. After the
notice, `blast_fun_migrators::package_admin::authorize_upgrade` returns its upgrade ticket, and
`blast_fun_migrators::package_admin::commit_upgrade_and_advance` commits the receipt and moves
`PackageVersion` to the next generation in the same transaction. From then on every call to the old
package's code aborts the generation check, so integrators must call the current package address;
type names keep the original address. Upgrading this package leaves the launchpad and the vault on
their own generations. `blast_fun_migrators::package_admin::schedule_make_immutable` and
`blast_fun_migrators::package_admin::make_immutable` end upgrades;
`blast_fun_migrators::package_admin::schedule_upgrade_delay` changes the notice. The package has no
pause of its own: migration stops with the launchpad's Migrate bit, and buybacks with the vault's
admin pause bit.

### Economics

All amounts are atomic units. BPS are out of 10,000.

#### Migration seed and residuals

The opening sqrt price is `floor(sqrt(coin_b / coin_a) × 2^64)` from the handed-off atomic amounts:
Quote/Meme when Meme is coin A, Meme/Quote otherwise. Display decimals never enter it. The seed fixes
the side with more atoms (Meme on a tie), unless the venue's math says that would overdraw the other
side by rounding, in which case it fixes the other side. Whatever the venue does not take is the
migration residual; a launch's terms send residuals to Blast, paid to the `Treasury` at once, or held
for the partner when the launch named one. Position principal plus residuals equals the hand-off.

#### Blast's LP-fee share and the split

Each collection takes Blast's share of each asset, `ceil(gross × bps / 10,000)`, with the vault's
per-asset share. A launch's vault starts with the `LaunchConfig.protocol_lp_fees` value applied at
migration (1,500 BPS each by default, at most 3,000); Blast can change one vault's share only after a
fixed 48-hour notice. The rest of each asset is apportioned over the fee split's routes by largest
remainder, so the routes always sum to what is left. This is separate from Blast's one-time
migration allocation, which the launchpad takes at migration. The vault guide has the details,
including partner payouts.

#### Auto-LP math

Auto-LP never swaps. It fixes all of one side and pays what the venue asks of the other at the
current price; the rest of the other side waits. Bluefin's side choice, with `P`, `L`, `U` the
current, lower, and upper sqrt prices (Q64.64), `a` the Meme balance, `b` the Quote balance, and a
2-atom margin: fix Meme when `liquidity = a × (P × U / 2^64) / (U − P)` is positive and below 2^128
and `ceil(liquidity × (P − L) / 2^64) + 2 ≤ b`; otherwise fix Quote when
`liquidity = b × 2^64 / (P − L)` is positive and `ceil(liquidity × 2^64 / P) − floor(liquidity ×
2^64 / U) + 2 ≤ a`; otherwise wait. A price at or outside the range adds nothing. Cetus uses Cetus's
own liquidity math with no margin.

#### Buybacks

A buyback spends exactly `quote_in` of the burn Quote; Quote the pool does not take returns to the
burn Quote. Every Meme bought is burned, or sent to `@0x0` under a fixed supply.

### Time rules

- Preparation happens only in the launch's creation PTB; the tier never changes afterwards.
- Migration has no deadline: a `MigrationReady` launch can migrate at any later time, unless the
  launchpad's Migrate bit is paused.
- A proposed fee split waits a fixed 48 hours; once ready it stays ready until someone settles and
  applies it, or the owner cancels it. Until then collections use the current split.
- Collections have no deadline or cooldown.

### Reading state

- Which venue a launch uses: the launch's `venue` field, the type name of
  `blast_fun_migrators::cetus::Venue` or `blast_fun_migrators::bluefin::Venue`.
- A Cetus coin's tier: the `u32` tick spacing in the `VenueConfig` dynamic field keyed by
  `blast_fun_migrators::cetus::PoolTierKey` (typed by the Meme); its `PoolCreationCap` is the dynamic
  object field keyed by `blast_fun_migrators::cetus::CreationCapKey`, whose ID matches
  `CetusPoolReserved`.
- A Bluefin coin's tier: the `blast_fun_migrators::bluefin::PoolTier` (`tick_spacing`, `fee_rate`)
  in the `VenueConfig` dynamic field keyed by `blast_fun_migrators::bluefin::PoolTierKey`.
- A vault's pool: `blast_vault::vault::pool_id`, or the `pool_id` in its `VaultCreated` event. The
  vault's type arguments name the Meme and Quote; the `VaultCreated` event's third type argument
  names the venue.
- The positions: dynamic object fields of the vault keyed by `blast_vault::vault::PositionKey` (the
  Cetus `CetusLPBurnProof` or the Bluefin `Position`) and, on Cetus, `blast_vault::vault::AutoLpPositionKey`
  (the auto-LP `Position`), each typed by the venue witness.
- Pending LP fees: dev-inspect `collect_fees` against the live vault and pool.

### Events

| Event | Emitted by | What to derive |
| --- | --- | --- |
| `blast_fun_migrators::blast_events::CetusPoolReserved` | `blast_fun_migrators::cetus::prepare` | `meme`, `quote`, `pool_creation_cap_id`, `tick_spacing`: the Cetus pair is reserved |
| launchpad `blast_fun::events::MigrationAllocationPaid`, `blast_fun::events::ProtocolFeesAccrued`, `blast_fun::events::Migrated` | `migrate`, inside `launch::migrate` | recipients paid, Blast's one-time allocation, pool amounts and disposal |
| `blast_vault_events::VaultCreated` | `migrate` | `vault_id`, `pool_id`, `position_id`, `liquidity`, the sealed `terms`, residual amounts; type arguments `<Meme, Quote, Venue>` |
| `blast_vault_events::FeesCollected` | `collect_fees`, `settle_and_apply_fee_split` | gross amounts, Blast's cut, each route's amounts in route order |
| `blast_vault_events::AutoLpPositionOpened`, `blast_vault_events::AutoLiquidityAdded` | collections | Cetus's auto-LP position; liquidity added and what still waits |
| `blast_vault_events::BuybackBurned` | `buyback_and_burn` | `quote_spent`, `meme_burned`, burn Quote still waiting |
| `blast_core::blast_core_events::ProtocolFeesPaid` | migration and collections on a vault without a partner | Blast's residuals and LP-fee cut paid to the treasury |
| `delayed::DelayedApplied` | `settle_and_apply_fee_split` | keyed by `blast_vault::vault::FeeSplitKey` with the vault ID as `owner`: the previous and new split |

`CetusPoolReserved` and the vault and core events are plain Sui events (not wrapped in an envelope);
so are the launchpad's. Cetus and Bluefin emit their
own pool, position, and swap events in the same transactions.

### Aborts

| Flow | Abort | Fix |
| --- | --- | --- |
| any | code 9 in `blast_admin::operational_version` | call the current package ID of the migrators, launchpad, or vault package |
| Cetus prepare | Cetus aborts in its own modules | choose a tick spacing Cetus registers, for a pair it accepts |
| Bluefin prepare | `blast_fun_migrators::bluefin::EInvalidTier` | tick spacing 1..=400, fee rate 1..=20,000 |
| Cetus migrate, collect, buyback | `blast_fun_migrators::cetus::EInvalidCoinOrder` (migrate), `blast_fun_migrators::cetus::EWrongCoinPair` | pass the pool's coin order; `CoinA` and `CoinB` must be the launch's Meme and Quote |
| migrate | `sui::dynamic_field` code 1 reading the tier; 8 `blast_core::errors::EWrongVenue` in `blast_core::migration` | call the migrate of the venue the launch stores |
| migrate | 12 `blast_fun::errors::EInvalidLaunchLifecycle`, 25 `blast_admin::errors::EPaused` (`package_version`) | wait for `MigrationReady`; wait for Migrate to be unpaused |
| migrate | 1 `blast_vault::errors::EUnadmittedVenue`, 33 `blast_vault::errors::EUnadmittedIssuer`, 4 `blast_vault::errors::EZeroLiquidity` (vault) | the venue and the launchpad's `PackageWitness` must be listed in `VaultRegistry`; the seed must give positive liquidity |
| migrate | Cetus aborts when the pair's pool already exists or the tick spacing is no longer registered; Bluefin aborts on a wrong creation fee | the launch stays `MigrationReady`; pass the exact Bluefin fee |
| collect, settle, buyback | `blast_fun_migrators::cetus::EPositionPoolMismatch`, `blast_fun_migrators::bluefin::EPositionPoolMismatch` | pass the vault's own pool |
| settle and apply | 18 `ENoPending` or 17 `ENotReady` from Blast admin's `delayed` module | wait until the scheduled split is ready |
| buyback | 7 `blast_vault::errors::EBuybackQuoteOutOfRange`, 8 `blast_vault::errors::EBuybackBelowMinimum`; Blast admin `EPaused` when the vault's admin bit is set | spend a positive amount up to the burn Quote; re-quote `min_meme_out` |
| package administration | `blast_fun_migrators::package_admin::EWrongUpgradeAction`, `blast_fun_migrators::package_admin::EInvalidDigest` | execute the exact scheduled action; use a 32-byte digest |

### Pitfalls

- Calling `prepare` outside the creation PTB. The `VenueTicket` cannot be stored, so prepare,
  `launch::new`, `launch::finalize`, and `launch::share` share one PTB.
- Passing the `TreasuryCap` by value to `prepare`. Cetus takes it by mutable reference and Bluefin
  by immutable reference; `launch::new` takes it by value afterwards.
- Choosing a Cetus tick spacing Cetus does not register, or a Bluefin tier outside its bounds:
  creation aborts, and the tier can never change after creation.
- Passing Cetus coin types in Meme/Quote order instead of the pool's order.
- Calling `launch::migrate` directly. Its `Migration` must be redeemed by the venue; call the venue's
  `migrate`, which calls it.
- Forgetting the Bluefin pool-creation fee coin, or passing a different amount.
- Expecting the burned Cetus position to grow: auto-LP goes to the second position.
- Expecting a ready fee split to apply by itself. Someone must call `settle_and_apply_fee_split`.
- Calling an old package ID after an upgrade.

### Q&A

**Which venue does a launch migrate to?** The one whose `prepare` produced the ticket the launch
redeemed; the launch stores that venue's witness type in `venue`. Only that venue's `migrate`
succeeds.

**What is the PTB to start a launch on Cetus?** `blast_fun_migrators::cetus::prepare` with the
`TreasuryCap` by mutable reference (returns the `VenueTicket`), `launch::new` with the ticket, the
`TreasuryCap` by value, and the venue ticket, the launch setters, `launch::finalize`, and
`launch::share`, in that order.

**Can anyone withdraw the migrated liquidity?** No. The vault holds the position under the venue's
key with no removal path, and the Cetus migration position is also burned through Cetus LP Burn.

**Who can migrate a graduated launch?** Anyone, with no deadline, by calling the venue's `migrate`.
The PTB that makes the final buy can migrate in the same transaction.

**Why do Cetus calls take `CoinA` and `CoinB`?** Cetus orders a pool's coins by type name, so the
pool's types may be `Pool<Quote, Meme>`. The venue proves the pair matches the launch and retypes
balances between the two orders.

**Who receives the migration residuals?** Blast: they are paid to the `Treasury`, or held in the
vault for the partner payout when the launch named a partner.

**How often should LP fees be collected?** As often as useful; collection is permissionless and
cheap to retry. Frequent collection also keeps the auto-LP price-move exposure small.

**How does the creator change the LP-fee split?** With the curve-fee cap, call `launch::prove_owner`
and `blast_vault::vault::schedule_fee_split` in one PTB. After 48 hours anyone applies it with the
venue's `settle_and_apply_fee_split`, which first settles fees under the old split.

**Does pausing the launchpad stop collections?** No. The Migrate bit stops migration only; fee
collection never pauses, and buybacks stop only with the vault's admin pause.

**Why might a Cetus migration fail?** Cetus no longer registers the tick spacing, Cetus's
pool-manager role created the pair's pool first, the vault registry does not admit the venue, or the
launchpad's Migrate bit is paused. The launch stays `MigrationReady` in every case.
