// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Merkle rounds Blast's rewards administrator schedules on a migrated presale vault and anyone
/// publishes once the vault's round notice has elapsed, funding them from its holder-reward fee
/// share.
module blast_presale::holder_rewards;

// === Public Types ===

/// A holder round with optional, independent one-shot gas custody.
/// Claims do not touch its gas reserve.
public struct Round<phantom Meme, phantom Quote> has key {
    id: UID,
    vault_id: ID,
    number: u64,
    claim_deadline_ms: u64,
    root: vector<u8>,
    leaf_count: u64,
    claimed_bitmap: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    treasury: address,
    gas_reserve: Option<Balance<Quote>>,
}

// === Public Functions ===

/// Schedules a round's terms for publication after the vault's applied round notice, replacing
/// any scheduled round or notice change. The terms' static checks run when they are built; the
/// round number, interval and budget are checked against the vault now to fail fast, and again at
/// publication. The claim window is a duration that publication starts. A zero reserve disables
/// reimbursement for this round. `meme_amount` must be zero: holder Meme fees go to the treasury,
/// and the field stays in the terms and leaf for parity with the migrators' rounds. USD
/// eligibility and gas attribution remain off chain.
public fun schedule_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
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
    package_version.assert_current();

    let terms = presale_vault::new_round_terms(
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
/// Atomically funds holder leaves and separate gas custody under that treasury, with claims open
/// for the scheduled window from now.
public fun publish_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    let terms = vault.take_round_publication(clock);
    let treasury = fee_policy.destination();
    assert!(treasury == terms.expected_treasury(), errors::treasury_changed!());
    assert_fundable(vault, &terms);
    let claim_deadline_at_ms = clock
        .timestamp_ms()
        .checked_add(terms.claim_window_duration_ms())
        .destroy_or!(abort errors::claim_deadline_overflow!());

    let vault_id = object::id(vault);
    let gas_reserve_amount = terms.gas_reserve_amount();
    let mut quote = vault.fund_round(
        terms.end_checkpoint(),
        terms.quote_amount() + gas_reserve_amount,
    );
    let gas_reserve = if (gas_reserve_amount > 0) option::some(quote.split(gas_reserve_amount))
    else option::none();
    let round = Round<Meme, Quote> {
        id: object::new(ctx),
        vault_id,
        number: terms.number(),
        claim_deadline_ms: claim_deadline_at_ms,
        root: terms.root(),
        leaf_count: terms.leaf_count(),
        claimed_bitmap: unclaimed(terms.leaf_count()),
        meme: balance::zero(),
        quote,
        treasury,
        gas_reserve,
    };
    let quote_unallocated = vault.holder_rewards_quote();

    event::emit(RoundPublished<Meme, Quote> {
        vault_id,
        round_id: round.id.to_inner(),
        number: terms.number(),
        start_checkpoint: terms.start_checkpoint(),
        end_checkpoint: terms.end_checkpoint(),
        claim_deadline_ms: claim_deadline_at_ms,
        root: terms.root(),
        manifest_digest: terms.manifest_digest(),
        leaf_count: terms.leaf_count(),
        meme_amount: terms.meme_amount(),
        quote_amount: terms.quote_amount(),
        quote_unallocated,
        treasury,
        gas_reserve_amount,
    });

    transfer::share_object(round);
}

/// Cancels the scheduled round, even a ready one; nothing was reserved, so no balance moves.
public fun cancel_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    vault.cancel_round_publication();
}

/// Schedules a new round notice, after the applied one; replaces any scheduled round.
public fun schedule_round_delay<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<RewardsAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    vault.schedule_round_publication_delay(delay_ms, clock);
}

/// Anyone applies a ready round-notice change.
public fun apply_round_delay<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    vault.apply_round_publication_delay(clock);
}

/// Cancels the pending round-notice change, even a ready one.
public fun cancel_round_delay<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    vault.cancel_round_publication_delay();
}

