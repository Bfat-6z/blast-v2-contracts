// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Standalone presales with capped commitments, proportional fills or a first-come hard cap,
/// migration-gated claims, full refunds when a sale does not migrate, the migration hand-off to
/// the sale's venue, and the owner proof its vault accepts.
module blast_presale::blast_presale;

// === Public Types ===

/// Shared singleton every presale's object ID derives from, so a client finds a coin's one sale
/// from the coin type alone.
public struct PresaleRegistry has key {
    id: UID,
}

/// Derives the one presale of `SaleToken` from the registry.
public struct PresaleKey<phantom SaleToken>() has copy, drop, store;

/// Who may commit and the maximum Quote each wallet may commit.
///
/// `Open` gives every wallet the same cap and minimum. The minimum times the
/// participant bound must reach the raise, so filling every slot funds the sale
/// and dust commitments cannot lock real buyers out. `Allowlisted` commits one
/// cap per wallet in a positional Blake2b-256 Merkle tree, supporting equal,
/// tiered, or fully custom caps.
public enum EligibilityPolicy has copy, drop, store {
    Open { wallet_cap: u64, max_participants: u64, min_commitment: u64 },
    Allowlisted { root: vector<u8>, leaf_count: u64 },
}

/// Who may commit once an uncapped phase lifts wallet caps.
public enum UncappedAccess has copy, drop, store {
    /// Only wallets the sale's eligibility policy admits, without their caps.
    Eligible,
    /// Any wallet, bounded like an open policy: `min_commitment` over the slots held to it must
    /// reach the raise so dust cannot lock buyers out. Every slot counts under an open policy;
    /// under an allowlist only the slots beyond its leaves do, since allowlisted wallets may
    /// commit any positive amount.
    Anyone { max_participants: u64, min_commitment: u64 },
}

/// An optional closing phase, starting `starts_after_ms` into the commitment window,
/// that lifts wallet caps. Whether the sale then overflows or stops at its raise is the
/// sale's `HardCap`, not the phase's.
public struct UncappedPhase has copy, drop, store {
    starts_after_ms: u64,
    access: UncappedAccess,
}

/// From `starts_after_ms` into the commitment window, the sale takes Quote only up to its
/// raise, first come, first served: a commitment takes what is left and returns the excess at
/// once, and the sale stops accepting Quote when the raise is full. Before then it overflows,
/// filling every wallet at one common rate. With `closes_when_filled`, a sale whose raise is full
/// under its hard cap may settle at once instead of waiting for the window's end.
public struct HardCap has copy, drop, store {
    starts_after_ms: u64,
    closes_when_filled: bool,
}

/// The presale's one-way lifecycle.
public enum Lifecycle has copy, drop, store {
    Pending,
    Open,
    Funded,
    Migrated,
    Cancelled,
}

/// One creator's authority over one presale.
public struct PresaleCap has key, store {
    id: UID,
    presale_id: ID,
}

/// One recipient's share, in BPS, of the token supply or of the raise, paid at migration or
/// vested from it as its `blast_core::payout::Recipient` says.
public struct RecipientShare has copy, drop, store {
    recipient: Recipient,
    bps: Bps,
}

/// The exact token or Quote amount one recipient receives at migration, apportioned from its
/// `RecipientShare` when the presale is created.
public struct RecipientPayout has copy, drop, store {
    recipient: Recipient,
    amount: u64,
}

/// Dynamic-field name for one wallet's undelivered commitment.
public struct CommitmentKey(address) has copy, drop, store;

/// One wallet's Quote commitment and immutable cap.
public struct Commitment has copy, drop, store {
    quote: u64,
    wallet_cap: u64,
}

/// Hot potato from `new` to `finalize`, collecting the creator's settings. Only `finalize`
/// consumes it, so every sale is finalized in the transaction whose `new` checked the creation
/// policy and snapshotted Blast's rates. `finalize` validates the settings together; the supply,
/// token allocations, raise, windows, eligibility policy, and the vault's LP-fee split must all be
/// set.
public struct PresaleInitializer<phantom SaleToken, phantom Quote> {
    treasury_cap: TreasuryCap<SaleToken>,
    venue: TypeName,
    protocol_fees: ProtocolFees,
    token_supply: u64,
    burnable: bool,
    token_allocation_bps: Bps,
    liquidity_token_allocation_bps: Bps,
    recipient_allocations: vector<RecipientShare>,
    participant_vesting: Option<VestingTerms>,
    raise_target: u64,
    raise_allocations: vector<RecipientShare>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: Option<EligibilityPolicy>,
    uncapped: Option<UncappedPhase>,
    hard_cap: Option<HardCap>,
    fee_split: Option<FeeSplit>,
    partner_id: Option<ID>,
}

/// One standalone presale and its complete custody until migration or refund.
///
/// The complete fixed or burn-only token supply is apportioned at creation.
/// Presale, LP, Blast, and additional recipient allocations stay escrowed until
/// a funded migration atomically releases them. Blast's rates are snapshotted
/// at creation, Blast's `FeeAdmin` may change them until the window starts, and its
/// fees move into the sale's protocol-fee ledger on migration, which pays them to the treasury at
/// once, or, when the sale names a Blast partner, holds them until
/// `pay_protocol_fees_with_partner` pays the partner its cut of each and the treasury the rest.
/// If the raise is missed, every commitment
/// is refunded. Anyone may migrate a funded sale until it is cancelled; once LP
/// is still unmigrated at its deadline, anyone may cancel it so every
/// commitment becomes refundable. Under participant vesting, each claim locks the
/// participant's tokens in its own schedule instead of paying them out.
public struct Presale<phantom SaleToken, phantom Quote> has key {
    id: UID,
    presale_cap_id: ID,
    lifecycle: Lifecycle,
    /// The commitment window's length: as created until the sale closes early, then the time it
    /// ran.
    duration_ms: u64,
    liquidity_window_ms: u64,
    /// When commitments open, fixed by `share`; zero until then. The window's end, the LP
    /// deadline, and the uncapped and hard-cap starts are derived from it and the lengths above.
    start_ms: u64,
    raise_target: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    hard_cap: Option<HardCap>,
    /// The venue witness type the sale's liquidity migrates to; only it redeems the hand-off.
    venue: TypeName,
    /// The LP-fee split the sale's vault starts with.
    fee_split: FeeSplit,
    total_commitments: u64,
    /// The wallets holding an undelivered commitment: admitted by their first commitment and
    /// released by their claim, so the claim that empties the sale is the last one.
    participants: u64,
    quote: Balance<Quote>,
    token_allocation: u64,
    participant_vesting: Option<VestingTerms>,
    sale_tokens: Balance<SaleToken>,
    liquidity_tokens: Balance<SaleToken>,
    recipient_payouts: vector<RecipientPayout>,
    recipient_tokens: Balance<SaleToken>,
    raise_payouts: vector<RecipientPayout>,
    protocol_fees: ProtocolFees,
    protocol_quote: u64,
    protocol_tokens: Balance<SaleToken>,
    /// The Blast partner named at creation, paid its cut of Blast's fees. It never changes once
    /// the sale is shared.
    partner_id: Option<ID>,
    /// Blast's raise and token fees from migration until paid; bound to `partner_id`.
    fee_ledger: Ledger<SaleToken, Quote>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(PresaleRegistry { id: object::new(ctx) });
}

// === Public Functions ===

/// Creates one equal-cap policy with a bounded number of distinct wallets, each
/// of which must commit at least `min_commitment` in total.
public fun open_eligibility(
    wallet_cap: u64,
    max_participants: u64,
    min_commitment: u64,
): EligibilityPolicy {
    let policy = EligibilityPolicy::Open { wallet_cap, max_participants, min_commitment };
    policy.assert_valid_eligibility();

    policy
}

/// Creates one allowlist policy whose leaves are `(index, wallet, wallet_cap)`.
public fun allowlisted_eligibility(root: vector<u8>, leaf_count: u64): EligibilityPolicy {
    let policy = EligibilityPolicy::Allowlisted { root, leaf_count };
    policy.assert_valid_eligibility();

    policy
}

