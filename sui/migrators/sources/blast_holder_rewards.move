// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Holder rewards: rounds funded from a vault's rewards share and paid by Merkle proof.
///
/// Blast's off-chain system turns checkpointed holder balances into a Merkle allocation, and a
/// Blast administrator schedules it as a round on the vault. Once the vault's round notice has
/// elapsed, anyone publishes it, reserving its budget from the vault. Anyone can relay a proof
/// afterwards; each leaf pays its committed beneficiary once.
module blast_fun_migrators::blast_holder_rewards;

// === Public Types ===

/// Independently funded claims with optional gas custody, recoverable at the claim deadline.
public struct Round<phantom Meme, phantom Quote> has key {
    id: UID,
    vault: ID,
    number: u64,
    claim_deadline_at_ms: u64,
    root: vector<u8>,
    leaf_count: u64,
    claimed: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    treasury: address,
    gas_reserve: Option<Balance<Quote>>,
}

// === Public Functions ===

/// Schedules a round's terms for publication after the vault's applied round notice, replacing
/// any scheduled round or notice change. The terms' static checks run when they are built; the
/// round number, interval and budget are checked against the vault now to fail fast, and again at
/// publication. The claim window is a duration that publication starts. Zero reserve disables
/// reimbursement. Gas attribution remains off chain.
public fun schedule_round<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<RewardsAdmin>,
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
    clock: &Clock,
) {
    migrators_version.assert_current();

    let terms = vault::new_round_terms(
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
    );
    assert_fundable(vault, &terms);

    vault.schedule_round_publication(terms, clock);
}

/// Anyone publishes the scheduled round once its notice has elapsed: the governed treasury must
/// still be the expected one, and the round number, interval and budget must still fit the vault.
/// Funds holder claims and optional gas custody separately, with claims open for the scheduled
/// window from now.
public fun publish_round<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    lp_fee_policy: &LpFeePolicy,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();

    let terms = vault.take_round_publication(clock);
    let treasury = lp_fee_policy.protocol_destination();
    assert!(treasury == terms.expected_treasury(), ETreasuryChanged);
    assert_fundable(vault, &terms);
    let claim_deadline_at_ms = clock
        .timestamp_ms()
        .checked_add(terms.claim_window_duration_ms())
        .destroy_or!(abort EClaimDeadlineOverflow);

    let vault_id = object::id(vault);
    let gas_reserve_amount = terms.gas_reserve_amount();
    let (meme, mut quote) = vault.fund_round(
        terms.end_checkpoint(),
        terms.meme_amount(),
        terms.quote_amount() + gas_reserve_amount,
    );
    let gas_reserve = if (gas_reserve_amount > 0) option::some(quote.split(gas_reserve_amount))
    else option::none();
    let round = Round {
        id: object::new(ctx),
        vault: vault_id,
        number: terms.number(),
        claim_deadline_at_ms,
        root: terms.root(),
        leaf_count: terms.leaf_count(),
        claimed: unclaimed(terms.leaf_count()),
        meme,
        quote,
        treasury,
        gas_reserve,
    };
    let round_id = round.id.to_inner();
    let (meme_unallocated, quote_unallocated) = vault.rewards_balances();

    transfer::share_object(round);

    blast_events::round_published(
        vault_id,
        round_id,
        terms.number(),
        terms.start_checkpoint(),
        terms.end_checkpoint(),
        claim_deadline_at_ms,
        terms.root(),
        terms.manifest_digest(),
        terms.leaf_count(),
        terms.meme_amount(),
        terms.quote_amount(),
        meme_unallocated,
        quote_unallocated,
        treasury,
        gas_reserve_amount,
    );
}

/// Cancels the scheduled round, even a ready one; nothing was reserved, so no balance moves.
public fun cancel_round<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    migrators_version.assert_current();

    vault.cancel_round_publication();
}

