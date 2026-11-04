// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the payout's abort location.
#[allow(lint(abort_without_constant))]
/// The one way Blast sends coins to people: an amount paid outright, or locked in an irrevocable
/// linear vesting schedule. Each product keeps its own recipient lists and shares.
module blast_core::payout;

// === Public Types ===

/// Linear vesting terms: `periods` equal steps of `period_duration_ms` each, the first available
/// `cliff_delay_ms` after the payout. The whole schedule fits in `max_vesting_duration_ms`.
public struct VestingTerms has copy, drop, store {
    cliff_delay_ms: u64,
    period_duration_ms: u64,
    periods: u64,
}

// === Public Functions ===

/// Linear vesting terms whose steps and cliff fit in the technical bound, so a payout can always
/// create the schedule. Product limits on the duration belong to creation tooling.
public fun vesting_terms(cliff_delay_ms: u64, period_duration_ms: u64, periods: u64): VestingTerms {
    assert!(
        period_duration_ms > 0
            && periods > 0
            && period_duration_ms <= constants::max_vesting_duration_ms!() / periods
            && cliff_delay_ms <= period_duration_ms * periods,
        blast_core::errors::invalid_vesting_terms!(),
    );

    VestingTerms { cliff_delay_ms, period_duration_ms, periods }
}

/// Pays `amount` of `balance` to `destination`: outright, or locked in an irrevocable linear
/// schedule starting now when `vesting` is set, returning the schedule's ID. A zero amount sends
/// nothing.
public fun pay_or_vest<Asset>(
    balance: &mut Balance<Asset>,
    amount: u64,
    destination: address,
    vesting: Option<VestingTerms>,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<ID> {
    if (vesting.is_none() || amount == 0) {
        pay(balance, amount, destination, ctx);
        return option::none()
    };

    let terms = vesting.destroy_some();
    let schedule = linear_vesting::new_irrevocable(
        balance.split(amount).into_coin(ctx),
        destination,
        clock.timestamp_ms(),
        terms.cliff_delay_ms,
        terms.period_duration_ms,
        terms.periods,
        clock,
        ctx,
    );
    let schedule_id = object::id(&schedule);

    schedule.share();

    option::some(schedule_id)
}

/// Transfers `amount` split from `balance` to `destination` as a coin; a zero amount sends
/// nothing.
public fun pay<Asset>(
    balance: &mut Balance<Asset>,
    amount: u64,
    destination: address,
    ctx: &mut TxContext,
) {
    if (amount == 0) return;

    transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
}

/// Transfers all of `balance` to `destination`; an empty balance sends nothing.
public fun pay_all<Asset>(mut balance: Balance<Asset>, destination: address, ctx: &mut TxContext) {
    let amount = balance.value();
    pay(&mut balance, amount, destination, ctx);
    balance.destroy_zero();
}

// === Imports ===

use blast_core::constants;

use blast_fun_vesting::blast_fun_linear_vesting as linear_vesting;

use sui::{balance::Balance, clock::Clock};