/// Lifts wallet caps for eligible wallets `start_delay_ms` into the window.
public fun uncapped_for_eligible(start_delay_ms: u64): UncappedPhase {
    UncappedPhase { starts_after_ms: start_delay_ms, access: UncappedAccess::Eligible }
}

/// Opens the sale to any wallet without caps `start_delay_ms` into the window, admitting
/// at most `max_participants` wallets in total, each committing at least `min_commitment`.
public fun uncapped_for_anyone(
    start_delay_ms: u64,
    max_participants: u64,
    min_commitment: u64,
): UncappedPhase {
    let phase = UncappedPhase {
        starts_after_ms: start_delay_ms,
        access: UncappedAccess::Anyone { max_participants, min_commitment },
    };
    phase.assert_valid_uncapped_access();

    phase
}

/// One recipient's share in BPS of the supply or the raise, paid or vested at migration as
/// `recipient` says. Presale creation validates each list of shares under that list's own rules
/// and error.
public fun recipient_share(recipient: Recipient, bps: Bps): RecipientShare {
    RecipientShare { recipient, bps }
}

/// Starts a presale of `SaleToken` raising `Quote` whose liquidity migrates to the venue that
/// issued `venue_ticket` for the pair, and snapshots Blast's rates. The venue keeps the pool terms,
/// such as a CLMM tier, which it records while preparing the ticket.
///
/// A venue in this or any other package issues tickets sealed by its own witness, which only its
/// defining module can construct. The `CreationPolicy` must admit that venue, so Blast decides
/// which venues may open sales; the sale's migration hand-off is then redeemable only by it.
public fun new<SaleToken, Quote>(
    treasury_cap: TreasuryCap<SaleToken>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    venue_ticket: VenueTicket<SaleToken, Quote>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
): PresaleInitializer<SaleToken, Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::create_pause_bit!());

    let venue = venue_ticket.redeem_ticket();
    creation_policy.assert_allowed<Quote>(venue);
    assert!(
        type_name::with_original_ids<SaleToken>() != type_name::with_original_ids<Quote>(),
        blast_presale::errors::invalid_asset_pair!(),
    );
    // `Currency<SaleToken>` and `TreasuryCap<SaleToken>` are each unique per type, and making the
    // supply fixed or burn-only consumes the cap, so holding it proves the supply is still unknown.
    assert!(treasury_cap.total_supply() == 0, blast_presale::errors::initial_supply_not_zero!());

    PresaleInitializer {
        treasury_cap,
        venue,
        protocol_fees: fee_policy.fees(),
        token_supply: 0,
        burnable: false,
        token_allocation_bps: bps::new(0),
        liquidity_token_allocation_bps: bps::new(0),
        recipient_allocations: vector[],
        participant_vesting: option::none(),
        raise_target: 0,
        raise_allocations: vector[],
        duration_ms: 0,
        liquidity_window_ms: 0,
        eligibility: option::none(),
        uncapped: option::none(),
        hard_cap: option::none(),
        fee_split: option::none(),
        partner_id: option::none(),
    }
}

/// Sets the complete supply `finalize` mints, and whether it then becomes burn-only rather than
/// fixed.
public fun set_supply<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    token_supply: u64,
    burnable: bool,
) {
    package_version.assert_current(constants::version!());

    self.token_supply = token_supply;
    self.burnable = burnable;
}

/// Splits the supply in BPS between the buyers, the LP, and each recipient. With Blast's token
/// rate the shares must total exactly 10,000 BPS.
public fun set_token_allocations<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    token_allocation_bps: Bps,
    liquidity_token_allocation_bps: Bps,
    recipient_allocations: vector<RecipientShare>,
) {
    package_version.assert_current(constants::version!());

    self.token_allocation_bps = token_allocation_bps;
    self.liquidity_token_allocation_bps = liquidity_token_allocation_bps;
    self.recipient_allocations = recipient_allocations;
}

/// Locks each participant's claimed tokens in its own schedule under `vesting_terms`, starting at
/// its claim, instead of paying them out. Without it, claims pay tokens out at once.
public fun set_participant_vesting<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    vesting_terms: VestingTerms,
) {
    package_version.assert_current(constants::version!());

    self.participant_vesting = option::some(vesting_terms);
}

/// Sets the Quote the sale raises and each recipient's share of it, paid at migration. The LP
/// keeps what Blast's and the recipients' shares leave.
public fun set_raise<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    raise_target: u64,
    raise_allocations: vector<RecipientShare>,
) {
    package_version.assert_current(constants::version!());

    self.raise_target = raise_target;
    self.raise_allocations = raise_allocations;
}

/// Sets how long commitments stay open from the start, and how long after the window anyone may
/// migrate a funded sale before anyone may cancel it: at least seven days.
public fun set_windows<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    commitment_duration_ms: u64,
    liquidity_window_duration_ms: u64,
) {
    package_version.assert_current(constants::version!());

    self.duration_ms = commitment_duration_ms;
    self.liquidity_window_ms = liquidity_window_duration_ms;
}

/// Sets who may commit and each wallet's cap.
public fun set_eligibility<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    eligibility: EligibilityPolicy,
) {
    package_version.assert_current(constants::version!());

    self.eligibility = option::some(eligibility);
}

/// Adds a closing phase that lifts wallet caps. Without one, caps hold for the whole window.
public fun set_uncapped_phase<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    uncapped: UncappedPhase,
) {
    package_version.assert_current(constants::version!());

    self.uncapped = option::some(uncapped);
}

/// Hard-caps the sale at its raise from `start_delay_ms` into the window: zero for the whole
/// window, or the uncapped phase's offset to keep an overflowing capped phase before it. With
/// `closes_when_filled`, anyone may settle the sale once its raise is full under the hard cap;
/// without it, a full sale waits for the window's end. Without a hard cap, the sale overflows
/// for the whole window and always runs to its end.
public fun set_hard_cap<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    start_delay_ms: u64,
    closes_when_filled: bool,
) {
    package_version.assert_current(constants::version!());

    self.hard_cap = option::some(HardCap { starts_after_ms: start_delay_ms, closes_when_filled });
}

/// Sets how the sale's vault splits every collected LP fee after Blast's share: any of the core
/// routes, including the sale owner, auto-LP, holder rewards, and burn.
public fun set_fee_split<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    fee_split: FeeSplit,
) {
    package_version.assert_current(constants::version!());

    self.fee_split = option::some(fee_split);
}

/// Names the sale's Blast partner, one the `CreationPolicy` lets new presales name; from
/// `finalize` on it is the sale's partner for good. The partner earns its cut of Blast's raise and
/// token fees, which migration holds until `pay_protocol_fees_with_partner` pays them, and its
/// vault inherits the partner, which then earns its cut of Blast's LP fees (ADR 0137).
public fun set_partner<SaleToken, Quote>(
    self: &mut PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    creation_policy: &CreationPolicy,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    let partner_id = object::id(partner);
    creation_policy.assert_partner(partner_id, clock);

    self.partner_id = option::some(partner_id);
}

/// The venue witness type the sale migrates to, so a venue finalizing an initializer it is
/// handed can confirm the sale is its own.
public fun venue<SaleToken, Quote>(self: &PresaleInitializer<SaleToken, Quote>): TypeName {
    self.venue
}

