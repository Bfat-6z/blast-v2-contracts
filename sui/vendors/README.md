# Vendor contracts

One-off Move packages built for a specific partner's custom demands. Each lives in
its own directory here, is published on its own, and depends inward
on the Blast packages it extends; no Blast package imports a vendor package.

A vendor package that creates `blast_presale` sales is a plain venue over
`blast_core` with its own sealed `Venue` witness: it imports no product. Its
`prepare` issues the `blast_core::migration::VenueTicket` that the public
`blast_presale::new` redeems, and its `migrate` redeems the sealed `Migration`
that `blast_presale::migrate` returned earlier in the PTB. Blast's presale
`AdapterAdmin` must admit that witness in the shared `CreationPolicy` before
the package can open a sale. A vendor venue that also creates a `blast_vault`
vault must be admitted in the vault's `VaultRegistry` too
([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md),
[ADR 0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md)).

Keep each package self-contained: its venue interface stubs under `interfaces/`,
its own `scripts/verify.sh`, publish script, and README naming the partner terms
it fixes, its custody, and its deployment order.

| Directory | Purpose |
| --- | --- |
| [`aftermath_dao_presale`](aftermath_dao_presale/README.md) | Presale venue into a 50/50 Aftermath pool behind a 2% DAO-fee pool |
