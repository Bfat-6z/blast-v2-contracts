// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Holder-reward rounds funded from a vault's rewards balance under the Blast admin witness, and
/// Merkle claims that pay each committed beneficiary once.
module blast_fun_migrators::blast_holder_rewards_tests;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct BLAST_HOLDER_REWARDS_TESTS has drop {}

public struct QUOTE() has drop;

/// The test adapter's launch witness, which is also its vault venue marker.
public struct TestVenue() has drop;

public struct TestPosition has key, store { id: UID }

/// One vault whose whole fee split funds holder rewards.
public struct RewardsFixture {
    scenario: Scenario,
    migrators_version: MigratorsVersion,
    policy: LpFeePolicy,
    clock: Clock,
    vault: LpVault<BLAST_HOLDER_REWARDS_TESTS, QUOTE>,
}

/// Independently encoded `RoundPublished` in ABI order.
public struct ExpectedRoundPublished has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    claim_deadline_at_ms: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
    treasury: address,
    gas_reserve_amount: u64,
}

/// Independently encoded `RewardPaid` in ABI order.
public struct ExpectedRewardPaid has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

/// Independently encoded settlement payload in ABI order.
public struct ExpectedGasReserveSettled has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    treasury: address,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
}

/// Independently encoded recovery payload in ABI order.
public struct ExpectedRoundClosed has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
}

// === Tests ===

// Publication

#[test]
fun publication_reserves_its_budget_from_the_rewards_balance_and_announces_the_commitment() {
    let mut f = start();
    let root = f.leaf(0, 0, ALICE, 10, 20);

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, root, digest(), 1, 10, 20);

    let published = event::events_by_type<blast_events::RoundPublished>();
    assert_eq!(published.length(), 1);
    let round_id = round_id_of(published[0]);
    assert_eq!(
        bcs::to_bytes(&published[0]),
        bcs::to_bytes(
            &ExpectedRoundPublished {
                vault_id: object::id(&f.vault),
                round_id,
                number: 0,
                start_checkpoint: 0,
                end_checkpoint: 10,
                claim_deadline_at_ms: DEADLINE_AT_MS,
                root,
                manifest_digest: digest(),
                leaf_count: 1,
                meme_amount: 10,
                quote_amount: 20,
                meme_unallocated: FUNDED_MEME - 10,
                quote_unallocated: FUNDED_QUOTE - 20,
                treasury: PUBLISHER,
                gas_reserve_amount: 0,
            },
        ),
    );
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, FUNDED_QUOTE - 20);
    assert_eq!(f.vault.next_round(), 1);
    assert_eq!(f.vault.last_checkpoint(), option::some(10));

    f.scenario.next_tx(BOT);
    let round = f.take_round(round_id);
    assert_balances!(|| round.round_balances_for_testing(), 10, 20);
    assert!(!round.is_claimed_for_testing(0));
    test_scenario::return_shared(round);

    f.end();
}

#[test]
fun a_round_may_reserve_the_whole_rewards_balance_of_one_asset() {
    let mut f = start();

    let round_id = f.round(0, FUNDED_MEME, 0);

    assert_balances!(|| f.vault.rewards_balances(), 0, FUNDED_QUOTE);
    f.claim(round_id, 0, ALICE, FUNDED_MEME, 0, vector[]);
    f.assert_received(ALICE, FUNDED_MEME, 0);

    f.end();
}

#[test]
fun rounds_accept_adjacent_intervals_and_gaps() {
    let mut f = start();
    let first = f.leaf(0, 0, ALICE, 1, 1);
    let second = f.leaf(1, 0, ALICE, 1, 1);

    f.scenario.next_tx(ADMIN);
    f.publish(0, 7, 9, first, digest(), 1, 1, 1);
    f.publish(1, 9, 30, second, digest(), 1, 1, 1);
    f.publish(2, 40, 50, digest(), digest(), 1, 1, 1);

    assert_eq!(f.vault.next_round(), 3);
    assert_eq!(f.vault.last_checkpoint(), option::some(50));
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EWrongRound,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_stale_round_number_cannot_fund_another_round() {
    let mut f = start();
    f.round(0, 10, 20);

    f.round(0, 10, 20);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EWrongRound,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_skipped_round_number_is_rejected() {
    let mut f = start();

    f.round(1, 10, 20);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EOverlappingInterval,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun overlapping_intervals_are_rejected() {
    let mut f = start();
    f.round(0, 1, 1);

    f.scenario.next_tx(ADMIN);
    f.publish(1, 9, 20, digest(), digest(), 1, 1, 1);

    f.end();
}

#[test]
fun low_volume_checkpoint_gaps_are_accepted() {
    let mut f = start();
    f.round(0, 1, 1);
    f.scenario.next_tx(ADMIN);
    f.publish(1, 11, 20, digest(), digest(), 1, 1, 1);
    assert_eq!(f.vault.next_round(), 2);
    assert_eq!(f.vault.last_checkpoint(), option::some(20));
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EEmptyInterval, location = blast_fun_migrators::vault)]
fun an_empty_interval_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 10, 10, digest(), digest(), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidCommitment,
    location = blast_fun_migrators::vault,
)]
fun a_malformed_root_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, vector::tabulate!(31, |_| 1u8), digest(), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidCommitment,
    location = blast_fun_migrators::vault,
)]
fun a_malformed_manifest_digest_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, digest(), vector::tabulate!(33, |_| 1u8), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidLeafCount,
    location = blast_fun_migrators::vault,
)]
fun an_empty_leaf_set_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, digest(), digest(), 0, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidLeafCount,
    location = blast_fun_migrators::vault,
)]
fun the_first_leaf_count_over_capacity_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, digest(), digest(), 65_537, 1, 1);

    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EEmptyBudget, location = blast_fun_migrators::vault)]
