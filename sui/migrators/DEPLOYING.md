# Deploying the migrators

Use this procedure for a new `blast_migrators` publication. It follows the
custody rule of [ADR 0114](../../docs/decisions/0114-launchpad-custody-before-activation.md),
amended by [ADR 0134](../../docs/decisions/0134-delayed-administration-pause-and-table-acl.md),
and the shared launch stack of
[ADR 0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md).
Record the result in the format [`deployments/README.md`](../../deployments/README.md)
requires.

**Publish → wrap → verify custody → admit the venues in each product and the
vault → release the products and the vault.**

## 1. Prepare and publish

`blast_admin`, `blast_partners`, `blast_core` and `blast_vault` must already be
published, with their `Published.toml` entries committed, so this build links
to the one Blast ACL, the core `Treasury` and the vault. The vault must also be
wrapped, so its shared `PackageVersion` and `VaultRegistry` exist; it stays
paused until step 4. The products are not dependencies: they may be published
before or after this package. This package compiles no treasury address:
Blast's LP fees and migration residuals go to the core `Treasury`.

Run `node scripts/check_mainnet_abi.mjs` and record its PASS line: it proves the
Cetus CLMM, Cetus LP Burn and Bluefin Spot revisions this package links to. Then
publish from a reviewed commit with the pinned dependencies. The deployer
receives the raw `UpgradeCap` and an owned
`blast_admin::package_version::Publication<BLAST_MIGRATORS>`. **Do not upgrade,
restrict, transfer or destroy the cap before step 2**: `package_admin::wrap`
accepts only a never-upgraded cap, and an upgraded cap can never be sealed.

From the publish effects, record the shared `VenueConfig`.

## 2. Wrap

Call `blast_admin::package_admin::wrap<BLAST_MIGRATORS>(publication,
upgrade_cap)` in one transaction. It consumes the Publication, seals the cap
inside a shared `PackageAdmin<BLAST_MIGRATORS>` and shares
`PackageVersion<BLAST_MIGRATORS>`. From its effects verify that:

- the `UpgradeCap` is wrapped, no longer address-owned, at policy compatible
  (`0`), and the Publication is deleted;
- the version defines no pause bits and nothing is paused;
- the upgrade notice reads 172,800,000 ms (48 hours).

Record the `PackageAdmin` and `PackageVersion` IDs.

## 3. Configure

Migrators holds no policy and defines no pause bits, so there is nothing to
release here. That is a residual risk to accept at deployment: the package has no
emergency stop of its own. Migration stops with each product's migration pause
bit and `buyback_and_burn` with the vault's admin bit, but `prepare`,
`collect_fees` and `settle_and_apply_fee_split` can be stopped only by advancing
this package's version through a delayed upgrade, which retires every call
to the old bytecode after the upgrade notice. Package upgrades take `blast_admin::package_admin`'s
`UpgradeAdmin<BLAST_MIGRATORS>` and `CancelAdmin<BLAST_MIGRATORS>` roles, and
buybacks the shared `blast_core::blast_domain::BuybackAdmin`. Blast's LP share
for new sales is each product's own LP-fee policy, sealed into the `Migration`.

## 4. Admit the venues

The venue witnesses are `<migrators>::cetus::Venue` and
`<migrators>::bluefin::Venue`. Each must be admitted in each product that should
offer it, and in the vault:

1. **Products.** With each product's `AdapterAdmin`, schedule the venue in its
   venue list (the launchpad's `launch_config`, the presale's
   `creation_policy`) and apply it after its notice, before that product's
   release ([launchpad DEPLOYING](../launchpad/DEPLOYING.md),
   [presale DEPLOYING](../presale/DEPLOYING.md)). A product's `new` rejects a
   ticket from any other venue.
2. **Vault.** With the core `blast_domain::AdapterAdmin`, schedule
   `blast_vault_package::schedule_witness<Witness>` on the `VaultRegistry` for
   each venue witness and for each product's `PackageWitness` (the issuer of
   its sales' vault terms), and apply each with
   `blast_vault_package::apply_witness`; without them, migration aborts in
   `blast_vault::vault::new`. Removing a venue or a product from the list
   strands every sale that depends on it until it is listed again; reserve that
   for a witness found unsafe. The vault publishes fully paused with a zero
   admission notice and admissions ignore the pause, so admit every witness
   that should start admitted, then schedule and apply a 172,800,000 ms
   (48-hour) notice with `schedule_witness_delay` and `apply_witness_delay`.
   Only then does `blast_vault_package::unpause` (signed in as
   `UnpauseAdmin<BLAST_VAULT_PACKAGE>`) release the vault. A venue admitted
   later waits the 48-hour notice.

## 5. Record and upgrade later

Record the publication, source verification, the IDs above, transaction
digests and the ABI check output. For later upgrades, increment
`constants::version`, schedule the digest with
`UpgradeAdmin<BLAST_MIGRATORS>`, wait the applied notice, authorize, upgrade
natively and call `package_admin::commit_upgrade_and_advance` in the same PTB.
A vault upgrade requires a dependency-only relink of this package in the same
release window, because the venues call version-gated vault functions; script
both as one step. A delayed `UpgradeAdmin` action can instead make the package
immutable, which ends venue relinking for good
([ADR 0088](../../docs/decisions/0088-reusable-launch-accounting-and-atomic-migration.md)).
