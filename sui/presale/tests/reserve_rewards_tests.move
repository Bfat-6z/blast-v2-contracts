// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::reserve_rewards_tests;

// === Constants ===

const OWNER: address = @0xA;
const HOLDER: address = @0xB;
const TREASURY: address = @0xC;
/// The round notice every vault starts with.
const ROUND_NOTICE_MS: u64 = 7_200_000;
/// The claim window every helper schedules.
const CLAIM_WINDOW_DURATION_MS: u64 = 604_800_000;
/// The claim deadline of a round scheduled at the fixture's start time of 1 ms and published once
/// the default notice elapses.
const DEADLINE_AT_MS: u64 = 612_000_001;
/// A raised round notice.
const NOTICE_MS: u64 = 10_800_000;
/// A publication time well after the default notice elapses.
const LATE_AT_MS: u64 = 50_000_000;

// === Test-Only Types ===

public struct MEME has drop {}
public struct QUOTE has drop {}
public struct ReserveFixture {
    scenario: Scenario,
    vault: Vault<MEME, QUOTE>,
    policy: FeePolicy,
    clock: Clock,
}

// === Tests ===

#[test]
#[expected_failure(
    abort_code = rewards::ETreasuryChanged,
    location = blast_presale::holder_rewards,
)]
fun a_policy_change_after_planning_blocks_publication_with_gas_reimbursement() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination_for_testing(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
                f.scenario.ctx()
            );
    });
    fixture.publish(30);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = rewards::ETreasuryChanged,
    location = blast_presale::holder_rewards,
)]
fun a_policy_change_after_planning_blocks_publication_without_gas_reimbursement() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination_for_testing(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
                f.scenario.ctx()
            );
    });
    fixture.publish_budget(1_000, 0);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = rewards::ETreasuryChanged,
    location = blast_presale::holder_rewards,
)]
fun a_changed_treasury_is_rejected_before_an_overcommitted_budget() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.schedule_budget_to(970, 30, TREASURY);
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination_for_testing(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
                f.scenario.ctx()
            );
        f.drain_holder_rewards(1_000);
        f.publish_after_notice();
    });
    std::unit_test::destroy(package_version);
    abort
}

#[test]
fun publication_accepts_a_new_plan_bound_to_the_changed_treasury() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination_for_testing(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
             f.scenario.ctx());
    });
    fixture.publish_budget_to(970, 30, @0xD);
    assert_eq!(fixture.holder_quote(), 0);
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.holder_quote(), 1_000);
    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
fun settlement_pays_measured_cost_returns_unused_reserve_and_preserves_holder_custody() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    assert_eq!(fixture.holder_quote(), 0);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        let (meme, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(vector[meme, quote], vector[0, 970]);
        assert_eq!(reserve, option::some(30));
        f
            .policy
            .set_destination_for_testing(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
             f.scenario.ctx());
        f.settle(&mut round, 24);
        assert_eq!(f.holder_quote(), 6);
        let (_, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(quote, 970);
        assert_eq!(reserve, option::none());
        f.return_round(round);
    });
    fixture.next_tx!(TREASURY, |f| f.assert_payment(24));
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.assert_payment(970));
    fixture.next_tx!(OWNER, |f| f.close());
    assert_eq!(fixture.holder_quote(), 6);
    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
fun close_returns_unsettled_reserve_and_unclaimed_holders_without_an_admin() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.holder_quote(), 1_000);
    fixture.end();
}

#[test]
fun zero_reserve_disables_reimbursement_and_allows_claim_and_close() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(0);
    fixture.next_tx!(HOLDER, |f| {
        let round = f.take_round();
        let (_, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(quote, 970);
        assert_eq!(reserve, option::none());
        f.return_round(round);
    });
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.assert_payment(970));
    assert_eq!(fixture.holder_quote(), 30);
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.holder_quote(), 30);
    fixture.end();
}

#[test]
fun blast_can_cover_gas_and_fund_the_entire_holder_quote_budget() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish_budget(1_000, 0);
    assert_eq!(fixture.holder_quote(), 0);
    fixture.next_tx!(HOLDER, |f| {
        let mut round = f.take_round();
        rewards::claim(&mut round, &package_version, 0, HOLDER, 0, 1_000, vector[], &f.clock, f.ctx!());
        let (_, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(quote, 0);
        assert_eq!(reserve, option::none());
        f.return_round(round);
    });
    fixture.next_tx!(HOLDER, |f| f.assert_payment(1_000));
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.holder_quote(), 0);
    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(abort_code = rewards::EReserveSettled, location = blast_presale::holder_rewards)]
fun disabled_reimbursement_cannot_be_settled() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(0);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        f.settle(&mut round, 0);
        abort
    })
}

#[test]
#[expected_failure(abort_code = rewards::EOverReserve, location = blast_presale::holder_rewards)]
fun settlement_rejects_cost_above_the_reserve() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        f.settle(&mut round, 31);
        abort
    })
}