fun an_empty_budget_is_rejected() {
    let mut f = start();

    f.round(0, 0, 0);

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EInsufficientBudget, location = blast_fun_migrators::blast_holder_rewards)]
fun a_meme_budget_above_the_rewards_balance_is_rejected() {
    let mut f = start();

    f.round(0, FUNDED_MEME + 1, 0);

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EInsufficientBudget, location = blast_fun_migrators::blast_holder_rewards)]
fun a_quote_budget_above_the_rewards_balance_is_rejected() {
    let mut f = start();

    f.round(0, 0, FUNDED_QUOTE + 1);

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EInsufficientBudget, location = blast_fun_migrators::blast_holder_rewards)]
fun reserved_funds_cannot_back_a_second_round() {
    let mut f = start();
    f.round(0, FUNDED_MEME, 0);

    f.round(1, 1, 0);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_scheduling_before_every_round_check() {
    let mut f = start();
    f.migrators_version.set_for_testing(2);

    f.scenario.next_tx(ADMIN);
    f.publish(7, 10, 10, vector[], vector[], 0, 0, 0);

    f.end();
}

// Claims

#[test]
fun a_relayed_claim_pays_the_committed_beneficiary_once_and_emits_the_exact_payment() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, ALICE, 10, 20, vector[]);

    let paid = event::events_by_type<blast_events::RewardPaid>();
    assert_eq!(paid.length(), 1);
    assert_eq!(
        bcs::to_bytes(&paid[0]),
        bcs::to_bytes(
            &ExpectedRewardPaid {
                round_id,
                index: 0,
                beneficiary: ALICE,
                meme_amount: 10,
                quote_amount: 20,
                meme_remaining: 0,
                quote_remaining: 0,
            },
        ),
    );
    f.assert_round(round_id, 0, 0, 0, true);
    f.assert_received(ALICE, 10, 20);
    f.assert_received(BOT, 0, 0);

    f.end();
}

#[test]
fun a_quote_only_claim_creates_no_zero_meme_coin() {
    let mut f = start();
    let round_id = f.round(0, 0, 20);

    f.claim(round_id, 0, ALICE, 0, 20, vector[]);

    f.assert_received(ALICE, 0, 20);
    f.end();
}

#[test]
fun two_leaves_are_claimed_with_positional_proofs_and_leave_exact_remainders() {
    let mut f = start();
    let alice = f.leaf(0, 0, ALICE, 10, 0);
    let bob = f.leaf(0, 1, BOB, 5, 7);
    let root = merkle::node_for_testing(alice, bob);
    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, root, digest(), 2, 15, 7);
    let round_id = published_round_id();

    f.claim(round_id, 1, BOB, 5, 7, vector[alice]);
    let paid = event::events_by_type<blast_events::RewardPaid>();
    assert_eq!(
        bcs::to_bytes(&paid[0]),
        bcs::to_bytes(
            &ExpectedRewardPaid {
                round_id,
                index: 1,
                beneficiary: BOB,
                meme_amount: 5,
                quote_amount: 7,
                meme_remaining: 10,
                quote_remaining: 0,
            },
        ),
    );
    f.assert_round(round_id, 10, 0, 1, true);
    f.assert_round(round_id, 10, 0, 0, false);
    f.claim(round_id, 0, ALICE, 10, 0, vector[bob]);

    f.assert_round(round_id, 0, 0, 0, true);
    f.assert_received(ALICE, 10, 0);
    f.assert_received(BOB, 5, 7);
    f.end();
}

#[test]
fun a_later_round_leaves_earlier_unclaimed_entitlements_intact() {
    let mut f = start();
    let first = f.round(0, 10, 20);
    let second = f.round(1, 20, 40);

    f.claim(second, 0, ALICE, 20, 40, vector[]);
    f.claim(first, 0, ALICE, 10, 20, vector[]);

    f.assert_round(first, 0, 0, 0, true);
    f.assert_round(second, 0, 0, 0, true);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 30, FUNDED_QUOTE - 60);
    f.end();
}

#[test]
fun the_largest_round_claims_its_last_bitmap_bit() {
    let mut f = start();
    let alice_leaf = f.leaf(0, 65_535, ALICE, 1, 0);
    let sibling = f.leaf(0, 0, ALICE, 1, 0);
    let proof = vector::tabulate!(16, |_| sibling);
    let mut root = alice_leaf;
    proof.do_ref!(|sibling| root = merkle::node_for_testing(*sibling, root));
    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 1, root, root, 65_536, 1, 0);
    let round_id = published_round_id();

    f.claim(round_id, 65_535, ALICE, 1, 0, proof);

    f.assert_round(round_id, 0, 0, 65_535, true);
    f.assert_round(round_id, 0, 0, 65_534, false);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EAlreadyClaimed,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_payout_cannot_be_replayed_even_after_the_budget_is_drained() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);
    f.claim(round_id, 0, ALICE, 10, 20, vector[]);

    f.claim(round_id, 0, ALICE, 10, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidProof,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_relayer_cannot_substitute_its_own_address() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, BOT, 10, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidProof,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_holder_cannot_change_an_amount() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, ALICE, 9, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidProof,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_proof_of_the_wrong_depth_is_rejected() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, ALICE, 10, 20, vector[digest()]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidIndex,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun an_index_outside_the_leaf_set_is_rejected_before_proof_work() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 1, ALICE, 10, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidBeneficiary,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_zero_beneficiary_is_rejected_before_proof_work() {
    let mut f = start();
    let round_id = f.round(0, 1, 1);

    f.claim(round_id, 0, @0x0, 1, 1, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EEmptyClaim,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun an_empty_claim_cannot_consume_a_bitmap_bit() {
    let mut f = start();
    let round_id = f.round(0, 1, 1);

    f.claim(round_id, 0, ALICE, 0, 0, vector[]);

    f.end();
}

#[test]
#[expected_failure(abort_code = balance::ENotEnough, location = sui::balance)]
fun a_claim_cannot_exceed_its_reserved_budget() {
    let mut f = start();
    let root = f.leaf(0, 0, ALICE, 2, 1);
    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, root, digest(), 1, 1, 1);
    let round_id = published_round_id();

    f.claim(round_id, 0, ALICE, 2, 1, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_a_claim_before_every_claim_check() {
    let mut f = start();
    let round_id = f.round(0, 1, 1);
    f.migrators_version.set_for_testing(2);

    f.claim(round_id, 99, @0x0, 0, 0, vector[]);

    f.end();
}

// Optional gas custody and deadline recovery

#[test]
fun the_maximal_combined_quote_budget_is_supported_without_overflow() {
    let mut f = start();
    let maximum = 18_446_744_073_709_551_615;
    let gas = maximum / 11;
    let quote = maximum - gas;
    f.vault.restore_rewards(balance::zero(), balance::create_for_testing(maximum - FUNDED_QUOTE));
    let root = f.leaf(0, 0, ALICE, 10, quote);
    f.publish_reserved(0, 0, 10, root, digest(), 1, 10, quote, gas, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    let id = published_round_id();
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, 0);
    f.settle(id, gas);
    f.claim(id, 0, ALICE, 10, quote, vector[]);
    f.assert_received(PUBLISHER, 0, gas);
    f.assert_received(ALICE, 10, quote);
    f.close(id, DEADLINE_AT_MS);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, 0);
    f.end();
}

#[test]
fun zero_reimbursement_returns_the_entire_reserve() {
    assert_reimbursement(0);
}

#[test]
fun one_unit_reimbursement_returns_every_remaining_unit() {
    assert_reimbursement(1);
}

#[test]
fun partial_reimbursement_preserves_claim_custody() {
    assert_reimbursement(29);
}

#[test]
fun full_reimbursement_does_not_consume_holder_funds() {
    assert_reimbursement(30);
}

#[test]
fun permissionless_close_returns_unclaimed_holder_funds_and_unsettled_reserve() {
    let mut f = start();
    let round_id = f.reserve_round(30);
    f.close(round_id, DEADLINE_AT_MS);
    let events = event::events_by_type<blast_events::RoundClosed>();
    assert_eq!(events.length(), 1);
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&ExpectedRoundClosed {
        vault_id: object::id(&f.vault), round_id, number: 0,
        meme_returned: 10, quote_returned: 300, gas_reserve_returned: 30,
    }));
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME, FUNDED_QUOTE);
    assert_eq!(f.vault.next_round(), 1);
    assert_eq!(f.vault.last_checkpoint(), option::some(10));
    f.end();
}

