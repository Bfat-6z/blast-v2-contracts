// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_vesting::blast_fun_checkpoint_vesting_tests;

// === Constants ===

const FUNDER: address = @0xF00D;

const BENEFICIARY: address = @0xB0B;

const REFUND_RECIPIENT: address = @0xCAFE;

const CALLER: address = @0xC11;

const CANCELER: address = @0xCA11;

const TOTAL_AMOUNT: u64 = 1_000;

const FIRST_MS: u64 = 100;

const SECOND_MS: u64 = 250;

const FINAL_MS: u64 = 700;

const FIRST_AMOUNT: u64 = 100;

const SECOND_AMOUNT: u64 = 400;

const MAX_CHECKPOINTS: u64 = 256;

// === Test-Only Types ===

public struct TEST_COIN() has drop;

/// Single-transaction construction, vector probes, and focused failure paths.
public struct UnitFixture {
    scenario: Scenario,
    clock: Clock,
    schedule: Option<Schedule>,
    vestings: vector<Vesting<TEST_COIN>>,
    cancel_cap: Option<CancelCap<TEST_COIN>>,
}

/// Shared irrevocable lifecycle with beneficiary payout inspection.
public struct ClaimFixture {
    scenario: Scenario,
    clock: Clock,
    vesting: Option<Vesting<TEST_COIN>>,
    created: VestingCreated,
    vesting_id: ID,
}

/// Shared cancellable lifecycle with a transferred cancellation capability.
public struct CancelFixture {
    scenario: Scenario,
    clock: Clock,
    vesting: Option<Vesting<TEST_COIN>>,
    cancel_cap: Option<CancelCap<TEST_COIN>>,
    created: VestingCreated,
    vesting_id: ID,
    cancel_cap_id: ID,
}

// === Tests ===

#[test]
fun vested_value_matches_the_checkpoints_at_every_boundary() {
    let mut fixture = start_unit(0);

    assert_eq!(fixture.vested_at(FIRST_MS - 1), 0);
    assert_eq!(fixture.vested_at(FIRST_MS), FIRST_AMOUNT);
    assert_eq!(fixture.vested_at(SECOND_MS - 1), FIRST_AMOUNT);
    assert_eq!(fixture.vested_at(SECOND_MS), SECOND_AMOUNT);
    assert_eq!(fixture.vested_at(FINAL_MS - 1), SECOND_AMOUNT);
    assert_eq!(fixture.vested_at(FINAL_MS), TOTAL_AMOUNT);
    assert_eq!(fixture.vested_at(FINAL_MS + 1), TOTAL_AMOUNT);

    fixture.end();
}

#[test]
fun one_checkpoint_schedule_is_supported() {
    let mut fixture = start_unit(0);

    assert_eq!(fixture.vested_at_with(one_checkpoint_schedule(10, 1), 1, 9), 0);
    assert_eq!(fixture.vested_at_with(one_checkpoint_schedule(10, 1), 1, 10), 1);

    fixture.end();
}

#[test]
fun maximum_checkpoint_count_vests_the_first_middle_and_final_boundaries() {
    let mut fixture = start_unit(0);

    assert_eq!(fixture.vested_at_with(checkpoint_range(MAX_CHECKPOINTS), 256, 0), 1);
    assert_eq!(fixture.vested_at_with(checkpoint_range(MAX_CHECKPOINTS), 256, 127), 128);
    assert_eq!(fixture.vested_at_with(checkpoint_range(MAX_CHECKPOINTS), 256, 255), 256);

    fixture.end();
}