#[test]
#[expected_failure(abort_code = rewards::EReserveSettled, location = blast_presale::holder_rewards)]
fun duplicate_settlement_cannot_pay_twice() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        f.settle(&mut round, 24);
        f.settle(&mut round, 1);
        abort
    })
}

#[test]
#[expected_failure(
    abort_code = rewards::EInsufficientBudget,
    location = blast_presale::holder_rewards,
)]
fun publication_cannot_overcommit_holder_and_reserve_quote() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(31);
    abort
}

#[test]
#[expected_failure(
    abort_code = rewards::EInsufficientBudget,
    location = blast_presale::holder_rewards,
)]
fun holder_quote_cannot_exceed_the_vault_before_reserve_is_checked() {
    let mut fixture = start_reserve_rewards();

    fixture.publish_budget(1_001, 1);

    abort
}

#[test]
fun a_gas_reserve_of_a_tenth_of_the_holder_quote_is_accepted() {
    let mut fixture = start_reserve_rewards();
    fixture.publish_budget(900, 90);
    assert_eq!(fixture.holder_quote(), 10);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = vault::EGasReserveTooLarge, location = blast_presale::presale_vault)]
fun a_gas_reserve_one_unit_above_a_tenth_of_the_holder_quote_is_rejected() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_budget_to(900, 91, TREASURY);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EMemeRewardsUnsupported, location = blast_presale::presale_vault)]
/// A round that promises Meme is rejected before its empty Quote budget or its gas reserve.
fun a_meme_round_is_rejected_before_its_quote_budget_and_gas_reserve() {
    let mut fixture = start_reserve_rewards();
    let version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    let clock = clock::create_for_testing(fixture.ctx!());
    fixture.vault.schedule_round(
        &version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        0,
        0,
        10,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        1,
        0,
        1,
        CLAIM_WINDOW_DURATION_MS,
        TREASURY,
        &clock,
    );
    abort
}

#[test]
#[expected_failure(
    abort_code = rewards::EClaimsStillOpen,
    location = blast_presale::holder_rewards,
)]
fun close_rejects_the_millisecond_before_the_deadline() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let round = f.take_round();
        f.clock.set_for_testing(DEADLINE_AT_MS - 1);
        round.close_round(&package_version, &mut f.vault, &f.clock);
        abort
    })
}

#[test]
#[expected_failure(abort_code = rewards::EWrongVault, location = blast_presale::holder_rewards)]
fun settlement_rejects_another_vault_before_its_amount_check() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        let mut other = vault::new_for_testing<MEME, QUOTE>(
            object::id_from_address(@0xCAFE),
            object::id_from_address(@0xCA9),
            presale::fee_split(vector[], bps::new(10_000)),
            fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
            option::none(),
            f.ctx!(),
        );
        round.settle_gas_reserve(
            &package_version,
            &blast_acl::witness_for_testing<RewardsAdmin>(),
            &mut other,
            31,
            f.ctx!(),
        );
        abort
    })
}

#[test]
fun collection_routes_holder_meme_and_preserves_holder_quote() {
    let mut fixture = start_reserve_rewards();
    fixture.collect_holder_fees();
    assert_eq!(fixture.holder_quote(), 1_010);
    fixture.next_tx!(TREASURY, |f| f.assert_meme_payment(100));
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::blast_acl,
)]
fun a_cap_without_rewards_authority_cannot_settle() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.settle_without_role();
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EAlreadyClaimed, location = blast_presale::holder_rewards)]
fun reserve_holder_leaf_cannot_pay_twice() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.claim());
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_presale::holder_rewards)]
fun reserve_holder_payment_cannot_be_redirected() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        rewards::claim(&mut round, &package_version, 0, OWNER, 0, 970, vector[], &f.clock, f.ctx!());
        abort
    })
}

#[test]
#[expected_failure(abort_code = vault::EInvalidCommitment, location = blast_presale::presale_vault)]
fun round_rejects_a_short_merkle_root() {
    let mut f = start_reserve_rewards();
    f.publish_commitment(vector[0u8], hash::blake2b256(&b"manifest"), 1, 0, 1);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EInvalidCommitment, location = blast_presale::presale_vault)]
fun round_rejects_a_short_manifest_digest() {
    let mut f = start_reserve_rewards();
    f.publish_commitment(hash::blake2b256(&b"root"), vector[0u8], 1, 0, 1);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EInvalidLeafCount, location = blast_presale::presale_vault)]
fun round_rejects_zero_leaves() {
    let mut f = start_reserve_rewards();
    f.publish_commitment(hash::blake2b256(&b"root"), hash::blake2b256(&b"manifest"), 0, 0, 1);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EInvalidLeafCount, location = blast_presale::presale_vault)]
fun round_rejects_the_first_leaf_above_capacity() {
    let mut f = start_reserve_rewards();
    f.publish_commitment(hash::blake2b256(&b"root"), hash::blake2b256(&b"manifest"), 65_537, 0, 1);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EEmptyBudget, location = blast_presale::presale_vault)]
