# Aftermath DAO-pool presale venue

`blast_aftermath_dao_presale` is a one-off partner package: a presale venue over
`blast_core` alone. A `blast_presale` sale prepared through its `prepare`
migrates into a fresh Aftermath weighted pool wrapped in Aftermath's DAO-fee
pool, and the DAO fee reaches the partner treasury. It imports no
product, so a presale upgrade never strands it
([ADR 0104](../../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md),
[ADR 0137](../../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md)).

## Pool terms

Every pool gets the same compiled terms; neither the creator nor the migration
caller chooses them.

- 50/50 weights and flatness zero, Aftermath's uncorrelated weighted-product curve.
- A 2% DAO fee on every swap, deposit, and withdrawal, paid as separate coins
  straight to the `TREASURY` compiled into the module.
- Aftermath's minimum 0.01% base swap-in fee, which it requires and which
  compounds into the locked LP, and no swap-out, deposit, or withdrawal fee.

## Authority and fees

Publication sends the package's only `AdminCap` to the publisher, and
`scripts/publish_immutable.sh` makes the package immutable in the same
transaction, so no one can change how a funded sale migrates. The `AdminCap`'s
one power is preparing sale tokens: `prepare<Lp, SaleToken, Quote, Issuer>`
takes it with the LP coin's `CreatePoolCapV2`, shares a
`PoolCreation<Lp, SaleToken>` holding that cap and the issuer type, and returns
the `VenueTicket` that `blast_presale::new` redeems, so the sale can migrate
only here.

The sale binding has two parts. The `AdminCap` holder pins the issuer at
`prepare` by passing the presale's package witness,
`blast_presale::blast_presale_package::PackageWitness`, as the `Issuer` type
argument (no presale import is needed; primitive, standard-library and
framework types are refused). `migrate` refuses a `Migration` whose terms any
other package sealed, so a hostile package that seals its own hand-off for this
venue cannot consume the reservation or set the pool's price. The presale then
holds one sale per sale token at its derived ID, so the issuer and the
`SaleToken` type together name exactly one sale. The ticket must be consumed in the same PTB, so the
`AdminCap` holder also holds the sale token's `TreasuryCap`. The creator's PTB
sets the sale's terms as for any presale, including its LP-fee split; these
sales have no `blast_vault::vault::Vault`, so the split, Blast's LP-fee rates
and holder-reward rounds never apply. Blast still takes its raise and token
shares when `blast_presale::migrate` runs.

Every migration sends the treasury that pool's DAO-fee `OwnerCap`. With it the
treasury can change its pool's DAO fee, anywhere Aftermath allows from 0% to
100%, or the fee recipient, directly through Aftermath.

## Migration and custody

Aftermath creates a pool only from a `CreatePoolCapV2` minted by a freshly
published LP coin. The partner publishes one per sale token (Aftermath's
`publish-lp-coin` transaction) and passes its cap to `prepare`, which emits
`PoolCreationReserved`. Migration stays permissionless without letting the
caller choose the LP coin. The migration PTB calls `blast_presale::migrate`,
then this package's `migrate` with the returned `Migration` and the sale
token's `PoolCreation`, which:

1. redeems the hand-off with this package's `Venue` and checks that the issuer
   `prepare` pinned sealed its terms, keeping only the sale's ID from them;
2. consumes the `PoolCreation`;
3. creates the pool in Aftermath's coin order and checks it holds every unit;
4. wraps it in a DAO-fee pool paying the treasury 2% and checks both values;
5. shares the DAO-fee pool, the object traders use; and
6. sends the treasury the pool's `OwnerCap`, and sends the LP coin Aftermath
   returned, the complete LP balance, to `0x0`.

No one can sign for `0x0`, so no transaction can use that LP coin: the
liquidity is locked in the pool forever. If Aftermath retires the AMM or
DAO-fee version this package links to, its migrations abort, its sales refund
at their LP deadline, and new sales need a new vendor package. A
`CreatePoolCapV2` for a different LP coin than `Lp` would make Aftermath abort
the migration, so `prepare` must bind the cap its `Lp` coin minted; a sale that
cannot migrate becomes refundable at its LP deadline.

## Deployment order

1. Publish `blast_core` ([deployments](../../../deployments/README.md)); the
   presale may be published before or after this package.
2. Run `scripts/verify.sh` and `node scripts/check_mainnet_abi.mjs`. The ABI
   gate fails on any newer Aftermath revision until it is reviewed.
3. Run `scripts/publish_immutable.sh --preview`, then `--execute`.
4. As Blast's presale `AdapterAdmin`, admit
   `<package>::blast_aftermath_dao_presale::Venue` in the presale's
   `CreationPolicy` and, as `ListingAdmin`, allow the sale's Quote type. The
   venue creates no vault, so it is never listed in the `VaultRegistry`.
5. Before the first sale migrates, prove a mainnet dev-inspect of `migrate` with a
   fresh LP coin for both coin orders: the local stubs prove types, not behavior.

`migrate` takes Aftermath's shared `PoolRegistry`
(`0xfcc774493db2c45c79f688f88d28023a3e7d98e4ee9f48bbf5c7990f651577ae`), the
DAO-fee `Version`
(`0xb4bfb0f917f12ad2a772bea9b4f22431f6f5f9653162c3ae6fae5b99b21392b7`), both as
recorded on 2026-09-02.