/// Requires a confirmed unregulated sale currency and checks every setting, then mints and
/// apportions the complete token supply and
/// irreversibly makes it fixed or burn-only before returning the presale for `share`.
public fun finalize<SaleToken, Quote>(
    self: PresaleInitializer<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    registry: &mut PresaleRegistry,
    currency: &mut Currency<SaleToken>,
    ctx: &mut TxContext,
): (Presale<SaleToken, Quote>, PresaleCap) {
    package_version.assert_current(constants::version!());

    currency.assert_unregulated_currency();

    let PresaleInitializer {
        treasury_cap,
        venue,
        protocol_fees,
        token_supply,
        burnable,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        recipient_allocations,
        participant_vesting,
        raise_target,
        raise_allocations,
        duration_ms: commitment_duration_ms,
        liquidity_window_ms: liquidity_window_duration_ms,
        eligibility,
        uncapped,
        hard_cap,
        fee_split,
        partner_id,
    } = self;

    let eligibility = eligibility.destroy_or!(abort blast_presale::errors::missing_setting!());
    let fee_split = fee_split.destroy_or!(abort blast_presale::errors::missing_setting!());
    // Values built by superseded bytecode meet this version's rules too.
    eligibility.assert_valid_eligibility();
    uncapped.do_ref!(|phase| phase.assert_valid_uncapped_access());
    assert!(raise_target > 0, blast_presale::errors::invalid_raise_target!());
    assert_raise_allocations(&raise_allocations, protocol_fees.raise_bps());
    assert_token_allocations(
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        protocol_fees.token_bps(),
        &recipient_allocations,
    );
    assert!(
        commitment_duration_ms > 0
            && liquidity_window_duration_ms >= constants::min_liquidity_window_duration_ms!(),
        blast_presale::errors::invalid_window!()
    );
    assert!(eligibility.can_reach(raise_target), blast_presale::errors::unreachable_raise!());
    uncapped.do_ref!(
        |phase| phase.assert_uncapped_phase(commitment_duration_ms, eligibility, raise_target)
    );
    hard_cap.do_ref!(|cap| assert!(
        cap.starts_after_ms < commitment_duration_ms,
        blast_presale::errors::invalid_hard_cap!(),
    ));

    let (
        token_allocation,
        liquidity_token_allocation,
        protocol_token_allocation,
        recipient_payouts,
    ) = apportion_supply(
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        protocol_fees.token_bps(),
        &recipient_allocations,
    );
    let (raise_payouts, protocol_quote, liquidity_quote) = apportion_raise(
        &raise_allocations,
        protocol_fees.raise_bps(),
        raise_target,
    );

    assert_seedable_price(liquidity_token_allocation, liquidity_quote);

    let treasury_cap_id = object::id(&treasury_cap);
    let (sale_tokens, liquidity_tokens, protocol_tokens, recipient_tokens) = mint_and_seal_supply(
        treasury_cap,
        currency,
        token_supply,
        token_allocation,
        liquidity_token_allocation,
        protocol_token_allocation,
        burnable,
    );

    let id = derived_object::claim(&mut registry.id, PresaleKey<SaleToken>());
    let presale_id = id.to_inner();
    let cap = PresaleCap { id: object::new(ctx), presale_id };
    let presale_cap_id = cap.id.to_inner();
    let fee_ledger = protocol_fees::new(
        blast_presale_package::package_witness(),
        presale_id,
        partner_id,
    );

    sui::event::emit(PresaleCreated<SaleToken, Quote> {
        presale_id,
        presale_cap_id,
        treasury_cap_id,
        token_supply,
        token_allocation_bps: token_allocation_bps.value(),
        participant_vesting,
        liquidity_token_allocation_bps: liquidity_token_allocation_bps.value(),
        recipients: recipient_allocations.recipients(),
        recipient_bps: recipient_allocations.bps(),
        burnable,
        raise_target,
        raise_recipients: raise_allocations.recipients(),
        raise_recipient_bps: raise_allocations.bps(),
        duration_ms: commitment_duration_ms,
        liquidity_window_ms: liquidity_window_duration_ms,
        eligibility,
        uncapped,
        hard_cap,
        venue,
        fee_split,
        protocol_raise_bps: protocol_fees.raise_bps().value(),
        protocol_token_bps: protocol_fees.token_bps().value(),
        protocol_lp_fee_meme_bps: protocol_fees.lp_fee_meme_bps().value(),
        protocol_lp_fee_quote_bps: protocol_fees.lp_fee_quote_bps().value(),
        protocol_quote,
        protocol_tokens: protocol_token_allocation,
    });

    (
        Presale {
            id,
            presale_cap_id,
            lifecycle: Lifecycle::Pending,
            duration_ms: commitment_duration_ms,
            liquidity_window_ms: liquidity_window_duration_ms,
            start_ms: 0,
            raise_target,
            eligibility,
            uncapped,
            hard_cap,
            venue,
            fee_split,
            total_commitments: 0,
            participants: 0,
            quote: balance::zero(),
            token_allocation,
            participant_vesting,
            sale_tokens,
            liquidity_tokens,
            recipient_payouts,
            recipient_tokens,
            raise_payouts,
            protocol_fees,
            protocol_quote,
            protocol_tokens,
            partner_id,
            fee_ledger,
        },
        cap,
    )
}

/// Shares a newly created presale and fixes its windows from `commitment_starts_at_ms`, or from now once that
/// has passed, so a sale can be created ahead of its start. Commitments open at the start; until
/// then Blast's `FeeAdmin` may change the sale's Blast rates.
public fun share<SaleToken, Quote>(
    mut self: Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    commitment_starts_at_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::create_pause_bit!());

    assert!(self.lifecycle == Lifecycle::Pending, blast_presale::errors::invalid_lifecycle!());

    // Every deadline is derived from the start, so the share proves each one fits in u64. Closing
    // early only brings the end and the LP deadline forward.
    let commitment_starts_at_ms = commitment_starts_at_ms.max(clock.timestamp_ms());
    let commitment_ends_at_ms = commitment_starts_at_ms
        .checked_add(self.duration_ms)
        .destroy_or!(abort blast_presale::errors::invalid_window!());
    let liquidity_deadline_at_ms = commitment_ends_at_ms
        .checked_add(self.liquidity_window_ms)
        .destroy_or!(abort blast_presale::errors::invalid_window!());

    self.lifecycle = Lifecycle::Open;
    self.start_ms = commitment_starts_at_ms;

    events::presale_opened<SaleToken, Quote>(
        self.id.to_inner(),
        commitment_starts_at_ms,
        commitment_ends_at_ms,
        liquidity_deadline_at_ms,
        self.uncapped_starts_at_ms(),
        self.hard_cap_starts_at_ms(),
        self.partner_id,
    );

    transfer::share_object(self);
}

/// Replaces this sale's snapshot of Blast's rates before its window starts, while nobody can have
/// committed: in its creation transaction before `share`, or once shared until its start. Once
/// shared the sale is public, so each rate may only stay or fall; only the creation transaction
/// may raise one, up to the applied fee policy. A changed token rate reapportions Blast's tokens
/// against the buyers' sale allocation and a changed raise rate its Quote against the LP's, each
/// rounded down; an unchanged rate keeps its amount, and every recipient keeps its amount.
public fun set_protocol_fees<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<FeeAdmin>,
    fee_policy: &FeePolicy,
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    match (self.lifecycle) {
        Lifecycle::Pending => (),
        Lifecycle::Open => {
            assert!(
                clock.timestamp_ms() < self.start_ms,
                blast_presale::errors::presale_started!(),
            );
            let current = self.protocol_fees;
            assert!(
                raise_bps.value() <= current.raise_bps().value()
                && token_bps.value() <= current.token_bps().value()
                && lp_fee_meme_bps.value() <= current.lp_fee_meme_bps().value()
                && lp_fee_quote_bps.value() <= current.lp_fee_quote_bps().value(),
                blast_presale::errors::protocol_fees_increased!()
            );
        },
        _ => abort blast_presale::errors::invalid_lifecycle!(),
    };
    let protocol_fees = fee_policy::protocol_fees(
        raise_bps,
        token_bps,
        lp_fee_meme_bps,
        lp_fee_quote_bps,
    );
    let ceiling = fee_policy.fees();
    assert!(
        raise_bps.value() <= ceiling.raise_bps().value()
        && token_bps.value() <= ceiling.token_bps().value()
        && lp_fee_meme_bps.value() <= ceiling.lp_fee_meme_bps().value()
        && lp_fee_quote_bps.value() <= ceiling.lp_fee_quote_bps().value(),
        blast_presale::errors::above_fee_policy!()
    );
    assert!(protocol_fees != self.protocol_fees, blast_presale::errors::protocol_fees_unchanged!());

    // Blast's Quote comes out of the raise left after the recipients', whose rest the LP keeps;
    // its tokens come out of its own and the buyers' allocations, whose rest the buyers keep. A
    // rate that does not change keeps the amount creation apportioned for it.
    let unallocated_raise = self.raise_target - total_amount(&self.raise_payouts);
    let unallocated_tokens = self.token_allocation + self.protocol_tokens.value();
    let protocol_quote = self.protocol_quote_at(raise_bps);
    let protocol_tokens = self.protocol_tokens_at(token_bps);
    assert!(protocol_quote < unallocated_raise, blast_presale::errors::invalid_raise_allocation!());
    assert!(
        protocol_tokens < unallocated_tokens,
        blast_presale::errors::invalid_token_allocation!(),
    );
    assert_seedable_price(self.liquidity_tokens.value(), unallocated_raise - protocol_quote);

    self.sale_tokens.join(self.protocol_tokens.withdraw_all());
    self.protocol_tokens.join(self.sale_tokens.split(protocol_tokens));
    self.token_allocation = unallocated_tokens - protocol_tokens;
    self.protocol_quote = protocol_quote;
    self.protocol_fees = protocol_fees;

    events::protocol_fees_changed<SaleToken, Quote>(
        self.id.to_inner(),
        raise_bps.value(),
        token_bps.value(),
        lp_fee_meme_bps.value(),
        lp_fee_quote_bps.value(),
        protocol_quote,
        protocol_tokens,
        self.token_allocation,
    );
}