fun round_rejects_an_empty_asset_budget() {
    let mut f = start_reserve_rewards();
    f.publish_commitment(hash::blake2b256(&b"root"), hash::blake2b256(&b"manifest"), 1, 0, 0);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidIndex, location = blast_presale::holder_rewards)]
fun claim_rejects_the_first_index_outside_the_round() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(0);
    fixture.next_tx!(HOLDER, |f| {
        let version = blast_presale::blast_presale_package::new_for_testing(f.ctx!());
        let mut round = f.take_round();
        rewards::claim(&mut round, &version, 1, HOLDER, 0, 970, vector[], &f.clock, f.ctx!());
        abort
    });
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidIndex, location = blast_presale::holder_rewards)]
fun claim_rejects_the_largest_index_before_bitmap_access() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(0);
    fixture.next_tx!(HOLDER, |f| {
        let version = blast_presale::blast_presale_package::new_for_testing(f.ctx!());
        let mut round = f.take_round();
        rewards::claim(
            &mut round,
            &version,
            std::u64::max_value!(),
            HOLDER,
            0,
            970,
            vector[],
            &f.clock,
            f.ctx!(),
        );
        abort
    });
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidBeneficiary, location = blast_presale::holder_rewards)]
fun claim_rejects_a_zero_beneficiary_before_the_merkle_proof() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(0);
    fixture.next_tx!(HOLDER, |f| {
        let version = blast_presale::blast_presale_package::new_for_testing(f.ctx!());
        let mut round = f.take_round();
        rewards::claim(&mut round, &version, 0, @0x0, 0, 970, vector[], &f.clock, f.ctx!());
        abort
    });
    abort
}

// Delayed publication

#[test]
fun a_round_publishes_exactly_when_the_default_notice_elapses() {
    let mut fixture = start_reserve_rewards();
    assert_eq!(fixture.vault.round_publication_for_testing().delay_ms(), ROUND_NOTICE_MS);
    fixture.next_tx!(OWNER, |f| {
        f.schedule_budget_to(970, 30, TREASURY);
        let scheduled = only_event<ActionScheduled<RoundPublicationKey, RoundTerms>>();
        let (owner, _, change, delay_ms, ready_at_ms) = scheduled.action_scheduled_fields();
        assert_eq!(owner, object::id(&f.vault));
        assert_eq!(change.action(), option::some(f.terms(970, 30)));
        assert_eq!(delay_ms, ROUND_NOTICE_MS);
        assert_eq!(ready_at_ms, 1 + ROUND_NOTICE_MS);
        assert_eq!(f.holder_quote(), 1_000);
        assert_eq!(f.vault.next_round(), 0);
    });
    fixture.next_tx!(HOLDER, |f| {
        f.clock.set_for_testing(1 + ROUND_NOTICE_MS);
        f.publish_scheduled();

        only_event<ActionApplied<RoundPublicationKey, RoundTerms>>();
        f.assert_published(970, 30, TREASURY, DEADLINE_AT_MS);
        assert_eq!(f.holder_quote(), 0);
        assert!(f.vault.round_publication_for_testing().pending().is_none());
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_round_cannot_publish_one_millisecond_before_the_default_notice_elapses() {
    let mut fixture = start_reserve_rewards();
    fixture.next_tx!(OWNER, |f| f.schedule_budget_to(970, 0, TREASURY));
    fixture.next_tx!(HOLDER, |f| {
        f.clock.set_for_testing(ROUND_NOTICE_MS);
        f.publish_scheduled();
    });
    abort
}

#[test]
fun anyone_publishes_a_ready_round_in_a_later_transaction() {
    let mut fixture = start_reserve_rewards();
    fixture.next_tx!(OWNER, |f| f.schedule_budget_to(970, 0, TREASURY));
    fixture.next_tx!(HOLDER, |f| f.publish_after_notice());
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.assert_payment(970));
    fixture.end();
}

#[test]
fun a_late_publication_still_opens_the_full_claim_window() {
    let mut fixture = start_reserve_rewards();
    fixture.next_tx!(OWNER, |f| f.schedule_budget_to(970, 0, TREASURY));
    fixture.next_tx!(HOLDER, |f| {
        f.clock.set_for_testing(LATE_AT_MS);
        f.publish_scheduled();
        f.assert_published(970, 0, TREASURY, LATE_AT_MS + CLAIM_WINDOW_DURATION_MS);
    });
    fixture.next_tx!(HOLDER, |f| {
        f.clock.set_for_testing(LATE_AT_MS + CLAIM_WINDOW_DURATION_MS - 1);
        f.claim();
    });
    fixture.next_tx!(HOLDER, |f| f.assert_payment(970));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = rewards::EClaimDeadlineOverflow, location = blast_presale::holder_rewards)]
fun a_claim_window_ending_beyond_u64_rejects_publication() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_round_with(0, 0, 10, hash::blake2b256(&b"root"), 1, 970, 0, std::u64::max_value!());
    fixture.publish_after_notice();
    abort
}

