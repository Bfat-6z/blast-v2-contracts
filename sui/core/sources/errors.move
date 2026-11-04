// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_core::errors;

// === Errors ===

#[test_only]
/// A basis-points rate must be at most 10,000.
const EInvalidBps: u64 = 0;

#[test_only]
/// Apportioned rates must sum to 10,000 and name a rounded-up part inside them.
const EInvalidApportionment: u64 = 1;

#[test_only]
/// Vesting needs positive steps whose total and cliff fit the technical bound.
const EInvalidVestingTerms: u64 = 2;

#[test_only]
/// A recipient must be a nonzero address.
const EInvalidRecipient: u64 = 3;

#[test_only]
/// Recipients must be within capacity, positive, distinct, and vested only where allowed.
const EInvalidRecipients: u64 = 4;

#[test_only]
/// A route needs a positive share and a nonzero address.
const EInvalidRoute: u64 = 5;

#[test_only]
/// A fee split needs at most 16 distinct routes summing to 10,000.
const EInvalidFeeSplit: u64 = 6;

#[test_only]
/// The treasury must be a nonzero address.
const EInvalidTreasury: u64 = 7;

#[test_only]
/// The Meme and Quote types must differ.
const EInvalidPair: u64 = 8;

#[test_only]
/// Blast's fees pay with exactly the partner the sale named, or with none.
const EPartnerMismatch: u64 = 9;

#[test_only]
/// Only the venue the sale stored can redeem its migration.
const EWrongVenue: u64 = 10;

#[test_only]
/// The owner proof must name the vault's product and sale.
const EWrongOwner: u64 = 11;

macro public(package) fun invalid_bps(): u64 { 0 }

macro public(package) fun invalid_apportionment(): u64 { 1 }

macro public(package) fun invalid_vesting_terms(): u64 { 2 }

macro public(package) fun invalid_recipient(): u64 { 3 }

macro public(package) fun invalid_recipients(): u64 { 4 }

macro public(package) fun invalid_route(): u64 { 5 }

macro public(package) fun invalid_fee_split(): u64 { 6 }

macro public(package) fun invalid_treasury(): u64 { 7 }

macro public(package) fun invalid_pair(): u64 { 8 }

macro public(package) fun partner_mismatch(): u64 { 9 }

macro public(package) fun wrong_venue(): u64 { 10 }

macro public(package) fun wrong_owner(): u64 { 11 }