/// Pays only the committed holder balances before the claim deadline; anyone may relay an unchanged
/// proof.
public fun claim<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    package_version: &PackageVersion,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(clock.timestamp_ms() < self.claim_deadline_ms, errors::claims_closed!());
    assert!(index < self.leaf_count, errors::invalid_index!());

    let (word, bit) = claim_bit(index);
    assert!(self.claimed_bitmap[word] & bit == 0, errors::already_claimed!());
    assert!(beneficiary != @0x0, errors::invalid_beneficiary!());
    assert!(meme_amount > 0 || quote_amount > 0, errors::empty_claim!());

    let digest = leaf(self.vault_id, self.number, index, beneficiary, meme_amount, quote_amount);
    assert!(
        merkle_tree::verify(self.root, digest, index, self.leaf_count, &proof),
        errors::invalid_proof!(),
    );

    let claimed_word = &mut self.claimed_bitmap[word];

    *claimed_word = *claimed_word | bit;
    self.meme.pay(meme_amount, beneficiary, ctx);
    self.quote.pay(quote_amount, beneficiary, ctx);

    event::emit(RewardClaimed<Meme, Quote> {
        round_id: self.id.to_inner(),
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        meme_remaining: self.meme.value(),
        quote_remaining: self.quote.value(),
    });
}

/// RewardsAdmin settles a measured, capped reimbursement once. The committed
/// treasury receives it; all unused reserve immediately returns to this vault.
public fun settle_gas_reserve<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<RewardsAdmin>,
    vault: &mut Vault<Meme, Quote>,
    reimbursement_amount: u64,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(self.vault_id == object::id(vault), errors::wrong_vault!());
    assert!(self.gas_reserve.is_some(), errors::reserve_settled!());
    assert!(reimbursement_amount <= self.gas_reserve.borrow().value(), errors::over_reserve!());

    let mut reserve = self.gas_reserve.extract();
    let reserve_returned = reserve.value() - reimbursement_amount;
    reserve.pay(reimbursement_amount, self.treasury, ctx);
    vault.restore_holder_rewards(reserve);
    let quote_unallocated = vault.holder_rewards_quote();

    event::emit(GasReserveSettled<Meme, Quote> {
        vault_id: self.vault_id,
        round_id: self.id.to_inner(),
        number: self.number,
        treasury: self.treasury,
        reimbursement_amount,
        reserve_returned,
        quote_unallocated,
    });
}

/// Anyone can close at the deadline, returning all unclaimed holder funds and
/// any unsettled reserve. Missing settlement authority cannot strand custody.
public fun close_round<Meme, Quote>(
    self: Round<Meme, Quote>,
    package_version: &PackageVersion,
    vault: &mut Vault<Meme, Quote>,
    clock: &Clock,
) {
    package_version.assert_current();

    assert!(self.vault_id == object::id(vault), errors::wrong_vault!());
    assert!(clock.timestamp_ms() >= self.claim_deadline_ms, errors::claims_still_open!());

    let Round { id, vault_id, number, meme, mut quote, gas_reserve, .. } = self;
    let (meme_returned, quote_returned) = (meme.value(), quote.value());
    let reserve = gas_reserve.destroy_or!(balance::zero());
    let gas_reserve_returned = reserve.value();
    quote.join(reserve);
    meme.destroy_zero();
    vault.restore_holder_rewards(quote);

    event::emit(RoundClosed<Meme, Quote> {
        vault_id,
        round_id: id.to_inner(),
        number,
        meme_returned,
        quote_returned,
        gas_reserve_returned,
    });

    id.delete();
}

// === Private Functions ===

/// Checks the terms against the vault: the next round number, an interval after the previous
/// round's, and a holder budget plus gas reserve within the unreserved holder rewards.
fun assert_fundable<Meme, Quote>(vault: &Vault<Meme, Quote>, terms: &RoundTerms) {
    assert!(terms.number() == vault.next_round(), errors::wrong_round!());
    assert!(
        vault.last_checkpoint().is_none_or!(|last| *last <= terms.start_checkpoint()),
        errors::overlapping_interval!(),
    );
    let available_quote = vault.holder_rewards_quote();
    assert!(
        terms.quote_amount() <= available_quote
            && terms.gas_reserve_amount() <= available_quote - terms.quote_amount(),
        errors::insufficient_budget!(),
    );
}

