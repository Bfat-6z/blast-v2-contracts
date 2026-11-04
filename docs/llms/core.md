## Shared core

### What it is

Package `blast_core` holds the money building blocks every Blast launch product shares, each
defined once: a basis-points unit and its exact apportionment, recipients and their vested or
outright payouts, the LP-fee split, the ledger that holds Blast's fees and pays the partner's cut,
the one treasury address, Merkle proofs, and the sealed values that carry a sale's liquidity to its
venue and prove a sale's ownership to its vault. It holds no user funds of its own. Products and
vaults embed its values and call it; integrators read its events and build PTBs that pass its
values between product and venue calls.

### Units and payouts

- `blast_core::bps::Bps` is a rate from 0 to 10,000 basis points; `blast_core::bps::new` aborts
  above 10,000. `blast_core::bps::apply_up` and `blast_core::bps::apply_down` round in the named
  direction.
- `blast_core::bps::apportion` splits an amount over rates that sum to exactly 10,000 by largest
  remainder: every part takes its floor, an optional named part takes its ceiling, and the
  leftover units go one each to the largest remaining remainders, earlier parts first. The parts
  always sum to the amount.
- `recipient::Recipient` is a nonzero address with a share and optional `recipient::VestingTerms`.
  `recipient::pay_or_vest` pays a recipient's amount as a coin, or locks it in an irrevocable,
  shared `blast_fun_linear_vesting::Vesting` schedule that starts at the payout and returns its ID.
  A zero amount sends nothing.

### Fee splits

`fee_split::FeeSplit` is a list of up to 16 routes summing to 10,000. Each route has a positive
share and a `fee_split::Destination`: an address, the vault's owner, auto-LP, holder rewards, or
burn. No address and no special kind appears twice. `fee_split::apportion` divides one collection
across the routes in order.

### Protocol fees, partners, and the treasury

`protocol_fees::Ledger` holds Blast's Meme, Quote, and SUI fees for one launch, presale, or vault.
`protocol_fees::take_share` moves Blast's rounded-up share of a fee into it. A ledger is bound at
creation to the partner its sale named, or to none. `protocol_fees::pay` pays everything to the
treasury and aborts when a partner is bound; `protocol_fees::pay_with_partner` first pays that
partner its cut of each asset through `blast_partners::blast_partners::pay`, then the treasury the
rest. Both emit `protocol_fees::ProtocolFeesPaid`. Products expose these payouts as calls anyone
may make.

`blast_treasury::Treasury` is a shared singleton holding the address Blast's fees go to. A Blast
admin with `blast_domain::TreasuryAdmin` schedules a new address with
`blast_treasury::schedule_destination`; anyone applies it with `blast_treasury::apply_destination`
once its notice has passed (48 hours from publication); a Blast admin with
`blast_domain::CancelAdmin` cancels it with `blast_treasury::cancel_destination`. Read the current
address with `blast_treasury::destination`.

### Migration hand-off and owner proof

- Before a sale's supply is minted, its venue prepares the coin and returns a
  `migration::VenueBinding` sealed by the venue's witness, naming the venue and its
  `migration::PoolTier`. The product's creation call consumes it with `migration::unbind` and
  stores the venue.
- At migration the product returns a `migration::Migration` sealed by its own witness, holding the
  pool's Meme and Quote and the new vault's `migration::VaultTerms`: the sale, the product, the
  fee split, Blast's LP-fee shares, the partner, and whether residuals go to Blast or the owner.
  Only the stored venue can consume it, with `migration::redeem`; any other venue aborts.
- `owner_proof::OwnerProof` is a product's sealed statement that the caller holds the sale's
  creator authority. A vault consumes it with `owner_proof::verify`, which aborts unless it names
  the vault's product and sale.

None of these values can be dropped, copied, or stored, so the PTB that creates one must consume it.

### Merkle proofs

`blast_core::merkle::verify` checks a positional Blake2b-256 proof of a leaf digest at an index. Internal nodes
hash as `blake2b256(0x01 || left || right)`; an odd node at any level is its own sibling. Each
consumer hashes its own leaves under its own domain prefix. Malformed roots, digests, or siblings,
an empty tree, an index outside it, or a proof of the wrong depth return false instead of aborting.

### Roles

`blast_domain` declares Blast's product roles for the shared ACL: `TreasuryAdmin`, `FeeAdmin`,
`ListingAdmin`, `AdapterAdmin`, `RewardsAdmin`, `BuybackAdmin`, `CreatorAdmin`,
`ClaimSignerAdmin`, and `CancelAdmin`. Only Blast admins hold them.

### Errors

Every abort is a small integer from the package's numeric registry; the reference lists each code.
The abort names the module that raised it.
