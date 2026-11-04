# Deploying the migrators

Use this procedure for a new `blast_fun_migrators` publication. It follows the
launchpad's custody rule ([ADR 0114](../../docs/decisions/0114-launchpad-custody-before-activation.md),
amended by [ADR 0134](../../docs/decisions/0134-delayed-administration-pause-and-table-acl.md)).
Record the result in the format [`deployments/README.md`](../../deployments/README.md)
requires.

**Publish → wrap → verify custody and policy → admit the adapters in the
launchpad → release the launchpad.**

## 1. Prepare and publish

`blast_admin`, `blast_partners` and the launchpad (`blast_fun`) must already be
published, with their `Published.toml` entries committed, so this build links
to the one Blast ACL and the live launchpad. Set `blast_lp_fee_destination` in
`Move.toml` to the approved treasury: it is a build-time named address and the
policy's genesis destination, and publication aborts while it is `0x0`.

Run `node scripts/check_mainnet_abi.mjs` and record its PASS line: it proves the
Cetus CLMM, Cetus LP Burn and Bluefin Spot revisions this package links to. Then
publish from a reviewed commit with the pinned dependencies, as for the
launchpad. The deployer receives the raw `UpgradeCap` and an owned
`blast_fun_migrators::Publication`. **Do not upgrade, restrict, transfer or
destroy the cap before step 2**: `package_admin::wrap` accepts only a
never-upgraded cap, and an upgraded cap can never be sealed.

From the publish effects, record the shared `LpFeePolicy` and `VenueConfig`.

## 2. Wrap

Call `package_admin::wrap(publication, upgrade_cap)` in one transaction. It
consumes the Publication, seals the cap inside a shared `PackageAdmin` and
shares the migrators `PackageVersion`. From its effects verify that:

- the `UpgradeCap` is wrapped, no longer address-owned, at policy compatible
  (`0`), and the Publication is deleted;
- the upgrade notice reads 172,800,000 ms (48 hours);
- `LpFeePolicy` holds `blast_lp_fee_destination`, default shares of 1,500 bps
  each, and a 48-hour notice on the destination, the default shares and the
  per-coin overrides, with no pending proposal.

Record the `PackageAdmin` and `PackageVersion` IDs.

## 3. Configure

Migrators declares no roles of its own: it takes the launchpad's
`blast_fun_domain` roles from the Blast ACL. Change the destination or shares
only through `lp_fee_policy::schedule_*` then `apply_*` with Clock, which wait
the applied 48-hour notice. Migrators has no pause switch, and the genesis
policy is compiled, so there is nothing to release here.

## 4. Admit the adapters in the launchpad

Launches reach this package only through migration witnesses the launchpad has
admitted. With the launchpad's `AdapterAdmin`, schedule and apply the admission
of `<migrators>::cetus::Witness` and `<migrators>::bluefin::Witness` in
`LaunchConfig`, after its notice. The launchpad's `package_admin::unpause`
refuses to release while an admission is pending, so admit before the
launchpad's release ([launchpad DEPLOYING](../launchpad/DEPLOYING.md)).

## 5. Record and upgrade later

Record the publication, source verification, the IDs above, transaction
digests and the ABI check output. For later upgrades, increment both compiled
generation constants, schedule the digest with `UpgradeAdmin`, wait the
snapshotted notice, authorize, upgrade natively and call
`commit_upgrade_and_advance` in the same PTB. A delayed `UpgradeAdmin` action
can instead make the package immutable, which ends venue relinking for good
([ADR 0088](../../docs/decisions/0088-reusable-launch-accounting-and-atomic-migration.md)).