#[test]
fun a_raised_notice_makes_publication_wait_until_ready() {
    let mut fixture = start_reserve_rewards();
    fixture.raise_notice(NOTICE_MS);
    fixture.schedule_budget_to(970, 0, TREASURY);

    fixture.clock.set_for_testing(1 + ROUND_NOTICE_MS + NOTICE_MS);
    fixture.publish_scheduled();

    assert_eq!(fixture.vault.next_round(), 1);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_raised_notice_rejects_publication_one_millisecond_early() {
    let mut fixture = start_reserve_rewards();
    fixture.raise_notice(NOTICE_MS);
    fixture.schedule_budget_to(970, 0, TREASURY);

    fixture.clock.set_for_testing(ROUND_NOTICE_MS + NOTICE_MS);
    fixture.publish_scheduled();

    abort
}

#[test]
fun a_cancelled_round_reserves_nothing_and_leaves_the_cursor() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_budget_to(970, 30, TREASURY);

    fixture.cancel_round();

    let cancelled = only_event<ActionCancelled<RoundPublicationKey, RoundTerms>>();
    let (_, _, change, _, _) = cancelled.action_cancelled_fields();
    assert_eq!(change.action(), option::some(fixture.terms(970, 30)));
    assert_eq!(fixture.holder_quote(), 1_000);
    assert_eq!(fixture.vault.next_round(), 0);
    assert_eq!(fixture.vault.last_checkpoint(), option::none());
    assert!(fixture.vault.round_publication_for_testing().pending().is_none());
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun a_cancelled_round_cannot_be_published() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_budget_to(970, 0, TREASURY);
    fixture.cancel_round();

    fixture.publish_scheduled();

    abort
}

#[test]
fun rescheduling_replaces_the_pending_round_and_announces_its_cancellation() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_budget_to(500, 30, TREASURY);

    fixture.schedule_budget_to(970, 0, TREASURY);

    let cancelled = only_event<ActionCancelled<RoundPublicationKey, RoundTerms>>();
    let (_, _, change, _, _) = cancelled.action_cancelled_fields();
    let replaced = vault::new_round_terms(
        0,
        0,
        10,
        rewards::leaf_for_testing(object::id(&fixture.vault), 0, 0, HOLDER, 0, 500),
        hash::blake2b256(&b"manifest"),
        1,
        0,
        500,
        30,
        CLAIM_WINDOW_DURATION_MS,
        TREASURY,
    );
    assert_eq!(change.action(), option::some(replaced));
    fixture.publish_after_notice();
    assert_eq!(fixture.holder_quote(), 30);
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.assert_payment(970));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInsufficientBudget, location = blast_presale::holder_rewards)]
fun publication_rechecks_the_budget_the_schedule_checked() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_budget_to(970, 30, TREASURY);
    fixture.drain_holder_rewards(1);

    fixture.publish_after_notice();

    abort
}

#[test]
#[expected_failure(abort_code = vault::EInvalidCommitment, location = blast_presale::presale_vault)]
fun scheduling_checks_the_terms_before_the_vault() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_round_with(9, 0, 10, vector[], 1, 2_000, 0, CLAIM_WINDOW_DURATION_MS);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EBudgetOverflow, location = blast_presale::presale_vault)]
fun a_holder_quote_and_gas_reserve_beyond_u64_are_rejected() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_round_with(0, 0, 10, hash::blake2b256(&b"root"), 1, std::u64::max_value!(), 1, CLAIM_WINDOW_DURATION_MS);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EZeroClaimWindow, location = blast_presale::presale_vault)]
fun scheduling_requires_a_positive_claim_window() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_round_with(0, 0, 10, hash::blake2b256(&b"root"), 1, 970, 0, 0);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EZeroTreasury, location = blast_presale::presale_vault)]
fun scheduling_requires_a_nonzero_expected_treasury() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_budget_to(970, 0, @0x0);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EWrongRound, location = blast_presale::holder_rewards)]
fun scheduling_rejects_a_number_other_than_the_next_round() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_round_with(1, 0, 10, hash::blake2b256(&b"root"), 1, 970, 0, CLAIM_WINDOW_DURATION_MS);
    abort
}

#[test]
fun a_shorter_notice_waits_the_applied_one() {
    let mut fixture = start_reserve_rewards();
    fixture.raise_notice(NOTICE_MS);
    fixture.schedule_notice(0);

    fixture.clock.set_for_testing(1 + ROUND_NOTICE_MS + NOTICE_MS);
    fixture.apply_notice();

    assert_eq!(fixture.vault.round_publication_for_testing().delay_ms(), 0);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_shorter_notice_cannot_apply_before_the_applied_one_elapses() {
    let mut fixture = start_reserve_rewards();
    fixture.raise_notice(NOTICE_MS);
    fixture.schedule_notice(0);

    fixture.clock.set_for_testing(ROUND_NOTICE_MS + NOTICE_MS);
    fixture.apply_notice();

    abort
}

#[test]
fun a_cancelled_notice_change_keeps_the_applied_notice() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_notice(NOTICE_MS);

    fixture.cancel_notice();

    assert_eq!(fixture.vault.round_publication_for_testing().delay_ms(), ROUND_NOTICE_MS);
    assert!(fixture.vault.round_publication_for_testing().pending().is_none());
    fixture.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongRoundProposal, location = blast_presale::presale_vault)]