/// Locks the supplied `Coin<Quote>` in this presale under an equal-cap, open
/// eligibility policy and returns whatever a hard-capped uncapped phase could not
/// accept (a zero coin otherwise).
public fun commit_open<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    quote_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::commit_pause_bit!());

    self.assert_open(clock);
    assert!(quote_in.value() > 0, blast_presale::errors::zero_commitment!());

    let (wallet_cap, max_participants, min_commitment) = self.eligibility.open_limits();

    self.record_commitment(quote_in, wallet_cap, max_participants, min_commitment, clock, ctx)
}

/// Locks Quote from an allowlisted wallet after verifying its Merkle-committed cap,
/// returning whatever a hard cap could not accept.
public fun commit_allowlisted<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    quote_in: Coin<Quote>,
    index: u64,
    wallet_cap: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::commit_pause_bit!());

    self.assert_open(clock);
    assert!(quote_in.value() > 0, blast_presale::errors::zero_commitment!());

    let max_participants = self
        .eligibility
        .verify_allowlisted(
            index,
            ctx.sender(),
            wallet_cap,
            &proof,
        );

    // Allowlisted wallets are few and named, so any positive commitment counts.
    self.record_commitment(quote_in, wallet_cap, max_participants, 1, clock, ctx)
}

/// Locks Quote from any wallet once an uncapped phase open to anyone has started,
/// returning whatever a hard cap could not accept.
public fun commit_uncapped<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    quote_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::commit_pause_bit!());

    self.assert_open(clock);
    assert!(quote_in.value() > 0, blast_presale::errors::zero_commitment!());
    assert!(
        clock.timestamp_ms() >= self.uncapped_starts_at_ms(),
        blast_presale::errors::uncapped_phase_not_open!(),
    );

    let (max_participants, min_commitment) = self.uncapped.destroy_some().anyone_limits();
    let no_wallet_cap = std::u64::max_value!();

    self.record_commitment(quote_in, no_wallet_cap, max_participants, min_commitment, clock, ctx)
}

/// Fixes the fill after the commitment window, or as soon as the raise is full under a hard cap
/// that closes the sale when filled; closing early ends the window now, so the LP deadline counts
/// from now. Underfunded sales become fully refundable. Anyone may settle.
public fun settle<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    assert!(self.lifecycle == Lifecycle::Open, blast_presale::errors::invalid_lifecycle!());

    let now_at_ms = clock.timestamp_ms();
    assert!(
        now_at_ms >= self.commitment_ends_at_ms() || self.can_close_early(now_at_ms),
        blast_presale::errors::presale_not_ended!()
    );

    // A sale closing early ends now, so its LP deadline counts from now.
    if (now_at_ms < self.commitment_ends_at_ms()) self.duration_ms = now_at_ms - self.start_ms;

    if (self.total_commitments < self.raise_target) {
        self.cancel();
    } else {
        self.lifecycle = Lifecycle::Funded;

        events::presale_funded<SaleToken, Quote>(
            self.id.to_inner(),
            self.total_commitments,
            self.raise_target,
            self.total_commitments - self.raise_target,
            self.token_allocation,
            self.commitment_ends_at_ms(),
            self.liquidity_deadline_at_ms(),
        );
    };
}

/// Cancels a funded presale still unmigrated at its LP deadline, preserving all
/// Quote for refunds. Anyone may cancel.
public fun cancel_unlaunched<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    assert!(self.lifecycle == Lifecycle::Funded, blast_presale::errors::invalid_lifecycle!());
    assert!(
        clock.timestamp_ms() >= self.liquidity_deadline_at_ms(),
        blast_presale::errors::liquidity_deadline_not_reached!(),
    );

    self.cancel();
}

/// Delivers one participant's pro-rata tokens and overflow Quote after migration,
/// or its full Quote after cancellation. Under participant vesting, the tokens are
/// locked in a shared irrevocable linear schedule starting at this claim instead of
/// paid out; the Quote refund is always paid at once. Anyone may relay; the final
/// claim receives the bounded integer-rounding remainder.
public fun claim<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    participant: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    assert!(
        self.lifecycle == Lifecycle::Migrated || self.lifecycle == Lifecycle::Cancelled,
        blast_presale::errors::invalid_lifecycle!(),
    );

    let key = CommitmentKey(participant);
    assert!(self.id.has_dynamic_field(key), blast_presale::errors::no_commitment!());

    let Commitment { quote: commitment, .. } = self.id.remove_dynamic_field<_, Commitment>(key);
    let tokens = self.claimable_tokens(commitment);
    let quote_refund = self.refundable_quote(commitment);
    let participant_recipient = payout::recipient(participant, self.participant_vesting);

    self.participants = self.participants - 1;
    let vesting_id = payout::pay_or_vest(
        &mut self.sale_tokens,
        tokens,
        &participant_recipient,
        clock,
        ctx,
    );
    payout::pay(&mut self.quote, quote_refund, participant, ctx);

    events::claimed<SaleToken, Quote>(
        self.id.to_inner(),
        participant,
        commitment,
        tokens,
        quote_refund,
        self.participants,
        vesting_id,
    );
}

/// Pays Blast's raise and token fees to `treasury` and the raise recipients their shares, and
/// releases every token recipient's tokens at once, locking each vesting share in its own shared
/// irrevocable schedule starting now, then returns the hand-off only the stored venue can redeem:
/// the rest of the raise, the LP-token allocation, and the vault's terms, with the sale's LP-fee
/// split, Blast's snapshotted LP-fee rates, its partner, and the migration residuals kept for the
/// owner. A sale naming a Blast partner holds Blast's fees in its ledger instead, for
/// `pay_protocol_fees_with_partner`. Anyone may call it until the sale is cancelled; an unredeemed
/// hand-off aborts the transaction, so the venue's pool creation stays atomic with this state
/// transition.
public fun migrate<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    treasury: &Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
): Migration<SaleToken, Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::migration_pause_bit!());

    assert!(self.lifecycle == Lifecycle::Funded, blast_presale::errors::invalid_lifecycle!());

    let mut quote = self.quote.split(self.raise_target);
    let protocol_quote = quote.split(self.protocol_quote);
    let liquidity_tokens = self.liquidity_tokens.withdraw_all();
    let recipient_tokens = self.recipient_tokens.value();

    self.pay_or_hold_protocol_fees(protocol_quote, treasury, ctx);
    self.pay_raise_allocations(&mut quote, clock, ctx);
    self.release_recipient_tokens(clock, ctx);
    self.lifecycle = Lifecycle::Migrated;

    events::presale_migrated<SaleToken, Quote>(
        self.id.to_inner(),
        self.venue,
        quote.value(),
        liquidity_tokens.value(),
        recipient_tokens,
    );

    let terms = migration::vault_terms(
        blast_presale_package::package_witness(),
        self.id.to_inner(),
        self.fee_split,
        self.protocol_fees.lp_fee_meme_bps(),
        self.protocol_fees.lp_fee_quote_bps(),
        self.partner_id,
        migration::residuals_to_owner(),
    );

    migration::new(
        blast_presale_package::package_witness(),
        liquidity_tokens,
        quote,
        self.venue,
        terms,
    )
}

