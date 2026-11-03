// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed dynamic-object custody for migration positions, their protocol residuals, and the
/// balances every LP-fee collection is split into.
module blast_fun_migrators::vault;

// === Constants ===

/// Initial notice before a creator split or its next notice period may change.
const DEFAULT_FEE_SPLIT_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

/// Initial notice before a scheduled holder-reward round may publish, or its next notice
/// period may change. Zero lets a round schedule and publish in one transaction.
const DEFAULT_ROUND_NOTICE_MS: u64 = 0;

// === Public Types ===

/// A sealed field name that binds one venue position type to one vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// A sealed field name for the separate position auto-LP adds to on venues whose migration
/// position cannot receive more liquidity (Cetus burns it).
public struct AutoLpPositionKey<phantom Venue>() has copy, drop, store;

/// Keys the creator fee split's delayed lifecycle.
public struct FeeSplitKey() has copy, drop, store;

/// Keys the holder-reward round publication's delayed lifecycle; its action is the round's terms.
public struct RoundPublicationKey() has copy, drop, store;

/// The committed terms of one holder-reward round, checked when built: two 32-byte commitments,
/// 1 to 65,536 leaves, a nonempty checkpoint interval and budget, a holder Quote and gas reserve
/// that sum within u64, a nonzero expected treasury, and a positive claim window. The claim
/// window is a duration; publication starts it.
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

/// Shared per-launch custody for one position, its protocol migration residuals, and the balances
/// its LP fees are split into.
///
/// Every collection pays Blast's live share from `LpFeePolicy`, then splits the rest by the
/// creator's `FeeSplit`: the creator share accrues here until the live curve-fee cap claims it,
/// the auto-LP share goes back into the position in the same call (any part the pool does not
/// take waits here for the next call), the rewards share funds holder-reward rounds, and every
/// recipient is paid at once. The burn share's Meme is burned at once and its Quote waits here until
/// a buyback admin swaps it for Meme to burn. The split changes only after the fees accrued under
/// the current one are settled, so each fee follows the split it accrued under. When the launch
/// named a partner, Blast's live share waits here instead, until
/// `claim_protocol_lp_fees_with_partner` pays the partner its cut and Blast the rest.
///
/// A holder-reward round waits in `round_publication` for its applied notice before anyone may
/// publish it; at most one round is scheduled at a time.
public struct LpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    /// The Blast partner the launch named, paid its cut of Blast's LP fees. It never changes.
    partner_id: Option<ID>,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    unpaid_protocol_meme: Balance<Meme>,
    unpaid_protocol_quote: Balance<Quote>,
    fee_split: Delayed<FeeSplitKey, FeeSplit>,
    creator_meme: Balance<Meme>,
    creator_quote: Balance<Quote>,
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

/// Announces a creator split and next notice period under the live curve-fee cap.
/// The currently applied notice always governs this proposal, including a reduction to zero.
public fun schedule_fee_split<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    proposed: FeeSplit,
    delay_ms: u64,
    clock: &Clock,
) {
    migrators_version.assert_current();
    launch.assert_curve_fee_cap(curve_fee_cap);

    self.fee_split.schedule(proposed, delay_ms, clock);
}

/// Cancels even a ready creator-split proposal with the launch's live curve-fee cap.
public fun cancel_fee_split<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
) {
    migrators_version.assert_current();
    launch.assert_curve_fee_cap(curve_fee_cap);

    self.fee_split.cancel();
}

