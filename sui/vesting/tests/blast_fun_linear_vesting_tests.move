// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_vesting::blast_fun_linear_vesting_tests;

// === Constants ===

const FUNDER: address = @0xF00D;

const BENEFICIARY: address = @0xB0B;

const REFUND_RECIPIENT: address = @0xCAFE;

const CALLER: address = @0xC11;

const CANCELER: address = @0xCA11;

const TOTAL_AMOUNT: u64 = 1_001;

const START_MS: u64 = 100;

const CLIFF_MS: u64 = 200;

const PERIOD_MS: u64 = 100;

const PERIODS: u64 = 4;

// === Test-Only Types ===

public struct TEST_COIN() has drop;

/// Single-transaction construction, vector probes, and focused failure paths.
public struct UnitFixture {
    scenario: Scenario,
    clock: Clock,
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
fun vested_value_matches_the_vectors_at_every_boundary() {
    let mut fixture = start_unit(0);

    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 99), 0);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 100), 0);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 299), 0);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 300), 500);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 399), 500);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 400), 750);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 499), 750);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 500), TOTAL_AMOUNT);
    assert_eq!(fixture.vested_at(START_MS, CLIFF_MS, 10_000), TOTAL_AMOUNT);

    fixture.end();
}

#[test]
fun cliff_between_period_boundaries_releases_every_elapsed_period() {
    let mut fixture = start_unit(0);

    assert_eq!(fixture.vested_at(START_MS, 250, 349), 0);
    assert_eq!(fixture.vested_at(START_MS, 250, 350), 500);
    assert_eq!(fixture.vested_at(START_MS, 250, 399), 500);
    assert_eq!(fixture.vested_at(START_MS, 250, 400), 750);

    fixture.end();
}

#[test]
fun cliff_equal_to_the_duration_releases_everything_at_the_end() {
    let mut fixture = start_unit(0);

    assert_eq!(fixture.vested_at(START_MS, PERIOD_MS * PERIODS, 499), 0);
    assert_eq!(fixture.vested_at(START_MS, PERIOD_MS * PERIODS, 500), TOTAL_AMOUNT);

    fixture.end();
}

#[test]
fun maximum_width_schedule_uses_wide_multiplication() {
    let max = std::u64::max_value!();
    let mut fixture = start_unit(0);

    assert_eq!(fixture.vested_at_with(max, 0, 0, 1, max, max - 1), max - 1);
    assert_eq!(fixture.vested_at_with(max, 0, 0, 1, max, max), max);

    fixture.end();
}

#[test]
fun irrevocable_lifecycle_releases_each_period_and_replays_events() {
    let mut fixture = start_claim();
    let mut claimed = 0;

    fixture.next_tx!(CALLER, |f| {
        f.assert_created();

        f.claim_at(300);

        let event = collect_one<VestingClaimed>();
        let (vesting_id, coin_type, beneficiary, amount, released_total) =
            event.vesting_claimed_fields();
        assert_eq!(vesting_id, f.vesting_id());
        assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(amount, 500);
        assert_eq!(released_total, 500);
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), 500);
    });

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(400);

        let event = collect_one<VestingClaimed>();
        let (_, _, _, amount, released_total) = event.vesting_claimed_fields();
        assert_eq!(amount, 250);
        assert_eq!(released_total, 750);
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), 250);
    });

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(500);
        f.close();

        let event = collect_one<VestingClaimed>();
        let (_, _, _, amount, released_total) = event.vesting_claimed_fields();
        let closed = collect_one<VestingClosed>();
        let (closed_id, coin_type) = closed.vesting_closed_fields();
        assert_eq!(amount, 251);
        assert_eq!(released_total, TOTAL_AMOUNT);
        assert_eq!(closed_id, f.vesting_id());
        assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), 251);
    });

    let (_, _, _, _, _, total_amount, _, _, _, _) = fixture.created.vesting_created_fields();
    assert_eq!(claimed, total_amount);

    fixture.end();
}

#[test]
fun cancelable_schedule_preserves_prior_and_unclaimed_vested_value() {
    let mut fixture = start_cancel();
    let mut claimed = 0;

    fixture.next_tx!(CALLER, |f| {
        f.assert_created();

        f.claim_at(200);

        let event = collect_one<VestingClaimed>();
        let (_, _, _, amount, released_total) = event.vesting_claimed_fields();
        assert_eq!(amount, 250);
        assert_eq!(released_total, 250);
        claimed = claimed + amount;
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), 250);
    });

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(350);

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
        let (_, _, _, _, _, total_amount, _, _, _, _) = f.created.vesting_created_fields();

        assert_eq!(vesting_id, f.vesting_id());
        assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(refund_recipient, REFUND_RECIPIENT);
        assert_eq!(beneficiary_amount, 250);
        assert_eq!(refund_amount, 501);
        assert_eq!(released_total, 500);
        assert_eq!(released_total, claimed + beneficiary_amount);
        assert_eq!(claimed + beneficiary_amount + refund_amount, total_amount);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), 250);
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_payout(), 501);
    });

    fixture.end();
}

