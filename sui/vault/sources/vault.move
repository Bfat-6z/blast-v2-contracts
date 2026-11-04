// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the vault's abort location.
#[allow(lint(abort_without_constant))]
/// The one LP vault every Blast sale migrates into: permanent custody of a venue position, and the
/// split of every fee collection it earns.
///
/// An admitted venue builds the vault from the terms it redeemed from a sale's migration (or its
/// own standalone terms), attaches the position under its sealed `Venue` key, and shares it. Every
/// collection then pays Blast its per-vault share through the core protocol ledger, at once or held
/// for the sale's partner, and divides the rest by the vault's fee split: address routes are paid
/// at once, and the owner, auto-LP, holder-reward, and burn routes accrue here. The owner acts with
/// an `OwnerProof` from the sale's product; Blast acts through its roles; venue-only operations
/// require the venue's witness, which only the venue module constructs.
module blast_vault::vault;

// === Public Types ===

/// Derives a sale's one vault from the registry: the witness that sealed its terms and the sale.
public struct VaultKey has copy, drop, store {
    issuer: TypeName,
    origin: ID,
}

/// The key under which the venue's migration position is held; only `Venue` can reach it.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// The key for the separate position auto-LP adds to on venues whose migration position cannot
/// receive more liquidity (Cetus burns it).
public struct AutoLpPositionKey<phantom Venue>() has copy, drop, store;

/// Keys the fee split's delayed lifecycle.
public struct FeeSplitKey() has copy, drop, store;

/// Keys Blast's per-vault share's delayed lifecycle.
public struct ProtocolBpsKey() has copy, drop, store;

/// Keys the holder-reward round publication's delayed lifecycle; its action is the round's terms.
public struct RoundPublicationKey() has copy, drop, store;

/// The witness that creates every vault's protocol ledger; only this module constructs it.
public struct VaultWitness() has drop;

/// What a venue took from one vault's burn Quote for a buyback; `burn_buyback` on the same vault
/// consumes it, so the Quote spent is measured here, not reported by the venue.
public struct BuybackReceipt {
    vault_id: ID,
    taken_quote: u64,
}

/// What a venue took from one vault's auto-LP balances; `keep_auto_lp` on the same vault consumes
/// it, so the liquidity added is measured here, not reported by the venue.
public struct AutoLpReceipt {
    vault_id: ID,
    taken_meme: u64,
    taken_quote: u64,
}

/// Blast's share of each LP-fee collection, per asset, each at most 3,000 basis points.
public struct ProtocolBps has copy, drop, store {
    meme_bps: Bps,
    quote_bps: Bps,
}

/// The committed terms of one holder-reward round, checked when built: two 32-byte commitments, 1
/// to 65,536 leaves, a nonempty checkpoint interval and budget, a holder Quote and gas reserve that
/// sum within u64 with the reserve at most 10% of the holder Quote, a nonzero expected treasury,
/// and a positive claim window. The claim window is a duration; publication starts it.
public struct RoundTerms has copy, drop, store {
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
    claim_window_duration_ms: u64,
    expected_treasury: address,
}

/// Shared custody for one migrated sale's position and the balances its LP fees are split into.
/// A holder-reward round waits in `round_publication` for its applied notice before anyone may
/// publish it; at most one round is scheduled at a time.
public struct Vault<phantom Meme, phantom Quote> has key {
    id: UID,
    /// The terms the vault was created with; owner proofs are checked against them.
    terms: VaultTerms,
    pool_id: ID,
    fee_split: Delayed<FeeSplitKey, FeeSplit>,
    protocol_bps: Delayed<ProtocolBpsKey, ProtocolBps>,
    protocol: Ledger<Meme, Quote>,
    owner_meme: Balance<Meme>,
    owner_quote: Balance<Quote>,
    auto_lp_meme: Balance<Meme>,
    auto_lp_quote: Balance<Quote>,
    rewards_meme: Balance<Meme>,
    rewards_quote: Balance<Quote>,
    burn_quote: Balance<Quote>,
    next_round: u64,
    last_checkpoint: Option<u64>,
    round_publication: DelayedAction<RoundPublicationKey, RoundTerms>,
}

// === Public Functions ===

// Venue: creation and custody

