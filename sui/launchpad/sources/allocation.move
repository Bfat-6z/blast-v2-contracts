// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the allocation owner's abort location.
#[allow(lint(abort_without_constant))]
/// Migration allocation plans and their exact apportionment.
module blast_fun::allocation;

// === Public Types ===

/// One payee at migration, paid outright or vested, with its shares of the Meme supply and the
/// final Quote reserve.
public struct Recipient has copy, drop, store {
    payee: payout::Recipient,
    meme_bps: Bps,
    quote_bps: Bps,
}

/// How migration divides the Meme supply and the final Quote reserve between the curve, the pool,
/// and the recipients. Each asset sums to 10,000 once Blast's allocation is added.
public struct AllocationPlan has copy, drop, store {
    curve_meme_bps: Bps,
    lp_meme_bps: Bps,
    lp_quote_bps: Bps,
    protocol_meme_bps: Bps,
    protocol_quote_bps: Bps,
    recipients: vector<Recipient>,
}

/// Blast's one-time Meme and Quote shares, accrued as protocol fees at migration.
public struct ProtocolAllocation has copy, drop, store {
    meme_bps: Bps,
    quote_bps: Bps,
}

// === Public Functions ===

/// A plan recipient: `payee` (`blast_core::payout::recipient`, which rejects the zero address)
/// receives `meme_bps` of the Meme supply and `quote_bps` of the final Quote reserve at migration.
public fun recipient(payee: payout::Recipient, meme_bps: Bps, quote_bps: Bps): Recipient {
    Recipient { payee, meme_bps, quote_bps }
}

/// The curve needs positive Meme and the pool needs positive Meme and Quote shares.
/// Blast's allocation is added at finalization.
public fun plan(
    curve_meme_bps: Bps,
    lp_meme_bps: Bps,
    lp_quote_bps: Bps,
    recipients: vector<Recipient>,
): AllocationPlan {
    assert!(
        curve_meme_bps.value() > 0 && lp_meme_bps.value() > 0 && lp_quote_bps.value() > 0,
        blast_fun::errors::invalid_shares!(),
    );

    AllocationPlan {
        curve_meme_bps,
        lp_meme_bps,
        lp_quote_bps,
        protocol_meme_bps: bps::new(0),
        protocol_quote_bps: bps::new(0),
        recipients,
    }
}

// === Package Functions ===

public(package) fun meme_bps(self: &ProtocolAllocation): Bps { self.meme_bps }

public(package) fun quote_bps(self: &ProtocolAllocation): Bps { self.quote_bps }

/// Builds Blast's allocation; each asset's share is at most `max_protocol_allocation_bps`.
public(package) fun protocol_allocation(meme_bps: Bps, quote_bps: Bps): ProtocolAllocation {
    assert!(
        meme_bps.value() <= constants::max_protocol_allocation_bps!()
            && quote_bps.value() <= constants::max_protocol_allocation_bps!(),
        blast_fun::errors::invalid_protocol_allocation!(),
    );

    ProtocolAllocation { meme_bps, quote_bps }
}

/// Adds Blast's fee allocation and checks that each asset sums to 10,000.
public(package) fun add_protocol(
    mut self: AllocationPlan,
    protocol: ProtocolAllocation,
): AllocationPlan {
    assert!(
        self.recipients.length() <= constants::max_recipients!(),
        blast_fun::errors::recipient_capacity_reached!(),
    );

    self.protocol_meme_bps = protocol.meme_bps;
    self.protocol_quote_bps = protocol.quote_bps;

    assert!(
        self.recipients.fold!(
            self.curve_meme_bps.value() + self.lp_meme_bps.value() + protocol.meme_bps.value(),
            |sum, recipient| sum + recipient.meme_bps.value(),
        ) == blast_core::constants::basis_points_denominator!()
            && self.recipients.fold!(
                self.lp_quote_bps.value() + protocol.quote_bps.value(),
                |sum, recipient| sum + recipient.quote_bps.value(),
            ) == blast_core::constants::basis_points_denominator!(),
        blast_fun::errors::invalid_shares!(),
    );

    self
}

/// Splits the Meme `supply` into the curve's, pool's, Blast's, and each recipient's amounts;
/// Blast's rounds up.
public(package) fun apportion_meme(
    self: &AllocationPlan,
    supply: u64,
): (u64, u64, u64, vector<u64>) {
    let mut bps = vector[self.curve_meme_bps, self.lp_meme_bps, self.protocol_meme_bps];
    bps.append(self.recipients.map_ref!(|recipient| recipient.meme_bps));
    let amounts = bps::apportion(bps, supply, option::some(2));
    let recipients = vector::tabulate!(amounts.length() - 3, |i| amounts[i + 3]);

    (amounts[0], amounts[1], amounts[2], recipients)
}

/// Splits the final Quote `reserve` into the pool's, Blast's, and each recipient's amounts;
/// Blast's rounds up.
public(package) fun apportion_quote(
    self: &AllocationPlan,
    reserve: u64,
): (u64, u64, vector<u64>) {
    let mut bps = vector[self.lp_quote_bps, self.protocol_quote_bps];
    bps.append(self.recipients.map_ref!(|recipient| recipient.quote_bps));
    let amounts = bps::apportion(bps, reserve, option::some(1));
    let recipients = vector::tabulate!(amounts.length() - 2, |i| amounts[i + 2]);

    (amounts[0], amounts[1], recipients)
}

/// The plan's payees, in plan order.
public(package) fun payees(self: &AllocationPlan): vector<payout::Recipient> {
    self.recipients.map_ref!(|recipient| recipient.payee)
}

// === Test-Only Functions ===

#[test_only]
/// Builds an allocation above the policy maximum, for apportionment math tests.
public fun protocol_allocation_unchecked_for_testing(
    meme_bps: Bps,
    quote_bps: Bps,
): ProtocolAllocation {
    ProtocolAllocation { meme_bps, quote_bps }
}

#[test_only]
public fun add_protocol_for_testing(
    self: AllocationPlan,
    meme_bps: Bps,
    quote_bps: Bps,
): AllocationPlan {
    self.add_protocol(protocol_allocation(meme_bps, quote_bps))
}

// === Imports ===

use blast_core::{bps::{Self, Bps}, payout};

use blast_fun::constants;