/// Claims the protocol-owned migration residuals under a treasury admin.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<TreasuryAdmin>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    assert!(
        self.protocol_meme_residual.value() > 0 || self.protocol_quote_residual.value() > 0,
        ENothingClaimable,
    );

    let meme = self.protocol_meme_residual.withdraw_all().into_coin(ctx);
    let quote = self.protocol_quote_residual.withdraw_all().into_coin(ctx);

    blast_events::protocol_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
        ctx.sender(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

/// Pays the Blast LP fees this vault holds for its launch's partner: the partner its applied cut
/// of each asset, rounded down, then the `LpFeePolicy`'s current protocol destination the
/// rest. Anyone may claim, since both payees are fixed. Holding nothing is valid, moves nothing,
/// and emits nothing, so a claim can follow any collection.
public fun claim_protocol_lp_fees_with_partner<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    partner: &Partner,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(self.partner_id.contains(&object::id(partner)), EPartnerMismatch);
    if (self.unpaid_protocol_meme.value() == 0 && self.unpaid_protocol_quote.value() == 0) return;

    let protocol_destination = policy.protocol_destination();
    let mut protocol_meme = self.unpaid_protocol_meme.withdraw_all();
    let mut protocol_quote = self.unpaid_protocol_quote.withdraw_all();
    let partner_meme = partner.pay(&mut protocol_meme, ctx);
    let partner_quote = partner.pay(&mut protocol_quote, ctx);
    let paid_meme = protocol_meme.value();
    let paid_quote = protocol_quote.value();

    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);

    blast_events::protocol_lp_fees_claimed(
        self.id.to_inner(),
        protocol_destination,
        paid_meme,
        paid_quote,
        partner_meme,
        partner_quote,
    );
}

/// Claims the creator's accrued LP-fee share with the launch's live curve-fee cap.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    launch.assert_curve_fee_cap(curve_fee_cap);
    assert!(self.creator_meme.value() > 0 || self.creator_quote.value() > 0, ENoCreatorFees);

    let meme = self.creator_meme.withdraw_all().into_coin(ctx);
    let quote = self.creator_quote.withdraw_all().into_coin(ctx);

    blast_events::creator_fees_claimed(self.id.to_inner(), meme.value(), quote.value());

    (meme, quote)
}

// === Package Functions ===

/// Creates and shares the launch's vault, holding its fee split and the protocol residuals, with
/// `position`, holding `liquidity` in pool `pool_id`, attached under the venue's sealed key.
public(package) fun create<Meme, Quote, Venue, Position: key + store>(
    launch: &Launch<Meme, Quote>,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
) {
    transfer::share_object(
        new(
            launch,
            venue,
            pool_id,
            position,
            liquidity,
            protocol_meme_residual,
            protocol_quote_residual,
            ctx,
        ),
    );
}

/// Mutably borrows the venue position without providing a removal path. Another venue's key
/// finds no field, so the borrow aborts.
public(package) fun position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Reports whether the auto-LP position exists under `Venue`.
public(package) fun has_auto_lp_position<Meme, Quote, Venue>(
    self: &LpVault<Meme, Quote>,
    _venue: &Venue,
): bool {
    self.id.has_dynamic_object_field(AutoLpPositionKey<Venue>())
}

/// Attaches the auto-LP position once, with no removal path.
public(package) fun attach_auto_lp_position<Meme, Quote, Venue, Position: key + store>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
    position: Position,
) {
    let position_id = object::id(&position);
    self.id.add_dynamic_object_field(AutoLpPositionKey<Venue>(), position);

    blast_events::auto_lp_position_opened(self.id.to_inner(), position_id);
}

/// Immutably borrows the auto-LP position.
public(package) fun auto_lp_position<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &LpVault<Meme, Quote>,
    _venue: &Venue,
): &Position {
    self.id.dynamic_object_field(AutoLpPositionKey<Venue>())
}

/// Mutably borrows the auto-LP position without providing a removal path.
public(package) fun auto_lp_position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(AutoLpPositionKey<Venue>())
}