fun a_round_cancellation_cannot_discard_a_notice_change() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_notice(NOTICE_MS);

    fixture.cancel_round();

    abort
}

#[test]
#[expected_failure(abort_code = vault::EWrongRoundProposal, location = blast_presale::presale_vault)]
fun a_notice_cancellation_cannot_discard_a_scheduled_round() {
    let mut fixture = start_reserve_rewards();
    fixture.schedule_budget_to(970, 0, TREASURY);

    fixture.cancel_notice();

    abort
}

#[test]
fun signed_in_roles_schedule_cancel_and_change_the_notice() {
    let mut fixture = start_reserve_rewards();
    let version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    let (root, mut acl) = blast_acl::new_for_testing(fixture.ctx!());
    acl.grant_admin(&root, OWNER, fixture.ctx!());
    acl.grant_admin(&root, HOLDER, fixture.ctx!());
    fixture.scenario.next_tx(OWNER);
    let rewards_cap = fixture.scenario.take_from_sender<AdminCap>();
    fixture.scenario.next_tx(HOLDER);
    let cancel_cap = fixture.scenario.take_from_sender<AdminCap>();
    acl.grant_role<RewardsAdmin>(&root, object::id(&rewards_cap));
    acl.grant_role<CancelAdmin>(&root, object::id(&cancel_cap));

    fixture.schedule_as(&version, &acl.sign_in<RewardsAdmin>(&rewards_cap));
    fixture.vault.cancel_round(&version, &acl.sign_in<CancelAdmin>(&cancel_cap));
    fixture.schedule_notice_as(&version, &acl.sign_in<RewardsAdmin>(&rewards_cap), NOTICE_MS);
    fixture.vault.cancel_round_delay(&version, &acl.sign_in<CancelAdmin>(&cancel_cap));

    assert!(fixture.vault.round_publication_for_testing().pending().is_none());
    std::unit_test::destroy(rewards_cap);
    std::unit_test::destroy(cancel_cap);
    std::unit_test::destroy(root);
    std::unit_test::destroy(acl);
    std::unit_test::destroy(version);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_cancel_admin_cannot_sign_in_to_schedule_a_round() {
    let mut fixture = start_reserve_rewards();
    let version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    let (root, mut acl) = blast_acl::new_for_testing(fixture.ctx!());
    acl.grant_admin(&root, HOLDER, fixture.ctx!());
    fixture.scenario.next_tx(HOLDER);
    let cancel_cap = fixture.scenario.take_from_sender<AdminCap>();
    acl.grant_role<CancelAdmin>(&root, object::id(&cancel_cap));

    fixture.schedule_as(&version, &acl.sign_in<RewardsAdmin>(&cancel_cap));

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_rewards_admin_cannot_sign_in_to_cancel_a_round() {
    let mut fixture = start_reserve_rewards();
    let version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    let (root, mut acl) = blast_acl::new_for_testing(fixture.ctx!());
    acl.grant_admin(&root, OWNER, fixture.ctx!());
    fixture.scenario.next_tx(OWNER);
    let rewards_cap = fixture.scenario.take_from_sender<AdminCap>();
    acl.grant_role<RewardsAdmin>(&root, object::id(&rewards_cap));
    fixture.schedule_budget_to(970, 0, TREASURY);

    fixture.vault.cancel_round(&version, &acl.sign_in<CancelAdmin>(&rewards_cap));

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_scheduling_before_every_round_check() {
    let mut fixture = start_reserve_rewards();
    let mut version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    version.set_for_testing(2);

    let clock = clock::create_for_testing(fixture.ctx!());
    fixture.vault.schedule_round(
        &version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        7, 10, 10, vector[], vector[], 0, 0, 0, 0, 0, @0x0, &clock,
    );

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_publication_before_taking_the_round() {
    let mut fixture = start_reserve_rewards();
    let mut version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    version.set_for_testing(2);

    fixture.publish_with(&version);

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_round_cancellation_first() {
    let mut fixture = start_reserve_rewards();
    let mut version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    version.set_for_testing(2);

    fixture.vault.cancel_round(&version, &blast_acl::witness_for_testing<CancelAdmin>());

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_notice_scheduling_first() {
    let mut fixture = start_reserve_rewards();
    let mut version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    version.set_for_testing(2);

    fixture.schedule_notice_as(&version, &blast_acl::witness_for_testing<RewardsAdmin>(), 0);

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_notice_application_first() {
    let mut fixture = start_reserve_rewards();
    let mut version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    version.set_for_testing(2);

    fixture.apply_notice_with(&version);

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_generation_rejects_notice_cancellation_first() {
    let mut fixture = start_reserve_rewards();
    let mut version = blast_presale::blast_presale_package::new_for_testing(fixture.ctx!());
    version.set_for_testing(2);

    fixture.vault.cancel_round_delay(&version, &blast_acl::witness_for_testing<CancelAdmin>());

    abort
}

// === Test Helpers ===

fun start_reserve_rewards(): ReserveFixture {
    let mut scenario = test_scenario::begin(OWNER);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let result = {
        let mut vault = vault::new_for_testing<MEME, QUOTE>(
            object::id_from_address(@0xCAFE),
            object::id_from_address(@0xCA9),
            presale::fee_split(vector[], bps::new(10_000)),
            fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
            option::none(),
            scenario.ctx(),
        );
        let mut policy = fee_policy::new_zero_fees_for_testing(scenario.ctx());
        policy.set_destination_for_testing(
            &package_version,
            &blast_acl::witness_for_testing<TreasuryAdmin>(),
            TREASURY,
            scenario.ctx()
        );
        vault.credit_fees_for_testing(
            &policy,
            balance::zero(),
            balance::create_for_testing<QUOTE>(1_000),
            scenario.ctx(),
        );
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(1);
        ReserveFixture { scenario, vault, policy, clock }
    };
    std::unit_test::destroy(package_version);
    result
}

macro fun reserve_next_tx(
    $self: &mut ReserveFixture,
    $sender: address,
    $body: |&mut ReserveFixture|,
) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture)
}

macro fun reserve_ctx($self: &mut ReserveFixture): &mut TxContext {
    let fixture = $self;
    fixture.scenario.ctx()
}

fun publish_commitment(
    self: &mut ReserveFixture,
    root: vector<u8>,
    manifest: vector<u8>,
    leaves: u64,
    meme_amount: u64,
    quote_amount: u64,
) {
    let version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    self
        .vault
        .schedule_round(
            &version,
            &blast_acl::witness_for_testing<RewardsAdmin>(),
            0,
            0,
            10,
            root,
            manifest,
            leaves,
            meme_amount,
            quote_amount,
            0,
            CLAIM_WINDOW_DURATION_MS,
            TREASURY,
            &self.clock,
        );
    std::unit_test::destroy(version);
}

fun publish(self: &mut ReserveFixture, reserve: u64) {
    self.publish_budget(970, reserve);
}

fun publish_budget(self: &mut ReserveFixture, holder_quote: u64, reserve: u64) {
    self.publish_budget_to(holder_quote, reserve, TREASURY);
}

fun publish_budget_to(
    self: &mut ReserveFixture,
    holder_quote: u64,
    reserve: u64,
    expected_treasury: address,
) {
    self.schedule_budget_to(holder_quote, reserve, expected_treasury);
    self.publish_after_notice();
    self.assert_published(holder_quote, reserve, expected_treasury, DEADLINE_AT_MS);
}

/// Checks the one `RoundPublished` of this transaction, for round 0 paying the holder.
fun assert_published(
    self: &ReserveFixture,
    holder_quote: u64,
    reserve: u64,
    treasury: address,
    deadline_at_ms: u64,
) {
    let root = rewards::leaf_for_testing(object::id(&self.vault), 0, 0, HOLDER, 0, holder_quote);
    let payload = only_event<RoundPublished<MEME, QUOTE>>();
    let round_id = payload.reserve_published_id();
    let quote_unallocated = self.vault.holder_rewards_quote();
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&self.vault))));
    expected.append(bcs::to_bytes(&(round_id)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(10u64)));
    expected.append(bcs::to_bytes(&(deadline_at_ms)));
    expected.append(bcs::to_bytes(&(root)));
    expected.append(bcs::to_bytes(&(hash::blake2b256(&b"manifest"))));
    expected.append(bcs::to_bytes(&(1u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(holder_quote)));
    expected.append(bcs::to_bytes(&(quote_unallocated)));
    expected.append(bcs::to_bytes(&(treasury)));
    expected.append(bcs::to_bytes(&(reserve)));
    assert_eq!(payload.reserve_published_bytes(), expected);
}

/// Schedules round 0 over checkpoints [0, 10) with one leaf paying the holder `holder_quote`.
fun schedule_budget_to(
    self: &mut ReserveFixture,
    holder_quote: u64,
    reserve: u64,
    expected_treasury: address,
) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    let root = rewards::leaf_for_testing(object::id(&self.vault), 0, 0, HOLDER, 0, holder_quote);
    self.vault.schedule_round(
        &package_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        0,
        0,
        10,
        root,
        hash::blake2b256(&b"manifest"),
        1,
        0,
        holder_quote,
        reserve,
        CLAIM_WINDOW_DURATION_MS,
        expected_treasury,
        &self.clock,
    );
    std::unit_test::destroy(package_version);
}

/// Schedules explicit terms with the default manifest and treasury.
fun schedule_round_with(
    self: &mut ReserveFixture,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    leaf_count: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
    claim_window_duration_ms: u64,
) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    self.vault.schedule_round(
        &package_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        hash::blake2b256(&b"manifest"),
        leaf_count,
        0,
        quote_amount,
        gas_reserve_amount,
        claim_window_duration_ms,
        TREASURY,
        &self.clock,
    );
    std::unit_test::destroy(package_version);
}

/// Publishes the scheduled round permissionlessly in the current transaction.
fun publish_scheduled(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    self.publish_with(&package_version);
    std::unit_test::destroy(package_version);
}

/// Advances the clock by the applied notice, then publishes the round scheduled at the current
/// time.
fun publish_after_notice(self: &mut ReserveFixture) {
    let delay_ms = self.vault.round_publication_for_testing().delay_ms();
    self.clock.increment_for_testing(delay_ms);
    self.publish_scheduled();
}

/// Publishes the scheduled round under `package_version`.
fun publish_with(self: &mut ReserveFixture, package_version: &PackageVersion) {
    self.vault.publish_round(package_version, &self.policy, &self.clock, self.scenario.ctx());
}

/// Schedules the default one-leaf round under `admin`.
fun schedule_as(
    self: &mut ReserveFixture,
    package_version: &PackageVersion,
    admin: &AdminWitness<RewardsAdmin>,
) {
    self.vault.schedule_round(
        package_version,
        admin,
        0,
        0,
        10,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        0,
        970,
        0,
        CLAIM_WINDOW_DURATION_MS,
        TREASURY,
        &self.clock,
    );
}

/// Schedules a new round notice under `admin`.
fun schedule_notice_as(
    self: &mut ReserveFixture,
    package_version: &PackageVersion,
    admin: &AdminWitness<RewardsAdmin>,
    delay_ms: u64,
) {
    self.vault.schedule_round_delay(package_version, admin, delay_ms, &self.clock);
}

/// Applies the ready round-notice change under `package_version`.
fun apply_notice_with(self: &mut ReserveFixture, package_version: &PackageVersion) {
    self.vault.apply_round_delay(package_version, &self.clock);
}

/// Cancels the scheduled round as the cancel admin.
fun cancel_round(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    self.vault.cancel_round(&package_version, &blast_acl::witness_for_testing<CancelAdmin>());
    std::unit_test::destroy(package_version);
}

/// Schedules a new round notice as the rewards admin.
fun schedule_notice(self: &mut ReserveFixture, delay_ms: u64) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    self.schedule_notice_as(&package_version, &blast_acl::witness_for_testing<RewardsAdmin>(), delay_ms);
    std::unit_test::destroy(package_version);
}

