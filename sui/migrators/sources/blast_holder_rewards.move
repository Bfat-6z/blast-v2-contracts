// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Holder rewards: rounds funded from a vault's rewards share and paid by Merkle proof.
///
/// Blast's off-chain system turns checkpointed holder balances into a Merkle allocation, and a
/// Blast administrator publishes it as a round that reserves its budget from the vault. Anyone can
/// relay a proof afterwards; each leaf pays its committed beneficiary once.
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

/// Funds holder claims and optional gas custody separately, binding the expected governed treasury.
/// Zero reserve disables reimbursement. Gas attribution remains off chain.
public fun publish_round<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<RewardsAdmin>,
    lp_fee_policy: &LpFeePolicy,
    expected_treasury: address,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
    claim_deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();

    let treasury = lp_fee_policy.protocol_destination();
    assert!(treasury == expected_treasury, ETreasuryChanged);
    assert!(number == vault.next_round(), EWrongRound);
    assert!(
        start_checkpoint < end_checkpoint
            && vault.last_checkpoint().is_none_or!(|prior_end| *prior_end <= start_checkpoint),
        EInvalidInterval,
    );
    assert!(
        root.length() == constants::digest_length!()
            && manifest_digest.length() == constants::digest_length!(),
        EInvalidCommitment,
    );
    assert!(leaf_count > 0 && leaf_count <= constants::max_reward_leaves!(), EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);

    assert!(claim_deadline_at_ms > clock.timestamp_ms(), EInvalidClaimDeadline);

    let (available_meme, available_quote) = vault.rewards_balances();
    assert!(
        meme_amount <= available_meme && quote_amount <= available_quote
            && gas_reserve_amount <= available_quote - quote_amount,
        EInsufficientBudget,
    );

    let vault_id = object::id(vault);
    let (meme, mut quote) = vault.fund_round(
        end_checkpoint,
        meme_amount,
        quote_amount + gas_reserve_amount,
    );
    let gas_reserve = if (gas_reserve_amount > 0) option::some(quote.split(gas_reserve_amount))
    else option::none();
    let round = Round {
        id: object::new(ctx),
        vault: vault_id,
        number,
        claim_deadline_at_ms,
        root,
        leaf_count,
        claimed: unclaimed(leaf_count),
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
        number,
        start_checkpoint,
        end_checkpoint,
        claim_deadline_at_ms,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        meme_unallocated,
        quote_unallocated,
        treasury,
        gas_reserve_amount,
    );
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
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);

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
const EInvalidInterval: vector<u8> =
    b"Checkpoint interval must be nonempty and not overlap the previous round.";

#[error(code = 2)]
const EInvalidCommitment: vector<u8> =
    b"Root and manifest digest must each contain exactly 32 bytes.";

#[error(code = 3)]
const EInvalidLeafCount: vector<u8> = b"Round must contain between 1 and 65,536 leaves.";

#[error(code = 4)]
const EEmptyBudget: vector<u8> = b"At least one reward amount must be nonzero.";

#[error(code = 5)]
const EInvalidIndex: vector<u8> = b"Claim index must be less than the committed leaf count.";

#[error(code = 6)]
const EAlreadyClaimed: vector<u8> = b"This allocation has already been paid.";

#[error(code = 7)]
const EInvalidBeneficiary: vector<u8> = b"Beneficiary must not be the zero address.";

#[error(code = 8)]
const EInvalidProof: vector<u8> = b"Proof must match the committed recipient, amounts and domain.";

#[error(code = 9)]
const ETreasuryChanged: vector<u8> = b"Expected treasury must match the governed protocol destination.";

#[error(code = 10)]
const EInvalidClaimDeadline: vector<u8> = b"Claim deadline must be in the future.";

#[error(code = 11)]
const EInsufficientBudget: vector<u8> = b"Holder funding and gas reserve must fit the vault's available balances.";

#[error(code = 12)]
const EClaimsClosed: vector<u8> = b"The claim deadline has been reached.";

#[error(code = 13)]
const EWrongVault: vector<u8> = b"Round must be settled or closed against its funding vault.";

#[error(code = 14)]
const EReserveSettled: vector<u8> = b"Gas reimbursement is disabled or already settled.";

#[error(code = 15)]
const EOverReserve: vector<u8> = b"Reimbursement must not exceed the bound gas reserve.";

#[error(code = 16)]
const EClaimsStillOpen: vector<u8> = b"Round can close only at or after its claim deadline.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::blast_fun_domain::RewardsAdmin;

use blast_fun_migrators::{
    blast_events,
    constants,
    merkle,
    lp_fee_policy::LpFeePolicy,
    blast_fun_migrators::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
};

use sui::{balance::{Self, Balance}, clock::Clock};

use fun vault::pay as Balance.pay;