#[test]
fun settlement_after_deadline_is_allowed_until_permissionless_close() {
    let mut f = start();
    let round_id = f.reserve_round(30);
    f.clock.set_for_testing(DEADLINE_AT_MS + 1);
    f.settle(round_id, 24);
    f.close(round_id, DEADLINE_AT_MS + 1);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME, FUNDED_QUOTE - 24);
    f.assert_received(PUBLISHER, 0, 24);
    f.end();
}

#[test]
fun zero_reserve_supports_claims_and_permissionless_close_without_settlement() {
    let mut f = start();
    let round_id = f.reserve_round(0);
    f.assert_reserve(round_id, option::none());
    f.claim(round_id, 0, ALICE, 10, 300, vector[]);
    f.close(round_id, DEADLINE_AT_MS + 1);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, FUNDED_QUOTE - 300);
    f.end();
}

#[test]
fun a_treasury_change_after_publication_cannot_redirect_reimbursement() {
    let mut f = start();
    let round_id = f.reserve_round(30);
    f.change_treasury(BOB);
    f.settle(round_id, 24);
    f.assert_received(PUBLISHER, 0, 24);
    f.assert_received(BOB, 0, 0);
    f.close(round_id, DEADLINE_AT_MS);
    f.end();
}

#[test]
fun claims_work_one_millisecond_before_the_deadline() {
    let mut f = start();
    let round_id = f.reserve_round(30);
    f.clock.set_for_testing(DEADLINE_AT_MS - 1);
    f.claim(round_id, 0, ALICE, 10, 300, vector[]);
    f.assert_received(ALICE, 10, 300);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EReserveSettled, location = blast_fun_migrators::blast_holder_rewards)]
fun disabled_gas_custody_cannot_be_settled() {
    let mut f = start();
    let id = f.reserve_round(0);
    f.settle(id, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EOverReserve, location = blast_fun_migrators::blast_holder_rewards)]
fun reimbursement_cannot_exceed_the_reserved_quote() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.settle(id, 31);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EReserveSettled, location = blast_fun_migrators::blast_holder_rewards)]
fun settlement_cannot_be_replayed() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.settle(id, 24);
    f.settle(id, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EClaimsStillOpen, location = blast_fun_migrators::blast_holder_rewards)]
fun close_rejects_the_millisecond_before_deadline() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.close(id, DEADLINE_AT_MS - 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EClaimsClosed, location = blast_fun_migrators::blast_holder_rewards)]
fun claims_stop_exactly_at_the_deadline_before_proof_checks() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.clock.set_for_testing(DEADLINE_AT_MS);
    f.claim(id, 99, @0x0, 0, 0, vector[]);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EClaimsClosed, location = blast_fun_migrators::blast_holder_rewards)]
fun claims_stop_after_the_deadline() {
    let mut f = start();
    let id = f.reserve_round(0);
    f.clock.set_for_testing(DEADLINE_AT_MS + 1);
    f.claim(id, 0, ALICE, 10, 300, vector[]);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EZeroClaimWindow, location = blast_fun_migrators::vault)]
fun scheduling_requires_a_positive_claim_window() {
    let mut f = start();
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 10, 300, 30, 0, PUBLISHER);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EZeroTreasury, location = blast_fun_migrators::vault)]
fun scheduling_requires_a_nonzero_expected_treasury() {
    let mut f = start();
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 10, 300, 30, CLAIM_WINDOW_DURATION_MS, @0x0);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EInsufficientBudget, location = blast_fun_migrators::blast_holder_rewards)]
fun combined_holder_and_gas_budget_cannot_exceed_vault_quote() {
    let mut f = start();
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 10, FUNDED_QUOTE - 180, 181, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EBudgetOverflow, location = blast_fun_migrators::vault)]
fun a_holder_quote_and_gas_reserve_beyond_u64_are_rejected() {
    let mut f = start();
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 10, 18_446_744_073_709_551_615, 1, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.end();
}