/// A claim bitmap with every leaf's bit clear, 256 leaves per word.
fun unclaimed(leaf_count: u64): vector<u256> {
    vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256)
}

/// The bitmap word and bit recording leaf `index`'s claim.
fun claim_bit(index: u64): (u64, u256) {
    (index / 256, 1u256 << ((index % 256) as u8))
}

/// The domain-separated digest of one beneficiary's reward leaf.
fun leaf(
    vault_id: ID,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    let mut bytes = b"\x00blast-presale-holder-rewards-v1";
    bytes.append(bcs::to_bytes(&vault_id));
    bytes.append(bcs::to_bytes(&round));
    bytes.append(bcs::to_bytes(&index));
    bytes.append(bcs::to_bytes(&beneficiary));
    bytes.append(bcs::to_bytes(&meme));
    bytes.append(bcs::to_bytes(&quote));

    hash::blake2b256(&bytes)
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing<Meme, Quote>(
    vault_id: ID,
    number: u64,
    claim_deadline_at_ms: u64,
    root: vector<u8>,
    leaf_count: u64,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
): Round<Meme, Quote> {
    Round {
        id: object::new(ctx),
        vault_id,
        number,
        claim_deadline_ms: claim_deadline_at_ms,
        root,
        leaf_count,
        claimed_bitmap: unclaimed(leaf_count),
        meme,
        quote,
        treasury: @0x0,
        gas_reserve: option::none(),
    }
}

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: Round<Meme, Quote>) {
    let Round {
        id,
        vault_id: _,
        number: _,
        claim_deadline_ms: _,
        root: _,
        leaf_count: _,
        claimed_bitmap: _,
        meme,
        quote,
        treasury: _,
        gas_reserve,
    } = self;
    gas_reserve.destroy_or!(balance::zero()).destroy_zero();
    id.delete();
    meme.destroy_zero();
    quote.destroy_zero();
}

#[test_only]
public fun leaf_for_testing(
    vault_id: ID,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    leaf(vault_id, round, index, beneficiary, meme, quote)
}

#[test_only]
public fun balances_for_testing<Meme, Quote>(self: &Round<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

#[test_only]
public fun reserve_balances_for_testing<Meme, Quote>(
    self: &Round<Meme, Quote>,
): (u64, u64, Option<u64>) {
    (self.meme.value(), self.quote.value(), self.gas_reserve.map_ref!(|reserve| reserve.value()))
}

#[test_only]
public fun reserve_published_id<Meme, Quote>(payload: &RoundPublished<Meme, Quote>): ID {
    payload.round_id
}

#[test_only]
public fun reserve_published_bytes<Meme, Quote>(payload: &RoundPublished<Meme, Quote>): vector<u8> {
    bcs::to_bytes(payload)
}

#[test_only]
public fun reserve_claimed_bytes<Meme, Quote>(payload: &RewardClaimed<Meme, Quote>): vector<u8> {
    bcs::to_bytes(payload)
}

#[test_only]
public fun reserve_settled_bytes<Meme, Quote>(
    payload: &GasReserveSettled<Meme, Quote>,
): vector<u8> {
    bcs::to_bytes(payload)
}

#[test_only]
public fun reserve_closed_bytes<Meme, Quote>(payload: &RoundClosed<Meme, Quote>): vector<u8> {
    bcs::to_bytes(payload)
}

// === Events ===

public struct RoundPublished<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    claim_deadline_ms: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    quote_unallocated: u64,
    treasury: address,
    gas_reserve_amount: u64,
}

public struct RewardClaimed<phantom Meme, phantom Quote> has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

public struct GasReserveSettled<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    treasury: address,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
}

public struct RoundClosed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
}

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_presale::{
    blast_presale,
    blast_presale_domain::{CancelAdmin, RewardsAdmin},
    blast_presale_package::PackageVersion,
    errors,
    fee_policy::FeePolicy,
    merkle_tree,
    presale_vault::{Self, RoundTerms, Vault}
};

use std::bcs;

use sui::{balance::{Self, Balance}, clock::Clock, event, hash};

use fun blast_presale::pay as Balance.pay;
