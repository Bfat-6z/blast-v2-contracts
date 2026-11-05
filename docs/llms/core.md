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
- Every launch package uses one basis-points denominator, `blast_core::constants::basis_points_denominator`
  (10,000), and one cap on Blast's share of LP fees, `blast_core::constants::max_lp_fee_bps`
  (3,000 per asset). The bounds core's constructors enforce are public too:
  `blast_core::constants::max_routes` (20 routes per fee split) and
  `blast_core::constants::max_vesting_duration_ms` (2^63 ms). All four are public compile-time
  macros.
- A `payout::Recipient`, built with `payout::recipient`, is a nonzero destination address and
  optional `payout::VestingTerms` (from `payout::vesting_terms`); the zero address aborts.
  `payout::pay_or_vest` pays an amount to a recipient as a coin or, when it vests, locks the amount
  in an irrevocable, shared `blast_fun_linear_vesting::Vesting` schedule that starts at the payout
  and returns its ID. A zero amount sends and locks nothing. Each product keeps its own recipient
  lists and shares. `payout::destination` and `payout::recipient_vesting_terms` (called as
  `recipient.vesting_terms()`) read a recipient; `payout::cliff_delay_ms`,
  `payout::period_duration_ms`, and `payout::periods` read its terms.

### Fee splits

`fee_split::FeeSplit` is a list of up to 20 routes summing to 10,000. Each route has a positive
share and a `fee_split::Destination`: an address, the vault's owner, auto-LP, holder rewards, or
burn. No address and no special kind appears twice. `fee_split::apportion` divides one collection
across the routes in order.

### Protocol fees, partners, and the treasury

`protocol_fees::Ledger` holds Blast's Meme, Quote, and SUI fees for one launch, presale, or vault.
Only the module that owns it can create it, under its package witness, and every payment event
names that witness type, so a payment's origin is attributable.
`protocol_fees::take_cut` moves Blast's rounded-up cut of a fee into it. A ledger is bound at
creation to the partner its sale named, or to none. `protocol_fees::pay` pays everything to the
treasury and aborts when a partner is bound; `protocol_fees::pay_with_partner` first pays that
partner its cut of each asset through `blast_partners::blast_partners::pay`, then the treasury the
rest. Both emit `blast_core_events::ProtocolFeesPaid`; an empty ledger sends and emits nothing. Products expose these payouts as calls anyone
may make. `protocol_fees::balances`, `protocol_fees::package_witness`, `protocol_fees::origin`, and
`protocol_fees::partner_id` read a ledger. `protocol_fees::destroy` deletes one that holds nothing
and aborts while any fee is held, so its owner pays it out first.

`blast_treasury::Treasury` is a shared singleton holding the address Blast's fees go to. A Blast
admin with `blast_domain::TreasuryAdmin` schedules a new address with
`blast_treasury::schedule_destination`; anyone applies it with `blast_treasury::apply_destination`
once its notice has passed (48 hours from publication); a Blast admin with
`blast_domain::CancelAdmin` cancels it with `blast_treasury::cancel_destination`. Read the current
address with `blast_treasury::destination`, the notice the next change waits with
`blast_treasury::delay_ms`, and a scheduled change, as a `delayed::Proposal<address>`, with
`blast_treasury::pending_destination`. `blast_treasury::is_destination_ready` takes the `Clock` and
returns whether `blast_treasury::apply_destination` would succeed now: a change is scheduled, the
clock reads its `ready_at_ms` or later, and the clock plus its next notice still fits in a `u64`;
it returns false with nothing scheduled, before `ready_at_ms`, and after a cancel or an apply. The
treasury is never deleted: every ledger pays through it.

### Migration hand-off and owner proof

- Before a sale's supply is minted, its venue prepares the coin and returns a
  `migration::VenueTicket` for the sale's exact Meme and Quote pair, sealed by the venue's witness
  (`migration::issue_ticket`), so a ticket cannot start a sale of another coin or Quote. The venue
  keeps the pair's pool tier. The product's creation call redeems the ticket with `migration::redeem_ticket`
  and stores the venue.
- `migration::VaultTerms` are a vault's terms: the sale, the package witness that sealed them, the fee
  split, Blast's LP-fee shares, the partner, and whether residuals go to Blast or the owner. Only
  `migration::vault_terms`, under the issuing package's witness, builds them; a standalone vault's issuer
  builds its own the same way. It aborts when either of Blast's LP-fee shares exceeds 3,000 basis
  points, so every sealed term is within the cap.
- At migration the product creates a `migration::Migration` with `migration::new`, sealed by its own witness, holding the
  pool's Meme and Quote and terms the same package witness sealed. Only the stored venue can consume it,
  with `migration::redeem`; any other venue aborts.
- `owner_proof::OwnerProof` is a product's sealed statement that the caller holds the sale's
  creator authority, issued with `owner_proof::new`. A vault consumes it with
  `owner_proof::assert_terms`, which aborts unless it names
  the vault's package witness and sale.

None of these values can be dropped, copied, or stored, so the PTB that creates one must consume it.

Readers never consume them. `migration::ticket_venue` (called as `ticket.venue()`) reads a ticket's
venue. `migration::venue`, `migration::balances` (the Meme and Quote amounts), and
`migration::terms` read a migration; only `migration::redeem` releases its balances, and a copy of
its terms authorizes nothing, since an admitted venue never takes terms from its caller and each
sale has one vault. `migration::origin`, `migration::package_witness`, `migration::fee_split`,
`migration::protocol_bps`, `migration::partner_id`, and `migration::residuals` read terms;
`migration::is_protocol` and `migration::is_owner` read the `migration::ResidualPolicy` it
returns. `owner_proof::package_witness` and `owner_proof::origin` read
a proof.

### Pool seed price

`migration::sqrt_price_x64` derives the price a concentrated-liquidity venue (Cetus or Bluefin)
seeds a migrated pool at, from the migration's atomic Meme and Quote amounts:
`floor(sqrt(B / A) * 2^64)`, where B / A is Quote / Meme when Meme is coin A and Meme / Quote
otherwise. Display decimals never enter it, and the divisor amount must be positive.
`migration::is_seedable_price` says whether both venues can seed a full-range pool at that price:
it must lie within half of their shared sqrt-price range (from 2 x 4,295,048,016 to
79,226,673,515,401,279,992,447,579,055 / 2). A product uses it to refuse a sale that could never
migrate. Both are pure reads anyone may call.

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