/// Proves to the sale's vault that the caller holds the sale's creator capability.
public fun prove_owner<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    cap: &PresaleCap,
): OwnerProof {
    package_version.assert_current(constants::version!());
    self.assert_cap(cap);

    owner_proof::new(blast_presale_package::package_witness(), self.id.to_inner())
}

/// Pays a migrated sale's Blast partner its cut of each of Blast's fees the migration held, rounded
/// down so Blast keeps the remainder, and `treasury` the rest. The cut is the partner's
/// `blast_partners` applied rate. Anyone may call it: both recipients are fixed, and a ledger with
/// nothing held, before migration or once paid, sends nothing.
public fun pay_protocol_fees_with_partner<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    treasury: &Treasury,
    partner: &Partner,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    self.fee_ledger.pay_with_partner(treasury, partner, ctx);
}

/// Destroys the creator capability after cancellation. All minted SaleToken
/// allocations remain permanently locked in the cancelled presale.
public fun destroy_cap<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, cap: PresaleCap) {
    self.assert_cap(&cap);
    assert!(self.lifecycle == Lifecycle::Cancelled, blast_presale::errors::invalid_lifecycle!());

    let PresaleCap { id, presale_id: _ } = cap;
    id.delete();
}

// === Private Functions ===

/// Aborts unless `cap` is the sale's creator capability.
fun assert_cap<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, cap: &PresaleCap) {
    assert!(object::id(cap) == self.presale_cap_id, blast_presale::errors::wrong_presale_cap!());
}

/// Each share's recipient, in order.
fun recipients_of(shares: &vector<RecipientShare>): vector<Recipient> {
    shares.map_ref!(|share| share.recipient)
}

/// Each share's BPS, in order.
fun bps_of(shares: &vector<RecipientShare>): vector<u64> {
    shares.map_ref!(|share| share.bps.value())
}

fun assert_open<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Open, blast_presale::errors::invalid_lifecycle!());
    assert!(clock.timestamp_ms() >= self.start_ms, blast_presale::errors::presale_not_started!());
    assert!(
        clock.timestamp_ms() < self.commitment_ends_at_ms(),
        blast_presale::errors::presale_ended!(),
    );
}

// Windows, derived from the start `share` fixed: it proved both sums below fit in u64.

/// The exclusive end of the commitment window.
fun commitment_ends_at_ms<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self.start_ms + self.duration_ms
}

/// From when anyone may cancel a funded sale that has not migrated.
fun liquidity_deadline_at_ms<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self.commitment_ends_at_ms() + self.liquidity_window_ms
}

/// When wallet caps lift: the uncapped phase's offset into the window, which `finalize` bounds
/// below the duration, or the end of a sale without one. Read only while the sale is open, before
/// an early close can shorten the duration below it.
fun uncapped_starts_at_ms<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self
        .uncapped
        .map_ref!(|phase| self.start_ms + phase.starts_after_ms)
        .destroy_or!(self.commitment_ends_at_ms())
}

/// When the hard cap takes hold: its offset into the window, which `finalize` bounds below the
/// duration as created; none for a sale that overflows for its whole window.
fun hard_cap_starts_at_ms<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): Option<u64> {
    self.hard_cap.map_ref!(|cap| self.start_ms + cap.starts_after_ms)
}

/// Whether the hard cap holds the sale's commitments to its raise at `now_at_ms`.
fun is_hard_capped<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, now_at_ms: u64): bool {
    self.hard_cap_starts_at_ms().is_some_and!(|phase_starts_at_ms| now_at_ms >= *phase_starts_at_ms)
}

/// Whether the sale may settle before its window ends: its raise is full under a hard cap that
/// closes the sale when filled, so it can take no more Quote.
fun can_close_early<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, now_at_ms: u64): bool {
    self.hard_cap.is_some_and!(|cap| cap.closes_when_filled)
        && self.is_hard_capped(now_at_ms)
        && self.total_commitments >= self.raise_target
}

// Presale creation

/// Raise allocations: distinct recipients that, with Blast's share, leave the LP part of the raise.
fun assert_raise_allocations(raise_allocations: &vector<RecipientShare>, protocol_raise_bps: Bps) {
    assert!(
        valid_shares(raise_allocations, constants::max_recipients!())
            && total_bps(raise_allocations) + protocol_raise_bps.value()
                < blast_core::constants::basis_points_denominator!(),
        blast_presale::errors::invalid_raise_allocation!(),
    );
}

/// Token allocations: distinct recipients totalling exactly 10,000 BPS with the sale's, the LP's,
/// and Blast's shares.
fun assert_token_allocations(
    token_supply: u64,
    token_allocation_bps: Bps,
    liquidity_token_allocation_bps: Bps,
    protocol_token_bps: Bps,
    recipient_allocations: &vector<RecipientShare>,
) {
    assert!(
        token_supply > 0
            && token_allocation_bps.value() > 0
            && liquidity_token_allocation_bps.value() > 0
            && valid_shares(recipient_allocations, constants::max_recipients!()),
        blast_presale::errors::invalid_token_allocation!(),
    );
    assert!(
        total_bps(recipient_allocations)
            + token_allocation_bps.value()
            + liquidity_token_allocation_bps.value()
            + protocol_token_bps.value() == blast_core::constants::basis_points_denominator!(),
        blast_presale::errors::invalid_token_allocation!(),
    );
}

fun assert_valid_eligibility(self: &EligibilityPolicy) {
    let valid = match (self) {
        EligibilityPolicy::Open { wallet_cap, max_participants, min_commitment } => {
            *min_commitment > 0
                && *min_commitment <= *wallet_cap
                && *max_participants > 0
                && *max_participants <= constants::max_participants!()
        },
        EligibilityPolicy::Allowlisted { root, leaf_count } => {
            root.length() == constants::digest_length!()
                && *leaf_count > 0
                && *leaf_count <= constants::max_participants!()
        },
    };
    assert!(valid, blast_presale::errors::invalid_eligibility_policy!());
}

fun assert_valid_uncapped_access(self: &UncappedPhase) {
    match (self.access) {
        UncappedAccess::Anyone { max_participants, min_commitment } => assert!(
            min_commitment > 0
                && max_participants > 0
                && max_participants <= constants::max_participants!(),
            blast_presale::errors::invalid_uncapped_phase!(),
        ),
        UncappedAccess::Eligible => (),
    }
}

/// Whether there are at most `max` shares, each naming a distinct destination and taking positive
/// BPS. `blast_core::payout::recipient` already refuses the zero address.
fun valid_shares(shares: &vector<RecipientShare>, max: u64): bool {
    shares.length() <= max
        && shares.all!(|share| {
            let destination = share.recipient.destination();
            share.bps.value() > 0
                // ponytail: O(n²) duplicate validation is bounded by `max`.
                && shares.count!(|other| other.recipient.destination() == destination) == 1
        })
}

/// The BPS these shares take in total.
fun total_bps(shares: &vector<RecipientShare>): u64 {
    (*shares).fold!(0, |sum, share| sum + share.bps.value())
}

/// The amount these payouts take in total.
fun total_amount(payouts: &vector<RecipientPayout>): u64 {
    (*payouts).fold!(0, |sum, payout| sum + payout.amount)
}

/// The phase starts inside the window, and an open-to-anyone phase admits at least the
/// policy's wallets while its minimum over the slots held to it still reaches the raise.
fun assert_uncapped_phase(
    phase: &UncappedPhase,
    commitment_duration_ms: u64,
    eligibility: EligibilityPolicy,
    raise_target: u64,
) {
    assert!(
        phase.starts_after_ms < commitment_duration_ms,
        blast_presale::errors::invalid_uncapped_phase!(),
    );
    match (phase.access) {
        UncappedAccess::Anyone { max_participants, min_commitment } => {
            assert!(
                max_participants >= eligibility.participant_bound(),
                blast_presale::errors::invalid_uncapped_phase!(),
            );
            assert!(
                reaches(
                    min_commitment,
                    eligibility.slots_at_minimum(max_participants),
                    raise_target,
                ),
                blast_presale::errors::unreachable_raise!(),
            );
        },
        UncappedAccess::Eligible => (),
    }
}

