// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_partners::errors;

// === Errors ===

#[test_only]
/// A partner's recipient must not be the zero address.
const EInvalidRecipient: u64 = 0;

#[test_only]
/// A partner's share must be at most 80% of Blast's fee.
const EShareAboveMax: u64 = 1;

#[test_only]
/// An update must change the value it sets or proposes.
const EUnchanged: u64 = 2;

#[test_only]
/// Only the partner's applied cap may set its recipient.
const ENotLiveCap: u64 = 3;

#[test_only]
/// The partner list does not accept the partner now.
const EPartnerNotAccepted: u64 = 4;

macro public(package) fun invalid_recipient(): u64 { 0 }

macro public(package) fun share_above_max(): u64 { 1 }

macro public(package) fun unchanged(): u64 { 2 }

macro public(package) fun not_live_cap(): u64 { 3 }

macro public(package) fun partner_not_accepted(): u64 { 4 }