/// Splits one collection of the position's fees: Blast's live share to the protocol destination,
/// or, when the launch named a partner, held for `claim_protocol_lp_fees_with_partner`; then the
/// creator, auto-LP, and rewards shares into their balances, the burn share's Meme burned
/// and its Quote kept for buyback, and every recipient paid. A zero collection is valid, moves
/// nothing, and emits nothing.
public(package) fun split_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    mut meme: Balance<Meme>,
    mut quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    let gross_meme = meme.value();
    let gross_quote = quote.value();
    if (gross_meme == 0 && gross_quote == 0) {
        meme.destroy_zero();
        quote.destroy_zero();
        return
    };

    let (protocol_meme_bps, protocol_quote_bps) = policy.shares<Meme>();
    let protocol_meme = protocol_meme_bps.apply_up(gross_meme);
    let protocol_quote = protocol_quote_bps.apply_up(gross_quote);
    let (creator_meme, auto_lp_meme, rewards_meme, burn_meme, recipient_meme) = self
        .fee_split
        .value()
        .apportion_fee_split(gross_meme - protocol_meme);
    let (creator_quote, auto_lp_quote, rewards_quote, burn_quote, recipient_quote) = self
        .fee_split
        .value()
        .apportion_fee_split(gross_quote - protocol_quote);
    let recipients = *self.fee_split.value().recipients();

    let protocol_destination = self.pay_or_hold_protocol_lp_fees(
        meme.split(protocol_meme),
        quote.split(protocol_quote),
        policy,
        ctx,
    );

    self.creator_meme.join(meme.split(creator_meme));
    self.creator_quote.join(quote.split(creator_quote));
    self.auto_lp_meme.join(meme.split(auto_lp_meme));
    self.auto_lp_quote.join(quote.split(auto_lp_quote));
    self.rewards_meme.join(meme.split(rewards_meme));
    self.rewards_quote.join(quote.split(rewards_quote));
    currency.burn(meme.split(burn_meme), ctx);
    self.burn_quote.join(quote.split(burn_quote));

    recipients.length().do!(|i| {
        meme.pay(recipient_meme[i], recipients[i].destination(), ctx);
        quote.pay(recipient_quote[i], recipients[i].destination(), ctx);
    });
    meme.destroy_zero();
    quote.destroy_zero();

    blast_events::fees_collected(
        self.id.to_inner(),
        gross_meme,
        gross_quote,
        protocol_destination,
        protocol_meme,
        protocol_quote,
        creator_meme,
        creator_quote,
        auto_lp_meme,
        auto_lp_quote,
        rewards_meme,
        rewards_quote,
        burn_meme,
        burn_quote,
        recipient_meme,
        recipient_quote,
    );
}

/// Takes exactly `quote_in` of the Quote waiting to buy Meme back, under a live buyback admin.
/// Aborts unless `quote_in` is positive and at most the burn Quote held.
public(package) fun take_buyback_quote<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    _: &AdminWitness<BuybackAdmin>,
    quote_in: u64,
): Balance<Quote> {
    assert!(quote_in > 0 && quote_in <= self.burn_quote.value(), EBuybackQuoteOutOfRange);

    self.burn_quote.split(quote_in)
}

/// Burns the Meme a swap of `quote_in` returned, which must reach `min_meme_out`, and keeps the
/// Quote the pool did not take for the next buyback.
public(package) fun burn_buyback<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    currency: &mut Currency<Meme>,
    meme: Balance<Meme>,
    unspent_quote: Balance<Quote>,
    quote_in: u64,
    min_meme_out: u64,
    ctx: &mut TxContext,
) {
    let meme_burned = meme.value();
    assert!(meme_burned >= min_meme_out, EBuybackBelowMinimum);

    let quote_spent = quote_in - unspent_quote.value();
    currency.burn(meme, ctx);
    self.burn_quote.join(unspent_quote);

    blast_events::buyback_burned(
        self.id.to_inner(),
        quote_spent,
        meme_burned,
        self.burn_quote.value(),
    );
}

/// Takes every Meme and Quote waiting to be added back to the position.
public(package) fun take_auto_lp<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
): (Balance<Meme>, Balance<Quote>) {
    (self.auto_lp_meme.withdraw_all(), self.auto_lp_quote.withdraw_all())
}

