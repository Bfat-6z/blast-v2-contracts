// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Fully funded, fixed-beneficiary stepped-linear vesting.
module blast_fun_vesting::blast_fun_linear_vesting;

// === Public Types ===

/// Key-only shared custody for one immutable vesting schedule.
public struct Vesting<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    beneficiary: address,
    cancel_refund_recipient: Option<address>,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    released: u64,
}

/// Transferable authority to cancel one exact schedule and return only unvested value.
public struct CancelCap<phantom CoinType> has key, store {
    id: UID,
    vesting_id: ID,
}

// === Public Functions ===

/// Creates a fully funded schedule with no cancellation authority.
public fun new_irrevocable<CoinType>(
    funds: Coin<CoinType>,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Vesting<CoinType> {
    let vesting = new(
        funds,
        beneficiary,
        option::none(),
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        clock,
        ctx,
    );

    vesting.emit_created(option::none());

    vesting
}

/// Creates a fully funded schedule and its exact cancellation capability.
public fun new_cancelable<CoinType>(
    funds: Coin<CoinType>,
    beneficiary: address,
    refund_recipient: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Vesting<CoinType>, CancelCap<CoinType>) {
    let vesting = new(
        funds,
        beneficiary,
        option::some(refund_recipient),
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        clock,
        ctx,
    );
    let cancel_cap = CancelCap {
        id: object::new(ctx),
        vesting_id: vesting.id.to_inner(),
    };

    vesting.emit_created(option::some(cancel_cap.id.to_inner()));

    (vesting, cancel_cap)
}

/// Publishes a newly constructed schedule as top-level shared state.
public fun share<CoinType>(self: Vesting<CoinType>) {
    transfer::share_object(self);
}

/// Transfers all newly vested value to the fixed beneficiary.
public fun claim<CoinType>(
    self: &mut Vesting<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = self.vested_at(clock.timestamp_ms()) - self.released;
    assert!(amount > 0, ENothingClaimable);

    self.released = self.released + amount;
    transfer::public_transfer(self.balance.split(amount).into_coin(ctx), self.beneficiary);

    event::emit(VestingClaimed {
        vesting_id: self.id.to_inner(),
        coin_type: type_name::with_original_ids<CoinType>(),
        beneficiary: self.beneficiary,
        amount,
        released_total: self.released,
    });
}

/// Settles vested value to the beneficiary and unvested value to the fixed refund recipient.
public fun cancel<CoinType>(
    self: Vesting<CoinType>,
    cap: CancelCap<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(cap.vesting_id == self.id.to_inner(), EInvalidCancelCap);

    let vested_total = self.vested_at(clock.timestamp_ms());
    let beneficiary_amount = vested_total - self.released;
    let Vesting {
        id,
        mut balance,
        beneficiary,
        cancel_refund_recipient,
        ..
    } = self;
    // A matching cap can only be minted by `new_cancelable`, which stores `Some`.
    let refund_recipient = cancel_refund_recipient.destroy_some();
    let refund_amount = balance.value() - beneficiary_amount;
    let CancelCap { id: cap_id, vesting_id: _ } = cap;

    if (beneficiary_amount > 0) {
        transfer::public_transfer(balance.split(beneficiary_amount).into_coin(ctx), beneficiary);
    };
    if (refund_amount > 0) {
        transfer::public_transfer(balance.split(refund_amount).into_coin(ctx), refund_recipient);
    };

    event::emit(VestingCanceled {
        vesting_id: id.to_inner(),
        coin_type: type_name::with_original_ids<CoinType>(),
        beneficiary,
        refund_recipient,
        beneficiary_amount,
        refund_amount,
        released_total: vested_total,
    });

    balance.destroy_zero();
    id.delete();
    cap_id.delete();
}

/// Deletes a drained irrevocable schedule. Only the final vesting boundary releases the last
/// unit, so a drained schedule has always ended.
public fun close_irrevocable<CoinType>(self: Vesting<CoinType>) {
    assert!(self.cancel_refund_recipient.is_none(), ECancelCapRequired);
    assert!(self.balance.value() == 0, EScheduleNotEmpty);

    let Vesting {
        id,
        balance,
        ..
    } = self;

    event::emit(VestingClosed {
        vesting_id: id.to_inner(),
        coin_type: type_name::with_original_ids<CoinType>(),
    });

    balance.destroy_zero();
    id.delete();
}

// === Private Functions ===

fun new<CoinType>(
    funds: Coin<CoinType>,
    beneficiary: address,
    cancel_refund_recipient: Option<address>,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Vesting<CoinType> {
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(
        cancel_refund_recipient.is_none_or!(|recipient| *recipient != @0x0),
        EInvalidRefundRecipient,
    );
    assert!(funds.value() > 0, EZeroAllocation);
    assert!(period_ms > 0, EZeroPeriod);
    assert!(periods > 0, EZeroPeriods);
    assert!(start_ms >= clock.timestamp_ms(), EStartInPast);

    let max = std::u64::max_value!();
    assert!(period_ms <= max / periods, EScheduleOverflow);
    let duration_ms = period_ms * periods;
    assert!(cliff_ms <= duration_ms, EInvalidCliff);
    assert!(duration_ms <= max - start_ms, EScheduleOverflow);

    Vesting {
        id: object::new(ctx),
        balance: funds.into_balance(),
        beneficiary,
        cancel_refund_recipient,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        released: 0,
    }
}

fun emit_created<CoinType>(self: &Vesting<CoinType>, cancel_cap_id: Option<ID>) {
    event::emit(VestingCreated {
        vesting_id: self.id.to_inner(),
        coin_type: type_name::with_original_ids<CoinType>(),
        beneficiary: self.beneficiary,
        refund_recipient: self.cancel_refund_recipient,
        cancel_cap_id,
        total_amount: self.balance.value(),
        start_ms: self.start_ms,
        cliff_ms: self.cliff_ms,
        period_ms: self.period_ms,
        periods: self.periods,
    });
}

fun vested_at<CoinType>(self: &Vesting<CoinType>, timestamp_ms: u64): u64 {
    // Creation bounds `start_ms + cliff_ms` by the end time, so the sum cannot overflow.
    if (timestamp_ms < self.start_ms + self.cliff_ms) {
        return 0
    };

    // Conservation keeps this sum equal to the original u64 funding amount.
    let total_amount = self.balance.value() + self.released;
    if (timestamp_ms >= self.start_ms + self.period_ms * self.periods) {
        return total_amount
    };

    let elapsed_periods = (timestamp_ms - self.start_ms) / self.period_ms;
    total_amount.mul_div(elapsed_periods, self.periods)
}

// === Test-Only Functions ===

#[test_only]
public fun vesting_created_fields(
    self: &VestingCreated,
): (ID, TypeName, address, Option<address>, Option<ID>, u64, u64, u64, u64, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.beneficiary,
        self.refund_recipient,
        self.cancel_cap_id,
        self.total_amount,
        self.start_ms,
        self.cliff_ms,
        self.period_ms,
        self.periods,
    )
}

#[test_only]
public fun vesting_claimed_fields(self: &VestingClaimed): (ID, TypeName, address, u64, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.beneficiary,
        self.amount,
        self.released_total,
    )
}

