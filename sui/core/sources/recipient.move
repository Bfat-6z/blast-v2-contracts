// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the recipient's abort location.
#[allow(lint(abort_without_constant))]
/// The one way Blast sends coins to people: a recipient's share, its optional linear vesting, and
/// the payout that pays it or locks it in an irrevocable schedule.
module blast_core::recipient;

// === Public Types ===

/// Linear vesting terms: `periods` equal steps of `period_duration_ms` each, the first available
/// `cliff_delay_ms` after the payout. The whole schedule fits in `max_vesting_duration_ms`.
public struct VestingTerms has copy, drop, store {
    cliff_delay_ms: u64,
    period_duration_ms: u64,
    periods: u64,
}

/// One nonzero address's share, in basis points, of an amount a product divides, paid outright or
/// vested under `vesting`.
public struct Recipient has copy, drop, store {
    destination: address,
    bps: Bps,
    vesting: Option<VestingTerms>,
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

/// A recipient paid outright.
public fun new(destination: address, bps: Bps): Recipient {
    assert!(destination != @0x0, blast_core::errors::invalid_recipient!());

    Recipient { destination, bps, vesting: option::none() }
}

/// A recipient whose payout vests under `vesting`.
public fun vested(destination: address, bps: Bps, vesting: VestingTerms): Recipient {
    assert!(destination != @0x0, blast_core::errors::invalid_recipient!());

    Recipient { destination, bps, vesting: option::some(vesting) }
}

/// Checks a recipient list: at most `max` recipients, each with a positive share, no address
/// twice, and none vested unless `allow_vesting`.
public fun assert_valid(recipients: &vector<Recipient>, max: u64, allow_vesting: bool) {
    assert!(
        recipients.length() <= max
            && recipients.all!(|recipient| {
                recipient.bps.value() > 0
                    && (allow_vesting || recipient.vesting.is_none())
                    // Duplicate validation is O(n²), bounded by `max`.
                    && recipients.count!(|other| other.destination == recipient.destination) == 1
            }),
        blast_core::errors::invalid_recipients!(),
    );
}

/// The rates of `recipients`, in order, for apportionment.
public fun rates(recipients: &vector<Recipient>): vector<Bps> {
    recipients.map_ref!(|recipient| recipient.bps)
}

/// Pays `amount` of `balance` to `recipient`: outright, or locked in an irrevocable linear
/// schedule starting now when it vests, returning the schedule's ID. A zero amount sends nothing.
public fun pay_or_vest<T>(
    balance: &mut Balance<T>,
    recipient: &Recipient,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<ID> {
    if (recipient.vesting.is_none() || amount == 0) {
        pay(balance, amount, recipient.destination, ctx);
        return option::none()
    };

    let terms = recipient.vesting.destroy_some();
    let schedule = linear_vesting::new_irrevocable(
        balance.split(amount).into_coin(ctx),
        recipient.destination,
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
public fun pay<T>(
    balance: &mut Balance<T>,
    amount: u64,
    destination: address,
    ctx: &mut TxContext,
) {
    if (amount == 0) return;

    transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
}

/// Transfers all of `balance` to `destination`; an empty balance sends nothing.
public fun pay_all<T>(mut balance: Balance<T>, destination: address, ctx: &mut TxContext) {
    let amount = balance.value();
    pay(&mut balance, amount, destination, ctx);
    balance.destroy_zero();
}

public fun destination(self: &Recipient): address { self.destination }

public fun bps(self: &Recipient): Bps { self.bps }

public fun vesting(self: &Recipient): Option<VestingTerms> { self.vesting }

public fun cliff_delay_ms(self: &VestingTerms): u64 { self.cliff_delay_ms }

public fun period_duration_ms(self: &VestingTerms): u64 { self.period_duration_ms }

public fun periods(self: &VestingTerms): u64 { self.periods }

// === Imports ===

use blast_core::{bps::Bps, constants};

use blast_fun_vesting::blast_fun_linear_vesting as linear_vesting;

use sui::{balance::Balance, clock::Clock};
