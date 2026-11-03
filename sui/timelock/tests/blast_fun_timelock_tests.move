// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_timelock::blast_fun_timelock_tests;

// === Constants ===

const DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const ELEVEN_YEARS_MS: u64 = 11 * 365 * 24 * 60 * 60 * 1_000;
const START_MS: u64 = 1_000;

// === Tests ===

#[test]
fun a_new_value_is_in_force_at_once_with_nothing_scheduled() {
    let clock = start();
    let locked = timelock::new(5u64, DELAY_MS);

    assert_eq!(locked.value(&clock), 5);
    assert_eq!(locked.scheduled(), 5);
    assert_eq!(vector[locked.scheduled_at_ms(), locked.delay_ms()], vector[0, DELAY_MS]);

    end(clock);
}

#[test]
/// One millisecond before the delay ends the old value is in force; from the end on the new one is.
fun a_scheduled_value_takes_effect_exactly_after_the_delay() {
    let mut clock = start();
    let mut locked = timelock::new(5u64, DELAY_MS);

    locked.schedule(9, &clock);

    assert_eq!(locked.scheduled(), 9);
    assert_eq!(locked.scheduled_at_ms(), START_MS + DELAY_MS);
    clock.set_for_testing(START_MS + DELAY_MS - 1);
    assert_eq!(locked.value(&clock), 5);
    clock.set_for_testing(START_MS + DELAY_MS);
    assert_eq!(locked.value(&clock), 9);
    clock.increment_for_testing(1);
    assert_eq!(locked.value(&clock), 9);
    clock.increment_for_testing(10 * DELAY_MS);
    assert_eq!(locked.value(&clock), 9);

    end(clock);
}

#[test]
/// A new schedule keeps the value in force and restarts the delay.
fun a_new_schedule_replaces_a_pending_one_and_restarts_the_delay() {
    let mut clock = start();
    let mut locked = timelock::new(5u64, DELAY_MS);
    locked.schedule(9, &clock);
    clock.increment_for_testing(DELAY_MS - 1);

    locked.schedule(7, &clock);

    let rescheduled_at = clock.timestamp_ms();
    clock.set_for_testing(rescheduled_at + DELAY_MS - 1);
    assert_eq!(locked.value(&clock), 5);
    clock.set_for_testing(rescheduled_at + DELAY_MS);
    assert_eq!(locked.value(&clock), 7);

    end(clock);
}

#[test]
fun scheduling_the_value_in_force_cancels_a_pending_change() {
    let mut clock = start();
    let mut locked = timelock::new(5u64, DELAY_MS);
    locked.schedule(9, &clock);

    locked.schedule(5, &clock);

    assert_eq!(vector[locked.value(&clock), locked.scheduled()], vector[5, 5]);
    assert_eq!(locked.scheduled_at_ms(), START_MS + DELAY_MS);
    clock.increment_for_testing(10 * DELAY_MS);
    assert_eq!(locked.value(&clock), 5);

    end(clock);
}

#[test]
/// Once a change has taken effect, the next schedule starts from it.
fun a_schedule_after_the_switch_starts_from_the_new_value() {
    let mut clock = start();
    let mut locked = timelock::new(5u64, DELAY_MS);
    locked.schedule(9, &clock);
    clock.increment_for_testing(DELAY_MS);

    locked.schedule(3, &clock);

    assert_eq!(locked.value(&clock), 9);
    clock.increment_for_testing(DELAY_MS);
    assert_eq!(locked.value(&clock), 3);

    end(clock);
}

#[test]
fun the_shortest_and_largest_delays_are_accepted() {
    let mut clock = start();
    let mut shortest = timelock::new(@0xA, 1);
    let largest = timelock::new(@0xA, std::u64::max_value!());

    shortest.schedule(@0xB, &clock);

    assert_eq!(shortest.value(&clock), @0xA);
    clock.increment_for_testing(1);
    assert_eq!(shortest.value(&clock), @0xB);
    assert_eq!(largest.delay_ms(), std::u64::max_value!());

    end(clock);
}

#[test]
/// A generic timelock does not impose a product-policy ceiling on its delay.
fun a_delay_above_ten_years_is_accepted() {
    let clock = start();
    let mut locked = timelock::new(5u64, ELEVEN_YEARS_MS);

    locked.schedule(9, &clock);

    assert_eq!(locked.delay_ms(), ELEVEN_YEARS_MS);
    assert_eq!(locked.scheduled_at_ms(), START_MS + ELEVEN_YEARS_MS);

    end(clock);
}

#[test]
/// Scheduling the pending value again is a new schedule: it restarts the delay.
fun rescheduling_the_pending_value_restarts_the_delay() {
    let mut clock = start();
    let mut locked = timelock::new(5u64, DELAY_MS);
    locked.schedule(9, &clock);
    clock.increment_for_testing(DELAY_MS - 1);

    locked.schedule(9, &clock);

    clock.increment_for_testing(1);
    assert_eq!(locked.value(&clock), 5);
    clock.set_for_testing(START_MS + DELAY_MS - 1 + DELAY_MS);
    assert_eq!(locked.value(&clock), 9);

    end(clock);
}