/// Builds a vault for `terms`, unshared so a venue can read its address before attaching the
/// position (Aftermath pays its DAO fees to it). Aborts unless `Venue` and the terms' sealing
/// witness are admitted and Blast's share is within the vault maximum. The vault's ID derives from
/// the registry, the sealing witness, and the sale, so each sale has exactly one vault and a client
/// computes its address from the sale alone. The vault has `key` without
/// `store`, so it cannot leave this transaction except through `share_with_position`.
public fun new<Meme, Quote, Venue>(
    registry: &mut VaultRegistry,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    terms: VaultTerms,
    pool_id: ID,
): Vault<Meme, Quote> {
    package_version.assert_current(constants::generation!());
    registry.assert_venue<Venue>();
    registry.assert_issuer(terms.package_witness());
    let (meme_bps, quote_bps) = terms.protocol_bps();
    let protocol_bps = new_protocol_bps(meme_bps, quote_bps);

    let key = VaultKey { issuer: terms.package_witness(), origin: terms.origin() };
    let id = derived_object::claim(registry.uid_mut(), key);
    let fee_split = delayed::new(
        FeeSplitKey(),
        &id,
        terms.fee_split(),
        constants::fee_change_delay_ms!(),
    );
    let protocol_bps = delayed::new(
        ProtocolBpsKey(),
        &id,
        protocol_bps,
        constants::fee_change_delay_ms!(),
    );
    let round_publication = delayed_action::new(
        RoundPublicationKey(),
        &id,
        constants::round_notice_ms!(),
    );
    let protocol = protocol_fees::new(VaultWitness(), id.to_inner(), terms.partner_id());

    Vault {
        id,
        terms,
        pool_id,
        fee_split,
        protocol_bps,
        protocol,
        owner_meme: balance::zero(),
        owner_quote: balance::zero(),
        auto_lp_meme: balance::zero(),
        auto_lp_quote: balance::zero(),
        rewards_meme: balance::zero(),
        rewards_quote: balance::zero(),
        burn_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
        round_publication,
    }
}

/// Attaches `position`, holding `liquidity`, under the venue's sealed key with no removal path,
/// settles the migration residuals by the terms' policy, and shares the vault. Protocol residuals
/// are paid to the treasury at once, or held for the partner; owner residuals wait for the owner.
public fun share_with_position<Meme, Quote, Venue, Position: key + store>(
    mut self: Vault<Meme, Quote>,
    _: &Venue,
    treasury: &Treasury,
    position: Position,
    liquidity: u128,
    residual_meme: Balance<Meme>,
    residual_quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    assert!(liquidity > 0, blast_vault::errors::zero_liquidity!());

    let residual_meme_amount = residual_meme.value();
    let residual_quote_amount = residual_quote.value();
    let position_id = object::id(&position);
    self.id.add_dynamic_object_field(PositionKey<Venue>(), position);
    if (self.terms.has_protocol_residuals()) {
        self.protocol.accrue(residual_meme, residual_quote);
        if (self.terms.partner_id().is_none()) self.protocol.pay(treasury, ctx);
    } else {
        self.owner_meme.join(residual_meme);
        self.owner_quote.join(residual_quote);
    };

    blast_vault_events::vault_created<Meme, Quote, Venue>(
        self.id.to_inner(),
        self.pool_id,
        position_id,
        liquidity,
        self.terms,
        residual_meme_amount,
        residual_quote_amount,
    );
    transfer::share_object(self);
}

/// Borrows the venue's migration position mutably, with no removal path. Another venue's key finds
/// no field, so the borrow aborts.
public fun position_mut<Meme, Quote, Venue, Position: key + store>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
): &mut Position {
    package_version.assert_current(constants::generation!());

    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Whether the venue's auto-LP position exists.
public fun has_auto_lp_position<Meme, Quote, Venue>(self: &Vault<Meme, Quote>, _: &Venue): bool {
    self.id.has_dynamic_object_field(AutoLpPositionKey<Venue>())
}

/// Attaches the venue's auto-LP position once, with no removal path.
public fun attach_auto_lp_position<Meme, Quote, Venue, Position: key + store>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    position: Position,
) {
    package_version.assert_current(constants::generation!());
    self.assert_position<_, _, Venue>();

    let position_id = object::id(&position);
    self.id.add_dynamic_object_field(AutoLpPositionKey<Venue>(), position);

    blast_vault_events::auto_lp_position_opened<Meme, Quote>(self.id.to_inner(), position_id);
}