#[test]
fun maximum_checkpoint_count_claims_every_boundary_and_closes() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint_range(MAX_CHECKPOINTS);
    fixture.create_irrevocable(MAX_CHECKPOINTS, BENEFICIARY);

    MAX_CHECKPOINTS.do!(|timestamp_ms| {
        fixture.set_clock(timestamp_ms);
        fixture.claim(0);
    });
    fixture.close_irrevocable(0);

    let claimed = event::events_by_type<VestingClaimed>();
    assert_eq!(claimed.length(), MAX_CHECKPOINTS);
    claimed.length().do!(|index| {
        let (_, _, _, amount, released_total) = claimed[index].vesting_claimed_fields();
        assert_eq!(amount, 1);
        assert_eq!(released_total, index + 1);
    });
    let created = collect_one<VestingCreated>();
    let (_, _, _, _, _, total_amount, checkpoint_count) = created.vesting_created_fields();
    assert_eq!(total_amount, MAX_CHECKPOINTS);
    assert_eq!(checkpoint_count, MAX_CHECKPOINTS);
    collect_one<VestingClosed>();

    fixture.end();
}

#[test]
fun irrevocable_lifecycle_releases_irregular_amounts_and_replays_events() {
    let mut fixture = start_claim();
    let mut claimed = 0;

    fixture.next_tx!(CALLER, |f| {
        f.assert_created();

        f.claim_at(FIRST_MS);

        let event = collect_one<VestingClaimed>();
        let (vesting_id, coin_type, beneficiary, amount, released_total) =
            event.vesting_claimed_fields();
        assert_eq!(vesting_id, f.vesting_id());
        assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(amount, FIRST_AMOUNT);
        assert_eq!(released_total, FIRST_AMOUNT);
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), FIRST_AMOUNT);
    });

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(SECOND_MS);

        let event = collect_one<VestingClaimed>();
        let (_, _, _, amount, released_total) = event.vesting_claimed_fields();
        assert_eq!(amount, SECOND_AMOUNT - FIRST_AMOUNT);
        assert_eq!(released_total, SECOND_AMOUNT);
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), SECOND_AMOUNT - FIRST_AMOUNT);
    });

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(FINAL_MS);
        f.close();

        let event = collect_one<VestingClaimed>();
        let (_, _, _, amount, released_total) = event.vesting_claimed_fields();
        let closed = collect_one<VestingClosed>();
        let (closed_id, coin_type) = closed.vesting_closed_fields();
        assert_eq!(amount, TOTAL_AMOUNT - SECOND_AMOUNT);
        assert_eq!(released_total, TOTAL_AMOUNT);
        assert_eq!(closed_id, f.vesting_id());
        assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), TOTAL_AMOUNT - SECOND_AMOUNT);
    });

    let (_, _, _, _, _, total_amount, _) = fixture.created.vesting_created_fields();
    assert_eq!(claimed, total_amount);

    fixture.end();
}

#[test]
fun cancelable_schedule_preserves_prior_and_unclaimed_vested_value() {
    let mut fixture = start_cancel();
    let mut claimed = 0;

    fixture.next_tx!(CALLER, |f| {
        f.assert_created();

        f.claim_at(FIRST_MS);

        let event = collect_one<VestingClaimed>();
        let (_, _, _, amount, released_total) = event.vesting_claimed_fields();
        assert_eq!(amount, FIRST_AMOUNT);
        assert_eq!(released_total, FIRST_AMOUNT);
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), FIRST_AMOUNT);
    });

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(SECOND_MS);

        let canceled = collect_one<VestingCanceled>();
        let (
            vesting_id,
            coin_type,
            beneficiary,
            refund_recipient,
            beneficiary_amount,
            refund_amount,
            released_total,
        ) = canceled.vesting_canceled_fields();
        let (_, _, _, _, _, total_amount, _) = f.created.vesting_created_fields();

        assert_eq!(vesting_id, f.vesting_id());
        assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(refund_recipient, REFUND_RECIPIENT);
        assert_eq!(beneficiary_amount, SECOND_AMOUNT - FIRST_AMOUNT);
        assert_eq!(refund_amount, TOTAL_AMOUNT - SECOND_AMOUNT);
        assert_eq!(released_total, SECOND_AMOUNT);
        assert_eq!(released_total, claimed + beneficiary_amount);
        assert_eq!(claimed + beneficiary_amount + refund_amount, total_amount);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), SECOND_AMOUNT - FIRST_AMOUNT);
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_payout(), TOTAL_AMOUNT - SECOND_AMOUNT);
    });

    fixture.end();
}

