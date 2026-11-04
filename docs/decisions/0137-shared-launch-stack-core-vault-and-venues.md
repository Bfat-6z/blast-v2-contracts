# 0137: Shared launch stack: core, vault, and venues

- Status: proposed
- Date: 2026-11-04
- Owner decision: 2026-11-04, Jose accepted the design below with one exception (D7: each
  product keeps its own Quote allowlist and partner list)
- Supersedes: [0054](0054-v3-dex-migrators-and-locked-lp-fees.md) (one migrators package),
  [0089](0089-migrators-own-post-migration-and-start-launches.md) (migrators own everything after
  migration), [0044](0044-validated-basis-points-unit.md) (a `Bps` per package),
  [0107](0107-partner-cut-of-lp-fees.md) (partner cut rules),
  [0109](0109-vaults-without-a-presale.md) (presale-only standalone vaults),
  [0111](0111-venue-owned-presale-pool-tiers.md) (presale-only tier records),
  [0113](0113-presale-gas-reserve-and-holder-meme-routing.md) (holder Meme routed to the treasury),
  [0116](0116-aftermath-adapter-with-vault-addressed-dao-fees.md) (`FinalizeTicket`),
  and the presale rate model of [0101](0101-presale-protocol-fees.md), which becomes the shared rule
- Amends: [0001](0001-sui-package-and-module-layout.md) and
  [0010](0010-migration-and-venue-adapters.md) (package layout and adapters),
  [0014](0014-typed-creator-cap-and-diagnostic-modules.md) (the event envelope is dropped),
  [0088](0088-reusable-launch-accounting-and-atomic-migration.md) (dependency direction becomes
  symmetric), [0094](0094-one-role-per-administrator-action.md) and
  [0097](0097-one-singleton-acl-with-typed-roles.md) (one product role set, generic package roles),
  [0099](0099-standalone-overflow-presale.md) (presale no longer keeps its own copies),
  [0104](0104-external-presale-migrators-and-vendor-packages.md) (vendors redeem the hand-off),
  [0106](0106-presale-partners.md) (the partner also shares the token fee),
  [0117](0117-presale-versioning-and-activation.md) and
  [0134](0134-delayed-administration-pause-and-table-acl.md) (one generic package administration;
  vault and venue postures)
- Design record: the 2026-11-04 Fable architecture review

## Context

A coin launches in one of two products: the launchpad (`blast_fun`, a bonding curve) or the presale
(`blast_presale`, an escrow sale). Both end the same way. When the sale's target is reached, Blast
and the named recipients are paid, the remaining supply and Quote seed a DEX pool, the LP position is
burnt or locked in a vault, and the vault keeps collecting LP fees for Blast, partners, recipients
and holder rewards.

ADR 0099 forbids presale from importing the launchpad, and the vault and venue adapters live in the
migrators package, which imports the launchpad (ADR 0089). Presale therefore cloned them. The
2026-11-04 review measured about 2,300 to 2,600 near-duplicate production lines across the launch
stack (about 15,200 production lines): two LP vaults, two holder-reward engines, two Merkle verifiers,
two Cetus and two Bluefin adapters, three package-administration and version modules, three governed
treasury destinations, two basis-point units, two fee-split models, and four copies of partner
hold-and-pay. Each copy carries its own tests and its own audit reading, and a Cetus or Bluefin
version bump forces an upgrade of both the migrators (vault, rewards and policy) and the presale
escrow.

The ADR 0134 stack is a fresh lineage that holds no user assets, so layouts, ABIs, events and error
codes may all change. No backwards compatibility is kept.

## Decision

Keep the two sale products separate and move everything they share below both of them. Products and
venues never import each other; they meet through sealed values from a shared core.

### Packages

| Package | Responsibility | Posture |
| --- | --- | --- |
| `blast_admin` | ACL, delayed primitives, and one generic package version, pause-bit and 48-hour upgrade-custody implementation for every upgradeable package | immutable |
| `blast_partners` | partner identity, share terms, and payment | immutable |
| `blast_core` (new) | the shared money vocabulary: basis points, exact apportionment, recipients and the one payout primitive, the fee-split model, the protocol-fee ledger with the partner cut, the one treasury destination, Merkle proofs, the migration hand-off, the owner proof, and the shared product roles | immutable |
| `blast_fun` | the bonding-curve sale; `migrate` returns the hand-off | compatible-upgradeable |
| `blast_presale` | the escrow sale; `migrate` returns the hand-off | compatible-upgradeable |
| `blast_vault` (new) | permanent LP custody for both products: one fee split, Blast's share, the partner hold, holder-reward rounds, auto-LP and buyback balances, owner claims | compatible-upgradeable, slow cadence |
| `blast_venues` (new) | Cetus, Bluefin and Aftermath for both products: pool-creation preparation, hand-off redemption, pool creation and seeding, position locking, fee collection, auto-LP, buyback swaps | compatible-upgradeable, upgraded on venue version bumps |