#[test]
/// Several schedules in one instant keep the value in force and leave the last one pending.
fun several_schedules_in_one_instant_leave_the_last_pending() {
    let mut clock = start();
    let mut locked = timelock::new(5u64, DELAY_MS);

    locked.schedule(9, &clock);
    locked.schedule(7, &clock);

    assert_eq!(vector[locked.value(&clock), locked.scheduled()], vector[5, 7]);
    clock.increment_for_testing(DELAY_MS);
    assert_eq!(locked.value(&clock), 7);

    end(clock);
}

#[test]
/// Any value with copy, drop and store works, for example a vector.
fun a_timelocked_vector_switches_whole() {
    let mut clock = start();
    let mut locked = timelock::new(vector[1u8, 2], DELAY_MS);

    locked.schedule(vector[3u8], &clock);

    assert_eq!(locked.value(&clock), vector[1u8, 2]);
    clock.increment_for_testing(DELAY_MS);
    assert_eq!(locked.value(&clock), vector[3u8]);

    end(clock);
}

#[test]
/// A copy is a separate value: scheduling it leaves the original untouched.
fun a_copy_schedules_independently_of_the_original() {
    let mut clock = start();
    let original = timelock::new(5u64, DELAY_MS);
    let mut duplicate = original;

    duplicate.schedule(9, &clock);

    clock.increment_for_testing(DELAY_MS);
    assert_eq!(vector[original.value(&clock), duplicate.value(&clock)], vector[5, 9]);

    end(clock);
}

#[test]
/// The largest delay that fits from the current instant schedules without overflow.
fun the_largest_delay_that_fits_schedules_at_u64_max() {
    let mut clock = start();
    let max_delay = std::u64::max_value!() - START_MS;
    let mut locked = timelock::new(5u64, max_delay);

    locked.schedule(9, &clock);

    assert_eq!(locked.scheduled_at_ms(), std::u64::max_value!());
    assert_eq!(locked.value(&clock), 5);
    clock.set_for_testing(std::u64::max_value!());
    assert_eq!(locked.value(&clock), 9);

    end(clock);
}

#[test]
/// The test constructor builds a value mid-change, for dependents' own tests.
fun a_value_can_be_built_mid_change_for_tests() {
    let mut clock = start();
    let locked = timelock::new_scheduled_for_testing(5u64, 9, START_MS + 1, DELAY_MS);

    assert_eq!(locked.value(&clock), 5);
    clock.increment_for_testing(1);
    assert_eq!(locked.value(&clock), 9);

    end(clock);
}

#[test]
/// With the clock at zero a new value is in force and a schedule waits the whole delay.
fun a_schedule_at_clock_zero_takes_effect_at_the_delay() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut locked = timelock::new(5u64, DELAY_MS);
    assert_eq!(locked.value(&clock), 5);

    locked.schedule(9, &clock);

    assert_eq!(locked.scheduled_at_ms(), DELAY_MS);
    clock.set_for_testing(DELAY_MS - 1);
    assert_eq!(locked.value(&clock), 5);
    clock.set_for_testing(DELAY_MS);
    assert_eq!(locked.value(&clock), 9);

    end(clock);
}

#[test]
#[expected_failure(arithmetic_error, location = blast_fun_timelock::blast_fun_timelock)]
/// The only way `schedule` aborts: a Clock within the delay of `u64::MAX`.
fun a_schedule_whose_end_would_not_fit_in_a_u64_aborts() {
    let clock = start();
    let overflowing_delay = std::u64::max_value!() - START_MS + 1;
    let mut locked = timelock::new(5u64, overflowing_delay);

    locked.schedule(9, &clock);

    end(clock);
}

#[test]
#[expected_failure(
    abort_code = timelock::EInvalidDelay,
    location = blast_fun_timelock::blast_fun_timelock,
)]
/// The test constructor refuses the delays `new` refuses, so fixtures match production.
fun the_test_constructor_refuses_a_zero_delay() {
    timelock::new_scheduled_for_testing(5u64, 9, 0, 0);
}

#[test]
#[expected_failure(
    abort_code = timelock::EInvalidDelay,
    location = blast_fun_timelock::blast_fun_timelock,
)]
fun a_zero_delay_is_refused() {
    timelock::new(5u64, 0);
}

// === Test Helpers ===

fun start(): Clock {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(START_MS);

    clock
}

fun end(clock: Clock) {
    clock.destroy_for_testing();
}

// === Imports ===

use blast_fun_timelock::blast_fun_timelock as timelock;

use std::unit_test::assert_eq;

use sui::clock::{Self, Clock};
