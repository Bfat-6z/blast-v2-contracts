# Blast presale

`blast_presale` is a standalone Sui package for presales that overflow pro rata or
fill first come up to a hard cap. Its `UpgradeCap` is held in the shared generic
`blast_admin::package_admin::PackageAdmin<BLAST_PRESALE_PACKAGE>` after activation, allowing
governed logic changes with an atomic version cutover. It depends on `blast_admin`,
`blast_partners` and `blast_core` only: it imports no launchpad, venue or vault. The Cetus and
Bluefin venues are `blast_migrators`'s, the LP vault and its holder-reward rounds are
`blast_vault`'s, and the fee split, payouts and vesting, protocol-fee ledger, treasury, hand-off,
owner proof, and Merkle verifier are `blast_core`'s
([ADR 0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md)).

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
migration venue, fixed by the ticket (the venue keeps its pool terms, not the sale); and
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
the rest. Each recipient is a `blast_core::payout::Recipient`, paid outright or
vested: its cliff, step period, and step count are fixed at creation, and migration
locks it through `blast_core::payout::pay_or_vest` in an irrevocable
[`blast_fun_vesting`](../vesting/README.md) linear schedule that starts at migration
instead of paying it out. Fee shares cannot vest. Participant tokens may vest too, under terms fixed at creation:
each claim then locks the participant's tokens in its own irrevocable schedule
that starts at that claim, while its Quote refund is paid at once.

Blast's shared `FeePolicy` sets its shares of the raise, the token supply, and
collected LP fees; each sale snapshots them at creation, and every rate can be zero.
Raise and token fees move into the sale's `blast_core::protocol_fees::Ledger` at
migration and are paid to the core `Treasury`, as are LP fees. Until a sale's window starts,
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
`blast_partners` cut of every Blast fee: the raise and token fees and, after
migration, Blast's LP fees (ADR 0137, amending
[ADR 0106](../../docs/decisions/0106-presale-partners.md)). A partnered sale's
migration holds Blast's fees in its ledger, and anyone may then call
`pay_protocol_fees_with_partner` to pay the partner its cut and Blast the rest. Its vault inherits
the partner and holds Blast's LP fees at each collection, until anyone calls
`blast_vault::vault::pay_protocol_fees_with_partner` (ADR 0137).

Blast's shared `CreationPolicy` lists the Quote types, venue witnesses,
and Blast partners (a `blast_partners::partner_list::PartnerList`) new presales may use; creation aborts for anything unlisted. It is checked only at
creation, so delisting a type never affects a live sale. `blast_presale::new`,
`finalize`, and `migrate` are public, so a venue in another package, `blast_migrators` or a
partner's under [`sui/vendors`](../vendors/README.md), issues the ticket `new` redeems and redeems the
hand-off `migrate` returns with its own sealed witness, once Blast's `AdapterAdmin` admits
it; a primitive or vector, which anyone can construct, is never admitted
([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md)).

Sharing a sale fixes its windows from a start time, which may be ahead of the
share so a sale can be published a day early; commitments open at the start.

Every accepted commitment is locked in the presale's Quote custody. Participants cannot
withdraw while a sale is open or funded. Underfunded sales, and funded sales
cancelled after the LP deadline, refund every commitment; successfully migrated
sales refund only overflow. One common fill rate applies to every wallet.

Anyone may migrate a funded sale at any time until it is cancelled: one PTB calls
`blast_presale::migrate`, then the stored venue's `migrate` with the `Migration` it
returns. From the LP deadline onward, anyone may instead cancel an unmigrated funded
sale; whichever transaction lands first wins. The LP window is at least seven days, so
a funded sale reaches that exit only after a week in which nobody migrated it.
Migration atomically pays Blast its raise and token fees, or holds them for
`pay_protocol_fees_with_partner` when the sale names a partner, pays the configured
recipients, and hands the rest of the raise and the LP allocation to the stored venue
in a sealed `Migration`. The venue creates the pool and locks the position in a new
shared `blast_vault::vault::Vault`; a venue failure rolls back the presale transition.
Claims open only after success.

Fee collection, the vault's fee split, holder-reward rounds and owner claims are the
venue's and the vault's. The `PresaleCap` proves ownership to the vault through
`prove_owner`, whose owner claim pays the migration residuals and owner-route fees; the
cap can be destroyed after cancellation. Anyone may relay participant claims, but payment
always goes to the committed beneficiary. Allowlists use `blast_core::merkle` with the
presale's own leaf domain.

After minting, the contract consumes the matching TreasuryCap into Coin Registry
`Fixed` or `BurnOnly` state. No mint authority remains after the presale is
created. On cancellation participant Quote is refundable, but every SaleToken
allocation remains permanently locked in the presale and the supply mode cannot
be reversed.

Run `scripts/verify.sh`. Publish to mainnet with `scripts/publish.sh --preview`,
repeat with `--execute`, then seal custody with
`scripts/wrap_package_admin.sh <admin-package-id> <package-id> <publication-id> <upgrade-cap-id> --preview`
and `--execute` before creating any presale. The package mints no administrator
capability and keeps no administration of its own: Blast administers it through the one
shared Blast ACL (`blast_admin`,
[ADR 0097](../../docs/decisions/0097-one-singleton-acl-with-typed-roles.md)) and its
generic package objects. Product roles are `blast_core::blast_domain`'s, shared with the
launchpad and the vault: `FeeAdmin` sets Blast's rates and the partners new sales may
name, `ListingAdmin` and `AdapterAdmin` admit Quote types and venues for new sales, and
`TreasuryAdmin` governs the core treasury. Package roles are
`blast_admin::package_admin`'s `PauseAdmin`, `UnpauseAdmin`, `UpgradeAdmin` and
`CancelAdmin` over `BLAST_PRESALE_PACKAGE`. [DEPLOYING.md](DEPLOYING.md) gives the
complete order: custody verification, ordinary ACL configuration at zero delay,
enabling each operation's intended notice, then `creation_policy::unpause`. No presale
can exist under an unsealed cap or before unpause.

The accepted design is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md);
Blast's fees are proposed in [ADR 0101](../../docs/decisions/0101-presale-protocol-fees.md)
and its presale partners in [ADR 0106](../../docs/decisions/0106-presale-partners.md);
creation through the initializer, the sale-level hard cap, and early close are proposed in
[ADR 0110](../../docs/decisions/0110-presale-initializer-and-early-close.md); activation
follows [ADR 0117](../../docs/decisions/0117-presale-versioning-and-activation.md) on the
generic administration of ADR 0137. This source requires fresh publication.

The migrated sale's exact `PresaleCap` holder schedules or cancels a new split on the
vault with an owner proof from `prove_owner` (`blast_vault::vault::schedule_fee_split` /
`cancel_fee_split`). The notice is a fixed 48 hours; the venue applies a ready split.