/// Schedules a new round notice, after the applied one; replaces any scheduled round.
public fun schedule_round_delay<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<RewardsAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    migrators_version.assert_current();

    vault.schedule_round_publication_delay(delay_ms, clock);
}

/// Anyone applies a ready round-notice change.
public fun apply_round_delay<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    clock: &Clock,
) {
    migrators_version.assert_current();

    vault.apply_round_publication_delay(clock);
}

/// Cancels the pending round-notice change, even a ready one.
public fun cancel_round_delay<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    migrators_version.assert_current();

    vault.cancel_round_publication_delay();
}

/// Anyone may relay a proof; delivery is only to its committed beneficiary.
public fun claim<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();

    assert!(clock.timestamp_ms() < self.claim_deadline_at_ms, EClaimsClosed);
    assert!(index < self.leaf_count, EInvalidIndex);
    let (word, bit) = claim_bit(index);
    assert!(self.claimed[word] & bit == 0, EAlreadyClaimed);
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyClaim);

    let leaf_digest =
        merkle::leaf(self.vault, self.number, index, beneficiary, meme_amount, quote_amount);
    assert!(merkle::verify(self.root, leaf_digest, index, self.leaf_count, &proof), EInvalidProof);

    *&mut self.claimed[word] = self.claimed[word] | bit;
    self.meme.pay(meme_amount, beneficiary, ctx);
    self.quote.pay(quote_amount, beneficiary, ctx);

    blast_events::reward_paid(
        self.id.to_inner(),
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        self.meme.value(),
        self.quote.value(),
    );
}

/// RewardsAdmin settles a measured, capped reimbursement once. The committed
/// treasury receives it; all unused reserve immediately returns to this vault.
public fun settle_gas_reserve<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<RewardsAdmin>,
    vault: &mut LpVault<Meme, Quote>,
    reimbursement_amount: u64,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();

    assert!(self.vault == object::id(vault), EWrongVault);
    assert!(self.gas_reserve.is_some(), EReserveSettled);
    assert!(reimbursement_amount <= self.gas_reserve.borrow().value(), EOverReserve);

    let mut reserve = self.gas_reserve.extract();
    let reserve_returned = reserve.value() - reimbursement_amount;
    reserve.pay(reimbursement_amount, self.treasury, ctx);
    vault.restore_rewards(balance::zero(), reserve);
    let (_, quote_unallocated) = vault.rewards_balances();

    blast_events::gas_reserve_settled(
        self.vault,
        self.id.to_inner(),
        self.number,
        self.treasury,
        reimbursement_amount,
        reserve_returned,
        quote_unallocated,
    );
}

/// Anyone can close at the deadline, returning all unclaimed holder funds and
/// any unsettled reserve. Missing settlement authority cannot strand custody.
public fun close_round<Meme, Quote>(
    self: Round<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    vault: &mut LpVault<Meme, Quote>,
    clock: &Clock,
) {
    migrators_version.assert_current();

    assert!(self.vault == object::id(vault), EWrongVault);
    assert!(clock.timestamp_ms() >= self.claim_deadline_at_ms, EClaimsStillOpen);

    let Round { id, vault: vault_id, number, meme, mut quote, gas_reserve, .. } = self;
    let (meme_returned, quote_returned) = (meme.value(), quote.value());
    let reserve = gas_reserve.destroy_or!(balance::zero());
    let gas_reserve_returned = reserve.value();
    quote.join(reserve);
    vault.restore_rewards(meme, quote);

    blast_events::round_closed(
        vault_id,
        id.to_inner(),
        number,
        meme_returned,
        quote_returned,
        gas_reserve_returned,
    );

    id.delete();
}

// === Private Functions ===

