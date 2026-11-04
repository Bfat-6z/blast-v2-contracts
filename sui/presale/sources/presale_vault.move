// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Custody for one LP position, migrated from a presale or provided directly, its residuals, and its
/// holder-reward fee share.
///
/// A venue whose pool pays its fees as coins sent to an address, rather than into a position,
/// builds the vault before its position exists and names the vault's own ID as the recipient;
/// the vault then receives those coins with Sui's transfer-to-object receiving and splits them
/// like any collection.
module blast_presale::presale_vault;

// === Public Types ===

/// Sealed field name binding one venue position type to a vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Keys the delayed lifecycle of a vault's creator fee split.
public struct FeeSplitKey() has copy, drop, store;

/// Keys the delayed lifecycle of a vault's Blast LP-fee rates.
public struct ProtocolLpFeesKey() has copy, drop, store;

/// Keys the delayed lifecycle of a vault's holder-reward round publication; its action is the
/// round's terms.
public struct RoundPublicationKey() has copy, drop, store;

/// The committed terms of one holder-reward round, checked when built: two 32-byte commitments,
/// 1 to 65,536 leaves, a nonempty budget and checkpoint interval, a holder Quote and gas reserve
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

/// Shared custody for one LP position and its explicitly applied fee split: a presale's, after migration, or
/// an owner's own position locked here directly, with zero presale and creator-capability IDs.
///
/// Each collection first takes Blast's LP fees of each asset at the vault's
/// rates, snapshotted at creation and changeable only by Blast's `FeeAdmin`, then
/// pays every fee recipient its share of the rest at once; the holder-reward
/// Quote share accrues here until Blast's rewards administrator funds a round.
/// Its holder Meme remainder is paid to the current governed fee destination.
/// Blast's LP fees go to the protocol destination at once, unless the sale named
/// a partner: then they wait here for `pay_protocol_lp_fees_with_partner`.
///
/// A holder-reward round waits in `round_publication` for its applied notice before anyone may
/// publish it; at most one round is scheduled at a time.
public struct Vault<phantom Meme, phantom Quote> has key {
    id: UID,
    presale_id: ID,
    presale_cap_id: ID,
    pool_id: ID,
    fee_split: Delayed<FeeSplitKey, FeeSplit>,
    protocol_fees: Delayed<ProtocolLpFeesKey, ProtocolFees>,
    /// The Blast partner the sale named, paid its cut of Blast's LP fees. It never changes.
    partner_id: Option<ID>,
    unpaid_protocol_meme: Balance<Meme>,
    unpaid_protocol_quote: Balance<Quote>,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    holder_rewards_quote: Balance<Quote>,
    next_round: u64,
    last_checkpoint: Option<u64>,
    round_publication: DelayedAction<RoundPublicationKey, RoundTerms>,
}

// === Public Functions ===

/// Announces a split and next notice with this presale's creator cap. The applied notice
/// governs the proposal, including a reduction to zero. Standalone vaults have no creator cap.
public fun schedule_fee_split<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    cap: &PresaleCap,
    proposed: FeeSplit,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();
    self.assert_cap(cap);
    proposed.assert_valid_fee_split();

    self.fee_split.schedule(proposed, delay_ms, clock);
}

/// Cancels even a ready split proposal with this presale's creator cap.
public fun cancel_fee_split<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    cap: &PresaleCap,
) {
    package_version.assert_current();
    self.assert_cap(cap);

    self.fee_split.cancel();
}

/// Claims the pool's one-time migration residuals with the creator capability.
public fun claim_migration_residuals<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    cap: &PresaleCap,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();

    self.assert_cap(cap);
    assert!(
        self.migration_meme_residual.value() > 0
            || self.migration_quote_residual.value() > 0,
        blast_presale::errors::no_migration_residuals!(),
    );

    let meme = self.migration_meme_residual.withdraw_all().into_coin(ctx);
    let quote = self.migration_quote_residual.withdraw_all().into_coin(ctx);

    event::emit(MigrationResidualsClaimed<Meme, Quote> {
        vault_id: self.id.to_inner(),
        meme: meme.value(),
        quote: quote.value(),
    });

    (meme, quote)
}