/// Borrows the venue's auto-LP position.
public fun auto_lp_position<Meme, Quote, Venue, Position: key + store>(
    self: &Vault<Meme, Quote>,
    _: &Venue,
): &Position {
    self.id.dynamic_object_field(AutoLpPositionKey<Venue>())
}

/// Borrows the venue's auto-LP position mutably, with no removal path.
public fun auto_lp_position_mut<Meme, Quote, Venue, Position: key + store>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
): &mut Position {
    package_version.assert_current(constants::generation!());

    self.id.dynamic_object_field_mut(AutoLpPositionKey<Venue>())
}

/// Receives one coin sent to the vault's address, such as Aftermath's DAO fees, for the venue that
/// holds the position.
public fun receive_coin<Meme, Quote, Venue, Asset>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    coin: Receiving<Coin<Asset>>,
): Balance<Asset> {
    package_version.assert_current(constants::generation!());
    self.assert_position<_, _, Venue>();

    transfer::public_receive(&mut self.id, coin).into_balance()
}

// Venue: fee collection

/// Splits one collection of the position's fees: Blast's share of each asset, rounded up, into the
/// protocol ledger, paid to the treasury at once unless the sale named a partner; then the rest by
/// the fee split, in route order. Address routes are paid at once; the owner, auto-LP, and
/// holder-reward routes accrue; the burn route's Meme is burned and its Quote kept for buyback. A
/// zero collection moves and emits nothing.
public fun split_fees<Meme, Quote, Venue>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    mut meme: Balance<Meme>,
    mut quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::generation!());
    self.assert_position<_, _, Venue>();
    let (gross_meme, gross_quote) = (meme.value(), quote.value());
    if (gross_meme == 0 && gross_quote == 0) {
        meme.destroy_zero();
        quote.destroy_zero();
        return
    };

    let ProtocolBps { meme_bps, quote_bps } = self.protocol_bps.value();
    let (protocol_meme, protocol_quote) = self
        .protocol
        .take_cut(&mut meme, &mut quote, meme_bps, quote_bps);
    if (self.terms.partner_id().is_none()) self.protocol.pay(treasury, ctx);

    let fee_split = self.fee_split.value();
    let route_meme = fee_split.apportion(meme.value());
    let route_quote = fee_split.apportion(quote.value());
    fee_split.routes().length().do!(|i| {
        let destination = fee_split.routes()[i].destination();
        let (meme_part, quote_part) = (meme.split(route_meme[i]), quote.split(route_quote[i]));
        self.route_fees(destination, currency, meme_part, quote_part, ctx);
    });
    meme.destroy_zero();
    quote.destroy_zero();

    blast_vault_events::fees_collected<Meme, Quote>(
        self.id.to_inner(),
        gross_meme,
        gross_quote,
        protocol_meme,
        protocol_quote,
        route_meme,
        route_quote,
    );
}

/// Aborts unless the scheduled fee split is ready; a venue checks this before settling fees under
/// the current split.
public fun assert_fee_split_ready<Meme, Quote>(self: &Vault<Meme, Quote>, clock: &Clock) {
    self.fee_split.assert_ready(clock);
}

/// Applies the ready fee split after the venue has settled the fees accrued under the current one,
/// so each fee follows the split it accrued under.
public fun apply_fee_split<Meme, Quote, Venue>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());
    self.assert_position<_, _, Venue>();

    self.fee_split.apply(clock);
}

/// Takes every Meme and Quote waiting to be added back to the position, with the receipt
/// `keep_auto_lp` must consume, even when both are zero.
public fun take_auto_lp<Meme, Quote, Venue>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
): (Balance<Meme>, Balance<Quote>, AutoLpReceipt) {
    package_version.assert_current(constants::generation!());
    self.assert_position<_, _, Venue>();

    let meme = self.auto_lp_meme.withdraw_all();
    let quote = self.auto_lp_quote.withdraw_all();
    let receipt = AutoLpReceipt {
        vault_id: self.id.to_inner(),
        taken_meme: meme.value(),
        taken_quote: quote.value(),
    };

    (meme, quote, receipt)
}