/// Keeps what the pool did not take for the next call and records the amounts it added.
public(package) fun keep_auto_lp<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    added_meme: u64,
    added_quote: u64,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.auto_lp_meme.join(meme);
    self.auto_lp_quote.join(quote);

    if (added_meme == 0 && added_quote == 0) return;
    blast_events::auto_liquidity_added(
        self.id.to_inner(),
        added_meme,
        added_quote,
        self.auto_lp_meme.value(),
        self.auto_lp_quote.value(),
    );
}

/// Checks readiness before a venue settles accrued fees under the current split.
public(package) fun assert_fee_split_ready<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
    clock: &Clock,
) {
    self.fee_split.assert_ready(clock);
}

/// Applies only the stored ready proposal after the venue has settled accrued fees.
public(package) fun apply_fee_split<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    clock: &Clock,
) {
    self.fee_split.apply(clock);
}

/// Reserves holder-reward funds for the round numbered `next_round`, ending at `end_checkpoint`.
public(package) fun fund_round<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    end_checkpoint: u64,
    meme_amount: u64,
    quote_amount: u64,
): (Balance<Meme>, Balance<Quote>) {
    self.next_round = self.next_round + 1;
    self.last_checkpoint = option::some(end_checkpoint);

    (self.rewards_meme.split(meme_amount), self.rewards_quote.split(quote_amount))
}

/// Restores closed holder funds and unused gas custody to the funding vault.
public(package) fun restore_rewards<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.rewards_meme.join(meme);
    self.rewards_quote.join(quote);
}

/// Builds a round's terms after their static checks; `blast_holder_rewards` checks them against
/// the vault when scheduling and again when publishing.
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
        EInvalidCommitment,
    );
    assert!(leaf_count > 0 && leaf_count <= constants::max_reward_leaves!(), EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    assert!(start_checkpoint < end_checkpoint, EEmptyInterval);
    assert!(quote_amount.checked_add(gas_reserve_amount).is_some(), EBudgetOverflow);
    assert!(expected_treasury != @0x0, EZeroTreasury);
    assert!(claim_window_duration_ms > 0, EZeroClaimWindow);

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

/// Schedules `terms` for publication after the applied round notice, cancelling any scheduled
/// round or notice change.
public(package) fun schedule_round_publication<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    terms: RoundTerms,
    clock: &Clock,
) {
    self.round_publication.schedule(terms, clock);
}

/// Consumes the scheduled round once its notice has elapsed and returns its terms to publish.
public(package) fun take_round_publication<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    clock: &Clock,
): RoundTerms {
    self.round_publication.take_action(clock)
}

/// Discards the scheduled round, even a ready one; aborts when a notice change is pending.
public(package) fun cancel_round_publication<Meme, Quote>(self: &mut LpVault<Meme, Quote>) {
    assert!(
        self.round_publication.pending().is_none_or!(|proposal| {
            proposal.proposal_value().action().is_some()
        }),
        EWrongRoundProposal,
    );

    self.round_publication.cancel();
}

/// Schedules a new round notice after the applied one, cancelling any scheduled round.
public(package) fun schedule_round_publication_delay<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    delay_ms: u64,
    clock: &Clock,
) {
    self.round_publication.schedule_delay(delay_ms, clock);
}

/// Applies the ready round-notice change.
public(package) fun apply_round_publication_delay<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    clock: &Clock,
) {
    self.round_publication.apply_delay(clock);
}

/// Discards the pending round-notice change, even a ready one; aborts when a round is scheduled.
public(package) fun cancel_round_publication_delay<Meme, Quote>(self: &mut LpVault<Meme, Quote>) {
    assert!(
        self.round_publication.pending().is_none_or!(|proposal| {
            proposal.proposal_value().action().is_none()
        }),
        EWrongRoundProposal,
    );

    self.round_publication.cancel();
}