/// The number of distinct wallets the eligibility policy admits.
fun participant_bound(self: EligibilityPolicy): u64 {
    match (self) {
        EligibilityPolicy::Open { max_participants, .. } => max_participants,
        EligibilityPolicy::Allowlisted { leaf_count, .. } => leaf_count,
    }
}

/// The slots of an open-to-anyone phase whose commitments are held to the phase minimum: every
/// slot under an open policy, whose wallets already meet a minimum that reaches the raise, and
/// the slots beyond the leaf count under an allowlist, whose wallets may commit any positive
/// amount. The phase bound is at least the policy's, so the subtraction cannot underflow.
fun slots_at_minimum(self: EligibilityPolicy, max_participants: u64): u64 {
    match (self) {
        EligibilityPolicy::Open { .. } => max_participants,
        EligibilityPolicy::Allowlisted { leaf_count, .. } => max_participants - leaf_count,
    }
}

/// Whether filling every open participant slot at the minimum commitment funds the raise.
/// Allowlist caps are committed off chain, so only the open policy is checked.
fun can_reach(self: EligibilityPolicy, raise_target: u64): bool {
    match (self) {
        EligibilityPolicy::Open { max_participants, min_commitment, .. } => {
            reaches(min_commitment, max_participants, raise_target)
        },
        EligibilityPolicy::Allowlisted { .. } => true,
    }
}

/// Whether `max_participants` wallets each committing `min_commitment` reach `raise_target`.
fun reaches(min_commitment: u64, max_participants: u64, raise_target: u64): bool {
    (min_commitment as u128) * (max_participants as u128) >= (raise_target as u128)
}

/// The LP's tokens and Quote seed a price both CLMM venues can pool.
fun assert_seedable_price(liquidity_tokens: u64, liquidity_quote: u64) {
    assert!(
        migration::is_seedable_price(
            migration::sqrt_price_x64(liquidity_tokens, liquidity_quote, true),
        ),
        blast_presale::errors::unseedable_price!(),
    );
}

/// Apportions the supply so every atomic unit belongs to exactly one allocation, returning the
/// presale and LP allocations, Blast's allocation, and each recipient's payout. The presale, LP,
/// and every recipient must receive a positive amount.
fun apportion_supply(
    token_supply: u64,
    token_allocation_bps: Bps,
    liquidity_token_allocation_bps: Bps,
    protocol_token_bps: Bps,
    recipient_allocations: &vector<RecipientShare>,
): (u64, u64, u64, vector<RecipientPayout>) {
    // Apportioned in this order: the presale, the LP, Blast, then each recipient.
    let mut shares = vector[
        token_allocation_bps,
        liquidity_token_allocation_bps,
        protocol_token_bps,
    ];
    shares.append(recipient_allocations.map_ref!(|allocation| allocation.bps));
    let amounts = bps::apportion(shares, token_supply, option::none());

    let (token_allocation, liquidity_token_allocation) = (amounts[0], amounts[1]);
    let recipient_payouts = payouts(recipient_allocations, &amounts, 3);
    assert!(
        token_allocation > 0
            && liquidity_token_allocation > 0
            && recipient_payouts.all!(|payout| payout.amount > 0),
        blast_presale::errors::invalid_token_allocation!(),
    );

    (token_allocation, liquidity_token_allocation, amounts[2], recipient_payouts)
}

/// Apportions the raise the same way among the recipients, Blast, and the LP, which keeps the
/// last share, returning each recipient's payout, Blast's Quote, and the LP's Quote. Every
/// recipient and the LP must receive a positive amount.
fun apportion_raise(
    raise_allocations: &vector<RecipientShare>,
    protocol_raise_bps: Bps,
    raise_target: u64,
): (vector<RecipientPayout>, u64, u64) {
    // Apportioned in this order: each recipient, Blast, then the LP, which keeps the rest.
    let allocated_bps = total_bps(raise_allocations) + protocol_raise_bps.value();
    let mut shares = raise_allocations.map_ref!(|allocation| allocation.bps);

    shares.push_back(protocol_raise_bps);
    shares.push_back(bps::new(blast_core::constants::basis_points_denominator!() - allocated_bps));
    let amounts = bps::apportion(shares, raise_target, option::none());

    let raise_payouts = payouts(raise_allocations, &amounts, 0);
    let protocol_quote = amounts[raise_allocations.length()];
    let liquidity_quote = amounts[raise_allocations.length() + 1];
    assert!(
        raise_payouts.all!(|payout| payout.amount > 0) && liquidity_quote > 0,
        blast_presale::errors::invalid_raise_allocation!(),
    );

    (raise_payouts, protocol_quote, liquidity_quote)
}

/// Pairs each allocation's recipient with its apportioned amount, read from `amounts` starting
/// at `first`.
fun payouts(
    allocations: &vector<RecipientShare>,
    amounts: &vector<u64>,
    first: u64,
): vector<RecipientPayout> {
    vector::tabulate!(
        allocations.length(),
        |i| RecipientPayout { recipient: allocations[i].recipient, amount: amounts[first + i] },
    )
}

/// The pinned Coin Registry exposes only `is_regulated`, which also returns false for
/// legacy `Unknown` currencies that may have a deny cap. Read the canonical Currency BCS
/// prefix to require `Unregulated` instead. Recheck this layout when changing the Sui pin.
/// Holding the TreasuryCap proves supply is still Some(Unknown); reject any other layout.
fun assert_unregulated_currency<SaleToken>(currency: &Currency<SaleToken>) {
    assert_unregulated_currency_bytes(bcs::to_bytes(currency));
}

fun assert_unregulated_currency_bytes(serialized: vector<u8>) {
    let mut bytes = sui::bcs::new(serialized);
    bytes.peel_address(); // UID
    bytes.peel_u8(); // decimals
    bytes.peel_vec_u8(); // name
    bytes.peel_vec_u8(); // symbol
    bytes.peel_vec_u8(); // description
    bytes.peel_vec_u8(); // icon_url
    assert!(
        bytes.peel_vec_length() == 1 // Some supply
            && bytes.peel_enum_tag() == 2 // SupplyState::Unknown
            && bytes.peel_enum_tag() == 1, // RegulatedState::Unregulated
        blast_presale::errors::sale_token_not_unregulated!(),
    );
}

/// Mints the complete supply once, splits off the presale, LP, and Blast allocations, then gives
/// up mint authority forever by making the supply fixed or burn-only.
fun mint_and_seal_supply<SaleToken>(
    mut treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    token_supply: u64,
    token_allocation: u64,
    liquidity_token_allocation: u64,
    protocol_token_allocation: u64,
    burnable: bool,
): (Balance<SaleToken>, Balance<SaleToken>, Balance<SaleToken>, Balance<SaleToken>) {
    let mut recipient_tokens = treasury_cap.mint_balance(token_supply);
    let sale_tokens = recipient_tokens.split(token_allocation);
    let liquidity_tokens = recipient_tokens.split(liquidity_token_allocation);
    let protocol_tokens = recipient_tokens.split(protocol_token_allocation);

    if (burnable) currency.make_supply_burn_only(treasury_cap)
    else currency.make_supply_fixed(treasury_cap);

    (sale_tokens, liquidity_tokens, protocol_tokens, recipient_tokens)
}

// Fee changes

/// Blast's Quote under the raise rate `raise_bps`: the amount creation apportioned while the rate
/// is unchanged, otherwise its rate of the raise, rounded down.
fun protocol_quote_at<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, raise_bps: Bps): u64 {
    if (raise_bps == self.protocol_fees.raise_bps()) return self.protocol_quote;

    self.raise_target.mul_div(raise_bps.value(), blast_core::constants::basis_points_denominator!())
}

/// Blast's tokens under the token rate `token_bps`: the amount creation apportioned while the
/// rate is unchanged, otherwise its rate of the supply, rounded down.
fun protocol_tokens_at<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, token_bps: Bps): u64 {
    if (token_bps == self.protocol_fees.token_bps()) return self.protocol_tokens.value();

    self
        .token_supply()
        .mul_div(token_bps.value(), blast_core::constants::basis_points_denominator!())
}