/// Consumes the auto-LP receipt, keeps what the pool did not take for the next call, and records
/// what it added: the receipt's amounts less what returns. Aborts unless the receipt is this
/// vault's and each return is at most what was taken.
public fun keep_auto_lp<Meme, Quote, Venue>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    receipt: AutoLpReceipt,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    package_version.assert_current(constants::generation!());
    self.assert_position<_, _, Venue>();
    let AutoLpReceipt { vault_id, taken_meme, taken_quote } = receipt;
    assert!(vault_id == self.id.to_inner(), blast_vault::errors::wrong_vault!());
    assert!(
        meme.value() <= taken_meme && quote.value() <= taken_quote,
        blast_vault::errors::returned_exceeds_taken!(),
    );

    let added_meme = taken_meme - meme.value();
    let added_quote = taken_quote - quote.value();

    self.auto_lp_meme.join(meme);
    self.auto_lp_quote.join(quote);

    if (added_meme == 0 && added_quote == 0) return;
    blast_vault_events::auto_liquidity_added<Meme, Quote>(
        self.id.to_inner(),
        added_meme,
        added_quote,
        self.auto_lp_meme.value(),
        self.auto_lp_quote.value(),
    );
}

/// Takes exactly `quote_in` of the Quote waiting to buy Meme back, under a buyback administrator,
/// with the receipt `burn_buyback` must consume. Aborts unless `quote_in` is positive and at most
/// the burn Quote held.
public fun take_buyback_quote<Meme, Quote, Venue>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    _: &AdminWitness<BuybackAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    quote_in: u64,
): (Balance<Quote>, BuybackReceipt) {
    package_version.assert_current(constants::generation!());
    package_version.assert_not_paused(constants::admin_pause_bit!());
    self.assert_position<_, _, Venue>();
    assert!(
        quote_in > 0 && quote_in <= self.burn_quote.value(),
        blast_vault::errors::buyback_quote_out_of_range!(),
    );

    let receipt = BuybackReceipt { vault_id: self.id.to_inner(), taken_quote: quote_in };

    (self.burn_quote.split(quote_in), receipt)
}

/// Consumes the buyback receipt, burns the Meme the swap returned, which must reach
/// `min_meme_out`, and keeps the Quote the pool did not take for the next buyback. Aborts unless
/// the receipt is this vault's and the unspent Quote is at most what was taken.
public fun burn_buyback<Meme, Quote, Venue>(
    self: &mut Vault<Meme, Quote>,
    _: &Venue,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    receipt: BuybackReceipt,
    currency: &mut Currency<Meme>,
    meme: Balance<Meme>,
    unspent_quote: Balance<Quote>,
    min_meme_out: u64,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::generation!());
    self.assert_position<_, _, Venue>();
    let BuybackReceipt { vault_id, taken_quote } = receipt;
    assert!(vault_id == self.id.to_inner(), blast_vault::errors::wrong_vault!());
    assert!(unspent_quote.value() <= taken_quote, blast_vault::errors::returned_exceeds_taken!());
    let meme_burned = meme.value();
    assert!(meme_burned >= min_meme_out, blast_vault::errors::buyback_below_minimum!());

    let quote_spent = taken_quote - unspent_quote.value();

    burn(currency, meme, ctx);
    self.burn_quote.join(unspent_quote);

    blast_vault_events::buyback_burned<Meme, Quote>(
        self.id.to_inner(),
        quote_spent,
        meme_burned,
        self.burn_quote.value(),
    );
}

// Owner

/// Claims the owner's accrued LP fees and owner residuals with an owner proof from the sale's
/// product. Aborts when nothing has accrued.
public fun claim_owner_balances<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    proof: OwnerProof,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current(constants::generation!());
    proof.assert_terms(&self.terms);
    assert!(
        self.owner_meme.value() > 0 || self.owner_quote.value() > 0,
        blast_vault::errors::nothing_to_claim!(),
    );

    let meme = self.owner_meme.withdraw_all().into_coin(ctx);
    let quote = self.owner_quote.withdraw_all().into_coin(ctx);

    blast_vault_events::owner_balances_claimed<Meme, Quote>(
        self.id.to_inner(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

/// Proposes a new fee split with an owner proof, ready after the fixed 48-hour notice.
public fun schedule_fee_split<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    proof: OwnerProof,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    proposed: FeeSplit,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());
    proof.assert_terms(&self.terms);

    self.fee_split.schedule_value(proposed, clock);
}