/// Checks the terms against the vault: the next round number, an interval after the previous
/// round's, and a holder budget plus gas reserve within the unreserved rewards.
fun assert_fundable<Meme, Quote>(vault: &LpVault<Meme, Quote>, terms: &RoundTerms) {
    assert!(terms.number() == vault.next_round(), EWrongRound);
    assert!(
        vault.last_checkpoint().is_none_or!(|prior_end| *prior_end <= terms.start_checkpoint()),
        EOverlappingInterval,
    );
    let (available_meme, available_quote) = vault.rewards_balances();
    assert!(
        terms.meme_amount() <= available_meme && terms.quote_amount() <= available_quote
            && terms.gas_reserve_amount() <= available_quote - terms.quote_amount(),
        EInsufficientBudget,
    );
}

/// A claim bitmap with every leaf's bit clear, 256 leaves per word.
fun unclaimed(leaf_count: u64): vector<u256> {
    vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256)
}

/// Locates leaf `index` in the claim bitmap as its word and the bit within that word.
fun claim_bit(index: u64): (u64, u256) {
    (index / 256, 1u256 << ((index % 256) as u8))
}

// === Test-Only Functions ===

#[test_only]
/// Returns the Meme and Quote the round still holds for unpaid leaves.
public fun round_balances_for_testing<Meme, Quote>(self: &Round<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

#[test_only]
/// Reports whether leaf `index` has been paid.
public fun is_claimed_for_testing<Meme, Quote>(self: &Round<Meme, Quote>, index: u64): bool {
    let (word, bit) = claim_bit(index);
    self.claimed[word] & bit != 0
}

#[test_only]
/// Returns the independent pending gas custody; none means disabled or settled.
public fun gas_reserve_for_testing<Meme, Quote>(self: &Round<Meme, Quote>): Option<u64> {
    self.gas_reserve.map_ref!(|reserve| reserve.value())
}

// === Errors ===

#[error(code = 0)]
const EWrongRound: vector<u8> = b"Round number must match the vault's next round.";

#[error(code = 1)]
const EOverlappingInterval: vector<u8> =
    b"Checkpoint interval must not overlap the previous round.";

#[error(code = 2)]
const EEmptyClaim: vector<u8> = b"At least one claimed amount must be nonzero.";

#[error(code = 3)]
const EInvalidIndex: vector<u8> = b"Claim index must be less than the committed leaf count.";

#[error(code = 4)]
const EAlreadyClaimed: vector<u8> = b"This allocation has already been paid.";

#[error(code = 5)]
const EInvalidBeneficiary: vector<u8> = b"Beneficiary must not be the zero address.";

#[error(code = 6)]
const EInvalidProof: vector<u8> = b"Proof must match the committed recipient, amounts and domain.";

#[error(code = 7)]
const ETreasuryChanged: vector<u8> =
    b"Expected treasury must match the governed protocol destination.";

#[error(code = 8)]
const EClaimDeadlineOverflow: vector<u8> = b"The claim window must end within u64 milliseconds.";

#[error(code = 9)]
const EInsufficientBudget: vector<u8> =
    b"Holder funding and gas reserve must fit the vault's available balances.";

#[error(code = 10)]
const EClaimsClosed: vector<u8> = b"The claim deadline has been reached.";

#[error(code = 11)]
const EWrongVault: vector<u8> = b"Round must be settled or closed against its funding vault.";

#[error(code = 12)]
const EReserveSettled: vector<u8> = b"Gas reimbursement is disabled or already settled.";

#[error(code = 13)]
const EOverReserve: vector<u8> = b"Reimbursement must not exceed the bound gas reserve.";

#[error(code = 14)]
const EClaimsStillOpen: vector<u8> = b"Round can close only at or after its claim deadline.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::blast_fun_domain::{CancelAdmin, RewardsAdmin};

use blast_fun_migrators::{
    blast_events,
    merkle,
    lp_fee_policy::LpFeePolicy,
    blast_fun_migrators::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault, RoundTerms},
};

use sui::{balance::{Self, Balance}, clock::Clock};

use fun vault::pay as Balance.pay;