/// The round's number, which must equal the vault's next round.
public(package) fun number(self: &RoundTerms): u64 {
    self.number
}

/// The first checkpoint of the round's holding interval.
public(package) fun start_checkpoint(self: &RoundTerms): u64 {
    self.start_checkpoint
}

/// The checkpoint that ends the round's holding interval.
public(package) fun end_checkpoint(self: &RoundTerms): u64 {
    self.end_checkpoint
}

/// The 32-byte Merkle root of the round's allocation.
public(package) fun root(self: &RoundTerms): vector<u8> {
    self.root
}

/// The 32-byte digest of the round's off-chain manifest.
public(package) fun manifest_digest(self: &RoundTerms): vector<u8> {
    self.manifest_digest
}

/// The number of leaves the root commits.
public(package) fun leaf_count(self: &RoundTerms): u64 {
    self.leaf_count
}

/// The Meme the round reserves for holders.
public(package) fun meme_amount(self: &RoundTerms): u64 {
    self.meme_amount
}

/// The Quote the round reserves for holders.
public(package) fun quote_amount(self: &RoundTerms): u64 {
    self.quote_amount
}

/// The Quote the round reserves for gas reimbursement; zero disables it.
public(package) fun gas_reserve_amount(self: &RoundTerms): u64 {
    self.gas_reserve_amount
}

/// How long claims stay open after publication.
public(package) fun claim_window_duration_ms(self: &RoundTerms): u64 {
    self.claim_window_duration_ms
}

/// The protocol destination the round's gas reimbursement must still pay at publication.
public(package) fun expected_treasury(self: &RoundTerms): address {
    self.expected_treasury
}

/// Returns the venue pool the attached position belongs to.
public(package) fun pool_id<Meme, Quote>(self: &LpVault<Meme, Quote>): ID {
    self.pool_id
}

/// Returns the number the next holder-reward round must carry.
public(package) fun next_round<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.next_round
}

/// Returns the checkpoint the next holder-reward round must start at, or none before the first.
public(package) fun last_checkpoint<Meme, Quote>(self: &LpVault<Meme, Quote>): Option<u64> {
    self.last_checkpoint
}

/// Returns the Meme and Quote not yet reserved by a holder-reward round.
public(package) fun rewards_balances<Meme, Quote>(self: &LpVault<Meme, Quote>): (u64, u64) {
    (self.rewards_meme.value(), self.rewards_quote.value())
}

/// Transfers `amount` split from `balance` to `destination`, skipping empty shares.
public(package) fun pay<T>(
    balance: &mut Balance<T>,
    amount: u64,
    destination: address,
    ctx: &mut TxContext,
) {
    if (amount > 0) transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
}

// === Private Functions ===

/// Pays Blast's LP fees to the policy's protocol destination and returns it, or, on a vault whose
/// launch named a partner, holds them for `claim_protocol_lp_fees_with_partner` and returns none.
fun pay_or_hold_protocol_lp_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    protocol_meme: Balance<Meme>,
    protocol_quote: Balance<Quote>,
    policy: &LpFeePolicy,
    ctx: &mut TxContext,
): Option<address> {
    if (self.partner_id.is_some()) {
        self.unpaid_protocol_meme.join(protocol_meme);
        self.unpaid_protocol_quote.join(protocol_quote);
        return option::none()
    };

    let protocol_destination = policy.protocol_destination();
    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);
    option::some(protocol_destination)
}

/// Pays all of `balance` to `destination`, sending no coin when it is empty.
fun pay_all<T>(mut balance: Balance<T>, destination: address, ctx: &mut TxContext) {
    let amount = balance.value();
    balance.pay(amount, destination, ctx);
    balance.destroy_zero();
}