`blast_fun_migrators` is removed. Each boundary is a real one: `blast_core` against `blast_vault`
separates immutable value types from upgradeable custody, `blast_vault` against `blast_venues`
isolates the volatile external venue dependencies from custody, and the two products keep their
separate custody, lifecycle and upgrade risk (ADR 0099).

Dependencies point inward only. Both products and the vault depend on `blast_core`; the venues depend
on `blast_core` and `blast_vault`; vendor migrators depend on `blast_core` and `blast_presale`. No
product imports the vault or a venue, and no venue imports a product.

### One implementation per money concept

- **Basis points and apportionment.** One `Bps` and one exact largest-remainder apportionment with an
  optional index that rounds up for Blast.
- **Recipients and payout.** One `Recipient` with optional vesting and one pay-or-vest primitive.
  Launch recipients, presale raise and token recipients, and vault address routes all use it.
- **Fee split.** One `FeeSplit` of typed routes (an address, the owner, auto-LP, holder rewards,
  burn) summing to 10,000 basis points under one validation and one apportionment.
- **Protocol fees and partners.** One ledger accrues Blast's fees, splits creator and protocol
  shares, and pays the treasury, holding Blast's part when a partner is bound until anyone pays the
  partner its cut. It is the only Blast caller of `blast_partners` payment.
- **Treasury.** One governed protocol destination replaces the launchpad, migrators and presale
  destinations and the migrators' return of residuals to the treasury administrator.
- **Merkle.** One verifier, with the leaf domain fixed per purpose (holder rewards, presale
  allowlists), not per product.
- **Holder rewards.** One round engine in the vault, paying Meme, Quote or both.
- **Package administration.** One generic version object with pause bits and one generic 48-hour
  upgrade custody in `blast_admin`, typed by each package's marker. Each product keeps only its own
  unpause guard over its own configurations.

### Sealed hand-off and atomic migration

A venue first prepares the coin while its supply is still unminted: it reserves any venue
pool-creation capability against the coin's `TreasuryCap`, records the pool tier, and returns a
non-droppable venue binding sealed by its own witness. The product's `new` checks the binding's venue
against its own delayed migrator allowlist and stores it. The ordering is the same for both products:
the launch ticket lends its `TreasuryCap` for preparation, and its supply recheck at `destroy` still
guarantees the exact supply.

At migration the product runs its own checks and payouts, then returns a non-droppable `Migration`
hand-off carrying the pool's Meme and Quote, the stored venue, and the new vault's terms, sealed by
the product's own witness. Only the stored venue's witness can redeem it. The venue creates the pool
at the price the two balances imply, locks or burns the position, and creates the vault in the same
call, so the transaction completes whole or not at all. A stranger cannot forge a vault that claims
a launch, and an unadmitted venue cannot take a launch's liquidity.

