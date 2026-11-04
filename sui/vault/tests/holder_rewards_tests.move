// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_vault::holder_rewards_tests;

// === Constants ===

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const RELAYER: address = @0x4E1A;
const ROUND_NOTICE_MS: u64 = 2 * 60 * 60 * 1_000;
const CLAIM_WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const MANIFEST: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000001";

// === Tests ===

// Publication and claims

#[test]
fun a_published_round_pays_each_leaf_once_and_returns_the_rest_at_close() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 1_000, 1_000);
    let vault_id = object::id(&vault);
    let (alice, bob) = (leaf(vault_id, 0, 0, ALICE, 100, 10), leaf(vault_id, 0, 1, BOB, 50, 5));
    schedule(&mut vault, &f, 0, 0, 100, merkle::node(alice, bob), 2, 150, 20, 1);
    let mut f = publish_after_notice(&mut scenario, f, &mut vault);

    let (unreserved_meme, unreserved_quote) = vault.rewards_balances();
    assert_eq!(vector[unreserved_meme, unreserved_quote], vector[850, 979]);
    scenario.next_tx(RELAYER);
    let mut round = take_round(&scenario);
    round.claim(f.version(), 0, ALICE, 100, 10, vector[bob], f.clock(), scenario.ctx());
    assert!(round.is_claimed_for_testing(0) && !round.is_claimed_for_testing(1));
    let (round_meme, round_quote, gas_reserve) = round.round_balances_for_testing();
    assert_eq!(vector[round_meme, round_quote], vector[50, 10]);
    assert_eq!(gas_reserve, option::some(1));
    assert_eq!(event::events_by_type<RewardClaimed<VAULT_FIXTURE, QUOTE>>().length(), 1);
    scenario.next_tx(RELAYER);
    assert_eq!(vault_fixture::take_coin_value<VAULT_FIXTURE>(&scenario, ALICE), 100);
    assert_eq!(vault_fixture::take_coin_value<QUOTE>(&scenario, ALICE), 10);

    f.clock_mut().increment_for_testing(CLAIM_WINDOW_MS);
    round.close_round(f.version(), &mut vault, f.clock());

    let (unreserved_meme, unreserved_quote) = vault.rewards_balances();
    assert_eq!(vector[unreserved_meme, unreserved_quote], vector[900, 990]);
    assert_eq!(vault.next_round(), 1);
    assert_eq!(event::events_by_type<RoundClosed<VAULT_FIXTURE, QUOTE>>().length(), 1);
    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
fun publication_announces_the_round_once() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS);

    holder_rewards::publish_round(&mut vault, f.version(), f.treasury(), f.clock(), scenario.ctx());

    assert_eq!(event::events_by_type<RoundPublished<VAULT_FIXTURE, QUOTE>>().length(), 1);
    finish_vault(scenario, f, vault);
}

#[test]
fun a_single_leaf_round_verifies_with_an_empty_proof() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    let alice = leaf(object::id(&vault), 0, 0, ALICE, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, alice, 1, 100, 0, 0);
    let f = publish_after_notice(&mut scenario, f, &mut vault);

    let mut round = take_round(&scenario);
    round.claim(f.version(), 0, ALICE, 100, 0, vector[], f.clock(), scenario.ctx());

    let (round_meme, round_quote, gas_reserve) = round.round_balances_for_testing();
    assert_eq!(vector[round_meme, round_quote], vector[0, 0]);
    assert!(gas_reserve.is_none());
    finish(scenario, f, vault, round);
}

#[test]
fun claims_continue_while_the_package_is_paused() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    let alice = leaf(object::id(&vault), 0, 0, ALICE, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, alice, 1, 100, 0, 0);
    let mut f = publish_after_notice(&mut scenario, f, &mut vault);
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    let mut round = take_round(&scenario);
    round.claim(f.version(), 0, ALICE, 100, 0, vector[], f.clock(), scenario.ctx());

    assert!(round.is_claimed_for_testing(0));
    finish(scenario, f, vault, round);
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EAlreadyClaimed, location = blast_vault::holder_rewards)]
fun a_leaf_cannot_be_claimed_twice() {
    let (mut scenario, f, vault, mut round, bob) = two_leaf_round();

    round.claim(f.version(), 0, ALICE, 100, 10, vector[bob], f.clock(), scenario.ctx());
    round.claim(f.version(), 0, ALICE, 100, 10, vector[bob], f.clock(), scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInvalidProof, location = blast_vault::holder_rewards)]