/// Sets Blast's share of each asset in this vault's later LP-fee collections. Fees still in the
/// pool are split at the new rates when collected; the creator's split of the rest is unchanged.
public fun schedule_protocol_lp_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
    delay_ms: u64,
    clock: &Clock
) {
    package_version.assert_current();

    let proposed = self.protocol_fees.value().with_lp_fees(lp_fee_meme_bps, lp_fee_quote_bps);

    self.protocol_fees.schedule(proposed, delay_ms, clock);
}

/// Anyone may apply the announced LP rates once the complete notice has elapsed.
public fun apply_protocol_lp_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    clock: &Clock
) {
    package_version.assert_current();

    self.protocol_fees.apply(clock);
}

/// Cancels even a ready LP-rate change.
public fun cancel_protocol_lp_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current();

    self.protocol_fees.cancel();
}

/// Pays the Blast LP fees this vault holds for its partner: the partner its cut of each asset in
/// force now, rounded down, then the fee policy's current destination the rest. Anyone may call
/// it, since both payees are fixed. Holding nothing is valid, moves nothing, and emits nothing,
/// so it can follow any collection.
public fun pay_protocol_lp_fees_with_partner<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    partner: &Partner,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(
        self.partner_id.contains(&object::id(partner)),
        blast_presale::errors::wrong_partner!(),
    );
    if (self.unpaid_protocol_meme.value() == 0 && self.unpaid_protocol_quote.value() == 0) return;

    let protocol_destination = fee_policy.destination();
    let mut protocol_meme = self.unpaid_protocol_meme.withdraw_all();
    let mut protocol_quote = self.unpaid_protocol_quote.withdraw_all();
    let partner_meme = partner.pay(&mut protocol_meme, ctx);
    let partner_quote = partner.pay(&mut protocol_quote, ctx);
    let paid_meme = protocol_meme.value();
    let paid_quote = protocol_quote.value();

    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);

    event::emit(ProtocolLpFeesPaid<Meme, Quote> {
        vault_id: self.id.to_inner(),
        protocol_destination,
        protocol_meme: paid_meme,
        protocol_quote: paid_quote,
        partner_meme,
        partner_quote,
    });
}

// === Package Functions ===

/// Creates and shares a migrated presale's vault, with its venue position sealed as a dynamic
/// object field, the presale's initial LP-fee split and fixed partner, and its snapshotted Blast rates.
public(package) fun create<Meme, Quote, Venue, Position: key + store>(
    sale: &Presale<Meme, Quote>,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
) {
    let vault = new(sale, pool_id, migration_meme_residual, migration_quote_residual, ctx);
    vault.share_with_position(venue, position, liquidity);
}

/// Builds a migrated presale's vault as `create` does but with no position yet, for a venue whose
/// pool must name the vault's address before its position exists. The vault has only `key`, so
/// the venue can do nothing with it but `share_with_position` in the same call.
public(package) fun new<Meme, Quote>(
    sale: &Presale<Meme, Quote>,
    pool_id: ID,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): Vault<Meme, Quote> {
    let (presale_id, presale_cap_id, fee_split, protocol_fees, partner_id) = sale.vault_config();

    build(
        presale_id,
        presale_cap_id,
        fee_split,
        protocol_fees,
        partner_id,
        pool_id,
        migration_meme_residual,
        migration_quote_residual,
        ctx,
    )
}

/// Attaches `position`, holding `liquidity` in the vault's pool, under the venue's sealed key,
/// announces the custody, and shares the vault.
public(package) fun share_with_position<Meme, Quote, Venue, Position: key + store>(
    mut self: Vault<Meme, Quote>,
    venue: &Venue,
    position: Position,
    liquidity: u128,
) {
    self.attach(venue, position, liquidity);
    transfer::share_object(self);
}

/// Whether the vault's position sits under `Venue`: the venue that migrated the sale.
public(package) fun has_position<Meme, Quote, Venue>(
    self: &Vault<Meme, Quote>,
    _venue: &Venue,
): bool {
    self.id.has_dynamic_object_field(PositionKey<Venue>())
}

/// Receives one fee coin a venue sent to this vault's address. The venue module hands every
/// received coin to `split_fees` in the same call, so fees leave only by the split.
public(package) fun receive_fee<Meme, Quote, Asset>(
    self: &mut Vault<Meme, Quote>,
    fee: Receiving<Coin<Asset>>,
): Coin<Asset> {
    transfer::public_receive(&mut self.id, fee)
}