#[test]
fun a_gas_reserve_of_a_tenth_of_the_holder_quote_is_accepted() {
    let mut f = start();
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 0, 300, 30, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.assert_reserve(published_round_id(), option::some(30));
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME, FUNDED_QUOTE - 330);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EGasReserveTooLarge, location = blast_fun_migrators::vault)]
fun a_gas_reserve_one_unit_above_a_tenth_of_the_holder_quote_is_rejected() {
    let mut f = start();
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 0, 300, 31, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EGasReserveTooLarge, location = blast_fun_migrators::vault)]
fun a_meme_only_round_cannot_reserve_gas() {
    let mut f = start();
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 10, 0, 1, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::ETreasuryChanged, location = blast_fun_migrators::blast_holder_rewards)]
fun changed_treasury_rejects_publication_with_gas() {
    let mut f = start();
    f.change_treasury(BOB);
    f.publish_reserved(0, 0, 10, digest(), digest(), 1, 10, 300, 30, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::ETreasuryChanged, location = blast_fun_migrators::blast_holder_rewards)]
fun a_treasury_change_after_scheduling_rejects_publication_before_the_budget() {
    let mut f = start();
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.change_treasury(BOB);
    f.drain_rewards(0, FUNDED_QUOTE);

    f.publish_after_notice();

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EWrongVault, location = blast_fun_migrators::blast_holder_rewards)]
fun settlement_rejects_a_different_vault_before_over_reserve() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.settle_against_wrong_vault(id);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EWrongVault, location = blast_fun_migrators::blast_holder_rewards)]
fun close_rejects_a_different_vault_before_deadline() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.close_against_wrong_vault(id);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_generation_rejects_settlement_before_vault_and_budget_checks() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.migrators_version.set_for_testing(2);
    f.settle(id, 31);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_generation_rejects_close_before_deadline_checks() {
    let mut f = start();
    let id = f.reserve_round(30);
    f.migrators_version.set_for_testing(2);
    f.close(id, ROUND_NOTICE_MS);
    f.end();
}

// Delayed publication

#[test]
fun a_round_publishes_exactly_when_the_default_notice_elapses() {
    let mut f = start();
    let root = f.leaf(0, 0, ALICE, 10, 300);
    assert_eq!(f.vault.round_publication_for_testing().delay_ms(), ROUND_NOTICE_MS);

    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, root, digest(), 1, 10, 300, 30, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    let scheduled = event::events_by_type<ActionScheduled<RoundPublicationKey, RoundTerms>>();
    assert_eq!(scheduled.length(), 1);
    let (owner, _, change, delay_ms, ready_at_ms) = scheduled[0].action_scheduled_fields();
    assert_eq!(owner, object::id(&f.vault));
    assert_eq!(change.action(), option::some(f.terms(0, 0, 10, root, 1, 10, 300, 30)));
    assert_eq!(delay_ms, ROUND_NOTICE_MS);
    assert_eq!(ready_at_ms, ROUND_NOTICE_MS);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME, FUNDED_QUOTE);
    assert_eq!(f.vault.next_round(), 0);

    f.scenario.next_tx(BOT);
    f.clock.set_for_testing(ROUND_NOTICE_MS);
    f.publish_scheduled();

    assert_eq!(event::events_by_type<ActionApplied<RoundPublicationKey, RoundTerms>>().length(), 1);
    assert_eq!(event::events_by_type<blast_events::RoundPublished>().length(), 1);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, FUNDED_QUOTE - 330);
    assert!(f.vault.round_publication_for_testing().pending().is_none());
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_round_cannot_publish_one_millisecond_before_the_default_notice_elapses() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.scenario.next_tx(BOT);
    f.clock.set_for_testing(ROUND_NOTICE_MS - 1);
    f.publish_scheduled();

    f.end();
}

#[test]
fun anyone_publishes_a_ready_round_in_a_later_transaction() {
    let mut f = start();
    let root = f.leaf(0, 0, ALICE, 10, 20);
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, root, digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.scenario.next_tx(BOT);
    f.publish_after_notice();
    let round_id = published_round_id();

    f.claim(round_id, 0, ALICE, 10, 20, vector[]);
    f.assert_received(ALICE, 10, 20);
    f.end();
}

#[test]
fun a_late_publication_still_opens_the_full_claim_window() {
    let mut f = start();
    let root = f.leaf(0, 0, ALICE, 10, 20);
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, root, digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.scenario.next_tx(BOT);
    f.clock.set_for_testing(LATE_AT_MS);
    f.publish_scheduled();
    let round_id = published_round_id();
    let published = event::events_by_type<blast_events::RoundPublished>();
    assert_eq!(
        bcs::to_bytes(&published[0]),
        bcs::to_bytes(
            &ExpectedRoundPublished {
                vault_id: object::id(&f.vault),
                round_id,
                number: 0,
                start_checkpoint: 0,
                end_checkpoint: 10,
                claim_deadline_at_ms: LATE_AT_MS + CLAIM_WINDOW_DURATION_MS,
                root,
                manifest_digest: digest(),
                leaf_count: 1,
                meme_amount: 10,
                quote_amount: 20,
                meme_unallocated: FUNDED_MEME - 10,
                quote_unallocated: FUNDED_QUOTE - 20,
                treasury: PUBLISHER,
                gas_reserve_amount: 0,
            },
        ),
    );

    f.clock.set_for_testing(LATE_AT_MS + CLAIM_WINDOW_DURATION_MS - 1);
    f.claim(round_id, 0, ALICE, 10, 20, vector[]);
    f.assert_received(ALICE, 10, 20);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EClaimDeadlineOverflow, location = blast_fun_migrators::blast_holder_rewards)]
fun a_claim_window_ending_beyond_u64_rejects_publication() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, 18_446_744_073_709_551_615, PUBLISHER);
    f.clock.set_for_testing(ROUND_NOTICE_MS);

    f.publish_scheduled();

    f.end();
}