#[test]
fun cancellation_after_a_claim_in_the_same_period_pays_only_the_refund() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(200);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_payout(), 250);
    });

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(299);

        let canceled = collect_one<VestingCanceled>();
        let (_, _, _, _, beneficiary_amount, refund_amount, released_total) =
            canceled.vesting_canceled_fields();
        assert_eq!(beneficiary_amount, 0);
        assert_eq!(refund_amount, 751);
        assert_eq!(released_total, 250);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert!(!f.has_payout());
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_payout(), 751);
    });

    fixture.end();
}

#[test]
fun cancellation_before_the_first_period_returns_the_full_allocation() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(START_MS);

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
fun cancellation_after_full_vesting_has_no_refund() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(START_MS + PERIOD_MS * PERIODS);

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
    fixture.create_irrevocable(TOTAL_AMOUNT, BENEFICIARY, 0, 0, 1, 4);
    fixture.create_irrevocable(10, REFUND_RECIPIENT, 0, 0, 1, 2);
    let first_id = fixture.vesting_id(0);
    let second_id = fixture.vesting_id(1);
    fixture.set_clock(1);

    fixture.claim(1);
    fixture.claim(0);

    let created = event::events_by_type<VestingCreated>();
    let (id, _, beneficiary, _, _, total_amount, _, _, _, periods) =
        created[0].vesting_created_fields();
    assert_eq!(id, first_id);
    assert_eq!(beneficiary, BENEFICIARY);
    assert_eq!(total_amount, TOTAL_AMOUNT);
    assert_eq!(periods, 4);
    let (id, _, beneficiary, _, _, total_amount, _, _, _, periods) =
        created[1].vesting_created_fields();
    assert_eq!(id, second_id);
    assert_eq!(beneficiary, REFUND_RECIPIENT);
    assert_eq!(total_amount, 10);
    assert_eq!(periods, 2);

    let claimed = event::events_by_type<VestingClaimed>();
    let (id, _, beneficiary, amount, released_total) = claimed[0].vesting_claimed_fields();
    assert_eq!(id, second_id);
    assert_eq!(beneficiary, REFUND_RECIPIENT);
    assert_eq!(amount, 5);
    assert_eq!(released_total, 5);
    let (id, _, beneficiary, amount, released_total) = claimed[1].vesting_claimed_fields();
    assert_eq!(id, first_id);
    assert_eq!(beneficiary, BENEFICIARY);
    assert_eq!(amount, 250);
    assert_eq!(released_total, 250);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidBeneficiary,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_beneficiary_before_zero_refund_recipient() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(0, @0x0, @0x0, 0, 0, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidRefundRecipient,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun cancelable_constructor_rejects_zero_refund_before_zero_allocation() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(0, BENEFICIARY, @0x0, 0, 0, PERIOD_MS, PERIODS);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EZeroAllocation,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_allocation_before_zero_period() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(0, BENEFICIARY, 0, 0, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EZeroPeriod,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_period_before_zero_period_count() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EZeroPeriods,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_period_count_before_a_past_start() {
    let mut fixture = start_unit(100);
    fixture.create_irrevocable(1, BENEFICIARY, 99, 0, 1, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EStartInPast,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_a_past_start_before_duration_overflow() {
    let mut fixture = start_unit(100);
    fixture.create_irrevocable(1, BENEFICIARY, 99, 0, std::u64::max_value!(), 2);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleOverflow,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_duration_multiplication_overflow() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, std::u64::max_value!(), 2);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidCliff,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_cliff_after_end_before_end_time_overflow() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, std::u64::max_value!(), 5, 1, 4);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleOverflow,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_end_time_overflow() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, std::u64::max_value!(), 0, 1, 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun claim_rejects_zero_release_before_the_cliff() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(TOTAL_AMOUNT, BENEFICIARY, START_MS, CLIFF_MS, PERIOD_MS, PERIODS);
    fixture.set_clock(299);

    fixture.claim(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun claim_rejects_a_repeat_claim_in_the_same_period() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(TOTAL_AMOUNT, BENEFICIARY, START_MS, CLIFF_MS, PERIOD_MS, PERIODS);
    fixture.set_clock(300);
    fixture.claim(0);
    fixture.set_clock(399);

    fixture.claim(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun claim_rejects_a_drained_schedule() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(TOTAL_AMOUNT, BENEFICIARY, START_MS, CLIFF_MS, PERIOD_MS, PERIODS);
    fixture.set_clock(500);
    fixture.claim(0);
    fixture.set_clock(600);

    fixture.claim(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidCancelCap,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun cancellation_rejects_a_cap_for_another_schedule() {
    let mut fixture = start_unit(0);
    fixture.cancel_with_mismatched_cap();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleNotEmpty,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun close_rejects_a_schedule_before_its_end() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, 1, 1);

    fixture.close_irrevocable(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleNotEmpty,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun close_rejects_unclaimed_custody_after_the_end() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, 1, 1);
    fixture.set_clock(1);

    fixture.close_irrevocable(0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ECancelCapRequired,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun irrevocable_close_rejects_a_cancellable_schedule_before_the_balance_check() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(1, BENEFICIARY, REFUND_RECIPIENT, 0, 0, 1, 1);

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

fun start_unit(timestamp_ms: u64): UnitFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(timestamp_ms);

    UnitFixture {
        scenario,
        clock,
        vestings: vector[],
        cancel_cap: option::none(),
    }
}

fun unit_create_irrevocable(
    self: &mut UnitFixture,
    amount: u64,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let vesting = linear::new_irrevocable(
        funds,
        beneficiary,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        &self.clock,
        self.scenario.ctx(),
    );
    self.vestings.push_back(vesting);
}

fun unit_create_cancelable(
    self: &mut UnitFixture,
    amount: u64,
    beneficiary: address,
    refund_recipient: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let (vesting, cancel_cap) = linear::new_cancelable(
        funds,
        beneficiary,
        refund_recipient,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        &self.clock,
        self.scenario.ctx(),
    );
    self.vestings.push_back(vesting);
    self.cancel_cap.fill(cancel_cap);
}

/// The standard schedule's vested value at `timestamp_ms` for `start_ms` and `cliff_ms`.
fun unit_vested_at(
    self: &mut UnitFixture,
    start_ms: u64,
    cliff_ms: u64,
    timestamp_ms: u64,
): u64 {
    self.vested_at_with(TOTAL_AMOUNT, start_ms, cliff_ms, PERIOD_MS, PERIODS, timestamp_ms)
}

/// Observes a schedule's vested value at `timestamp_ms` through the public API: cancellation
/// reports it as `released_total`. Each probe runs on its own clock, which starts at zero.
fun unit_vested_at_with(
    self: &mut UnitFixture,
    amount: u64,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    timestamp_ms: u64,
): u64 {
    let mut clock = clock::create_for_testing(self.scenario.ctx());
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let (vesting, cancel_cap) = linear::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
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
    self.create_cancelable(1, BENEFICIARY, REFUND_RECIPIENT, 0, 0, 1, 1);
    let first_cap = self.cancel_cap.extract();
    self.create_cancelable(1, BENEFICIARY, REFUND_RECIPIENT, 0, 0, 1, 1);

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
    let vesting = linear::new_irrevocable(
        funds,
        BENEFICIARY,
        START_MS,
        CLIFF_MS,
        PERIOD_MS,
        PERIODS,
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
    let (vesting, cancel_cap) = linear::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        START_MS,
        0,
        PERIOD_MS,
        PERIODS,
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
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    ) = self.created.vesting_created_fields();

    assert_eq!(vesting_id, self.vesting_id);
    assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
    assert_eq!(beneficiary, BENEFICIARY);
    assert!(refund_recipient.is_none());
    assert!(cancel_cap_id.is_none());
    assert_eq!(total_amount, TOTAL_AMOUNT);
    assert_eq!(start_ms, START_MS);
    assert_eq!(cliff_ms, CLIFF_MS);
    assert_eq!(period_ms, PERIOD_MS);
    assert_eq!(periods, PERIODS);
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
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    ) = self.created.vesting_created_fields();

    assert_eq!(vesting_id, self.vesting_id);
    assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
    assert_eq!(beneficiary, BENEFICIARY);
    assert_eq!(refund_recipient, option::some(REFUND_RECIPIENT));
    assert_eq!(cancel_cap_id, option::some(self.cancel_cap_id));
    assert_eq!(total_amount, TOTAL_AMOUNT);
    assert_eq!(start_ms, START_MS);
    assert_eq!(cliff_ms, 0);
    assert_eq!(period_ms, PERIOD_MS);
    assert_eq!(periods, PERIODS);
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

use blast_fun_vesting::blast_fun_linear_vesting::{
    Self as linear,
    CancelCap,
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

use fun unit_cancel_with_mismatched_cap as UnitFixture.cancel_with_mismatched_cap;

use fun unit_claim as UnitFixture.claim;

use fun unit_close_irrevocable as UnitFixture.close_irrevocable;

use fun unit_create_cancelable as UnitFixture.create_cancelable;

use fun unit_create_irrevocable as UnitFixture.create_irrevocable;

use fun unit_end as UnitFixture.end;

use fun unit_set_clock as UnitFixture.set_clock;

use fun unit_vested_at as UnitFixture.vested_at;

use fun unit_vested_at_with as UnitFixture.vested_at_with;

use fun unit_vesting_id as UnitFixture.vesting_id;