/// Applies the ready round-notice change.
fun apply_notice(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    self.apply_notice_with(&package_version);
    std::unit_test::destroy(package_version);
}

/// Cancels the pending round-notice change as the cancel admin.
fun cancel_notice(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self.ctx!());
    self.vault.cancel_round_delay(&package_version, &blast_acl::witness_for_testing<CancelAdmin>());
    std::unit_test::destroy(package_version);
}

/// Raises the round notice from the default, which applies once the default elapses.
fun raise_notice(self: &mut ReserveFixture, delay_ms: u64) {
    self.schedule_notice(delay_ms);
    self.clock.set_for_testing(1 + ROUND_NOTICE_MS);
    self.apply_notice();
    assert_eq!(self.vault.round_publication_for_testing().delay_ms(), delay_ms);
}

/// Burns unreserved holder Quote so the budget shrinks between scheduling and publication.
fun drain_holder_rewards(self: &mut ReserveFixture, quote_amount: u64) {
    self.vault.withdraw_holder_rewards_for_testing(quote_amount).destroy_for_testing();
}

/// The terms `schedule_budget_to` schedules for the fixture's treasury.
fun terms(self: &ReserveFixture, holder_quote: u64, reserve: u64): RoundTerms {
    vault::new_round_terms(
        0,
        0,
        10,
        rewards::leaf_for_testing(object::id(&self.vault), 0, 0, HOLDER, 0, holder_quote),
        hash::blake2b256(&b"manifest"),
        1,
        0,
        holder_quote,
        reserve,
        CLAIM_WINDOW_DURATION_MS,
        TREASURY,
    )
}