fun a_claim_for_more_than_its_leaf_is_rejected() {
    let (mut scenario, f, vault, mut round, bob) = two_leaf_round();

    round.claim(f.version(), 0, ALICE, 101, 10, vector[bob], f.clock(), scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInvalidProof, location = blast_vault::holder_rewards)]
fun a_claim_for_another_beneficiary_is_rejected() {
    let (mut scenario, f, vault, mut round, bob) = two_leaf_round();

    round.claim(f.version(), 0, RELAYER, 100, 10, vector[bob], f.clock(), scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInvalidIndex, location = blast_vault::holder_rewards)]
fun a_claim_past_the_last_leaf_is_rejected() {
    let (mut scenario, f, vault, mut round, bob) = two_leaf_round();

    round.claim(f.version(), 2, ALICE, 100, 10, vector[bob], f.clock(), scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInvalidBeneficiary, location = blast_vault::holder_rewards)]
fun a_claim_to_the_zero_address_is_rejected() {
    let (mut scenario, f, vault, mut round, bob) = two_leaf_round();

    round.claim(f.version(), 0, @0x0, 100, 10, vector[bob], f.clock(), scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EEmptyClaim, location = blast_vault::holder_rewards)]
fun an_empty_claim_is_rejected() {
    let (mut scenario, f, vault, mut round, bob) = two_leaf_round();

    round.claim(f.version(), 0, ALICE, 0, 0, vector[bob], f.clock(), scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EClaimsClosed, location = blast_vault::holder_rewards)]
fun claims_close_at_the_deadline() {
    let (mut scenario, mut f, vault, mut round, bob) = two_leaf_round();
    f.clock_mut().increment_for_testing(CLAIM_WINDOW_MS);

    round.claim(f.version(), 0, ALICE, 100, 10, vector[bob], f.clock(), scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EClaimsStillOpen, location = blast_vault::holder_rewards)]
fun a_round_cannot_close_before_its_deadline() {
    let (scenario, mut f, mut vault, round, _) = two_leaf_round();
    f.clock_mut().increment_for_testing(CLAIM_WINDOW_MS - 1);

    round.close_round(f.version(), &mut vault, f.clock());

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVault, location = blast_vault::holder_rewards)]
fun a_round_cannot_close_into_another_vault() {
    let (mut scenario, mut f, vault, round, _) = two_leaf_round();
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    let mut other = f.new_vault(terms, scenario.ctx());
    f.clock_mut().increment_for_testing(CLAIM_WINDOW_MS);

    round.close_round(f.version(), &mut other, f.clock());

    destroy(other);
    abort_with_vault(scenario, f, vault)
}

// Gas reserve

#[test]
fun settling_the_gas_reserve_pays_the_treasury_and_returns_the_rest_at_once() {
    let (mut scenario, f, mut vault, mut round, _) = two_leaf_round();

    round.settle_gas_reserve(&rewards_admin(), f.version(), &mut vault, 1, scenario.ctx());

    let (_, _, gas_reserve) = round.round_balances_for_testing();
    assert!(gas_reserve.is_none());
    let (_, unreserved_quote) = vault.rewards_balances();
    assert_eq!(unreserved_quote, 979);
    assert_eq!(event::events_by_type<GasReserveSettled<VAULT_FIXTURE, QUOTE>>().length(), 1);
    scenario.next_tx(RELAYER);
    assert_eq!(
        vault_fixture::take_coin_value<QUOTE>(&scenario, vault_fixture::treasury_address()),
        1,
    );
    finish(scenario, f, vault, round);
}

#[test]
fun an_unsettled_gas_reserve_returns_at_close() {
    let (scenario, mut f, mut vault, round, _) = two_leaf_round();
    f.clock_mut().increment_for_testing(CLAIM_WINDOW_MS);

    round.close_round(f.version(), &mut vault, f.clock());

    let (unreserved_meme, unreserved_quote) = vault.rewards_balances();
    assert_eq!(vector[unreserved_meme, unreserved_quote], vector[1_000, 1_000]);
    finish_vault(scenario, f, vault);
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EReserveSettled, location = blast_vault::holder_rewards)]
fun the_gas_reserve_settles_once() {
    let (mut scenario, f, mut vault, mut round, _) = two_leaf_round();
    round.settle_gas_reserve(&rewards_admin(), f.version(), &mut vault, 0, scenario.ctx());

    round.settle_gas_reserve(&rewards_admin(), f.version(), &mut vault, 0, scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EOverReserve, location = blast_vault::holder_rewards)]