/// Creates and shares a vault for a position its owner provides directly, with no presale, so its
/// presale and creator-capability IDs are zero, no `PresaleCap` matches it, and it holds no
/// residuals. Its position is sealed for good, its LP-fee split and partner are immutable, and
/// Blast's rates are the `FeePolicy`'s now. A partner must be one the `CreationPolicy` accepts now.
public(package) fun create_without_presale<Meme, Quote, Venue, Position: key + store>(
    fee_split: FeeSplit,
    partner_id: Option<ID>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    clock: &Clock,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    ctx: &mut TxContext,
) {
    partner_id.do_ref!(|id| creation_policy.assert_partner(*id, clock.timestamp_ms()));

    let vault = build<Meme, Quote>(
        object::id_from_address(@0x0),
        object::id_from_address(@0x0),
        fee_split,
        fee_policy.fees(),
        partner_id,
        pool_id,
        balance::zero(),
        balance::zero(),
        ctx,
    );
    vault.share_with_position(venue, position, liquidity);
}

/// Borrows the custodied venue position without exposing a removal path.
public(package) fun position_mut<Meme, Quote, Venue, Position: key + store>(
    self: &mut Vault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Splits collected LP fees: Blast's LP fees at the vault's current rates, rounded up, are paid
/// to the current protocol destination or, on a partnered vault, held for
/// `pay_protocol_lp_fees_with_partner`; under the explicitly applied BPS, every fee recipient
/// is paid its share of the rest at once. Holder Meme goes to the governed treasury;
/// holder Quote stays in the vault. A zero
/// collection is valid, moves nothing, and emits nothing.
public(package) fun split_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
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

    let protocol_meme = self.protocol_fees.value().lp_fee_meme_bps().apply_up(gross_meme);
    let protocol_quote = self.protocol_fees.value().lp_fee_quote_bps().apply_up(gross_quote);
    let (fee_recipient_meme, holder_rewards_meme) = self.fee_amounts(gross_meme - protocol_meme);
    let (fee_recipient_quote, holder_rewards_quote) = self.fee_amounts(
        gross_quote - protocol_quote,
    );
    let recipients = self.fee_split.value().fee_recipients().recipients();

    let protocol_destination = self.pay_or_hold_protocol_lp_fees(
        meme.split(protocol_meme),
        quote.split(protocol_quote),
        fee_policy,
        ctx,
    );
    recipients.length().do!(|i| {
        meme.pay(fee_recipient_meme[i], recipients[i], ctx);
        quote.pay(fee_recipient_quote[i], recipients[i], ctx);
    });
    let treasury = fee_policy.destination();
    meme.pay_all(treasury, ctx);
    self.holder_rewards_quote.join(quote);

    event::emit(FeesCollected<Meme, Quote> {
        vault_id: self.id.to_inner(),
        gross_meme,
        gross_quote,
        protocol_destination,
        protocol_meme,
        protocol_quote,
        fee_recipient_meme,
        fee_recipient_quote,
        holder_rewards_meme,
        holder_rewards_quote,
    });

    if (holder_rewards_meme > 0) {
        event::emit(HolderMemePaid<Meme, Quote> {
            vault_id: self.id.to_inner(),
            treasury,
            meme_amount: holder_rewards_meme,
        });
    };
}

public(package) fun assert_cap<Meme, Quote>(self: &Vault<Meme, Quote>, cap: &PresaleCap) {
    assert!(object::id(cap) == self.presale_cap_id, blast_presale::errors::wrong_presale_cap!());
}

/// Checks the stored threshold before a venue performs any collection or policy mutation.
public(package) fun assert_fee_split_ready<Meme, Quote>(
    self: &Vault<Meme, Quote>, clock: &Clock,
) {
    self.fee_split.assert_ready(clock);
    self.fee_split.pending().destroy_some().proposal_value().assert_valid_fee_split();
}

/// Applies the stored ready split after the venue's required settlement boundary.
public(package) fun apply_fee_split<Meme, Quote>(self: &mut Vault<Meme, Quote>, clock: &Clock) {
    self.fee_split.apply(clock);
}

