# Blast presale

`blast_presale` is a standalone Sui package for presales that overflow pro rata or
fill first come up to a hard cap. Its
`UpgradeCap` is held in shared compatible `PackageAdmin` custody after activation, allowing governed logic changes and venue relinks with an atomic version cutover.
It does not import or mutate launchpad state. Its Bluefin, Cetus, and Aftermath
venues live in the same package; the LP vault and its holder-reward rounds are
`blast_vault`'s, and the fee split, hand-off, owner proof, and Merkle verifier are
`blast_core`'s ([ADR 0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md)).

A creator prepares the coin on a venue, whose `prepare` borrows the zero-supply
`TreasuryCap<SaleToken>`, records the pool tier, and returns a sealed
`blast_core::migration::VenueTicket`. `blast_presale::new` redeems the ticket and
returns a `PresaleInitializer`; the creator sets its terms on it, and `finalize`
checks them together and mints the supply with its matching
`Currency<SaleToken>` ([ADR 0110](../../docs/decisions/0110-presale-initializer-and-early-close.md)).
The currency must be confirmed unregulated; regulated coins and legacy coins
whose regulatory status is unknown cannot create a presale.
The terms are token supply; presale, LP, and per-recipient
allocation BPS; fixed or burn-only supply; Quote raise; commitment and migration
windows (the migration window is at least seven days); `EligibilityPolicy`;
migration venue, fixed by the ticket (Cetus and Bluefin record a pool tier in
`VenueConfig`, not in the sale; Aftermath records its DAO fee as the tier and keeps
the pool-creation capability of a fresh LP coin there for the sale's migration); and
the vault's starting `blast_core::fee_split::FeeSplit`: up to 20 routes to
addresses, the owner, auto-LP, holder rewards, or burn, whose BPS total 10,000.
Allocation BPS must total 10,000. The contract mints the complete
supply once and uses largest-remainder apportionment so every atomic unit belongs
to exactly one allocation. Eligibility is either an open policy (wallet cap,
participant bound, and a minimum commitment whose product with the bound must
reach the raise) or a Merkle allowlist whose leaves carry per-wallet caps.

An optional uncapped phase lifts wallet caps partway through the window, either
for eligible wallets or for anyone. An optional hard cap, from the start or from
a later point in the window, holds commitments to the raise first come, first
served, returning any excess Quote immediately; before it the sale overflows
pro rata. A sale whose hard cap closes it when filled may be settled by anyone as
soon as its raise is full, and its LP deadline then counts from that close;
otherwise every sale runs its full window. A phase open to
anyone must reach the raise at its minimum over the slots held to that minimum:
all of them under an open policy, and only those beyond the allowlist's leaves
under an allowlist, since allowlisted wallets may commit any positive amount.
Part of the raise can also be allocated to recipients in BPS; the LP seeds with
the rest. Any token or raise recipient share may vest: its cliff, step period,
and step count are fixed at creation, and migration locks it in an irrevocable
[`blast_fun_vesting`](../vesting/README.md)
linear schedule that starts at migration instead of paying it out. Fee shares
cannot vest. Participant tokens may vest too, under terms fixed at creation:
each claim then locks the participant's tokens in its own irrevocable schedule
that starts at that claim, while its Quote refund is paid at once.

Blast's shared `FeePolicy` sets its shares of the raise, the token supply, and
collected LP fees; each sale snapshots them at creation, and every rate can be zero.
Raise and token payouts go to the policy's current destination; LP fees go to the
core `Treasury`. Until a sale's window starts,
including in its creation transaction before `share`, Blast's `FeeAdmin` can change
all four of its rates with `blast_presale::set_protocol_fees`; Blast's token
difference moves to or from the buyers' sale allocation and its raise difference to or from the LP's Quote. After
migration Blast's LP-fee share is the vault's own setting, which Blast can change
per vault after a fixed 48-hour notice. Blast's token share counts
toward the 10,000 allocation BPS, and its raise share is apportioned with the raise
recipients'. Nothing is charged at creation, on commitment, on refund, or if a
sale does not migrate.

A sale may name one Blast partner, which the creator sets with `set_partner` on
the initializer before `finalize`; it never changes afterward. The partner earns its
`blast_partners` cut of Blast's raise fee and, after migration, of Blast's LP
fees; never of Blast's token fee. A partnered sale's migration holds Blast's
fees, and anyone may then call `pay_protocol_fees_with_partner` once to pay the
partner its cut and Blast the rest
([ADR 0106](../../docs/decisions/0106-presale-partners.md)). Its vault inherits
the partner and holds Blast's LP fees at each collection, until anyone calls
`blast_vault::vault::pay_protocol_fees_with_partner` (ADR 0137).

Blast's shared `CreationPolicy` lists the Quote types, venue witnesses,
and Blast partners new presales may use; creation aborts for anything unlisted. It is checked only at
creation, so delisting a type never affects a live sale. `blast_presale::new`,
`finalize`, and `migrate` are public, so a venue in another package, such as a partner's under
[`sui/vendors`](../vendors/README.md), issues the ticket `new` redeems and redeems the
hand-off `migrate` returns with its own sealed witness, once Blast's `AdapterAdmin` admits
it; a primitive or vector, which anyone can construct, is never admitted
([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md)).

Sharing a sale fixes its windows from a start time, which may be ahead of the
share so a sale can be published a day early; commitments open at the start.

Every accepted commitment is locked in the presale's Quote custody. Participants cannot
withdraw while a sale is open or funded. Underfunded sales, and funded sales
cancelled after the LP deadline, refund every commitment; successfully migrated
sales refund only overflow. One common fill rate applies to every wallet.

Anyone may call the configured Bluefin, Cetus, or Aftermath migration at any time until the
sale is cancelled. From the LP deadline onward, anyone may instead cancel an
unmigrated funded sale; whichever transaction lands first wins. The LP window is
at least seven days, so a funded sale reaches that exit only after a week in
which nobody migrated it. Migration
atomically pays Blast its raise and token fees, or holds them for
`pay_protocol_fees_with_partner` when the sale names a partner, takes the rest of
the raise and
the LP allocation, and hands them to the stored venue in a sealed `Migration`. The
venue creates the pool and locks the position, burn proof, or Aftermath DAO-fee owner
cap in a new shared `blast_vault::vault::Vault`, which the vault's `VaultRegistry`
must admit the venue to create (the Aftermath LP coin goes to `0x0`); a DEX failure
rolls back the presale transition. An Aftermath pool pays
its DAO fee as coins sent to the vault's address, which anyone receives into the
vault through `aftermath::collect_fees` (ADR 0116). Configured recipients receive their
distinct allocations in that same transaction. Claims open only after success.

Permissionless fee collection pays Blast its share of each asset at the vault's
current rate, or holds it for a partnered sale's partner payout, then applies the vault's
active split to the rest: address routes are paid in the same transaction, and the owner,
auto-LP, holder-reward and burn shares accrue in the vault. Presale venues do not yet add
auto-LP or buy back, so those balances only accrue. The vault's holder-reward rounds
(`blast_vault::holder_rewards`, under the shared `blast_core::blast_domain` roles) are
funded from the holder-reward share, each with a claim deadline after which anyone can
return its unclaimed rewards to the vault. The `PresaleCap` proves ownership to the vault
through `prove_owner`, whose owner claim pays the migration residuals and owner-route fees;
the cap can be destroyed after cancellation. Anyone may relay participant or reward claims,
but payment always goes to the committed beneficiary. Allowlists and holder rewards share
`blast_core::merkle`, each with its own leaf domain. No venue collects venue incentive
rewards credited to the position.

After minting, the contract consumes the matching TreasuryCap into Coin Registry
`Fixed` or `BurnOnly` state. No mint authority remains after the presale is
created. On cancellation participant Quote is refundable, but every SaleToken
allocation remains permanently locked in the presale and the supply mode cannot
be reversed.

Run `scripts/verify.sh`. Publish to mainnet with `scripts/publish.sh --preview`,
repeat with `--execute`, then seal custody with
`scripts/wrap_package_admin.sh <package-id> <publication-id> <upgrade-cap-id> --preview` and
`--execute` before creating any presale. The package mints no administrator
capability: Blast administers it through the one shared Blast ACL
(`blast_admin`, [ADR 0097](../../docs/decisions/0097-one-singleton-acl-with-typed-roles.md)),
which it already links through `blast_partners`. `blast_presale_domain` declares
roles: `FeeAdmin` sets Blast's rates and the partners new sales may name,
`TreasuryAdmin` governs the raise and token fee destination,
and `ListingAdmin` and `AdapterAdmin` admit Quote types and venues for new sales. `UpgradeAdmin` authorizes
compatible upgrades and atomic version cutovers. Holder-reward rounds and per-vault Blast
shares belong to the vault, under the shared `blast_core::blast_domain` roles.
[DEPLOYING.md](DEPLOYING.md) gives the complete order: custody verification, ordinary ACL configuration at zero delay,
enabling each operation’s intended notice, then immediate UnpauseAdmin release. No presale can exist
under an unsealed cap or before unpause.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md);
Blast's fees are proposed in [ADR 0101](../../docs/decisions/0101-presale-protocol-fees.md)
and its presale partners in [ADR 0106](../../docs/decisions/0106-presale-partners.md);
creation through the initializer, the sale-level hard cap, and early close are proposed in
[ADR 0110](../../docs/decisions/0110-presale-initializer-and-early-close.md).

Presale activation and operational versioning follow launchpad: publication transfers
`blast_presale_package::Publication`, and wrapping it with the matching fresh cap
shares PackageVersion fully paused while publication-owned operations have zero notice. Ordinary ACL
operations configure initial policy; settle setup proposals and enable each operation’s intended
notice before release. Later delay changes wait the old policy, and existing
pending actions keep their deadlines. See

[ADR 0117](../../docs/decisions/0117-presale-versioning-and-activation.md). This
source requires fresh publication; existing dependency-only releases stay unchanged.

The migrated sale's exact `PresaleCap` holder schedules or cancels a new split on
the vault with an owner proof from `prove_owner` (`blast_vault::vault::schedule_fee_split`
/ `cancel_fee_split`). The notice is a fixed 48 hours. Expiry alone retains the old
split. Anyone applies a ready stored proposal through Bluefin or Cetus
`settle_and_apply_fee_split`, collecting position fees under the old split first.
Aftermath `apply_fee_split` retains collection-time accounting: separate DAO-fee coins
use the applied split when received, even if sent before activation. This source has no
vault without a sale; ADR 0137's shared venues restore it.