/// Cancels the pending fee split with an owner proof, even a ready one.
public fun cancel_fee_split<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    proof: OwnerProof,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());
    proof.assert_terms(&self.terms);

    self.fee_split.cancel();
}

// Blast

/// Proposes Blast's per-vault share, each asset at most 3,000 basis points, ready after the fixed
/// 48-hour notice; it applies to fees collected after it is applied.
public fun schedule_protocol_bps<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    _: &AdminWitness<FeeAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    meme_bps: Bps,
    quote_bps: Bps,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());
    package_version.assert_not_paused(constants::admin_pause_bit!());
    let proposed = new_protocol_bps(meme_bps, quote_bps);

    self.protocol_bps.schedule_value(proposed, clock);
}

/// Applies Blast's ready per-vault share; anyone may call it.
public fun apply_protocol_bps<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());
    package_version.assert_not_paused(constants::admin_pause_bit!());

    self.protocol_bps.apply(clock);
}

/// Cancels Blast's pending per-vault share, even a ready one.
public fun cancel_protocol_bps<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());

    self.protocol_bps.cancel();
}

/// Pays the Blast fees held for the sale's partner: the partner its cut of each asset, then the
/// treasury the rest. Anyone may call it, since both payees are fixed; holding nothing moves and
/// emits nothing.
public fun pay_protocol_fees_with_partner<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    partner: &Partner,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::generation!());

    self.protocol.pay_with_partner(treasury, partner, ctx);
}

/// The pool the vault's position belongs to; venues check collections come from it.
public fun pool_id<Meme, Quote>(self: &Vault<Meme, Quote>): ID {
    self.pool_id
}

// === Package Functions ===

/// Builds a round's terms after their static checks; `holder_rewards` checks them against the
/// vault when scheduling and again when publishing.
public(package) fun new_round_terms(
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
    claim_window_duration_ms: u64,
    expected_treasury: address,
): RoundTerms {
    assert!(
        root.length() == constants::digest_length!()
            && manifest_digest.length() == constants::digest_length!(),
        blast_vault::errors::invalid_commitment!(),
    );
    assert!(
        leaf_count > 0 && leaf_count <= constants::max_reward_leaves!(),
        blast_vault::errors::invalid_leaf_count!(),
    );
    assert!(meme_amount > 0 || quote_amount > 0, blast_vault::errors::empty_budget!());
    assert!(start_checkpoint < end_checkpoint, blast_vault::errors::empty_interval!());
    assert!(
        quote_amount.checked_add(gas_reserve_amount).is_some(),
        blast_vault::errors::budget_overflow!(),
    );
    assert!(
        (gas_reserve_amount as u128) * (constants::basis_points_denominator!() as u128)
            <= (quote_amount as u128) * (constants::max_gas_reserve_bps!() as u128),
        blast_vault::errors::gas_reserve_too_large!(),
    );
    assert!(expected_treasury != @0x0, blast_vault::errors::zero_treasury!());
    assert!(claim_window_duration_ms > 0, blast_vault::errors::zero_claim_window!());

    RoundTerms {
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        gas_reserve_amount,
        claim_window_duration_ms,
        expected_treasury,
    }
}

/// Schedules `terms` for publication after the applied round notice, replacing any scheduled
/// round or notice change.
public(package) fun schedule_round_publication<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    terms: RoundTerms,
    clock: &Clock,
) {
    self.round_publication.schedule(terms, clock);
}

/// Consumes the scheduled round once its notice has elapsed and returns its terms.
public(package) fun take_round_publication<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    clock: &Clock,
): RoundTerms {
    self.round_publication.take_action(clock)
}

/// Discards the scheduled round, even a ready one; aborts when a notice change is pending.
public(package) fun cancel_round_publication<Meme, Quote>(self: &mut Vault<Meme, Quote>) {
    assert!(
        self.round_publication.pending().is_none_or!(|proposal| {
            proposal.proposal_value().action().is_some()
        }),
        blast_vault::errors::wrong_round_proposal!(),
    );

    self.round_publication.cancel();
}