public(package) fun pool_id<Meme, Quote>(self: &Vault<Meme, Quote>): ID {
    self.pool_id
}

public(package) fun next_round<Meme, Quote>(self: &Vault<Meme, Quote>): u64 {
    self.next_round
}

public(package) fun last_checkpoint<Meme, Quote>(self: &Vault<Meme, Quote>): Option<u64> {
    self.last_checkpoint
}

/// The holder Quote not yet reserved by a round; holder Meme goes to the treasury instead.
public(package) fun holder_rewards_quote<Meme, Quote>(self: &Vault<Meme, Quote>): u64 {
    self.holder_rewards_quote.value()
}

public(package) fun fund_round<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    end_checkpoint: u64,
    quote_amount: u64,
): Balance<Quote> {
    self.next_round = self.next_round + 1;
    self.last_checkpoint = option::some(end_checkpoint);

    self.holder_rewards_quote.split(quote_amount)
}

/// Builds a round's terms after their static checks; `holder_rewards` checks them against the
/// vault when scheduling and again when publishing. Rounds pay only Quote: `split_fees` sends
/// holder Meme to the treasury, so the Meme amount must be zero.
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
        blast_presale::errors::invalid_commitment!(),
    );
    assert!(
        leaf_count > 0 && leaf_count <= constants::max_reward_leaves!(),
        blast_presale::errors::invalid_leaf_count!(),
    );
    assert!(meme_amount == 0, blast_presale::errors::meme_rewards_unsupported!());
    assert!(quote_amount > 0, blast_presale::errors::empty_budget!());
    assert!(start_checkpoint < end_checkpoint, blast_presale::errors::empty_interval!());
    assert!(
        quote_amount.checked_add(gas_reserve_amount).is_some(),
        blast_presale::errors::budget_overflow!(),
    );
    assert!(
        (gas_reserve_amount as u128) * (constants::basis_points_denominator!() as u128)
            <= (quote_amount as u128) * (constants::max_gas_reserve_bps!() as u128),
        blast_presale::errors::gas_reserve_too_large!(),
    );
    assert!(expected_treasury != @0x0, blast_presale::errors::zero_treasury!());
    assert!(claim_window_duration_ms > 0, blast_presale::errors::zero_claim_window!());

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
    self: &mut Vault<Meme, Quote>,
    terms: RoundTerms,
    clock: &Clock,
) {
    self.round_publication.schedule(terms, clock);
}

/// Consumes the scheduled round once its notice has elapsed and returns its terms to publish.
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
        blast_presale::errors::wrong_round_proposal!(),
    );

    self.round_publication.cancel();
}

/// Schedules a new round notice after the applied one, cancelling any scheduled round.
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
        blast_presale::errors::wrong_round_proposal!(),
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

/// The governed destination the round's gas reimbursement must still pay at publication.
public(package) fun expected_treasury(self: &RoundTerms): address {
    self.expected_treasury
}

/// Returns a closed round's unclaimed Quote, or an unspent gas reserve, to the holder-reward
/// balance.
public(package) fun restore_holder_rewards<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    quote: Balance<Quote>,
) {
    self.holder_rewards_quote.join(quote);
}

// === Private Functions ===

/// Builds the vault bound to `pool_id` with no position yet; the caller attaches one and shares
/// it.
fun build<Meme, Quote>(
    presale_id: ID,
    presale_cap_id: ID,
    fee_split: FeeSplit,
    protocol_fees: ProtocolFees,
    partner_id: Option<ID>,
    pool_id: ID,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): Vault<Meme, Quote> {
    fee_split.assert_valid_fee_split();
    let id = object::new(ctx);
    let round_publication = delayed_action::new(RoundPublicationKey(), &id, DEFAULT_ROUND_NOTICE_MS);

    Vault {
        presale_id,
        presale_cap_id,
        pool_id,
        fee_split: delayed::new(FeeSplitKey(), &id, fee_split, DEFAULT_FEE_SPLIT_DELAY_MS),
        protocol_fees: delayed::new(
            ProtocolLpFeesKey(),
            &id,
            protocol_fees,
            DEFAULT_PROTOCOL_LP_FEE_DELAY_MS,
        ),
        partner_id,
        unpaid_protocol_meme: balance::zero(),
        unpaid_protocol_quote: balance::zero(),
        migration_meme_residual,
        migration_quote_residual,
        holder_rewards_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
        round_publication,
        id,
    }
}