#[test]
fun a_raised_notice_makes_publication_wait_until_ready() {
    let mut f = start();
    f.raise_notice(NOTICE_MS);
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.clock.set_for_testing(ROUND_NOTICE_MS + NOTICE_MS);
    f.publish_scheduled();

    assert_eq!(f.vault.next_round(), 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_raised_notice_rejects_publication_one_millisecond_early() {
    let mut f = start();
    f.raise_notice(NOTICE_MS);
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.clock.set_for_testing(ROUND_NOTICE_MS + NOTICE_MS - 1);
    f.publish_scheduled();

    f.end();
}

#[test]
fun a_cancelled_round_reserves_nothing_and_leaves_the_cursor() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 300, 30, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.cancel_round();

    let cancelled = event::events_by_type<ActionCancelled<RoundPublicationKey, RoundTerms>>();
    assert_eq!(cancelled.length(), 1);
    let (_, _, change, _, _) = cancelled[0].action_cancelled_fields();
    assert_eq!(change.action(), option::some(f.terms(0, 0, 10, digest(), 1, 10, 300, 30)));
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME, FUNDED_QUOTE);
    assert_eq!(f.vault.next_round(), 0);
    assert_eq!(f.vault.last_checkpoint(), option::none());
    assert!(f.vault.round_publication_for_testing().pending().is_none());
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun a_cancelled_round_cannot_be_published() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.cancel_round();

    f.publish_scheduled();

    f.end();
}

#[test]
fun rescheduling_replaces_the_pending_round_and_announces_its_cancellation() {
    let mut f = start();
    let replacement = f.leaf(0, 0, ALICE, 7, 9);
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 300, 30, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.schedule_reserved(0, 0, 10, replacement, digest(), 1, 7, 9, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    let cancelled = event::events_by_type<ActionCancelled<RoundPublicationKey, RoundTerms>>();
    assert_eq!(cancelled.length(), 1);
    let (_, _, change, _, _) = cancelled[0].action_cancelled_fields();
    assert_eq!(change.action(), option::some(f.terms(0, 0, 10, digest(), 1, 10, 300, 30)));
    f.publish_after_notice();
    let round_id = published_round_id();
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 7, FUNDED_QUOTE - 9);
    f.claim(round_id, 0, ALICE, 7, 9, vector[]);
    f.assert_received(ALICE, 7, 9);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_holder_rewards::EInsufficientBudget, location = blast_fun_migrators::blast_holder_rewards)]
fun publication_rechecks_the_budget_the_schedule_checked() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 300, 30, CLAIM_WINDOW_DURATION_MS, PUBLISHER);
    f.drain_rewards(0, FUNDED_QUOTE - 329);

    f.publish_after_notice();

    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EInvalidCommitment, location = blast_fun_migrators::vault)]
fun scheduling_checks_the_terms_before_the_vault() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);

    f.schedule_reserved(9, 0, 10, vector[], digest(), 1, FUNDED_MEME + 1, 0, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.end();
}

#[test]
fun a_shorter_notice_waits_the_applied_one() {
    let mut f = start();
    f.raise_notice(NOTICE_MS);
    f.scenario.next_tx(ADMIN);
    f.schedule_notice(0);

    f.clock.set_for_testing(ROUND_NOTICE_MS + NOTICE_MS);
    f.apply_notice();

    assert_eq!(f.vault.round_publication_for_testing().delay_ms(), 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_shorter_notice_cannot_apply_before_the_applied_one_elapses() {
    let mut f = start();
    f.raise_notice(NOTICE_MS);
    f.scenario.next_tx(ADMIN);
    f.schedule_notice(0);

    f.clock.set_for_testing(ROUND_NOTICE_MS + NOTICE_MS - 1);
    f.apply_notice();

    f.end();
}

#[test]
fun a_cancelled_notice_change_keeps_the_applied_notice() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_notice(NOTICE_MS);

    f.cancel_notice();

    assert_eq!(f.vault.round_publication_for_testing().delay_ms(), ROUND_NOTICE_MS);
    assert!(f.vault.round_publication_for_testing().pending().is_none());
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongRoundProposal, location = blast_fun_migrators::vault)]
fun a_round_cancellation_cannot_discard_a_notice_change() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_notice(NOTICE_MS);

    f.cancel_round();

    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongRoundProposal, location = blast_fun_migrators::vault)]
fun a_notice_cancellation_cannot_discard_a_scheduled_round() {
    let mut f = start();
    f.scenario.next_tx(ADMIN);
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.cancel_notice();

    f.end();
}

