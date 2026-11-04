## Shared core

### What it is

Package `blast_core` holds the money building blocks every Blast launch product shares, each
defined once: a basis-points unit and its exact apportionment, outright or vested payouts, the LP-fee split, the ledger that holds Blast's fees and pays the partner's cut,
the one treasury address, Merkle proofs, and the sealed values that carry a sale's liquidity to its
venue and prove a sale's ownership to its vault. It holds no user funds of its own. Products and
vaults embed its values and call it; integrators read its events and build PTBs that pass its
values between product and venue calls.

### Units and payouts

- `blast_core::bps::Bps` is a rate from 0 to 10,000 basis points; `blast_core::bps::new` aborts
  above 10,000. `blast_core::bps::apply_up` applies it rounding up.
- `blast_core::bps::apportion` splits an amount over rates that sum to exactly 10,000 by largest
  remainder: every part takes its floor, an optional named part takes its ceiling, and the
  leftover units go one each to the largest remaining remainders, earlier parts first. The parts
  always sum to the amount.
- `payout::pay_or_vest` pays an amount to a destination as a coin, or, given
  `payout::VestingTerms`, locks it in an irrevocable, shared `blast_fun_linear_vesting::Vesting`
  schedule that starts at the payout and returns its ID. A zero amount sends nothing. Each product
  keeps its own recipient lists and shares.

### Fee splits

`fee_split::FeeSplit` is a list of up to 20 routes summing to 10,000. Each route has a positive
share and a `fee_split::Destination`: an address, the vault's owner, auto-LP, holder rewards, or
burn. No address and no special kind appears twice. `fee_split::apportion` divides one collection
across the routes in order.

### Protocol fees, partners, and the treasury

`protocol_fees::Ledger` holds Blast's Meme, Quote, and SUI fees for one launch, presale, or vault.
Only the module that owns it can create it, under its package witness, and every payment event
names that witness type, so a payment's origin is attributable.
`protocol_fees::take_share` moves Blast's rounded-up share of a fee into it. A ledger is bound at
creation to the partner its sale named, or to none. `protocol_fees::pay` pays everything to the
treasury and aborts when a partner is bound; `protocol_fees::pay_with_partner` first pays that
partner its cut of each asset through `blast_partners::blast_partners::pay`, then the treasury the
rest. Both emit `protocol_fees::ProtocolFeesPaid`; an empty ledger sends and emits nothing. Products expose these payouts as calls anyone
may make.

`blast_treasury::Treasury` is a shared singleton holding the address Blast's fees go to. A Blast
admin with `blast_domain::TreasuryAdmin` schedules a new address with
`blast_treasury::schedule_destination`; anyone applies it with `blast_treasury::apply_destination`
once its notice has passed (48 hours from publication); a Blast admin with
`blast_domain::CancelAdmin` cancels it with `blast_treasury::cancel_destination`. Read the current
address with `blast_treasury::destination`.

### Migration hand-off and owner proof

- Before a sale's supply is minted, its venue prepares the coin and returns a
  `migration::VenueTicket` sealed by the venue's witness (`migration::issue_ticket`). The venue keeps
  the coin's pool tier. The product's creation call redeems the ticket with `migration::redeem_ticket`
  and stores the venue.
- `migration::VaultTerms` are a vault's terms: the sale, the package witness that sealed them, the fee
  split, Blast's LP-fee shares, the partner, and whether residuals go to Blast or the owner. Only
  `migration::vault_terms`, under the issuing package's witness, builds them; a standalone vault's issuer
  builds its own the same way.
- At migration the product creates a `migration::Migration` with `migration::new`, sealed by its own witness, holding the
  pool's Meme and Quote and terms the same package witness sealed. Only the stored venue can consume it,
  with `migration::redeem`; any other venue aborts.
- `owner_proof::OwnerProof` is a product's sealed statement that the caller holds the sale's
  creator authority. A vault consumes it with `owner_proof::verify`, which aborts unless it names
  the vault's package witness and sale.

None of these values can be dropped, copied, or stored, so the PTB that creates one must consume it.

### Merkle proofs

`blast_core::merkle::verify` checks a positional Blake2b-256 proof of a leaf digest at an index. Leaves hash
as `blake2b256(0x00 || domain || payload)` with `blast_core::merkle::leaf`, where each tree's
purpose names its own domain string; internal nodes hash as `blake2b256(0x01 || left || right)`;
an odd node at any level is its own sibling. Malformed roots, digests, or siblings,
an empty tree, an index outside it, or a proof of the wrong depth return false instead of aborting.

### Roles

`blast_domain` declares Blast's product roles for the shared ACL: `TreasuryAdmin`, `FeeAdmin`,
`ListingAdmin`, `AdapterAdmin`, `RewardsAdmin`, `BuybackAdmin`, `CreatorAdmin`,
`ClaimSignerAdmin`, and `CancelAdmin`. Only Blast admins hold them.

### Errors

Every abort is a small integer from the package's numeric registry; the reference lists each code.
The abort names the module that raised it.