fun a_reimbursement_above_the_reserve_is_rejected() {
    let (mut scenario, f, mut vault, mut round, _) = two_leaf_round();

    round.settle_gas_reserve(&rewards_admin(), f.version(), &mut vault, 2, scenario.ctx());

    abort_with(scenario, f, vault, round)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVault, location = blast_vault::holder_rewards)]
fun the_gas_reserve_cannot_settle_into_another_vault() {
    let (mut scenario, f, vault, mut round, _) = two_leaf_round();
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    let mut other = f.new_vault(terms, scenario.ctx());

    round.settle_gas_reserve(&rewards_admin(), f.version(), &mut other, 1, scenario.ctx());

    destroy(other);
    abort_with(scenario, f, vault, round)
}

// Scheduling against the vault

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongRound, location = blast_vault::holder_rewards)]
fun a_round_must_carry_the_next_number() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 100);

    schedule(&mut vault, &f, 1, 0, 100, root(), 1, 100, 0, 0);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EOverlappingInterval, location = blast_vault::holder_rewards)]
fun a_round_cannot_start_before_the_previous_one_ended() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 200, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    let f = publish_after_notice(&mut scenario, f, &mut vault);

    schedule(&mut vault, &f, 1, 99, 200, root(), 1, 100, 0, 0);

    abort_with_vault(scenario, f, vault)
}

#[test]
fun a_round_may_start_where_the_previous_one_ended() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 200, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    let f = publish_after_notice(&mut scenario, f, &mut vault);

    schedule(&mut vault, &f, 1, 100, 200, root(), 1, 100, 0, 0);
    let f = publish_after_notice(&mut scenario, f, &mut vault);

    assert_eq!(vault.next_round(), 2);
    finish_vault(scenario, f, vault);
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInsufficientBudget, location = blast_vault::holder_rewards)]
fun a_round_cannot_schedule_beyond_the_unreserved_rewards() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 100);

    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 100, 1);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInsufficientBudget, location = blast_vault::holder_rewards)]
fun a_round_cannot_publish_beyond_the_rewards_left_at_publication() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    let (meme, quote) = vault.withdraw_rewards_for_testing(1, 0);
    destroy(meme);
    destroy(quote);
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS);

    holder_rewards::publish_round(&mut vault, f.version(), f.treasury(), f.clock(), scenario.ctx());

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::ETreasuryChanged, location = blast_vault::holder_rewards)]
fun a_round_cannot_publish_after_the_treasury_changed() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    f.change_treasury(RELAYER);

    holder_rewards::publish_round(&mut vault, f.version(), f.treasury(), f.clock(), scenario.ctx());

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_round_cannot_publish_before_its_notice() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS - 1);

    holder_rewards::publish_round(&mut vault, f.version(), f.treasury(), f.clock(), scenario.ctx());

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EClaimDeadlineOverflow, location = blast_vault::holder_rewards)]
fun a_claim_window_past_the_end_of_time_is_rejected_at_publication() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    schedule_with_window(&mut vault, &f, 100, std::u64::max_value!() - ROUND_NOTICE_MS + 1);
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS);

    holder_rewards::publish_round(&mut vault, f.version(), f.treasury(), f.clock(), scenario.ctx());

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun the_admin_pause_stops_round_scheduling() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);

    abort_with_vault(scenario, f, vault)
}

// Cancellation and notice changes

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun a_cancelled_round_cannot_publish() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    holder_rewards::cancel_round(&mut vault, &cancel_admin(), f.version());
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS);

    holder_rewards::publish_round(&mut vault, f.version(), f.treasury(), f.clock(), scenario.ctx());

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongRoundProposal, location = blast_vault::vault)]
fun cancelling_a_round_cannot_discard_a_notice_change() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    holder_rewards::schedule_round_delay(&mut vault, &rewards_admin(), f.version(), 1, f.clock());

    holder_rewards::cancel_round(&mut vault, &cancel_admin(), f.version());

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongRoundProposal, location = blast_vault::vault)]
fun cancelling_a_notice_change_cannot_discard_a_round() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);

    holder_rewards::cancel_round_delay(&mut vault, &cancel_admin(), f.version());

    abort_with_vault(scenario, f, vault)
}