#[test]
fun signed_in_roles_schedule_cancel_and_change_the_notice() {
    let mut f = start();
    let (root, mut acl) = blast_acl::new_for_testing(f.scenario.ctx());
    acl.grant_admin(&root, ADMIN, f.scenario.ctx());
    acl.grant_admin(&root, BOB, f.scenario.ctx());
    f.scenario.next_tx(ADMIN);
    let rewards_cap = f.scenario.take_from_sender<AdminCap>();
    f.scenario.next_tx(BOB);
    let cancel_cap = f.scenario.take_from_sender<AdminCap>();
    acl.grant_role<RewardsAdmin>(&root, object::id(&rewards_cap));
    acl.grant_role<CancelAdmin>(&root, object::id(&cancel_cap));

    f.schedule_as(&acl.sign_in<RewardsAdmin>(&rewards_cap));
    f.cancel_round_as(&acl.sign_in<CancelAdmin>(&cancel_cap));
    f.schedule_notice_as(&acl.sign_in<RewardsAdmin>(&rewards_cap), NOTICE_MS);
    f.cancel_notice_as(&acl.sign_in<CancelAdmin>(&cancel_cap));

    assert!(f.vault.round_publication_for_testing().pending().is_none());
    destroy(rewards_cap);
    destroy(cancel_cap);
    destroy(root);
    destroy(acl);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_cancel_admin_cannot_sign_in_to_schedule_a_round() {
    let mut f = start();
    let (root, mut acl) = blast_acl::new_for_testing(f.scenario.ctx());
    acl.grant_admin(&root, BOB, f.scenario.ctx());
    f.scenario.next_tx(BOB);
    let cancel_cap = f.scenario.take_from_sender<AdminCap>();
    acl.grant_role<CancelAdmin>(&root, object::id(&cancel_cap));

    f.schedule_as(&acl.sign_in<RewardsAdmin>(&cancel_cap));

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_rewards_admin_cannot_sign_in_to_cancel_a_round() {
    let mut f = start();
    let (root, mut acl) = blast_acl::new_for_testing(f.scenario.ctx());
    acl.grant_admin(&root, ADMIN, f.scenario.ctx());
    f.scenario.next_tx(ADMIN);
    let rewards_cap = f.scenario.take_from_sender<AdminCap>();
    acl.grant_role<RewardsAdmin>(&root, object::id(&rewards_cap));
    f.schedule_reserved(0, 0, 10, digest(), digest(), 1, 10, 20, 0, CLAIM_WINDOW_DURATION_MS, PUBLISHER);

    f.cancel_round_as(&acl.sign_in<CancelAdmin>(&rewards_cap));

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_publication_before_taking_the_round() {
    let mut f = start();
    f.migrators_version.set_for_testing(2);

    f.publish_scheduled();

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_round_cancellation_first() {
    let mut f = start();
    f.migrators_version.set_for_testing(2);

    f.cancel_round();

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_notice_scheduling_first() {
    let mut f = start();
    f.migrators_version.set_for_testing(2);

    f.schedule_notice(0);

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_notice_application_first() {
    let mut f = start();
    f.migrators_version.set_for_testing(2);

    f.apply_notice();

    f.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_notice_cancellation_first() {
    let mut f = start();
    f.migrators_version.set_for_testing(2);

    f.cancel_notice();

    f.end();
}

// === Test Helpers ===

fun assert_reimbursement(reimbursement: u64) {
    let mut f = start();
    let round_id = f.reserve_round(30);
    f.assert_reserve(round_id, option::some(30));
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, FUNDED_QUOTE - 330);
    f.claim(round_id, 0, ALICE, 10, 300, vector[]);
    f.assert_reserve(round_id, option::some(30));
    f.settle(round_id, reimbursement);
    let events = event::events_by_type<blast_events::GasReserveSettled>();
    assert_eq!(events.length(), 1);
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&ExpectedGasReserveSettled {
        vault_id: object::id(&f.vault), round_id, number: 0,
        treasury: PUBLISHER, reimbursement_amount: reimbursement,
        reserve_returned: 30 - reimbursement,
        quote_unallocated: FUNDED_QUOTE - 300 - reimbursement,
    }));
    f.assert_reserve(round_id, option::none());
    f.assert_received(PUBLISHER, 0, reimbursement);
    f.assert_received(ALICE, 10, 300);
    f.close(round_id, DEADLINE_AT_MS);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, FUNDED_QUOTE - 300 - reimbursement);
    f.end();
}

/// Opens an owned launch whose whole fee split funds rewards, attaches its vault, and splits one
/// collection into the rewards balance under the zero default Blast share.
fun start(): RewardsFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_zero_fees_for_testing(scenario.ctx());
    let mut config = launch_config::new_zero_fees_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    config.admit<QUOTE, TestVenue>(&version, scenario.ctx());
    let (launch, mut currency) = scenario.open_launch<_, QUOTE, _>(
        test_utils::create_one_time_witness<BLAST_HOLDER_REWARDS_TESTS>(),
        &version,
        &config,
        TestVenue(),
        allocation::fee_split(bps::new(0), bps::new(0), bps::new(10_000), bps::new(0), vector[]),
        false,
    );
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let mut vault = vault::new_for_testing(
        &launch,
        &TestVenue(),
        object::id_from_address(POOL),
        position,
        1,
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );
    vault.split_fees(
        &policy,
        &mut currency,
        balance::create_for_testing(FUNDED_MEME),
        balance::create_for_testing(FUNDED_QUOTE),
        scenario.ctx(),
    );
    destroy(launch);
    destroy(currency);
    destroy(config);
    destroy(version);
    let clock = clock::create_for_testing(scenario.ctx());

    RewardsFixture { scenario, migrators_version, policy, clock, vault }
}

/// The leaf the fixture vault commits for one allocation.
fun leaf(
    self: &RewardsFixture,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    merkle::leaf(object::id(&self.vault), round, index, beneficiary, meme, quote)
}

/// Publishes as the rewards admin in the current transaction.
fun publish(
    self: &mut RewardsFixture,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
) {
    let treasury = self.policy.protocol_destination();
    self.publish_reserved(number, start_checkpoint, end_checkpoint, root, manifest_digest, leaf_count,
        meme_amount, quote_amount, 0, CLAIM_WINDOW_DURATION_MS, treasury);
}

/// Schedules with explicit reserve, claim window and treasury commitment, then publishes once the
/// applied notice elapses.
fun publish_reserved(
    self: &mut RewardsFixture,
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
) {
    self.schedule_reserved(
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
    self.publish_after_notice();
}

/// Schedules a round as the rewards admin in the current transaction.
fun schedule_reserved(
    self: &mut RewardsFixture,
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
) {
    self.vault.schedule_round(
        &self.migrators_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
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
        &self.clock,
    );
}

/// Publishes the scheduled round permissionlessly in the current transaction.
fun publish_scheduled(self: &mut RewardsFixture) {
    self.vault.publish_round(&self.migrators_version, &self.policy, &self.clock, self.scenario.ctx());
}

/// Advances the clock by the applied notice, then publishes the round scheduled at the current
/// time.
fun publish_after_notice(self: &mut RewardsFixture) {
    let delay_ms = self.vault.round_publication_for_testing().delay_ms();
    self.clock.increment_for_testing(delay_ms);
    self.publish_scheduled();
}

/// Schedules the default one-leaf round under `admin`.
fun schedule_as(self: &mut RewardsFixture, admin: &AdminWitness<RewardsAdmin>) {
    self.vault.schedule_round(
        &self.migrators_version,
        admin,
        0,
        0,
        10,
        digest(),
        digest(),
        1,
        10,
        20,
        0,
        CLAIM_WINDOW_DURATION_MS,
        PUBLISHER,
        &self.clock,
    );
}

/// Cancels the scheduled round as the cancel admin.
fun cancel_round(self: &mut RewardsFixture) {
    self.cancel_round_as(&blast_acl::witness_for_testing<CancelAdmin>());
}

/// Cancels the scheduled round under `admin`.
fun cancel_round_as(self: &mut RewardsFixture, admin: &AdminWitness<CancelAdmin>) {
    self.vault.cancel_round(&self.migrators_version, admin);
}

/// Schedules a new round notice as the rewards admin.
fun schedule_notice(self: &mut RewardsFixture, delay_ms: u64) {
    self.schedule_notice_as(&blast_acl::witness_for_testing<RewardsAdmin>(), delay_ms);
}

/// Schedules a new round notice under `admin`.
fun schedule_notice_as(self: &mut RewardsFixture, admin: &AdminWitness<RewardsAdmin>, delay_ms: u64) {
    self.vault.schedule_round_delay(&self.migrators_version, admin, delay_ms, &self.clock);
}

/// Applies the ready round-notice change.
fun apply_notice(self: &mut RewardsFixture) {
    self.vault.apply_round_delay(&self.migrators_version, &self.clock);
}

/// Cancels the pending round-notice change as the cancel admin.
fun cancel_notice(self: &mut RewardsFixture) {
    self.cancel_notice_as(&blast_acl::witness_for_testing<CancelAdmin>());
}

/// Cancels the pending round-notice change under `admin`.
fun cancel_notice_as(self: &mut RewardsFixture, admin: &AdminWitness<CancelAdmin>) {
    self.vault.cancel_round_delay(&self.migrators_version, admin);
}

/// Raises the round notice from the default, which applies once the default elapses.
fun raise_notice(self: &mut RewardsFixture, delay_ms: u64) {
    self.scenario.next_tx(ADMIN);
    self.schedule_notice(delay_ms);
    self.clock.set_for_testing(ROUND_NOTICE_MS);
    self.apply_notice();
    assert_eq!(self.vault.round_publication_for_testing().delay_ms(), delay_ms);
}

/// Burns unreserved rewards so the budget shrinks between scheduling and publication.
fun drain_rewards(self: &mut RewardsFixture, meme_amount: u64, quote_amount: u64) {
    let (meme, quote) = self.vault.withdraw_rewards_for_testing(meme_amount, quote_amount);
    destroy(meme);
    destroy(quote);
}

/// The terms the fixture's helpers schedule with the default manifest, window and treasury.
fun terms(
    _self: &RewardsFixture,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
): RoundTerms {
    vault::new_round_terms(
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        digest(),
        leaf_count,
        meme_amount,
        quote_amount,
        gas_reserve_amount,
        CLAIM_WINDOW_DURATION_MS,
        PUBLISHER,
    )
}

/// Publishes round `number` over checkpoints [10 * number, 10 * (number + 1)) with a single leaf
/// paying Alice, and returns its ID.
fun round(self: &mut RewardsFixture, number: u64, meme: u64, quote: u64): ID {
    let root = self.leaf(number, 0, ALICE, meme, quote);
    self.scenario.next_tx(ADMIN);
    self.publish(number, number * 10, (number + 1) * 10, root, digest(), 1, meme, quote);

    published_round_id()
}

/// Publishes one holder allocation with independent gas custody.
fun reserve_round(self: &mut RewardsFixture, gas: u64): ID {
    let root = self.leaf(0, 0, ALICE, 10, 300);
    self.scenario.next_tx(ADMIN);
    let treasury = self.policy.protocol_destination();
    self.publish_reserved(0, 0, 10, root, digest(), 1, 10, 300, gas, CLAIM_WINDOW_DURATION_MS, treasury);
    let id = published_round_id();
    let events = event::events_by_type<blast_events::RoundPublished>();
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&ExpectedRoundPublished {
        vault_id: object::id(&self.vault), round_id: id, number: 0,
        start_checkpoint: 0, end_checkpoint: 10, claim_deadline_at_ms: DEADLINE_AT_MS,
        root, manifest_digest: digest(), leaf_count: 1, meme_amount: 10, quote_amount: 300,
        meme_unallocated: FUNDED_MEME - 10, quote_unallocated: FUNDED_QUOTE - 300 - gas,
        treasury, gas_reserve_amount: gas,
    }));
    id
}

fun settle(self: &mut RewardsFixture, round_id: ID, reimbursement: u64) {
    self.scenario.next_tx(ADMIN);
    let mut round = self.take_round(round_id);
    round.settle_gas_reserve(&self.migrators_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(), &mut self.vault,
        reimbursement, self.scenario.ctx());
    test_scenario::return_shared(round);
}

fun close(self: &mut RewardsFixture, round_id: ID, now_at_ms: u64) {
    self.scenario.next_tx(BOT);
    self.clock.set_for_testing(now_at_ms);
    let round = self.take_round(round_id);
    round.close_round(&self.migrators_version, &mut self.vault, &self.clock);
}

fun assert_reserve(self: &mut RewardsFixture, round_id: ID, expected: Option<u64>) {
    self.scenario.next_tx(BOT);
    let round = self.take_round(round_id);
    assert_eq!(round.gas_reserve_for_testing(), expected);
    test_scenario::return_shared(round);
}

fun change_treasury(self: &mut RewardsFixture, destination: address) {
    self.policy.set_protocol_destination_for_testing(&self.migrators_version,
        &blast_acl::witness_for_testing<blast_fun::blast_fun_domain::TreasuryAdmin>(),
        destination, self.scenario.ctx());
}

fun settle_against_wrong_vault(self: &mut RewardsFixture, round_id: ID) {
    let mut other = self.other_vault();
    self.scenario.next_tx(ADMIN);
    let mut round = self.take_round(round_id);
    round.settle_gas_reserve(&self.migrators_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(), &mut other, 31, self.scenario.ctx());
    destroy(round);
    destroy(other);
}

fun close_against_wrong_vault(self: &mut RewardsFixture, round_id: ID) {
    let mut other = self.other_vault();
    self.scenario.next_tx(BOT);
    let round = self.take_round(round_id);
    round.close_round(&self.migrators_version, &mut other, &self.clock);
    destroy(other);
}

/// Builds a distinct, unfunded vault in this scenario for identity rejection.
fun other_vault(self: &mut RewardsFixture): LpVault<BLAST_HOLDER_REWARDS_TESTS, QUOTE> {
    let version = package_version::new_for_testing(self.scenario.ctx());
    let mut config = launch_config::new_zero_fees_for_testing(self.scenario.ctx());
    config.admit<QUOTE, TestVenue>(&version, self.scenario.ctx());
    let (launch, currency) = self.scenario.open_launch<_, QUOTE, _>(
        test_utils::create_one_time_witness<BLAST_HOLDER_REWARDS_TESTS>(), &version,
        &config, TestVenue(),
        allocation::fee_split(bps::new(0), bps::new(0), bps::new(10_000), bps::new(0), vector[]), false,
    );
    let position = TestPosition { id: object::new(self.scenario.ctx()) };
    let vault = vault::new_for_testing(&launch, &TestVenue(), object::id_from_address(POOL),
        position, 1, balance::zero(), balance::zero(), self.scenario.ctx());
    destroy(launch);
    destroy(currency);
    destroy(config);
    destroy(version);
    vault
}

/// Returns the ID of the one round this transaction published.
fun published_round_id(): ID {
    let published = event::events_by_type<blast_events::RoundPublished>();
    assert_eq!(published.length(), 1);

    round_id_of(published[0])
}

/// Relays one claim from the bot in a fresh transaction.
fun claim(
    self: &mut RewardsFixture,
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
) {
    self.scenario.next_tx(BOT);
    let mut round = self.take_round(round_id);

    round.claim(
        &self.migrators_version,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        proof,
        &self.clock,
        self.scenario.ctx(),
    );
    test_scenario::return_shared(round);
}

fun take_round(self: &RewardsFixture, round_id: ID): Round<BLAST_HOLDER_REWARDS_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(round_id)
}