/// Builds the vault with the launch's fee split and empty balances, attaches `position`, and
/// announces the custody.
fun new<Meme, Quote, Venue, Position: key + store>(
    launch: &Launch<Meme, Quote>,
    _venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    assert!(liquidity > 0, EZeroLiquidity);

    let position_id = object::id(&position);
    let id = object::new(ctx);
    let round_publication = delayed_action::new(RoundPublicationKey(), &id, DEFAULT_ROUND_NOTICE_MS);
    let fee_split = delayed::new(
        FeeSplitKey(),
        &id,
        launch.lp_fee_split(),
        DEFAULT_FEE_SPLIT_DELAY_MS,
    );
    let mut vault = LpVault {
        id,
        pool_id,
        partner_id: launch.partner_id(),
        protocol_meme_residual,
        protocol_quote_residual,
        unpaid_protocol_meme: balance::zero(),
        unpaid_protocol_quote: balance::zero(),
        fee_split,
        creator_meme: balance::zero(),
        creator_quote: balance::zero(),
        auto_lp_meme: balance::zero(),
        auto_lp_quote: balance::zero(),
        rewards_meme: balance::zero(),
        rewards_quote: balance::zero(),
        burn_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
        round_publication,
    };
    vault.id.add_dynamic_object_field(PositionKey<Venue>(), position);

    blast_events::vault_created<Meme, Quote, Venue>(
        vault.id.to_inner(),
        pool_id,
        position_id,
        vault.protocol_meme_residual.value(),
        vault.protocol_quote_residual.value(),
        liquidity,
        vault.fee_split.value(),
    );

    vault
}

/// Burns `meme`, or sends it to `@0x0` when the supply is fixed, as migration does.
fun burn<Meme>(currency: &mut Currency<Meme>, mut meme: Balance<Meme>, ctx: &mut TxContext) {
    if (currency.is_supply_burn_only()) return currency.burn_balance(meme);

    let meme_amount = meme.value();
    meme.pay(meme_amount, @0x0, ctx);
    meme.destroy_zero();
}

// === Test-Only Functions ===

#[test_only]
/// Builds the vault `create` shares, left unshared for focused tests.
public fun new_for_testing<Meme, Quote, Venue, Position: key + store>(
    launch: &Launch<Meme, Quote>,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    new(
        launch,
        venue,
        pool_id,
        position,
        liquidity,
        protocol_meme_residual,
        protocol_quote_residual,
        ctx,
    )
}

#[test_only]
/// Returns the ID of the position attached under `Venue`, or none for any other venue.
public fun position_id_for_testing<Meme, Quote, Venue>(self: &LpVault<Meme, Quote>): Option<ID> {
    dynamic_object_field::id(&self.id, PositionKey<Venue>())
}

#[test_only]
/// Returns the ID of the auto-LP position attached under `Venue`, or none before its first use.
public fun auto_lp_position_id_for_testing<Meme, Quote, Venue>(
    self: &LpVault<Meme, Quote>,
): Option<ID> {
    dynamic_object_field::id(&self.id, AutoLpPositionKey<Venue>())
}

#[test_only]
/// Returns the unclaimed protocol-owned Meme residual that migration left in the vault.
public fun protocol_meme_residual_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.protocol_meme_residual.value()
}

#[test_only]
/// Returns the unclaimed protocol-owned Quote residual that migration left in the vault.
public fun protocol_quote_residual_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.protocol_quote_residual.value()
}

#[test_only]
/// Returns the creator's current split of every collection after Blast's share.
public fun fee_split_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): FeeSplit {
    self.fee_split.value()
}

#[test_only]
/// Returns the applied split notice and the pending proposal, if present.
public fun fee_split_policy_for_testing<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): (u64, Option<Proposal<FeeSplit>>) {
    (self.fee_split.delay_ms(), self.fee_split.pending())
}

#[test_only]
/// Returns the round-publication slot: its applied notice and any scheduled round or notice.
public fun round_publication_for_testing<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): &DelayedAction<RoundPublicationKey, RoundTerms> {
    &self.round_publication
}