#[test_only]
public fun vesting_canceled_fields(
    self: &VestingCanceled,
): (ID, TypeName, address, address, u64, u64, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.beneficiary,
        self.refund_recipient,
        self.beneficiary_amount,
        self.refund_amount,
        self.released_total,
    )
}

#[test_only]
public fun vesting_closed_fields(self: &VestingClosed): (ID, TypeName) {
    (self.vesting_id, self.coin_type)
}

// === Events ===

/// Emitted after one fully funded schedule and any cancellation cap are created.
public struct VestingCreated has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    beneficiary: address,
    refund_recipient: Option<address>,
    cancel_cap_id: Option<ID>,
    total_amount: u64,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
}

/// Emitted after newly vested value is transferred to the fixed beneficiary.
public struct VestingClaimed has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    beneficiary: address,
    amount: u64,
    released_total: u64,
}

/// Emitted after fair cancellation settles vested and unvested custody.
public struct VestingCanceled has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    beneficiary: address,
    refund_recipient: address,
    beneficiary_amount: u64,
    refund_amount: u64,
    released_total: u64,
}

/// Emitted after a drained irrevocable schedule is deleted.
public struct VestingClosed has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
}

// === Errors ===

#[error(code = 0)]
const EInvalidBeneficiary: vector<u8> = b"Beneficiary must not be the zero address.";

#[error(code = 1)]
const EInvalidRefundRecipient: vector<u8> = b"Refund recipient must not be the zero address.";

#[error(code = 2)]
const EZeroAllocation: vector<u8> = b"Vesting allocation must be greater than zero.";

#[error(code = 3)]
const EZeroPeriod: vector<u8> = b"Vesting period must be greater than zero.";

#[error(code = 4)]
const EZeroPeriods: vector<u8> = b"Vesting period count must be greater than zero.";

#[error(code = 5)]
const EInvalidCliff: vector<u8> = b"Cliff must not exceed the vesting duration.";

#[error(code = 6)]
const EScheduleOverflow: vector<u8> = b"Vesting schedule exceeds the u64 time range.";

#[error(code = 7)]
const ENothingClaimable: vector<u8> = b"No vested balance is available to claim.";

#[error(code = 8)]
const EInvalidCancelCap: vector<u8> = b"Cancellation capability does not match this schedule.";

#[error(code = 9)]
const EScheduleNotEmpty: vector<u8> = b"Vesting schedule still holds funds.";

#[error(code = 10)]
const ECancelCapRequired: vector<u8> = b"Cancelable schedule requires its cancellation capability.";

#[error(code = 11)]
const EStartInPast: vector<u8> = b"Vesting start must not precede the current clock time.";

// === Imports ===

use std::type_name::{Self, TypeName};

use sui::{balance::Balance, clock::Clock, coin::Coin, event};