/// Asserts a round's remaining balances and whether leaf `index` is paid, in a fresh transaction.
fun assert_round(
    self: &mut RewardsFixture,
    round_id: ID,
    meme: u64,
    quote: u64,
    index: u64,
    claimed: bool,
) {
    self.scenario.next_tx(BOT);
    let round = self.take_round(round_id);

    assert_balances!(|| round.round_balances_for_testing(), meme, quote);
    assert_eq!(round.is_claimed_for_testing(index), claimed);
    test_scenario::return_shared(round);
}

/// Asserts `owner` received exactly one coin per nonzero asset since its last check.
fun assert_received(self: &mut RewardsFixture, owner: address, meme: u64, quote: u64) {
    self.scenario.next_tx(owner);
    if (meme > 0) {
        let coin = self.scenario.take_from_sender<Coin<BLAST_HOLDER_REWARDS_TESTS>>();
        assert_eq!(coin.burn_for_testing(), meme);
    };
    if (quote > 0) {
        assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    };
    assert!(!self.scenario.has_most_recent_for_sender<Coin<BLAST_HOLDER_REWARDS_TESTS>>());
    assert!(!self.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
}

/// Asserts the Meme and Quote amounts `$balances` reads.
macro fun assert_balances($balances: || -> (u64, u64), $meme: u64, $quote: u64) {
    let (meme_balance, quote_balance) = $balances();

    assert_eq!(meme_balance, $meme);
    assert_eq!(quote_balance, $quote);
}

/// Reads the round ID, the second field of `RoundPublished`.
fun round_id_of(published: blast_events::RoundPublished): ID {
    let mut r = bcs::new(bcs::to_bytes(&published));
    r.peel_address();

    object::id_from_address(r.peel_address())
}

/// A well-formed 32-byte commitment.
fun digest(): vector<u8> {
    vector::tabulate!(32, |_| 1u8)
}

fun end(self: RewardsFixture) {
    destroy(self);
}

// === Constants ===

const PUBLISHER: address = @0xB1A57;

const ADMIN: address = @0xAD;

const ALICE: address = @0xA;

const BOB: address = @0xB0B;

const BOT: address = @0xB07;

const POOL: address = @0x9001;

/// Rewards the fixture vault holds before any round.
const FUNDED_MEME: u64 = 1_000;

/// The round notice every vault starts with.
const ROUND_NOTICE_MS: u64 = 7_200_000;

/// The claim window every helper schedules; it outlasts the notice, so earlier rounds stay
/// claimable while later ones publish.
const CLAIM_WINDOW_DURATION_MS: u64 = 86_400_000;

/// The claim deadline of a round scheduled at time zero and published once the default notice
/// elapses.
const DEADLINE_AT_MS: u64 = 93_600_000;

/// A raised round notice.
const NOTICE_MS: u64 = 10_800_000;

/// A publication time well after the default notice elapses.
const LATE_AT_MS: u64 = 50_000_000;

const FUNDED_QUOTE: u64 = 2_000;

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminCap, AdminWitness},
    delayed_action::{ActionApplied, ActionCancelled, ActionScheduled},
};

use blast_fun::{
    allocation,
    blast_fun_domain::{CancelAdmin, RewardsAdmin},
    bps,
    launch_config,
    blast_fun::{Self as package_version},
};

use blast_fun_migrators::{
    blast_events,
    blast_holder_rewards::{Self, Round},
    launch_fixture,
    lp_fee_policy::{Self, LpFeePolicy},
    merkle,
    blast_fun_migrators::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault, RoundPublicationKey, RoundTerms},
};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, bcs, clock::{Self, Clock}, coin::Coin, event, test_scenario::{Self, Scenario}, test_utils};

use fun blast_holder_rewards::apply_round_delay as LpVault.apply_round_delay;
use fun blast_holder_rewards::cancel_round as LpVault.cancel_round;
use fun blast_holder_rewards::cancel_round_delay as LpVault.cancel_round_delay;
use fun blast_holder_rewards::publish_round as LpVault.publish_round;
use fun blast_holder_rewards::schedule_round as LpVault.schedule_round;
use fun blast_holder_rewards::schedule_round_delay as LpVault.schedule_round_delay;

use fun launch_fixture::admit as blast_fun::launch_config::LaunchConfig.admit;

use fun launch_fixture::open_launch as Scenario.open_launch;