/// Schedules a new round notice after the applied one, replacing any scheduled round.
public(package) fun schedule_round_publication_delay<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    delay_ms: u64,
    clock: &Clock,
) {
    self.round_publication.schedule_delay(delay_ms, clock);
}

/// Applies the ready round-notice change.
public(package) fun apply_round_publication_delay<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    clock: &Clock,
) {
    self.round_publication.apply_delay(clock);
}

/// Discards the pending round-notice change, even a ready one; aborts when a round is scheduled.
public(package) fun cancel_round_publication_delay<Meme, Quote>(self: &mut Vault<Meme, Quote>) {
    assert!(
        self.round_publication.pending().is_none_or!(|proposal| {
            proposal.proposal_value().action().is_none()
        }),
        blast_vault::errors::wrong_round_proposal!(),
    );

    self.round_publication.cancel();
}

/// Reserves holder-reward funds for the round numbered `next_round`, ending at `end_checkpoint`.
public(package) fun fund_round<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    end_checkpoint: u64,
    meme_amount: u64,
    quote_amount: u64,
): (Balance<Meme>, Balance<Quote>) {
    self.next_round = self.next_round + 1;
    self.last_checkpoint = option::some(end_checkpoint);

    (self.rewards_meme.split(meme_amount), self.rewards_quote.split(quote_amount))
}

/// Restores a closed round's holder funds and unused gas custody.
public(package) fun restore_rewards<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.rewards_meme.join(meme);
    self.rewards_quote.join(quote);
}

/// The Meme and Quote not yet reserved by a holder-reward round.
public(package) fun rewards_balances<Meme, Quote>(self: &Vault<Meme, Quote>): (u64, u64) {
    (self.rewards_meme.value(), self.rewards_quote.value())
}

/// The number the next holder-reward round must carry.
public(package) fun next_round<Meme, Quote>(self: &Vault<Meme, Quote>): u64 {
    self.next_round
}

/// The checkpoint the next round must start at or after, or none before the first.
public(package) fun last_checkpoint<Meme, Quote>(self: &Vault<Meme, Quote>): Option<u64> {
    self.last_checkpoint
}

public(package) fun number(self: &RoundTerms): u64 { self.number }

public(package) fun start_checkpoint(self: &RoundTerms): u64 { self.start_checkpoint }

public(package) fun end_checkpoint(self: &RoundTerms): u64 { self.end_checkpoint }

public(package) fun root(self: &RoundTerms): vector<u8> { self.root }

public(package) fun manifest_digest(self: &RoundTerms): vector<u8> { self.manifest_digest }

public(package) fun leaf_count(self: &RoundTerms): u64 { self.leaf_count }

public(package) fun meme_amount(self: &RoundTerms): u64 { self.meme_amount }

public(package) fun quote_amount(self: &RoundTerms): u64 { self.quote_amount }

public(package) fun gas_reserve_amount(self: &RoundTerms): u64 { self.gas_reserve_amount }

public(package) fun claim_window_duration_ms(self: &RoundTerms): u64 {
    self.claim_window_duration_ms
}

public(package) fun expected_treasury(self: &RoundTerms): address { self.expected_treasury }

// === Private Functions ===

/// Blast's per-vault share, each asset at most the vault maximum.
fun new_protocol_bps(meme_bps: Bps, quote_bps: Bps): ProtocolBps {
    assert!(
        meme_bps.value() <= constants::max_protocol_bps!()
            && quote_bps.value() <= constants::max_protocol_bps!(),
        blast_vault::errors::invalid_protocol_bps!(),
    );

    ProtocolBps { meme_bps, quote_bps }
}

/// Aborts unless `Venue` holds the vault's migration position.
fun assert_position<Meme, Quote, Venue>(self: &Vault<Meme, Quote>) {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        blast_vault::errors::wrong_venue!(),
    );
}

/// Sends one route's part of a collection where its destination says.
fun route_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    destination: Destination,
    currency: &mut Currency<Meme>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    let route_address = destination.address_of();
    if (route_address.is_some()) {
        let recipient = route_address.destroy_some();
        payout::pay_all(meme, recipient, ctx);
        payout::pay_all(quote, recipient, ctx);
    } else if (destination.is_owner()) {
        self.owner_meme.join(meme);
        self.owner_quote.join(quote);
    } else if (destination.is_auto_lp()) {
        self.auto_lp_meme.join(meme);
        self.auto_lp_quote.join(quote);
    } else if (destination.is_holder_rewards()) {
        self.rewards_meme.join(meme);
        self.rewards_quote.join(quote);
    } else {
        burn(currency, meme, ctx);
        self.burn_quote.join(quote);
    }
}