/// The complete supply, all of it still escrowed before the window starts.
fun token_supply<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self.sale_tokens.value()
        + self.liquidity_tokens.value()
        + self.recipient_tokens.value()
        + self.protocol_tokens.value()
}

// Commitments

fun record_commitment<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    mut quote_in: Coin<Quote>,
    wallet_cap: u64,
    max_participants: u64,
    min_commitment: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    let uncapped = clock.timestamp_ms() >= self.uncapped_starts_at_ms();
    let hard_capped = self.is_hard_capped(clock.timestamp_ms());
    let max_participants = self.participant_limit(uncapped, max_participants);
    let accepted_quote = self.acceptable_quote(quote_in.value(), hard_capped);
    let fills_raise = hard_capped && self.total_commitments + accepted_quote == self.raise_target;

    let key = CommitmentKey(ctx.sender());
    let is_new_participant = !self.id.has_dynamic_field(key);
    let wallet_commitment = self
        .commitment_or_empty(key, wallet_cap)
        .add_within_cap(accepted_quote, wallet_cap, uncapped);

    // The commitment that exactly fills a hard cap may be smaller than the minimum.
    assert!(
        wallet_commitment >= min_commitment || fills_raise,
        blast_presale::errors::below_minimum_commitment!(),
    );
    assert!(
        !is_new_participant || self.participants < max_participants,
        blast_presale::errors::participant_capacity_reached!(),
    );

    let total_commitments = self
        .total_commitments
        .checked_add(accepted_quote)
        .destroy_or!(abort blast_presale::errors::total_commitment_overflow!());

    self.store_commitment(key, wallet_commitment, wallet_cap);
    self.total_commitments = total_commitments;
    self.quote.join(quote_in.split(accepted_quote, ctx).into_balance());

    events::committed<SaleToken, Quote>(
        self.id.to_inner(),
        accepted_quote,
        wallet_commitment,
        total_commitments,
        self.participants,
    );

    quote_in
}

/// The wallet cap, participant bound, and minimum commitment of an open policy.
fun open_limits(policy: EligibilityPolicy): (u64, u64, u64) {
    match (policy) {
        EligibilityPolicy::Open { wallet_cap, max_participants, min_commitment } => {
            (wallet_cap, max_participants, min_commitment)
        },
        EligibilityPolicy::Allowlisted { .. } =>
            abort blast_presale::errors::wrong_eligibility_policy!(),
    }
}

/// The participant bound and minimum commitment of an uncapped phase open to anyone.
fun anyone_limits(phase: UncappedPhase): (u64, u64) {
    match (phase.access) {
        UncappedAccess::Anyone { max_participants, min_commitment } => {
            (max_participants, min_commitment)
        },
        UncappedAccess::Eligible => abort blast_presale::errors::uncapped_phase_not_open!(),
    }
}

/// The participant bound that applies now: the policy's until the uncapped phase starts, then
/// the phase's own.
fun participant_limit<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    uncapped: bool,
    policy_max_participants: u64,
): u64 {
    if (!uncapped) return policy_max_participants;

    match (self.uncapped.destroy_some().access) {
        UncappedAccess::Anyone { max_participants, .. } => max_participants,
        UncappedAccess::Eligible => policy_max_participants,
    }
}

/// The Quote a commitment of `offered` adds: all of it, except that under the hard cap the sale
/// accepts only what is left of the raise.
fun acceptable_quote<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    offered: u64,
    hard_capped: bool,
): u64 {
    if (!hard_capped) return offered;

    assert!(self.total_commitments < self.raise_target, blast_presale::errors::presale_filled!());
    offered.min(self.raise_target - self.total_commitments)
}

/// The wallet's commitment so far, or an empty one under `wallet_cap` before its first commit.
fun commitment_or_empty<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    key: CommitmentKey,
    wallet_cap: u64,
): Commitment {
    if (self.id.has_dynamic_field(key)) *dynamic_field::borrow(&self.id, key)
    else Commitment { quote: 0, wallet_cap }
}

/// The wallet's total after adding `quote`, held to the caller's cap until the uncapped phase.
fun add_within_cap(self: Commitment, quote: u64, wallet_cap: u64, uncapped: bool): u64 {
    // Caps no longer apply once uncapped, so a record's cap need not match the caller's.
    assert!(
        uncapped || self.wallet_cap == wallet_cap,
        blast_presale::errors::invalid_eligibility_proof!(),
    );

    let wallet_commitment = self
        .quote
        .checked_add(quote)
        .destroy_or!(abort blast_presale::errors::wallet_cap_exceeded!());
    assert!(
        uncapped || wallet_commitment <= wallet_cap,
        blast_presale::errors::wallet_cap_exceeded!(),
    );

    wallet_commitment
}

/// Records the wallet's new total, admitting the wallet as a participant on its first commitment.
fun store_commitment<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    key: CommitmentKey,
    wallet_commitment: u64,
    wallet_cap: u64,
) {
    if (self.id.has_dynamic_field(key)) {
        self.id.dynamic_field_mut<_, Commitment>(key).quote = wallet_commitment;
    } else {
        self.id.add_dynamic_field(key, Commitment { quote: wallet_commitment, wallet_cap });
        self.participants = self.participants + 1;
    };
}

/// The allowlist's leaf count, after proving `wallet_cap` is `wallet`'s committed cap at `index`.
fun verify_allowlisted(
    policy: EligibilityPolicy,
    index: u64,
    wallet: address,
    wallet_cap: u64,
    proof: &vector<vector<u8>>,
): u64 {
    match (policy) {
        EligibilityPolicy::Open { .. } => abort blast_presale::errors::wrong_eligibility_policy!(),
        EligibilityPolicy::Allowlisted { root, leaf_count } => {
            assert!(wallet_cap > 0, blast_presale::errors::invalid_eligibility_proof!());

            let digest = allowlist_leaf(index, wallet, wallet_cap);
            assert!(
                merkle::verify(root, digest, index, leaf_count, proof),
                blast_presale::errors::invalid_eligibility_proof!(),
            );

            leaf_count
        },
    }
}

/// The digest of one allowlist leaf, under the presale allowlist's Merkle leaf domain.
fun allowlist_leaf(index: u64, wallet: address, wallet_cap: u64): vector<u8> {
    let mut payload = bcs::to_bytes(&index);
    payload.append(bcs::to_bytes(&wallet));
    payload.append(bcs::to_bytes(&wallet_cap));

    merkle::leaf(constants::allowlist_leaf_domain!(), payload)
}

// Claims

/// The sale tokens one commitment claims: none unless the sale migrated, otherwise its pro-rata
/// share of the token allocation, or everything left on the last claim.
fun claimable_tokens<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, commitment: u64): u64 {
    if (self.lifecycle != Lifecycle::Migrated) return 0;
    if (self.is_last_claim()) return self.sale_tokens.value();

    self.token_allocation.mul_div(commitment, self.total_commitments)
}

/// The Quote one commitment gets back: its pro-rata share of every commitment after a
/// cancellation, or of the overflow above the raise after a migration; everything left on the
/// last claim.
fun refundable_quote<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, commitment: u64): u64 {
    if (self.is_last_claim()) return self.quote.value();

    let refund_pool = if (self.lifecycle == Lifecycle::Cancelled) self.total_commitments
    else self.total_commitments - self.raise_target;

    refund_pool.mul_div(commitment, self.total_commitments)
}

/// Whether the claim in progress, whose record `claim` has already removed, is the final one: it
/// takes everything left so the integer-rounding remainder is never stranded.
fun is_last_claim<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.participants == 1
}

// Migration

/// Moves Blast's raise fee and token fee into the sale's ledger and pays them to `treasury` now,
/// or, when the sale names a partner, holds them for `pay_protocol_fees_with_partner`.
fun pay_or_hold_protocol_fees<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    protocol_quote: Balance<Quote>,
    treasury: &Treasury,
    ctx: &mut TxContext,
) {
    self.fee_ledger.accrue(self.protocol_tokens.withdraw_all(), protocol_quote);

    if (self.partner_id.is_none()) self.fee_ledger.pay(treasury, ctx);
}