#[test]
fun cancellation_after_a_claim_before_the_next_checkpoint_pays_only_the_refund() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(FIRST_MS);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), FIRST_AMOUNT);
    });

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(SECOND_MS - 1);

        let canceled = collect_one<VestingCanceled>();
        let (_, _, _, _, beneficiary_amount, refund_amount, released_total) =
            canceled.vesting_canceled_fields();
        assert_eq!(beneficiary_amount, 0);
        assert_eq!(refund_amount, TOTAL_AMOUNT - FIRST_AMOUNT);
        assert_eq!(released_total, FIRST_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert!(!f.has_payout());
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_payout(), TOTAL_AMOUNT - FIRST_AMOUNT);
    });

    fixture.end();
}

#[test]
fun cancellation_before_first_checkpoint_returns_the_full_allocation() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(FIRST_MS - 1);

        let canceled = collect_one<VestingCanceled>();
        let (_, _, _, _, beneficiary_amount, refund_amount, released_total) =
            canceled.vesting_canceled_fields();
        assert_eq!(beneficiary_amount, 0);
        assert_eq!(refund_amount, TOTAL_AMOUNT);
        assert_eq!(released_total, 0);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert!(!f.has_payout());
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_payout(), TOTAL_AMOUNT);
    });

    fixture.end();
}

#[test]
fun cancellation_after_final_checkpoint_has_no_refund() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(FINAL_MS);

        let canceled = collect_one<VestingCanceled>();
        let (_, _, _, _, beneficiary_amount, refund_amount, released_total) =
            canceled.vesting_canceled_fields();
        assert_eq!(beneficiary_amount, TOTAL_AMOUNT);
        assert_eq!(refund_amount, 0);
        assert_eq!(released_total, TOTAL_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), TOTAL_AMOUNT);
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert!(!f.has_payout());
    });

    fixture.end();
}