/// Attaches `position`, holding `liquidity` in the vault's pool, once under the venue's sealed key
/// and announces the custody; a second attachment under the same venue aborts in the framework.
fun attach<Meme, Quote, Venue, Position: key + store>(
    self: &mut Vault<Meme, Quote>,
    _venue: &Venue,
    position: Position,
    liquidity: u128,
) {
    assert!(liquidity > 0, blast_presale::errors::zero_liquidity!());

    let position_id = object::id(&position);
    self.id.add_dynamic_object_field(PositionKey<Venue>(), position);

    event::emit(VaultCreated<Meme, Quote, Venue> {
        vault_id: self.id.to_inner(),
        presale_id: self.presale_id,
        pool_id: self.pool_id,
        position_id,
        position_liquidity: liquidity,
        fee_recipients: self.fee_split.value().fee_recipients().recipients(),
        fee_recipient_bps: self.fee_split.value().fee_recipients().bps(),
        holder_rewards_bps: self.fee_split.value().holder_rewards_bps().value(),
        protocol_lp_fee_meme_bps: self.protocol_fees.value().lp_fee_meme_bps().value(),
        protocol_lp_fee_quote_bps: self.protocol_fees.value().lp_fee_quote_bps().value(),
        migration_meme_residual: self.migration_meme_residual.value(),
        migration_quote_residual: self.migration_quote_residual.value(),
    });
}

/// Pays Blast's LP fees to the fee policy's current destination and returns it, or, on a vault
/// naming a partner, holds them for `pay_protocol_lp_fees_with_partner` and returns none.
fun pay_or_hold_protocol_lp_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    protocol_meme: Balance<Meme>,
    protocol_quote: Balance<Quote>,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): Option<address> {
    if (self.partner_id.is_some()) {
        self.unpaid_protocol_meme.join(protocol_meme);
        self.unpaid_protocol_quote.join(protocol_quote);
        return option::none()
    };

    let protocol_destination = fee_policy.destination();
    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);

    option::some(protocol_destination)
}

/// Pays all of `balance` to `recipient`, sending no coin when it is empty.
fun pay_all<Asset>(mut balance: Balance<Asset>, recipient: address, ctx: &mut TxContext) {
    let amount = balance.value();
    balance.pay(amount, recipient, ctx);
    balance.destroy_zero();
}

/// Splits `amount` under the applied BPS into each fee recipient's amount and the
/// holder-reward amount.
fun fee_amounts<Meme, Quote>(self: &Vault<Meme, Quote>, amount: u64): (vector<u64>, u64) {
    let mut recipient_amounts = self.fee_split.value().apportion_fee(amount);
    let holder_rewards = recipient_amounts.pop_back();

    (recipient_amounts, holder_rewards)
}

// === Test-Only Functions ===

#[test_only]
public fun set_protocol_lp_fees_for_testing<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    admin: &AdminWitness<FeeAdmin>,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_protocol_lp_fees(
        package_version,
        admin,
        lp_fee_meme_bps,
        lp_fee_quote_bps,
        DEFAULT_PROTOCOL_LP_FEE_DELAY_MS,
        &clock
    );
    clock.set_for_testing(DEFAULT_PROTOCOL_LP_FEE_DELAY_MS);
    self.apply_protocol_lp_fees(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun new_for_testing<Meme, Quote>(
    presale_id: ID,
    presale_cap_id: ID,
    fee_split: FeeSplit,
    protocol_fees: ProtocolFees,
    partner_id: Option<ID>,
    ctx: &mut TxContext,
): Vault<Meme, Quote> {
    let id = object::new(ctx);
    let round_publication = delayed_action::new(RoundPublicationKey(), &id, DEFAULT_ROUND_NOTICE_MS);

    Vault {
        presale_id,
        presale_cap_id,
        pool_id: object::id_from_address(@0x1),
        fee_split: delayed::new(FeeSplitKey(), &id, fee_split, DEFAULT_FEE_SPLIT_DELAY_MS),
        protocol_fees: delayed::new(
            ProtocolLpFeesKey(),
            &id,
            protocol_fees,
            DEFAULT_PROTOCOL_LP_FEE_DELAY_MS,
        ),
        partner_id,
        unpaid_protocol_meme: balance::zero(),
        unpaid_protocol_quote: balance::zero(),
        migration_meme_residual: balance::zero(),
        migration_quote_residual: balance::zero(),
        holder_rewards_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
        round_publication,
        id,
    }
}

#[test_only]
public fun protocol_fees_for_testing<Meme, Quote>(self: &Vault<Meme, Quote>): ProtocolFees {
    self.protocol_fees.value()
}

#[test_only]
/// Returns the applied creator split, its notice and its pending proposal.
public fun fee_split_policy_for_testing<Meme, Quote>(
    self: &Vault<Meme, Quote>,
): (FeeSplit, u64, Option<Proposal<FeeSplit>>) {
    (self.fee_split.value(), self.fee_split.delay_ms(), self.fee_split.pending())
}

#[test_only]
/// Returns the round-publication slot: its applied notice and any scheduled round or notice.
public fun round_publication_for_testing<Meme, Quote>(
    self: &Vault<Meme, Quote>,
): &DelayedAction<RoundPublicationKey, RoundTerms> {
    &self.round_publication
}

#[test_only]
public fun credit_fees_for_testing<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    self.split_fees(fee_policy, meme, quote, ctx)
}