/// Releases each raise recipient its share out of `quote`, leaving the LP's share.
fun pay_raise_allocations<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    quote: &mut Balance<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.raise_payouts.do_ref!(|raise_payout| {
        let vesting_id = payout::pay_or_vest(
            quote,
            raise_payout.amount,
            &raise_payout.recipient,
            clock,
            ctx,
        );
        events::raise_allocated<SaleToken, Quote>(
            self.id.to_inner(),
            raise_payout.recipient.destination(),
            raise_payout.amount,
            vesting_id,
        );
    });
}

/// Releases every escrowed recipient token to its configured recipient.
fun release_recipient_tokens<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.recipient_payouts.length().do!(|i| {
        let recipient_payout = self.recipient_payouts[i];
        let vesting_id = payout::pay_or_vest(
            &mut self.recipient_tokens,
            recipient_payout.amount,
            &recipient_payout.recipient,
            clock,
            ctx,
        );
        events::recipient_allocated<SaleToken, Quote>(
            self.id.to_inner(),
            recipient_payout.recipient.destination(),
            recipient_payout.amount,
            vesting_id,
        );
    });
}

// Cancellation

fun cancel<SaleToken, Quote>(self: &mut Presale<SaleToken, Quote>) {
    self.lifecycle = Lifecycle::Cancelled;

    events::presale_cancelled<SaleToken, Quote>(
        self.id.to_inner(),
        self.total_commitments,
        self.quote.value(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// An unshared presale registry, as publication shares it.
public fun registry_for_testing(ctx: &mut TxContext): PresaleRegistry {
    PresaleRegistry { id: object::new(ctx) }
}

#[test_only]
/// The key the presale of `SaleToken` derives its ID from.
public fun presale_key_for_testing<SaleToken>(): PresaleKey<SaleToken> {
    PresaleKey()
}

#[test_only]
/// Builds an open policy without its rules, as superseded bytecode could.
public fun open_eligibility_unchecked_for_testing(
    wallet_cap: u64,
    max_participants: u64,
    min_commitment: u64,
): EligibilityPolicy {
    EligibilityPolicy::Open { wallet_cap, max_participants, min_commitment }
}

#[test_only]
public fun assert_unregulated_currency_for_testing<SaleToken>(currency: &Currency<SaleToken>) {
    currency.assert_unregulated_currency();
}

#[test_only]
public fun assert_unregulated_currency_bytes_for_testing(serialized: vector<u8>) {
    assert_unregulated_currency_bytes(serialized);
}

#[test_only]
public fun cap_for_testing(presale_id: ID, ctx: &mut TxContext): PresaleCap {
    PresaleCap { id: object::new(ctx), presale_id }
}

#[test_only]
public fun allowlist_leaf_for_testing(index: u64, wallet: address, wallet_cap: u64): vector<u8> {
    allowlist_leaf(index, wallet, wallet_cap)
}

#[test_only]
public fun merkle_node_for_testing(left: vector<u8>, right: vector<u8>): vector<u8> {
    merkle::node(left, right)
}

#[test_only]
public fun protocol_fees_for_testing<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): ProtocolFees {
    self.protocol_fees
}

#[test_only]
public fun is_funded_for_testing<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.lifecycle == Lifecycle::Funded
}

#[test_only]
public fun is_migrated_for_testing<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.lifecycle == Lifecycle::Migrated
}

#[test_only]
public fun is_cancelled_for_testing<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.lifecycle == Lifecycle::Cancelled
}

#[test_only]
public fun custody_for_testing<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): (u64, u64, u64, u64, u64, u64, u64) {
    (
        self.total_commitments,
        self.participants,
        self.quote.value(),
        self.sale_tokens.value(),
        self.liquidity_tokens.value(),
        self.recipient_tokens.value(),
        self.protocol_tokens.value(),
    )
}

#[test_only]
public fun commitment_for_testing<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    participant: address,
): u64 {
    let key = CommitmentKey(participant);

    if (self.id.has_dynamic_field(key)) {
        dynamic_field::borrow<_, Commitment>(&self.id, key).quote
    } else 0
}

#[test_only]
public fun created_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (ID, ID, ID, u64, u64, u64, u64, u64, u64, EligibilityPolicy) {
    (
        event.presale_id,
        event.presale_cap_id,
        event.treasury_cap_id,
        event.token_supply,
        event.token_allocation_bps,
        event.liquidity_token_allocation_bps,
        event.raise_target,
        event.duration_ms,
        event.liquidity_window_ms,
        event.eligibility,
    )
}

#[test_only]
public fun created_migration_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (TypeName, FeeSplit) {
    (event.venue, event.fee_split)
}

#[test_only]
public fun created_protocol_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (vector<u64>, u64, u64) {
    (
        vector[
            event.protocol_raise_bps,
            event.protocol_token_bps,
            event.protocol_lp_fee_meme_bps,
            event.protocol_lp_fee_quote_bps,
        ],
        event.protocol_quote,
        event.protocol_tokens,
    )
}

#[test_only]
public fun hard_cap_for_testing(start_delay_ms: u64, closes_when_filled: bool): HardCap {
    HardCap { starts_after_ms: start_delay_ms, closes_when_filled }
}

#[test_only]
public fun created_hard_cap<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): Option<HardCap> {
    event.hard_cap
}

#[test_only]
/// Blast's Meme, Quote, and SUI fees the sale's ledger holds.
public fun protocol_fee_balances_for_testing<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): (u64, u64, u64) {
    self.fee_ledger.balances()
}

#[test_only]
public fun recipient_for_testing(share: &RecipientShare): Recipient {
    share.recipient
}

#[test_only]
public fun created_supply_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (vector<Recipient>, vector<u64>, bool) {
    (event.recipients, event.recipient_bps, event.burnable)
}

#[test_only]
public fun created_raise_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (vector<Recipient>, vector<u64>) {
    (event.raise_recipients, event.raise_recipient_bps)
}

#[test_only]
public fun created_participant_vesting<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): Option<VestingTerms> {
    event.participant_vesting
}

// === Events ===

/// A presale was created with fully funded token allocations.
public struct PresaleCreated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    presale_cap_id: ID,
    treasury_cap_id: ID,
    token_supply: u64,
    token_allocation_bps: u64,
    participant_vesting: Option<VestingTerms>,
    liquidity_token_allocation_bps: u64,
    /// Each token recipient, with the terms it vests under, if any, and its share.
    recipients: vector<Recipient>,
    recipient_bps: vector<u64>,
    burnable: bool,
    raise_target: u64,
    /// Each raise recipient, with the terms it vests under, if any, and its share.
    raise_recipients: vector<Recipient>,
    raise_recipient_bps: vector<u64>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    hard_cap: Option<HardCap>,
    venue: TypeName,
    fee_split: FeeSplit,
    /// Blast's rates, snapshotted for this sale.
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    /// Blast's shares of the raise and of the supply, paid on migration.
    protocol_quote: u64,
    protocol_tokens: u64,
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, package_version::PackageVersion};

use blast_core::{
    blast_domain::FeeAdmin,
    blast_treasury::Treasury,
    bps::{Self, Bps},
    fee_split::FeeSplit,
    merkle,
    migration::{Self, Migration, VenueTicket},
    owner_proof::{Self, OwnerProof},
    payout::{Self, Recipient, VestingTerms},
    protocol_fees::{Self, Ledger}
};

use blast_partners::blast_partners::Partner;

use blast_presale::{
    blast_presale_package::{Self, BLAST_PRESALE_PACKAGE},
    constants,
    creation_policy::CreationPolicy,
    events,
    fee_policy::{Self, FeePolicy, ProtocolFees}
};

use std::{bcs, type_name::{Self, TypeName}};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    derived_object,
    dynamic_field
};

use fun bps_of as vector.bps;

use fun recipients_of as vector.recipients;

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;

use fun dynamic_field::remove as UID.remove_dynamic_field;

use fun assert_unregulated_currency as Currency.assert_unregulated_currency;