#[test]
fun schedules_in_one_transaction_emit_events_matched_by_id() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 3);
    fixture.create_irrevocable(3, BENEFICIARY);
    fixture.add_checkpoint(5, 2);
    fixture.add_checkpoint(20, 7);
    fixture.create_irrevocable(7, REFUND_RECIPIENT);
    let first_id = fixture.vesting_id(0);
    let second_id = fixture.vesting_id(1);
    fixture.set_clock(10);

    fixture.claim(1);
    fixture.claim(0);

    let created = event::events_by_type<VestingCreated>();
    let (id, _, beneficiary, _, _, total_amount, checkpoint_count) =
        created[0].vesting_created_fields();
    assert_eq!(id, first_id);
    assert_eq!(beneficiary, BENEFICIARY);
    assert_eq!(total_amount, 3);
    assert_eq!(checkpoint_count, 1);
    let (id, _, beneficiary, _, _, total_amount, checkpoint_count) =
        created[1].vesting_created_fields();
    assert_eq!(id, second_id);
    assert_eq!(beneficiary, REFUND_RECIPIENT);
    assert_eq!(total_amount, 7);
    assert_eq!(checkpoint_count, 2);

    let claimed = event::events_by_type<VestingClaimed>();
    let (id, _, beneficiary, amount, released_total) = claimed[0].vesting_claimed_fields();
    assert_eq!(id, second_id);
    assert_eq!(beneficiary, REFUND_RECIPIENT);
    assert_eq!(amount, 2);
    assert_eq!(released_total, 2);
    let (id, _, beneficiary, amount, released_total) = claimed[1].vesting_claimed_fields();
    assert_eq!(id, first_id);
    assert_eq!(beneficiary, BENEFICIARY);
    assert_eq!(amount, 3);
    assert_eq!(released_total, 3);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EInvalidBeneficiary,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_zero_beneficiary_before_zero_refund_recipient() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(0, @0x0, @0x0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EInvalidRefundRecipient,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun cancelable_constructor_rejects_zero_refund_before_zero_allocation() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(0, BENEFICIARY, @0x0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EZeroAllocation,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_zero_allocation_before_empty_checkpoints() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(0, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ENoCheckpoints,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_empty_checkpoints() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ETooManyCheckpoints,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_more_than_256_checkpoints_before_ordering_checks() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint_range(MAX_CHECKPOINTS);

    fixture.add_checkpoint(0, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointInPast,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_a_past_first_checkpoint_before_the_final_amount_check() {
    let mut fixture = start_unit(100);
    fixture.add_checkpoint(99, 1);

    fixture.create_irrevocable(2, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointTimesNotIncreasing,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_checkpoint_times_that_do_not_increase_before_amounts() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);

    fixture.add_checkpoint(10, 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointAmountsNotIncreasing,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_zero_first_checkpoint_amount() {
    let mut fixture = start_unit(0);

    fixture.add_checkpoint(10, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointAmountsNotIncreasing,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_checkpoint_amounts_that_do_not_increase() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);

    fixture.add_checkpoint(20, 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EFinalAmountMismatch,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_final_amount_different_from_funding() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);

    fixture.create_irrevocable(2, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun claim_rejects_zero_release_before_first_checkpoint() {
    let mut fixture = start_unit(0);
    fixture.create_standard();
    fixture.set_clock(FIRST_MS - 1);

    fixture.claim(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun claim_rejects_a_repeat_claim_before_the_next_checkpoint() {
    let mut fixture = start_unit(0);
    fixture.create_standard();
    fixture.set_clock(FIRST_MS);
    fixture.claim(0);
    fixture.set_clock(SECOND_MS - 1);

    fixture.claim(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun claim_rejects_a_drained_schedule() {
    let mut fixture = start_unit(0);
    fixture.create_standard();
    fixture.set_clock(FINAL_MS);
    fixture.claim(0);
    fixture.set_clock(FINAL_MS + 1);

    fixture.claim(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EInvalidCancelCap,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun cancellation_rejects_a_cap_for_another_schedule() {
    let mut fixture = start_unit(0);
    fixture.cancel_with_mismatched_cap();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EScheduleNotEmpty,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun close_rejects_a_schedule_before_its_final_checkpoint() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_irrevocable(1, BENEFICIARY);

    fixture.close_irrevocable(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EScheduleNotEmpty,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun close_rejects_unclaimed_custody_after_the_final_checkpoint() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_irrevocable(1, BENEFICIARY);
    fixture.set_clock(10);

    fixture.close_irrevocable(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECancelCapRequired,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun irrevocable_close_rejects_a_cancellable_schedule_before_the_balance_check() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_cancelable(1, BENEFICIARY, REFUND_RECIPIENT);

    fixture.close_irrevocable(0);

    fixture.end();
}

// === Test Helpers ===

macro fun claim_fixture_next_tx(
    $fixture: &mut ClaimFixture,
    $sender: address,
    $fn: |&mut ClaimFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun cancel_fixture_next_tx(
    $fixture: &mut CancelFixture,
    $sender: address,
    $fn: |&mut CancelFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun standard_schedule(): Schedule {
    let mut schedule = checkpoints::new_schedule();
    schedule.add(FIRST_MS, FIRST_AMOUNT);
    schedule.add(SECOND_MS, SECOND_AMOUNT);
    schedule.add(FINAL_MS, TOTAL_AMOUNT);
    schedule
}

fun one_checkpoint_schedule(timestamp_ms: u64, cumulative_amount: u64): Schedule {
    let mut schedule = checkpoints::new_schedule();
    schedule.add(timestamp_ms, cumulative_amount);
    schedule
}

/// Checkpoints `(index, index + 1)` for every index below `length`.
fun checkpoint_range(length: u64): Schedule {
    let mut schedule = checkpoints::new_schedule();
    length.do!(|index| schedule.add(index, index + 1));
    schedule
}

fun start_unit(timestamp_ms: u64): UnitFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(timestamp_ms);

    UnitFixture {
        scenario,
        clock,
        schedule: option::some(checkpoints::new_schedule()),
        vestings: vector[],
        cancel_cap: option::none(),
    }
}

fun unit_add_checkpoint(
    self: &mut UnitFixture,
    timestamp_ms: u64,
    cumulative_amount: u64,
) {
    self.schedule.borrow_mut().add(timestamp_ms, cumulative_amount);
}

fun unit_add_checkpoint_range(self: &mut UnitFixture, length: u64) {
    let schedule = self.schedule.borrow_mut();
    length.do!(|index| schedule.add(index, index + 1));
}

/// Consumes the pending schedule into a new irrevocable vesting and starts an empty schedule.
fun unit_create_irrevocable(
    self: &mut UnitFixture,
    amount: u64,
    beneficiary: address,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let schedule = self.schedule.swap(checkpoints::new_schedule());
    let vesting = checkpoints::new_irrevocable(
        funds,
        beneficiary,
        schedule,
        &self.clock,
        self.scenario.ctx(),
    );
    self.vestings.push_back(vesting);
}

/// Consumes the pending schedule into a new cancelable vesting and starts an empty schedule.
fun unit_create_cancelable(
    self: &mut UnitFixture,
    amount: u64,
    beneficiary: address,
    refund_recipient: address,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let schedule = self.schedule.swap(checkpoints::new_schedule());
    let (vesting, cancel_cap) = checkpoints::new_cancelable(
        funds,
        beneficiary,
        refund_recipient,
        schedule,
        &self.clock,
        self.scenario.ctx(),
    );
    self.vestings.push_back(vesting);
    self.cancel_cap.fill(cancel_cap);
}

fun unit_create_standard(self: &mut UnitFixture) {
    self.add_checkpoint(FIRST_MS, FIRST_AMOUNT);
    self.add_checkpoint(SECOND_MS, SECOND_AMOUNT);
    self.add_checkpoint(FINAL_MS, TOTAL_AMOUNT);
    self.create_irrevocable(TOTAL_AMOUNT, BENEFICIARY);
}

/// The standard schedule's vested value at `timestamp_ms`.
fun unit_vested_at(self: &mut UnitFixture, timestamp_ms: u64): u64 {
    self.vested_at_with(standard_schedule(), TOTAL_AMOUNT, timestamp_ms)
}

/// Observes a schedule's vested value at `timestamp_ms` through the public API: cancellation
/// reports it as `released_total`. Each probe runs on its own clock, which starts at zero.
fun unit_vested_at_with(
    self: &mut UnitFixture,
    schedule: Schedule,
    amount: u64,
    timestamp_ms: u64,
): u64 {
    let mut clock = clock::create_for_testing(self.scenario.ctx());
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let (vesting, cancel_cap) = checkpoints::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        schedule,
        &clock,
        self.scenario.ctx(),
    );
    clock.set_for_testing(timestamp_ms);
    vesting.cancel(cancel_cap, &clock, self.scenario.ctx());
    clock.destroy_for_testing();

    let canceled = event::events_by_type<VestingCanceled>();
    let (_, _, _, _, _, _, released_total) =
        canceled[canceled.length() - 1].vesting_canceled_fields();
    released_total
}

fun unit_vesting_id(self: &UnitFixture, index: u64): ID {
    object::id(&self.vestings[index])
}

fun unit_set_clock(self: &mut UnitFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

fun unit_claim(self: &mut UnitFixture, index: u64) {
    self.vestings[index].claim(&self.clock, self.scenario.ctx());
}

fun unit_cancel_with_mismatched_cap(self: &mut UnitFixture) {
    self.add_checkpoint(1, 1);
    self.create_cancelable(1, BENEFICIARY, REFUND_RECIPIENT);
    let first_cap = self.cancel_cap.extract();
    self.add_checkpoint(1, 1);
    self.create_cancelable(1, BENEFICIARY, REFUND_RECIPIENT);

    self.vestings.remove(1).cancel(first_cap, &self.clock, self.scenario.ctx());
}

fun unit_close_irrevocable(self: &mut UnitFixture, index: u64) {
    self.vestings.remove(index).close_irrevocable();
}

fun unit_end(self: UnitFixture) {
    destroy(self);
}

fun start_claim(): ClaimFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let clock = clock::create_for_testing(scenario.ctx());
    let funds = coin::mint_for_testing<TEST_COIN>(TOTAL_AMOUNT, scenario.ctx());
    let vesting = checkpoints::new_irrevocable(
        funds,
        BENEFICIARY,
        standard_schedule(),
        &clock,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    let created = collect_one<VestingCreated>();

    vesting.share();
    scenario.next_tx(CALLER);
    let vesting = scenario.take_shared<Vesting<TEST_COIN>>();

    ClaimFixture {
        scenario,
        clock,
        vesting: option::some(vesting),
        created,
        vesting_id,
    }
}

fun start_cancel(): CancelFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let clock = clock::create_for_testing(scenario.ctx());
    let funds = coin::mint_for_testing<TEST_COIN>(TOTAL_AMOUNT, scenario.ctx());
    let (vesting, cancel_cap) = checkpoints::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        standard_schedule(),
        &clock,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    let cancel_cap_id = object::id(&cancel_cap);
    let created = collect_one<VestingCreated>();

    vesting.share();
    transfer::public_transfer(cancel_cap, CANCELER);
    scenario.next_tx(CANCELER);
    let vesting = scenario.take_shared<Vesting<TEST_COIN>>();
    let cancel_cap = scenario.take_from_sender<CancelCap<TEST_COIN>>();

    CancelFixture {
        scenario,
        clock,
        vesting: option::some(vesting),
        cancel_cap: option::some(cancel_cap),
        created,
        vesting_id,
        cancel_cap_id,
    }
}

fun collect_one<T: copy + drop>(): T {
    let mut events = event::events_by_type<T>();
    assert!(events.length() == 1);
    events.pop_back()
}

fun claim_fixture_assert_created(self: &ClaimFixture) {
    let (
        vesting_id,
        coin_type,
        beneficiary,
        refund_recipient,
        cancel_cap_id,
        total_amount,
        checkpoint_count,
    ) = self.created.vesting_created_fields();

    assert_eq!(vesting_id, self.vesting_id);
    assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
    assert_eq!(beneficiary, BENEFICIARY);
    assert!(refund_recipient.is_none());
    assert!(cancel_cap_id.is_none());
    assert_eq!(total_amount, TOTAL_AMOUNT);
    assert_eq!(checkpoint_count, 3);
}

fun claim_fixture_claim_at(self: &mut ClaimFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
    self.vesting.borrow_mut().claim(&self.clock, self.scenario.ctx());
}

fun claim_fixture_close(self: &mut ClaimFixture) {
    self.vesting.extract().close_irrevocable();
}

fun claim_fixture_vesting_id(self: &ClaimFixture): ID {
    self.vesting_id
}

fun claim_fixture_take_payout(self: &ClaimFixture): u64 {
    self.scenario.take_from_sender<Coin<TEST_COIN>>().burn_for_testing()
}

fun claim_fixture_end(self: ClaimFixture) {
    assert!(self.vesting.is_none());
    destroy(self);
}

fun cancel_fixture_assert_created(self: &CancelFixture) {
    let (
        vesting_id,
        coin_type,
        beneficiary,
        refund_recipient,
        cancel_cap_id,
        total_amount,
        checkpoint_count,
    ) = self.created.vesting_created_fields();

    assert_eq!(vesting_id, self.vesting_id);
    assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
    assert_eq!(beneficiary, BENEFICIARY);
    assert_eq!(refund_recipient, option::some(REFUND_RECIPIENT));
    assert_eq!(cancel_cap_id, option::some(self.cancel_cap_id));
    assert_eq!(total_amount, TOTAL_AMOUNT);
    assert_eq!(checkpoint_count, 3);
}

fun cancel_fixture_claim_at(self: &mut CancelFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
    self.vesting.borrow_mut().claim(&self.clock, self.scenario.ctx());
}

fun cancel_fixture_cancel_at(self: &mut CancelFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
    self.vesting.extract().cancel(
        self.cancel_cap.extract(),
        &self.clock,
        self.scenario.ctx(),
    );
}

fun cancel_fixture_vesting_id(self: &CancelFixture): ID {
    self.vesting_id
}

fun cancel_fixture_take_payout(self: &CancelFixture): u64 {
    self.scenario.take_from_sender<Coin<TEST_COIN>>().burn_for_testing()
}

fun cancel_fixture_has_payout(self: &CancelFixture): bool {
    self.scenario.has_most_recent_for_sender<Coin<TEST_COIN>>()
}

fun cancel_fixture_end(self: CancelFixture) {
    assert!(self.vesting.is_none());
    assert!(self.cancel_cap.is_none());
    destroy(self);
}

// === Imports ===

use blast_fun_vesting::blast_fun_checkpoint_vesting::{
    Self as checkpoints,
    CancelCap,
    Schedule,
    Vesting,
    VestingCanceled,
    VestingClaimed,
    VestingClosed,
    VestingCreated,
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock::{Self, Clock}, coin::{Self, Coin}, event, test_scenario::{Self, Scenario}};

use fun cancel_fixture_assert_created as CancelFixture.assert_created;

use fun cancel_fixture_cancel_at as CancelFixture.cancel_at;

use fun cancel_fixture_claim_at as CancelFixture.claim_at;

use fun cancel_fixture_end as CancelFixture.end;

use fun cancel_fixture_has_payout as CancelFixture.has_payout;

use fun cancel_fixture_next_tx as CancelFixture.next_tx;

use fun cancel_fixture_take_payout as CancelFixture.take_payout;

use fun cancel_fixture_vesting_id as CancelFixture.vesting_id;

use fun claim_fixture_assert_created as ClaimFixture.assert_created;

use fun claim_fixture_claim_at as ClaimFixture.claim_at;

use fun claim_fixture_close as ClaimFixture.close;

use fun claim_fixture_end as ClaimFixture.end;

use fun claim_fixture_next_tx as ClaimFixture.next_tx;

use fun claim_fixture_take_payout as ClaimFixture.take_payout;

use fun claim_fixture_vesting_id as ClaimFixture.vesting_id;

use fun unit_add_checkpoint as UnitFixture.add_checkpoint;

use fun unit_add_checkpoint_range as UnitFixture.add_checkpoint_range;

use fun unit_cancel_with_mismatched_cap as UnitFixture.cancel_with_mismatched_cap;

use fun unit_claim as UnitFixture.claim;

use fun unit_close_irrevocable as UnitFixture.close_irrevocable;

use fun unit_create_cancelable as UnitFixture.create_cancelable;

use fun unit_create_irrevocable as UnitFixture.create_irrevocable;

use fun unit_create_standard as UnitFixture.create_standard;

use fun unit_end as UnitFixture.end;

use fun unit_set_clock as UnitFixture.set_clock;

use fun unit_vested_at as UnitFixture.vested_at;

use fun unit_vested_at_with as UnitFixture.vested_at_with;

use fun unit_vesting_id as UnitFixture.vesting_id;