fun take_round(self: &ReserveFixture): Round<MEME, QUOTE> {
    self.scenario.take_shared()
}

fun return_round(_self: &ReserveFixture, round: Round<MEME, QUOTE>) {
    test_scenario::return_shared(round);
}

fun settle(self: &mut ReserveFixture, round: &mut Round<MEME, QUOTE>, amount: u64) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let (_, _, reserve) = round.reserve_balances_for_testing();
    let reserve_amount = reserve.destroy_or!(0);
    round.settle_gas_reserve(
        &package_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        &mut self.vault,
        amount,
        self.scenario.ctx(),
    );
    let payload = only_event<GasReserveSettled<MEME, QUOTE>>();
    let quote_unallocated = self.vault.holder_rewards_quote();
    let treasury = TREASURY;
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&self.vault))));
    expected.append(bcs::to_bytes(&(object::id(round))));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(treasury)));
    expected.append(bcs::to_bytes(&(amount)));
    expected.append(bcs::to_bytes(&(reserve_amount - amount)));
    expected.append(bcs::to_bytes(&(quote_unallocated)));
    assert_eq!(payload.reserve_settled_bytes(), expected);

    std::unit_test::destroy(package_version);
}

fun claim(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let mut round = self.take_round();
    rewards::claim(&mut round, &package_version, 0, HOLDER, 0, 970, vector[], &self.clock, self.ctx!());
    let payload = only_event<RewardClaimed<MEME, QUOTE>>();
    let holder = HOLDER;
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&round))));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(holder)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(970u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    assert_eq!(payload.reserve_claimed_bytes(), expected);
    self.return_round(round);

    std::unit_test::destroy(package_version);
}

