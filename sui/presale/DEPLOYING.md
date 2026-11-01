# Deploying Blast presale

Use this runbook for a new `blast_presale` deployment. Record the normalized result
in the format required by [`deployments/README.md`](../../../deployments/README.md).
Publication alone cannot activate presales. The publisher receives an owned Bootstrap;
only wrapping it with the matching fresh UpgradeCap shares PackageVersion.
Initial policy setters borrow Bootstrap; routine mutations and sale creation
require that shared version (ADR 0117, amended by ADR 0134). Wrap starts fully
paused; immediate UnpauseAdmin release enables sales.

1. Retire the previous generation's link when a release changes presale logic.
   The live package, recorded in
   `deployments/sui/mainnet/2026-10-20-blast-presale-unregulated.json`, is sealed
   dependency-only and can never gain new logic, so such a release is a new
   publication, not an upgrade
   ([ADR 0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md)).
   Its record stays. Delete its
   `[published.mainnet]` entry from `Published.toml` before publishing, so this
   build publishes a new package rather than resolving to the old one, and commit
   the entry the new publication writes: vendor packages link to it.
2. `blast_admin` and `blast_partners` must already be published, with their
   `Published.toml` entries committed, so this build links to the one Blast ACL
   and the partner registry (see the partners
   [README](../partners/README.md)). Run the complete `scripts/verify.sh` gate,
   then `scripts/publish.sh --preview`
   and `--execute`, which publish to mainnet. The sender receives the raw `UpgradeCap` and owned `blast_presale_package::Bootstrap`; the
   package mints no administrator capability. Do not upgrade the package before custody finalization:
   `package_admin::wrap` accepts only a never-upgraded cap, and a cap upgraded
   first can never be sealed.
3. Borrow Bootstrap for `fee_policy::bootstrap` to set the nonzero destination
   and initial four fee rates. Admit every initial Quote and reviewed adapter
   with `creation_policy::bootstrap_quote<Quote>` and
   `creation_policy::bootstrap_migration_witness<Witness>`, passing `true`.
   Zero fees are legal defaults. Both allowlists must be nonempty; validate
   each adapter's dependency and venue evidence before admitting it. Initial
   setup may span transactions and emits the normal applied-value events.
   These calls need no Clock or ACL witness. Read back the chosen policy.
   Then seal custody with `scripts/wrap_package_admin.sh <package-id> <bootstrap-id>
   <upgrade-cap-id> <creation-policy-id> --preview` and `--execute`.
4. From the effects of step 3, verify that `PackageAdmin` is shared and that the
   `UpgradeCap` is wrapped inside it, no longer address-owned, with its policy
   unchanged at compatible (`0`). Record the newly shared `PackageVersion` from
   these finalization effects; its initial pause mask must be 11. Bootstrap
   must be deleted and never available again. From the publish effects, record the
   shared `FeePolicy`, `CreationPolicy`, and `VenueConfig` singletons.
5. With the Blast ACL's `SuperAdminCap`, grant the presale roles
   (`blast_acl::grant_role` with each `blast_presale_domain` type) to the
   operations multisig's `AdminCap`, minting one with `blast_acl::grant_admin`
   if needed. Grant each concern deliberately: `TreasuryAdmin` redirects Blast's
   fee payouts; `FeeAdmin` sets the rates of every future sale, of a sale before
   its start, and Blast's LP-fee rates on every vault, and chooses the Blast
   partners new sales may name; `ListingAdmin` allows Quote types;
   `AdapterAdmin` allows migrators, each of which receives the liquidity of the
   sales it creates; `RewardsAdmin` directs every vault's holder-reward share;
   and `UpgradeAdmin` authorizes compatible upgrades with atomic generation cutover. Each call signs in
   with `blast_acl::sign_in` in the same PTB. The root revokes a role or an
   administrator at once if a cap is lost or compromised.
6. Grant `UnpauseAdmin`, sign in through the real ACL and call
   `blast_presale_package::unpause` with the shared mutable PackageVersion and
   selected bits (all = 11). This release is immediate and takes no Clock.
   No presale can start before it. Later governed fee, destination and adapter
   admission changes use their full 48-hour schedule/apply flow, even while paused.
7. Before admitting Aftermath during bootstrap or through later administration,
   run `sui/vendors/aftermath_dao_presale`'s `node scripts/check_mainnet_abi.mjs`,
   which pins the Aftermath AMM and DAO-fee revisions this package links to.
   Prove a mainnet dev-inspect of `aftermath::migrate` with a fresh LP coin for
   both coin orders: the local stubs prove types, not behavior. Allow
   only Quote types whose deny-list and pause controls Blast accepts (owner,
   2026-10-02): payouts are pushed, so a denied fee recipient blocks that vault's
   collection and a denied raise recipient blocks migration until the LP deadline.
   Create sale coins through Coin Registry without regulation. Finalization
   enforces confirmed `Unregulated` status and rejects legacy `Unknown` status,
   which can conceal an existing deny cap. Accept each presale partner deal, once it is registered
   in `blast_partners`, as `FeeAdmin` with `creation_policy::add_partner`.
8. Operate a keeper that calls `settle` and the venue's `migrate` in one PTB as
   soon as a sale's `end_ms` passes, followed by
   `blast_presale::pay_protocol_fees_with_partner` for a sale that names a
   partner, which pays the partner and Blast the fees its migration held. The seven-day LP-window floor keeps a
   successful raise from being settled and cancelled in one transaction, but a
   funded sale still reaches its refund exit after a week without migration. For
   Bluefin, pass a `Coin<SUI>` equal to `config::get_pool_creation_fee_amount<SUI>`
   read at submission time; Bluefin aborts on any other amount. For Cetus, the
   Quote must be in Cetus's permission-pair allowlist at the sale's tick spacing
   when the sale is created. For Aftermath, pass the sale's shared
   `aftermath::PoolCreation` by value; its DAO fees then wait as coins at the
   vault's address until a keeper lists them in `aftermath::collect_fees`.
9. Record publication, source verification, object IDs, transaction digests, each
   presale role granted with its `AdminCap` and holder, and the checks above.

The package behavior and exact callable signatures live in source. The design
rationale is [ADR 0099](../../docs/decisions/0099-standalone-overflow-presale.md)
with its amendments [0101](../../docs/decisions/0101-presale-protocol-fees.md),
[0102](../../docs/decisions/0102-presale-creation-allowlists.md),
[0104](../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md),
and [0106](../../docs/decisions/0106-presale-partners.md).

For later governed upgrades, increment both compiled generation constants. Authorize
the digest with UpgradeAdmin, execute the native upgrade, and call
`commit_upgrade_and_advance` with the receipt and mutable PackageVersion in the
same PTB. Refresh SDK package IDs while retaining the original type identity and
shared objects. Never advance a version separately from the native commit.
