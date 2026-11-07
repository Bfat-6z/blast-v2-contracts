// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Fully funded vesting at bounded, immutable cumulative checkpoints.
module blast_fun_vesting::blast_fun_checkpoint_vesting;

// === Constants ===

const MAX_CHECKPOINTS: u64 = 256;

// === Public Types ===

/// One exact cumulative unlock boundary.
public struct Checkpoint has drop, store {
    timestamp_ms: u64,
    cumulative_amount: u64,
}

/// Ability-free builder that must be consumed by a constructor in the creating PTB.
public struct Schedule {
    checkpoints: vector<Checkpoint>,
}

/// Key-only shared custody for one immutable checkpoint schedule.
public struct Vesting<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    beneficiary: address,
    cancel_refund_recipient: Option<address>,
    checkpoints: vector<Checkpoint>,
    released: u64,
}

/// Transferable authority to cancel one exact schedule and return only unvested value.
public struct CancelCap<phantom CoinType> has key, store {
    id: UID,
    vesting_id: ID,
}

// === Public Functions ===

/// Creates an empty schedule that must be populated and consumed in the same PTB.
public fun new_schedule(): Schedule {
    Schedule { checkpoints: vector[] }
}

/// Appends one strictly increasing cumulative unlock boundary.
public fun add(
    self: &mut Schedule,
    timestamp_ms: u64,
    cumulative_amount: u64,
) {
    let length = self.checkpoints.length();
    assert!(length < MAX_CHECKPOINTS, ETooManyCheckpoints);
    if (length == 0) {
        assert!(cumulative_amount > 0, ECheckpointAmountsNotIncreasing);
    } else {
        let previous = &self.checkpoints[length - 1];
        assert!(
            timestamp_ms > previous.timestamp_ms,
            ECheckpointTimesNotIncreasing,
        );
        assert!(
            cumulative_amount > previous.cumulative_amount,
            ECheckpointAmountsNotIncreasing,
        );
    };

    self.checkpoints.push_back(Checkpoint { timestamp_ms, cumulative_amount });
}

/// Creates a fully funded schedule with no cancellation authority.
public fun new_irrevocable<CoinType>(
    funds: Coin<CoinType>,
    beneficiary: address,
    schedule: Schedule,
    clock: &Clock,
    ctx: &mut TxContext,
): Vesting<CoinType> {
    let vesting = new(
        funds,
        beneficiary,
        option::none(),
        schedule,
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
    schedule: Schedule,
    clock: &Clock,
    ctx: &mut TxContext,
): (Vesting<CoinType>, CancelCap<CoinType>) {
    let vesting = new(
        funds,
        beneficiary,
        option::some(refund_recipient),
        schedule,
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

/// Deletes a drained irrevocable schedule. Only the final checkpoint releases the last unit, so
/// a drained schedule has always ended.
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
    schedule: Schedule,
    clock: &Clock,
    ctx: &mut TxContext,
): Vesting<CoinType> {
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(
        cancel_refund_recipient.is_none_or!(|recipient| *recipient != @0x0),
        EInvalidRefundRecipient,
    );
    let total_amount = funds.value();
    assert!(total_amount > 0, EZeroAllocation);
    let Schedule { checkpoints } = schedule;
    assert!(!checkpoints.is_empty(), ENoCheckpoints);
    assert!(checkpoints[0].timestamp_ms >= clock.timestamp_ms(), ECheckpointInPast);
    assert!(
        checkpoints[checkpoints.length() - 1].cumulative_amount == total_amount,
        EFinalAmountMismatch,
    );

    Vesting {
        id: object::new(ctx),
        balance: funds.into_balance(),
        beneficiary,
        cancel_refund_recipient,
        checkpoints,
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
        checkpoint_count: self.checkpoints.length(),
    });
}

fun vested_at<CoinType>(self: &Vesting<CoinType>, timestamp_ms: u64): u64 {
    let mut low = 0;
    let mut high = self.checkpoints.length();
    while (low < high) {
        let middle = low + (high - low) / 2;
        if (self.checkpoints[middle].timestamp_ms <= timestamp_ms) {
            low = middle + 1;
        } else {
            high = middle;
        };
    };
    if (low == 0) {
        0
    } else {
        self.checkpoints[low - 1].cumulative_amount
    }
}

// === Test-Only Functions ===

#[test_only]
public fun vesting_created_fields(
    self: &VestingCreated,
): (ID, TypeName, address, Option<address>, Option<ID>, u64, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.beneficiary,
        self.refund_recipient,
        self.cancel_cap_id,
        self.total_amount,
        self.checkpoint_count,
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
    checkpoint_count: u64,
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
const ENoCheckpoints: vector<u8> = b"Vesting requires at least one checkpoint.";

#[error(code = 4)]
const ETooManyCheckpoints: vector<u8> = b"Vesting supports at most 256 checkpoints.";

#[error(code = 5)]
const ECheckpointInPast: vector<u8> = b"First checkpoint must not precede the current clock time.";

#[error(code = 6)]
const ECheckpointTimesNotIncreasing: vector<u8> = b"Checkpoint times must be strictly increasing.";

#[error(code = 7)]
const ECheckpointAmountsNotIncreasing: vector<u8> = b"Checkpoint amounts must be strictly increasing.";

#[error(code = 8)]
const EFinalAmountMismatch: vector<u8> = b"Final checkpoint amount must equal the funded allocation.";

#[error(code = 9)]
const ENothingClaimable: vector<u8> = b"No vested balance is available to claim.";

#[error(code = 10)]
const EInvalidCancelCap: vector<u8> = b"Cancellation capability does not match this schedule.";

#[error(code = 11)]
const EScheduleNotEmpty: vector<u8> = b"Vesting schedule still holds funds.";

#[error(code = 12)]
const ECancelCapRequired: vector<u8> = b"Cancelable schedule requires its cancellation capability.";

// === Imports ===

use std::type_name::{Self, TypeName};

use sui::{balance::Balance, clock::Clock, coin::Coin, event};