#[test]
fun a_round_notice_change_applies_after_the_current_notice() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    holder_rewards::schedule_round_delay(&mut vault, &rewards_admin(), f.version(), 1, f.clock());
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS);
    holder_rewards::apply_round_delay(&mut vault, f.version(), f.clock());

    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 100, 0, 0);
    f.clock_mut().increment_for_testing(1);
    holder_rewards::publish_round(&mut vault, f.version(), f.treasury(), f.clock(), scenario.ctx());

    assert_eq!(vault.round_publication_for_testing().delay_ms(), 1);
    assert_eq!(vault.next_round(), 1);
    finish_vault(scenario, f, vault);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun a_cancelled_notice_change_cannot_apply() {
    let mut scenario = vault_fixture::begin();
    let (mut f, mut vault) = start_with_rewards(&mut scenario, 100, 0);
    holder_rewards::schedule_round_delay(&mut vault, &rewards_admin(), f.version(), 1, f.clock());
    holder_rewards::cancel_round_delay(&mut vault, &cancel_admin(), f.version());
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS);

    holder_rewards::apply_round_delay(&mut vault, f.version(), f.clock());

    abort_with_vault(scenario, f, vault)
}

// Static round terms

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInvalidCommitment, location = blast_vault::vault)]
fun a_root_of_the_wrong_length_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    schedule(&mut vault, &f, 0, 0, 100, x"00", 1, 100, 0, 0);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInvalidLeafCount, location = blast_vault::vault)]
fun a_round_without_leaves_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    schedule(&mut vault, &f, 0, 0, 100, root(), 0, 100, 0, 0);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EInvalidLeafCount, location = blast_vault::vault)]
fun a_round_above_the_leaf_maximum_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    schedule(&mut vault, &f, 0, 0, 100, root(), 65_537, 100, 0, 0);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EEmptyBudget, location = blast_vault::vault)]
fun a_round_without_a_budget_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 0, 0, 0);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EEmptyInterval, location = blast_vault::vault)]
fun a_round_over_an_empty_interval_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    schedule(&mut vault, &f, 0, 100, 100, root(), 1, 100, 0, 0);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EBudgetOverflow, location = blast_vault::vault)]
fun a_quote_budget_and_reserve_that_overflow_are_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 0, std::u64::max_value!(), 1);

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EGasReserveTooLarge, location = blast_vault::vault)]
fun a_gas_reserve_above_ten_percent_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 0, 1_000);

    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 0, 100, 11);

    abort_with_vault(scenario, f, vault)
}

#[test]
fun a_gas_reserve_of_exactly_ten_percent_schedules() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 0, 1_000);

    schedule(&mut vault, &f, 0, 0, 100, root(), 1, 0, 100, 10);

    assert!(vault.round_publication_for_testing().pending().is_some());
    finish_vault(scenario, f, vault);
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EZeroTreasury, location = blast_vault::vault)]
fun a_round_expecting_the_zero_treasury_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    holder_rewards::schedule_round(
        &mut vault,
        &rewards_admin(),
        f.version(),
        0,
        0,
        100,
        root(),
        MANIFEST,
        1,
        100,
        0,
        0,
        CLAIM_WINDOW_MS,
        @0x0,
        f.clock(),
    );

    abort_with_vault(scenario, f, vault)
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EZeroClaimWindow, location = blast_vault::vault)]
fun a_round_without_a_claim_window_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 100, 0);

    schedule_with_window(&mut vault, &f, 100, 0);

    abort_with_vault(scenario, f, vault)
}

// === Test Helpers ===