fun close(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let round = self.take_round();
    self.clock.set_for_testing(DEADLINE_AT_MS);
    let round_id = object::id(&round);
    let (meme, quote, reserve) = round.reserve_balances_for_testing();
    round.close_round(&package_version, &mut self.vault, &self.clock);
    let payload = only_event<RoundClosed<MEME, QUOTE>>();
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&self.vault))));
    expected.append(bcs::to_bytes(&(round_id)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(meme)));
    expected.append(bcs::to_bytes(&(quote)));
    expected.append(bcs::to_bytes(&(reserve.destroy_or!(0u64))));
    assert_eq!(payload.reserve_closed_bytes(), expected);

    std::unit_test::destroy(package_version);
}

fun assert_payment(self: &ReserveFixture, amount: u64) {
    assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), amount);
}

fun holder_quote(self: &ReserveFixture): u64 {
    self.vault.holder_rewards_quote()
}

fun end(mut self: ReserveFixture) {
    let remaining = self.vault.holder_rewards_quote();
    self.vault.fund_round(0, remaining).destroy_for_testing();
    let ReserveFixture { scenario, vault, policy, clock } = self;
    vault.destroy_for_testing();
    policy.destroy_for_testing();
    clock.destroy_for_testing();
    scenario.end();
}

fun collect_holder_fees(self: &mut ReserveFixture) {
    self
        .vault
        .credit_fees_for_testing(
            &self.policy,
            balance::create_for_testing<MEME>(100),
            balance::create_for_testing<QUOTE>(10),
            self.scenario.ctx(),
        );
    let payload = only_event<HolderMemePaid<MEME, QUOTE>>();
    let treasury = TREASURY;
    let mut expected = bcs::to_bytes(&object::id(&self.vault));
    expected.append(bcs::to_bytes(&treasury));
    expected.append(bcs::to_bytes(&100u64));
    assert_eq!(payload.holder_meme_paid_bytes(), expected);
}

fun assert_meme_payment(self: &ReserveFixture, amount: u64) {
    let mut total = 0;
    while (self.scenario.has_most_recent_for_sender<Coin<MEME>>()) {
        total = total + self.scenario.take_from_sender<Coin<MEME>>().burn_for_testing();
    };
    assert_eq!(total, amount);
}

fun settle_without_role(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let (root, mut acl) = blast_acl::new_for_testing(self.ctx!());
    acl.grant_admin(&root, OWNER, self.ctx!());
    self.scenario.next_tx(OWNER);
    let cap = self.scenario.take_from_sender<AdminCap>();
    let witness = acl.sign_in<RewardsAdmin>(&cap);
    let mut round = self.take_round();
    round.settle_gas_reserve(
        &package_version,
        &witness,
        &mut self.vault,
        24,
        self.scenario.ctx(),
    );
    std::unit_test::destroy(package_version);
    abort
}

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminCap, AdminWitness},
    delayed_action::{ActionApplied, ActionCancelled, ActionScheduled}
};

use blast_presale::{
    blast_presale as presale,
    blast_presale_domain::{CancelAdmin, RewardsAdmin, TreasuryAdmin},
    blast_presale_package::PackageVersion,
    bps,
    fee_policy::{Self, FeePolicy},
    holder_rewards::{
        Self as rewards,
        Round,
        RoundPublished,
        RewardClaimed,
        GasReserveSettled,
        RoundClosed,
    },
    presale_vault::{Self as vault, Vault, HolderMemePaid, RoundPublicationKey, RoundTerms}
};

use std::{bcs, unit_test::assert_eq};

use sui::{balance, clock::{Self, Clock}, coin::Coin, event, hash, test_scenario::{Self, Scenario}};

use fun reserve_next_tx as ReserveFixture.next_tx;

use fun reserve_ctx as ReserveFixture.ctx;

use fun rewards::apply_round_delay as Vault.apply_round_delay;

use fun rewards::cancel_round as Vault.cancel_round;

use fun rewards::cancel_round_delay as Vault.cancel_round_delay;

use fun rewards::publish_round as Vault.publish_round;

use fun rewards::schedule_round as Vault.schedule_round;

use fun rewards::schedule_round_delay as Vault.schedule_round_delay;