#[test_only]
public fun fees_collected_fields<Meme, Quote>(
    event: &FeesCollected<Meme, Quote>,
): (u64, u64, vector<u64>, vector<u64>, u64, u64) {
    (
        event.gross_meme,
        event.gross_quote,
        event.fee_recipient_meme,
        event.fee_recipient_quote,
        event.holder_rewards_meme,
        event.holder_rewards_quote,
    )
}

#[test_only]
public fun fees_collected_protocol_fields<Meme, Quote>(
    event: &FeesCollected<Meme, Quote>,
): (Option<address>, u64, u64) {
    (event.protocol_destination, event.protocol_meme, event.protocol_quote)
}

#[test_only]
public fun protocol_lp_fees_paid_fields<Meme, Quote>(
    event: &ProtocolLpFeesPaid<Meme, Quote>,
): (ID, address, u64, u64, u64, u64) {
    (
        event.vault_id,
        event.protocol_destination,
        event.protocol_meme,
        event.protocol_quote,
        event.partner_meme,
        event.partner_quote,
    )
}

#[test_only]
public fun unpaid_protocol_lp_fees_for_testing<Meme, Quote>(self: &Vault<Meme, Quote>): (u64, u64) {
    (self.unpaid_protocol_meme.value(), self.unpaid_protocol_quote.value())
}

#[test_only]
/// Attaches `position` under `venue` to an unshared vault `new_for_testing` built.
public fun attach_position_for_testing<Meme, Quote, Venue, Position: key + store>(
    self: &mut Vault<Meme, Quote>,
    venue: &Venue,
    position: Position,
    liquidity: u128,
) {
    self.attach(venue, position, liquidity);
}

#[test_only]
/// Returns the ID of the position attached under `Venue`, or none for any other venue.
public fun position_id_for_testing<Meme, Quote, Venue>(self: &Vault<Meme, Quote>): Option<ID> {
    dynamic_object_field::id(&self.id, PositionKey<Venue>())
}

#[test_only]
/// The vault, presale, pool, and position IDs and the position liquidity a `VaultCreated` names.
public fun vault_created_fields<Meme, Quote, Venue>(
    event: &VaultCreated<Meme, Quote, Venue>,
): (ID, ID, ID, ID, u128) {
    (event.vault_id, event.presale_id, event.pool_id, event.position_id, event.position_liquidity)
}

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: Vault<Meme, Quote>) {
    let Vault {
        id,
        presale_id: _,
        presale_cap_id: _,
        pool_id: _,
        fee_split,
        protocol_fees,
        partner_id: _,
        unpaid_protocol_meme,
        unpaid_protocol_quote,
        migration_meme_residual,
        migration_quote_residual,
        holder_rewards_quote,
        next_round: _,
        last_checkpoint: _,
        round_publication,
    } = self;
    std::unit_test::destroy(fee_split);
    std::unit_test::destroy(protocol_fees);
    std::unit_test::destroy(round_publication);
    id.delete();
    unpaid_protocol_meme.destroy_zero();
    unpaid_protocol_quote.destroy_zero();
    migration_meme_residual.destroy_zero();
    migration_quote_residual.destroy_zero();
    holder_rewards_quote.destroy_zero();
}