/// A fixture with an owner-only vault holding `meme` and `quote` of unreserved holder rewards.
fun start_with_rewards(
    scenario: &mut Scenario,
    meme: u64,
    quote: u64,
): (VaultFixture, Vault<VAULT_FIXTURE, QUOTE>) {
    let mut f = vault_fixture::start(scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(scenario);
    let rewards_meme = f.meme(meme);
    vault.fund_rewards_for_testing(rewards_meme, balance::create_for_testing(quote));

    (f, vault)
}

/// A published round 0 over two leaves, Alice's (100, 10) at index 0 and Bob's (50, 5) at index
/// 1, with a one-unit gas reserve; returns Bob's leaf, the proof for Alice's claim.
fun two_leaf_round(): (
    Scenario,
    VaultFixture,
    Vault<VAULT_FIXTURE, QUOTE>,
    Round<VAULT_FIXTURE, QUOTE>,
    vector<u8>,
) {
    let mut scenario = vault_fixture::begin();
    let (f, mut vault) = start_with_rewards(&mut scenario, 1_000, 1_000);
    let vault_id = object::id(&vault);
    let (alice, bob) = (leaf(vault_id, 0, 0, ALICE, 100, 10), leaf(vault_id, 0, 1, BOB, 50, 5));
    schedule(&mut vault, &f, 0, 0, 100, merkle::node(alice, bob), 2, 150, 20, 1);
    let f = publish_after_notice(&mut scenario, f, &mut vault);
    let round = take_round(&scenario);

    (scenario, f, vault, round, bob)
}

/// Schedules round terms with the fixture's treasury and the standard claim window.
fun schedule(
    vault: &mut Vault<VAULT_FIXTURE, QUOTE>,
    f: &VaultFixture,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
) {
    holder_rewards::schedule_round(
        vault,
        &rewards_admin(),
        f.version(),
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        MANIFEST,
        leaf_count,
        meme_amount,
        quote_amount,
        gas_reserve_amount,
        CLAIM_WINDOW_MS,
        vault_fixture::treasury_address(),
        f.clock(),
    );
}

/// Schedules round 0 for `meme_amount` with a claim window of `claim_window_duration_ms`.
fun schedule_with_window(
    vault: &mut Vault<VAULT_FIXTURE, QUOTE>,
    f: &VaultFixture,
    meme_amount: u64,
    claim_window_duration_ms: u64,
) {
    holder_rewards::schedule_round(
        vault,
        &rewards_admin(),
        f.version(),
        0,
        0,
        100,
        root(),
        MANIFEST,
        1,
        meme_amount,
        0,
        0,
        claim_window_duration_ms,
        vault_fixture::treasury_address(),
        f.clock(),
    );
}

/// Waits out the round notice, publishes the scheduled round, and moves to the next transaction.
fun publish_after_notice(
    scenario: &mut Scenario,
    mut f: VaultFixture,
    vault: &mut Vault<VAULT_FIXTURE, QUOTE>,
): VaultFixture {
    f.clock_mut().increment_for_testing(ROUND_NOTICE_MS);
    holder_rewards::publish_round(vault, f.version(), f.treasury(), f.clock(), scenario.ctx());
    scenario.next_tx(vault_fixture::sender());

    f
}

fun take_round(scenario: &Scenario): Round<VAULT_FIXTURE, QUOTE> {
    scenario.take_shared<Round<VAULT_FIXTURE, QUOTE>>()
}

fun leaf(
    vault_id: ID,
    round_number: u64,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
): vector<u8> {
    holder_rewards::reward_leaf_for_testing(
        vault_id,
        round_number,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
    )
}

/// A well-formed root for rounds whose claims a test never makes.
fun root(): vector<u8> {
    x"00000000000000000000000000000000000000000000000000000000000000ff"
}

fun finish(
    scenario: Scenario,
    f: VaultFixture,
    vault: Vault<VAULT_FIXTURE, QUOTE>,
    round: Round<VAULT_FIXTURE, QUOTE>,
) {
    test_scenario::return_shared(round);
    finish_vault(scenario, f, vault);
}

fun finish_vault(scenario: Scenario, f: VaultFixture, vault: Vault<VAULT_FIXTURE, QUOTE>) {
    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

/// Ends an expected-failure test that should have aborted before this point.
fun abort_with(
    _: Scenario,
    _: VaultFixture,
    _: Vault<VAULT_FIXTURE, QUOTE>,
    _: Round<VAULT_FIXTURE, QUOTE>,
) {
    abort
}

/// Ends an expected-failure test that should have aborted before this point.
fun abort_with_vault(_: Scenario, _: VaultFixture, _: Vault<VAULT_FIXTURE, QUOTE>) {
    abort
}

fun rewards_admin(): AdminWitness<RewardsAdmin> { blast_acl::witness_for_testing() }

fun cancel_admin(): AdminWitness<CancelAdmin> { blast_acl::witness_for_testing() }

fun pause_admin(): AdminWitness<PauseAdmin<BLAST_VAULT_PACKAGE>> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, package_admin::{Self, PauseAdmin}};

use blast_core::{blast_domain::{CancelAdmin, RewardsAdmin}, merkle};

use blast_vault::{
    blast_vault_events::{GasReserveSettled, RewardClaimed, RoundClosed, RoundPublished},
    blast_vault_package::BLAST_VAULT_PACKAGE,
    constants,
    holder_rewards::{Self, Round},
    vault::Vault,
    vault_fixture::{Self, QUOTE, VAULT_FIXTURE, VaultFixture, owner_split}
};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, event, test_scenario::{Self, Scenario}};