#[test_only]
/// Takes unreserved holder-reward funds without advancing the round cursor, so a test can shrink
/// the budget between scheduling and publication; no production path does.
public fun withdraw_rewards_for_testing<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    meme_amount: u64,
    quote_amount: u64,
): (Balance<Meme>, Balance<Quote>) {
    (self.rewards_meme.split(meme_amount), self.rewards_quote.split(quote_amount))
}

#[test_only]
/// Returns the creator's unclaimed Meme and Quote LP fees.
public fun creator_balances_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): (u64, u64) {
    (self.creator_meme.value(), self.creator_quote.value())
}

#[test_only]
/// Returns the Meme and Quote waiting to be added back to the position.
public fun auto_lp_balances_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): (u64, u64) {
    (self.auto_lp_meme.value(), self.auto_lp_quote.value())
}

#[test_only]
/// Returns the partner the vault inherited from its launch.
public fun partner_id_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): Option<ID> {
    self.partner_id
}

#[test_only]
/// Returns Blast's Meme and Quote LP fees held for the partner claim.
public fun unpaid_protocol_lp_fees_for_testing<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): (u64, u64) {
    (self.unpaid_protocol_meme.value(), self.unpaid_protocol_quote.value())
}

#[test_only]
/// Returns the Quote waiting to buy Meme back.
public fun burn_quote_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.burn_quote.value()
}

// === Errors ===

#[error(code = 0)]
const ENothingClaimable: vector<u8> = b"No protocol migration residuals are available to claim.";

#[error(code = 1)]
const ENoCreatorFees: vector<u8> = b"No creator LP fees are available to claim.";

#[error(code = 2)]
const EZeroLiquidity: vector<u8> = b"Migration position must hold liquidity.";

#[error(code = 3)]
const EBuybackQuoteOutOfRange: vector<u8> =
    b"Buyback Quote must be positive and at most the burn Quote waiting to buy Meme back.";

#[error(code = 4)]
const EBuybackBelowMinimum: vector<u8> = b"Buyback must return at least the minimum Meme.";

#[error(code = 5)]
const EPartnerMismatch: vector<u8> = b"The partner is not the one the vault's launch named at creation.";

#[error(code = 6)]
const EInvalidCommitment: vector<u8> =
    b"Root and manifest digest must each contain exactly 32 bytes.";

#[error(code = 7)]
const EInvalidLeafCount: vector<u8> = b"Round must contain between 1 and 65,536 leaves.";

#[error(code = 8)]
const EEmptyBudget: vector<u8> = b"At least one reward amount must be nonzero.";

#[error(code = 9)]
const EEmptyInterval: vector<u8> = b"Checkpoint interval must be nonempty.";

#[error(code = 10)]
const EBudgetOverflow: vector<u8> = b"Holder Quote and gas reserve must sum within u64.";

#[error(code = 11)]
const EZeroTreasury: vector<u8> = b"Expected treasury must not be the zero address.";

#[error(code = 12)]
const EZeroClaimWindow: vector<u8> = b"Claim window must be positive.";

#[error(code = 13)]
const EWrongRoundProposal: vector<u8> =
    b"The pending round publication is the other kind: a round, or a notice change.";

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, Delayed, Proposal},
    delayed_action::{Self, DelayedAction},
};

use blast_fun::{
    allocation::FeeSplit,
    blast_fun_domain::{BuybackAdmin, TreasuryAdmin},
    creator_authority::CurveFeeCap,
    launch::Launch,
};

use blast_fun_migrators::{
    blast_events,
    constants,
    lp_fee_policy::LpFeePolicy,
    blast_fun_migrators::PackageVersion as MigratorsVersion,
};

use blast_partners::blast_partners::Partner;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::Currency,
    dynamic_object_field,
};

use fun pay as Balance.pay;
use fun pay_all as Balance.pay_all;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow as UID.dynamic_object_field;
use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;
use fun dynamic_object_field::exists as UID.has_dynamic_object_field;

use fun burn as Currency.burn;