/// Burns `meme`, or sends it to `@0x0` when the supply is fixed.
fun burn<Meme>(currency: &mut Currency<Meme>, meme: Balance<Meme>, ctx: &mut TxContext) {
    if (currency.is_supply_burn_only()) return currency.burn_balance(meme);

    payout::pay_all(meme, @0x0, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// The key a vault's ID derives from, for the terms sealed by `issuer` for the sale `origin`.
public fun vault_key_for_testing(issuer: TypeName, origin: ID): VaultKey {
    VaultKey { issuer, origin }
}

#[test_only]
/// The owner's, auto-LP's, holder rewards', and burn's balances, in that order.
public fun balances_for_testing<Meme, Quote>(
    self: &Vault<Meme, Quote>,
): (u64, u64, u64, u64, u64, u64, u64) {
    (
        self.owner_meme.value(),
        self.owner_quote.value(),
        self.auto_lp_meme.value(),
        self.auto_lp_quote.value(),
        self.rewards_meme.value(),
        self.rewards_quote.value(),
        self.burn_quote.value(),
    )
}

#[test_only]
/// The Meme, Quote, and SUI the protocol ledger holds.
public fun protocol_balances_for_testing<Meme, Quote>(self: &Vault<Meme, Quote>): (u64, u64, u64) {
    self.protocol.balances()
}

#[test_only]
/// The applied fee split.
public fun fee_split_for_testing<Meme, Quote>(self: &Vault<Meme, Quote>): FeeSplit {
    self.fee_split.value()
}

#[test_only]
/// Blast's applied per-vault share, Meme then Quote.
public fun protocol_bps_for_testing<Meme, Quote>(self: &Vault<Meme, Quote>): (Bps, Bps) {
    let ProtocolBps { meme_bps, quote_bps } = self.protocol_bps.value();

    (meme_bps, quote_bps)
}

#[test_only]
/// The round-publication slot: its applied notice and any scheduled round or notice.
public fun round_publication_for_testing<Meme, Quote>(
    self: &Vault<Meme, Quote>,
): &DelayedAction<RoundPublicationKey, RoundTerms> {
    &self.round_publication
}

#[test_only]
/// Adds holder-reward funds directly, as a collection's holder-reward route would.
public fun fund_rewards_for_testing<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.rewards_meme.join(meme);
    self.rewards_quote.join(quote);
}

#[test_only]
/// Takes unreserved holder-reward funds without advancing the round cursor, so a test can shrink
/// the budget between scheduling and publication; no production path does.
public fun withdraw_rewards_for_testing<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    meme_amount: u64,
    quote_amount: u64,
): (Balance<Meme>, Balance<Quote>) {
    (self.rewards_meme.split(meme_amount), self.rewards_quote.split(quote_amount))
}

#[test_only]
/// Adds burn Quote directly, as a collection's burn route would.
public fun fund_burn_quote_for_testing<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    quote: Balance<Quote>,
) {
    self.burn_quote.join(quote);
}

#[test_only]
/// Shares the vault without a position, for tests of round and Blast operations only.
public fun share_for_testing<Meme, Quote>(self: Vault<Meme, Quote>) {
    transfer::share_object(self);
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, Delayed},
    delayed_action::{Self, DelayedAction},
    package_version::PackageVersion
};

use blast_core::{
    blast_domain::{BuybackAdmin, CancelAdmin, FeeAdmin},
    blast_treasury::Treasury,
    bps::Bps,
    fee_split::{Destination, FeeSplit},
    migration::VaultTerms,
    owner_proof::OwnerProof,
    payout,
    protocol_fees::{Self, Ledger}
};

use blast_partners::blast_partners::Partner;

use blast_vault::{
    blast_vault_events,
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    constants
};

use std::type_name::TypeName;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::Currency,
    derived_object,
    dynamic_object_field,
    transfer::Receiving
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow as UID.dynamic_object_field;

use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;

use fun dynamic_object_field::exists as UID.has_dynamic_object_field;
