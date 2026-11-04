# Deploying the migrators

Use this procedure for a new `blast_fun_migrators` publication. It follows the
launchpad's custody rule ([ADR 0114](../../docs/decisions/0114-launchpad-custody-before-activation.md),
amended by [ADR 0134](../../docs/decisions/0134-delayed-administration-pause-and-table-acl.md))
and the shared launch stack of
[ADR 0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md).
Record the result in the format [`deployments/README.md`](../../deployments/README.md)
requires.

**Publish → wrap → verify custody → admit the venues in the launchpad and the
vault → release the launchpad and the vault.**

## 1. Prepare and publish

`blast_admin`, `blast_partners`, `blast_core`, the launchpad (`blast_fun`) and
`blast_vault` must already be published, with their `Published.toml` entries
committed, so this build links to the one Blast ACL, the core `Treasury`, the
live launchpad and the vault. The vault must also be wrapped, so its shared
`PackageVersion` and `VaultRegistry` exist; it stays paused until step 4. This
package compiles no treasury address: Blast's LP fees and launch residuals go
to the core `Treasury`.

Run `node scripts/check_mainnet_abi.mjs` and record its PASS line: it proves the
Cetus CLMM, Cetus LP Burn and Bluefin Spot revisions this package links to. Then
publish from a reviewed commit with the pinned dependencies, as for the
launchpad. The deployer receives the raw `UpgradeCap` and an owned
`blast_fun_migrators::Publication`. **Do not upgrade, restrict, transfer or
destroy the cap before step 2**: `package_admin::wrap` accepts only a
never-upgraded cap, and an upgraded cap can never be sealed.

From the publish effects, record the shared `VenueConfig`.

## 2. Wrap

Call `package_admin::wrap(publication, upgrade_cap)` in one transaction. It
consumes the Publication, seals the cap inside a shared `PackageAdmin` and
shares the migrators `PackageVersion`. From its effects verify that:

- the `UpgradeCap` is wrapped, no longer address-owned, at policy compatible
  (`0`), and the Publication is deleted;
- the upgrade notice reads 172,800,000 ms (48 hours).

Record the `PackageAdmin` and `PackageVersion` IDs.

## 3. Configure

Migrators declares no roles and holds no policy: package upgrades take the
launchpad's `blast_fun_domain` roles, and buybacks the shared
`blast_core::blast_domain::BuybackAdmin`. Blast's LP share for new launches is
the launchpad's delayed `ProtocolLpFees` in `LaunchConfig`
([launchpad DEPLOYING](../launchpad/DEPLOYING.md)). Migrators has no pause
switch, so there is nothing to release here.

## 4. Admit the venues

The venue witnesses are `<migrators>::cetus::Venue` and
`<migrators>::bluefin::Venue`. Each must be admitted twice:

1. **Launchpad.** With the launchpad's `AdapterAdmin`, schedule
   `launch_config::schedule_venue<Venue>` for each witness and apply it with
   `launch_config::apply_venue` after its notice. `launch::new` rejects a ticket
   from any other venue. The launchpad's `package_admin::unpause` refuses to
   release while an admission is pending, so admit before the launchpad's
   release ([launchpad DEPLOYING](../launchpad/DEPLOYING.md)).
2. **Vault.** With the core `blast_domain::AdapterAdmin`, schedule
   `blast_vault_package::schedule_witness<Witness>` on the `VaultRegistry` for
   each venue witness and for the launchpad's `blast_fun::launch::PackageWitness`
   (the issuer of every launch's vault terms), and apply each with
   `blast_vault_package::apply_witness`; without them, migration aborts in
   `blast_vault::vault::new`. Removing a venue or the launchpad from the list
   strands every graduated launch that depends on it until it is listed again;
   reserve that for a witness found unsafe. The vault publishes fully
   paused with a zero admission notice and admissions ignore the pause, so admit
   every venue that should start admitted, the presale venues included
   ([presale DEPLOYING](../presale/DEPLOYING.md)), then schedule and apply a
   172,800,000 ms (48-hour) notice with `schedule_witness_delay` and
   `apply_witness_delay`. Only then does `blast_vault_package::unpause` (signed in
   as `UnpauseAdmin<BLAST_VAULT_PACKAGE>`) release the vault: it refuses while
   the notice is zero, a pending change would set it to zero, or an admission is
   pending. A venue admitted later waits the 48-hour notice.

## 5. Record and upgrade later

Record the publication, source verification, the IDs above, transaction
digests and the ABI check output. For later upgrades, increment both compiled
generation constants, schedule the digest with `UpgradeAdmin`, wait the
snapshotted notice, authorize, upgrade natively and call
`commit_upgrade_and_advance` in the same PTB. A delayed `UpgradeAdmin` action
can instead make the package immutable, which ends venue relinking for good
([ADR 0088](../../docs/decisions/0088-reusable-launch-accounting-and-atomic-migration.md)).
