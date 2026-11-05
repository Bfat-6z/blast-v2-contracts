# 0138: Sealed treasury caps and venue admissions

- Status: proposed
- Date: 2026-11-05
- Owner decision: 2026-11-05, Jose asked for the `TreasuryCap` wrapped so that only venues reach it,
  for the launchpad and the presale alike
- Amends: [0137](0137-shared-launch-stack-core-vault-and-venues.md) (the sealed hand-off
  paragraph: the cap no longer travels raw beside the launch ticket) and
  [0108](0108-standalone-coin-template.md) (a `coin_template` coin can no longer start a presale)
- Design record: EasonC13's review of 8c04789d (H-1) and the fork evidence in contracts PR #219

## Context

ADR 0137 ordered a sale's creation as: publish the coin, prepare it on a venue, start the sale.
The venue's `prepare` borrows the coin's `TreasuryCap` (Cetus mints its `PoolCreationCap` from it),
and a programmable transaction cannot pass a reference one call returns into another, so the
launch ticket template handed the creator the raw cap beside the `LaunchTicket`, as a presale
creator already held it from the standalone coin template.

EasonC13's review (H-1) showed the gap: between publication and `prepare`, the cap holder can mint
Meme and create the pair's Cetus pool first; `prepare` cannot detect it, because the pinned Cetus
v15 bytecode has no non-aborting pool-existence read, and migration never adopts a pool, so the
launch would strand `MigrationReady`. The fork run in PR #219 pinned what Cetus does: a seed range
beside the initial price is refused, so a stranger with no Meme cannot open the pool and the window
belongs to the cap holder alone; Cetus keeps one pool per pair and spacing; and a plain unwind of
the seed leaves one atom of each coin in the pool, so the products' exact-supply checks refuse the
sale afterwards. That guard rests on Cetus rounding, not on a Blast rule.

## Decision

Seal the cap at the coin's creation, under the product that will open it, and let only an admitted
venue borrow it in between.

- `blast_core::sealed_treasury_cap::SealedTreasuryCap<Coin>` (`key, store`) holds the
  `TreasuryCap` and the original type of the sealing product's package witness. Only that witness
  opens it (`into_treasury_cap`), which the product's `new` does. Readers give the witness, the cap
  ID, and the total supply.
- `blast_core::sealed_treasury_cap::VenueAdmission` (`drop`) is a product's proof that it admits
  one venue, issued under its package witness by `venue_admission` after the product checked its
  own venue allowlist: `launch_config::venue_admission` and `creation_policy::venue_admission`,
  public and permissionless. A venue borrows the cap with `treasury_cap_mut`, presenting the
  admission and its own witness; a borrow with another product's admission aborts with
  `wrong_package_witness` (10) and one for another venue with the new `venue_not_admitted` (14).
  A reference result never leaves Move code, so a creator's transaction cannot reach the cap.
- The launchpad's `launch_ticket::new` returns the ticket and the sealed cap; the launch ticket
  template transfers both to the publisher; `launch::new` takes the sealed cap and opens it; the
  exact-supply recheck at `destroy` stays as defense in depth against an admitted venue.
- The presale creates its own sale tokens: `blast_presale::sale_token::new` takes a generated
  package's one-time witness, creates the currency, seals the cap under the presale's witness, and
  returns the registry initializer for the package to finalize. The new `presale_coin_template`
  package is that generated package. `blast_presale::new` takes the sealed cap and opens it; the
  zero-supply check stays. A coin created elsewhere, including through `coin_template`, can no
  longer start a sale: its creator held the raw cap, and nothing after that can take the window
  back.
- `blast_migrators::cetus::prepare` takes the sealed cap by mutable reference and the admission,
  and borrows through them; `blast_migrators::bluefin::prepare` takes the sealed cap by reference
  as proof of control only. The Aftermath DAO vendor's `prepare` never took the sale token's cap
  and is unchanged.

Products and venues still never import each other; the seal and the admission are core values,
like the venue ticket and the migration hand-off.

## Alternatives rejected

- **The cap inside the ticket, borrowed by a venue-side `prepare_launch`.** The venue would have
  to call the product to pass its allowlist, so the migrators would import both products,
  reversing 0137's direction and coupling every product upgrade to a migrators upgrade.
- **A venue allowlist in `blast_core`.** 0137's D7 keeps allowlists per product.
- **A hot-potato borrow returned to the creator's transaction.** The creator could mint, create the
  pool, and burn back inside that transaction.
- **Rejecting an existing pool in `prepare`.** Cetus v15 exposes no non-aborting existence read.
- **Sealing a cap the creator already holds.** The window before the seal would remain, guarded
  only by the rounding argument above.

## Consequences

- SDK and web: `publishMeme` effects name a `SealedTreasuryCap` instead of a `TreasuryCap`; a
  presale coin publisher patches `presale_coin_template`; creation PTBs add the product's
  admission before a Cetus `prepare`. `launchTicketBcs` is unchanged.
- Explorer naming gains `presale_coin::PRESALE_COIN` and the wallet-held
  `sealed_treasury_cap::SealedTreasuryCap<Coin>`; publication order gains `presale_coin_template`
  after `blast_presale`.
- The fork gate pins that a stranger cannot pre-create the pool and that no raw `TreasuryCap`
  leaves a publication; the creator-side sequence of PR #219 is no longer expressible.