Each product keeps its own creator authority (the launchpad's reassignable curve-fee cap, the
presale's transferable cap). A product proves ownership to the vault with a non-droppable owner proof
sealed by its witness, so the vault imports neither product.

### Authority, posture, events and errors

- The shared product roles (`TreasuryAdmin`, `FeeAdmin`, `ListingAdmin`, `AdapterAdmin`,
  `RewardsAdmin`, `BuybackAdmin`, `CreatorAdmin`, `ClaimSignerAdmin`, `CancelAdmin`) are declared
  once in `blast_core`. Package roles (`UpgradeAdmin`, `PauseAdmin`, `UnpauseAdmin` and the package's
  `CancelAdmin`) are generic over the package marker in `blast_admin`, so each package's grants stay
  separate.
- Products start fully paused and use pause bits create 1, trade or commit 2, migrate 4. The vault
  pauses only administrator operations; collection, owner claims and reward claims never pause. The
  venues have no pause bits: the product's migration bit gates migration, and collection must never
  freeze.
- Every package emits raw events from an `events` module; the launchpad's `Event<T>` envelope is
  dropped. Every package uses a numeric `errors` registry renumbered from zero, with exact-abort
  tests.

### Owner decisions

The owner accepted these behaviour changes on 2026-11-04:

1. **One vault and one fee-split model.** Presale vaults gain owner, auto-LP and burn routes;
   launchpad vaults may name address routes. Holder rewards accrue in both assets and rounds may pay
   either. ADR 0113's routing of holder Meme to the treasury ends.
2. **Blast's LP share** is snapshotted at vault creation and changeable per vault after 48 hours'
   notice, the presale model of ADR 0101. The launchpad's live defaults and per-coin overrides end,
   so Blast can no longer change every vault's share in one proposal.
3. **The partner takes its cut of every Blast fee**, including the presale token fee that ADR 0106
   excluded.
4. **Residuals.** A launch vault's migration residuals go to the treasury at vault creation, with
   the partner cut; a presale's stay claimable by its owner. One residual policy, executed once.
5. **Every venue for every product.** Aftermath, auto-LP and buyback become available to both; each
   product's migrator allowlist decides what it admits.
6. **Launchpad recipients may vest**, like presale recipients.
7. **Rejected: one Quote allowlist and one partner list.** Each product keeps its own Quote allowlist
   and partner acceptance list, so Blast can list a Quote or a partner for one product only.
8. **One product role set** for both products; the same administrator role governs both.
9. **One Merkle leaf domain per purpose**; the backend's manifests change their domain strings.
10. **One auto-LP side algorithm**, the margin-based one; Cetus compounding may differ by up to two
    atoms from today.
11. **No event envelope; numeric error registries everywhere.** On-chain abort messages are lost;
    the SDK maps codes.
12. **Unchanged:** the 2-hour round notice, the 48-hour fee-split notice, and the existing fee
    maximums.

## Alternatives considered

- **Merge the launchpad and the presale into one package.** Rejected: one generation and one upgrade
  for two products with different custody and failure modes (ADR 0099).
- **Presale depends on the migrators package.** Rejected: every migrators entry point takes
  launchpad types, so presale would couple to the launchpad lifecycle and still keep its vault.
- **Move presale's adapters into the migrators.** Rejected: the migrators would import both products
  and still carry two vault and two reward implementations.
- **Put the vault in the venues package.** Rejected: every venue version bump would re-ship custody.
- **Put money primitives in `blast_admin`.** Rejected: the governance package would grow money logic.
- **A generic venue plug-in object.** Rejected, as in ADR 0088: sealed witnesses and one hand-off
  type are enough.
- **Only share the holder-reward engine.** Considered first on 2026-11-04; it removes the largest
  copy but leaves two vaults, two venue layers and four partner payouts.

## Consequences

- Every concept the review found duplicated has one implementation, and the audit reads each money
  concept once. The review estimates the launch stack at about 10,700 production lines (about 27%
  fewer) and its tests at about 27,000 lines (from about 38,600), with more capability in both
  products.
- A Cetus or Bluefin version bump upgrades only `blast_venues`; no escrow or LP custody ships with it.
- A vault bug is fixed once for both products. A `blast_core` bug requires a fresh core and every
  package above it, as an ACL bug does today; the core is small, pure and property-tested, and its
  only shared objects change through delayed proposals.
- Immutable core enums (fee-split destinations, the residual policy) cannot gain variants without a
  new lineage, so their variant sets are chosen now.
- Owner actions on a vault take one extra PTB command (the owner proof); the SDK hides it.
- Each behaviour change above is proven with an old-against-new fixture run before its old code is
  deleted, and each implementation step deletes what it replaces in the same change.
- The SDK, the indexer decoders and the admin console change with the fresh lineage: new package
  IDs, hand-off and owner-proof PTB shapes, one vault and rewards event decoder, and one generic
  package-administration page.

## Implementation order

Each step is one reviewable change that compiles the workspace, passes the style and error-registry
gates and the affected tests, and deletes what it replaces.

1. `blast_admin`: generic package version and package administration.
2. `blast_core`: basis points, apportionment, recipients and payout, fee split and vault terms, the
   protocol-fee ledger, the treasury, Merkle, roles, events and errors.
3. `blast_vault`: the migrators vault and holder rewards ported onto core types, with a one-time
   differential fixture against today's launchpad and presale fee collections.
4. The hand-off and owner proof in both products.
5. `blast_venues`: Cetus and Bluefin from the migrators, Aftermath from presale, one venue math
   module; the migrators package is removed.
6. The Aftermath DAO presale vendor redeems the hand-off.
7. Product slimming: both products adopt the generic version, core roles, numeric errors and raw
   events, and delete their copies.
8. Documentation, integrator references, deployment order, then the SDK, indexer and admin-console
   changes.

Steps 1 and 2 are independent; 3 and 4 need 2; 5 needs 3 and 4; 6 needs 4; 7 needs 1 to 5.

## Verification

- Exact-abort tests for venue mismatch at redemption, an unadmitted binding at creation, and a
  hand-off or owner proof that is not consumed.
- Apportionment properties (sums preserved, the rounded-up index never loses a unit) and the existing
  graduation vectors reproduced on the core primitive.
- Partner-cut vectors equal to today's launchpad and vault outputs.
- Mainnet-fork PTB suites for launchpad, presale and standalone vaults on each venue, including
  preparation before supply leaves the ticket or `TreasuryCap`.