/// Seeds the holder Quote balance directly to exercise Merkle custody in tests.
#[test_only]
public fun credit_holder_for_testing<Meme, Quote>(self: &mut Vault<Meme, Quote>, quote: Balance<Quote>) {
    self.holder_rewards_quote.join(quote);
}

#[test_only]
/// Takes unreserved holder-reward funds without advancing the round cursor, so a test can shrink
/// the budget between scheduling and publication; no production path does.
public fun withdraw_holder_rewards_for_testing<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    quote_amount: u64,
): Balance<Quote> {
    self.holder_rewards_quote.split(quote_amount)
}

#[test_only]
public fun holder_meme_paid_bytes<Meme, Quote>(payload: &HolderMemePaid<Meme, Quote>): vector<u8> {
    std::bcs::to_bytes(payload)
}

// === Events ===

public struct VaultCreated<phantom Meme, phantom Quote, phantom Venue> has copy, drop {
    vault_id: ID,
    /// Zero for a vault created without a presale.
    presale_id: ID,
    pool_id: ID,
    position_id: ID,
    /// The position's liquidity in its venue's own units.
    position_liquidity: u128,
    fee_recipients: vector<address>,
    fee_recipient_bps: vector<u64>,
    holder_rewards_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    migration_meme_residual: u64,
    migration_quote_residual: u64,
}

public struct FeesCollected<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    gross_meme: u64,
    gross_quote: u64,
    /// Where Blast's LP fees were paid, or none when the vault holds them for its partner.
    protocol_destination: Option<address>,
    protocol_meme: u64,
    protocol_quote: u64,
    /// Aligned by index with the currently applied split's recipients.
    fee_recipient_meme: vector<u64>,
    fee_recipient_quote: vector<u64>,
    holder_rewards_meme: u64,
    holder_rewards_quote: u64,
}

public struct MigrationResidualsClaimed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme: u64,
    quote: u64,
}

/// A partnered vault paid the Blast LP fees it held: `partner_meme` and `partner_quote` to the
/// partner, and the rest, `protocol_meme` and `protocol_quote`, to `protocol_destination`.
public struct ProtocolLpFeesPaid<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    protocol_destination: address,
    protocol_meme: u64,
    protocol_quote: u64,
    partner_meme: u64,
    partner_quote: u64,
}

/// The holder Meme allocation in `FeesCollected` was paid to the treasury; only Quote accrues
/// for holder rounds.
public struct HolderMemePaid<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    treasury: address,
    meme_amount: u64,
}

// === Constants ===

/// Initial notice before a creator split or its next notice period may change.
const DEFAULT_FEE_SPLIT_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

/// Initial notice for protocol LP-fee changes: 48 hours in milliseconds.
const DEFAULT_PROTOCOL_LP_FEE_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

/// Initial notice before a scheduled holder-reward round may publish, or its next notice
/// period may change: 2 hours, so CancelAdmin can stop a bad round while daily rounds still fit.
const DEFAULT_ROUND_NOTICE_MS: u64 = 2 * 60 * 60 * 1_000;

// === Imports ===

use blast_admin::{
    delayed::{Self, Delayed, Proposal},
    delayed_action::{Self, DelayedAction},
    blast_acl::AdminWitness,
};

use blast_partners::blast_partners::Partner;

use blast_presale::{
    blast_presale::{Self as presale, FeeSplit, Presale, PresaleCap},
    blast_presale_domain::{CancelAdmin, FeeAdmin},
    blast_presale_package::PackageVersion,
    bps::Bps,
    constants,
    creation_policy::CreationPolicy,
    fee_policy::{FeePolicy, ProtocolFees}
};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    dynamic_object_field,
    event,
    transfer::Receiving
};

use fun presale::pay as Balance.pay;

use fun pay_all as Balance.pay_all;

use fun presale::bps_of as vector.bps;

use fun presale::recipients_of as vector.recipients;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;

use fun dynamic_object_field::exists as UID.has_dynamic_object_field;
