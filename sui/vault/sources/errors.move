// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_vault::errors;

// === Errors ===

#[test_only]
/// An admitted witness must not be a primitive or framework type.
const EInvalidWitness: u64 = 0;

#[test_only]
/// Only an admitted venue may create vaults.
const EUnadmittedVenue: u64 = 1;

#[test_only]
/// Unpause needs a nonzero witness admission notice and no pending admission.
const EUnguardedNotice: u64 = 2;

#[test_only]
/// Blast's share must be at most 3,000 basis points per asset.
const EInvalidProtocolBps: u64 = 3;

#[test_only]
/// The migration position must hold liquidity.
const EZeroLiquidity: u64 = 4;

#[test_only]
/// Only the venue holding the vault's position may act on it.
const EWrongVenue: u64 = 5;

#[test_only]
/// The owner has nothing accrued to claim.
const ENothingToClaim: u64 = 6;

#[test_only]
/// Buyback Quote must be positive and at most the burn Quote held.
const EBuybackQuoteOutOfRange: u64 = 7;

#[test_only]
/// The buyback must return at least the minimum Meme.
const EBuybackBelowMinimum: u64 = 8;

#[test_only]
/// The root and manifest digest must each be 32 bytes.
const EInvalidCommitment: u64 = 9;

#[test_only]
/// A round must commit 1 to 65,536 leaves.
const EInvalidLeafCount: u64 = 10;

#[test_only]
/// A round must fund some Meme or Quote.
const EEmptyBudget: u64 = 11;

#[test_only]
/// The start checkpoint must precede the end checkpoint.
const EEmptyInterval: u64 = 12;

#[test_only]
/// The holder Quote and gas reserve must sum within u64.
const EBudgetOverflow: u64 = 13;

#[test_only]
/// The gas reserve must be at most 10% of the holder Quote.
const EGasReserveTooLarge: u64 = 14;

#[test_only]
/// The expected treasury must be a nonzero address.
const EZeroTreasury: u64 = 15;

#[test_only]
/// The claim window must be positive.
const EZeroClaimWindow: u64 = 16;

#[test_only]
/// The round number must match the vault's next round.
const EWrongRound: u64 = 17;

#[test_only]
/// The checkpoint interval must not overlap the previous round.
const EOverlappingInterval: u64 = 18;

#[test_only]
/// Holder funding and gas reserve must fit the vault's unreserved rewards.
const EInsufficientBudget: u64 = 19;

#[test_only]
/// Cancel the pending proposal with the call matching its kind.
const EWrongRoundProposal: u64 = 20;

#[test_only]
/// The expected treasury must match the treasury's destination.
const ETreasuryChanged: u64 = 21;

#[test_only]
/// The claim window must end within u64 milliseconds.
const EClaimDeadlineOverflow: u64 = 22;

#[test_only]
/// The claim deadline has been reached.
const EClaimsClosed: u64 = 23;

#[test_only]
/// The claim index must be less than the committed leaf count.
const EInvalidIndex: u64 = 24;

#[test_only]
/// This allocation has already been paid.
const EAlreadyClaimed: u64 = 25;

#[test_only]
/// The beneficiary must not be the zero address.
const EInvalidBeneficiary: u64 = 26;

#[test_only]
/// At least one claimed amount must be nonzero.
const EEmptyClaim: u64 = 27;

#[test_only]
/// The proof must match the committed recipient, amounts, and domain.
const EInvalidProof: u64 = 28;

#[test_only]
/// A round or a venue receipt acts only on its own vault.
const EWrongVault: u64 = 29;

#[test_only]
/// Gas reimbursement is disabled or already settled.
const EReserveSettled: u64 = 30;

#[test_only]
/// The reimbursement must not exceed the round's gas reserve.
const EOverReserve: u64 = 31;

#[test_only]
/// A round can close only at or after its claim deadline.
const EClaimsStillOpen: u64 = 32;

#[test_only]
/// Only terms sealed by an admitted issuer may create vaults.
const EUnadmittedIssuer: u64 = 33;

#[test_only]
/// A venue returns at most what it took from the vault.
const EReturnedExceedsTaken: u64 = 34;

macro public(package) fun invalid_witness(): u64 { 0 }

macro public(package) fun unadmitted_venue(): u64 { 1 }

macro public(package) fun unguarded_notice(): u64 { 2 }

macro public(package) fun invalid_protocol_bps(): u64 { 3 }

macro public(package) fun zero_liquidity(): u64 { 4 }

macro public(package) fun wrong_venue(): u64 { 5 }

macro public(package) fun nothing_to_claim(): u64 { 6 }

macro public(package) fun buyback_quote_out_of_range(): u64 { 7 }

macro public(package) fun buyback_below_minimum(): u64 { 8 }

macro public(package) fun invalid_commitment(): u64 { 9 }

macro public(package) fun invalid_leaf_count(): u64 { 10 }

macro public(package) fun empty_budget(): u64 { 11 }

macro public(package) fun empty_interval(): u64 { 12 }

macro public(package) fun budget_overflow(): u64 { 13 }

macro public(package) fun gas_reserve_too_large(): u64 { 14 }

macro public(package) fun zero_treasury(): u64 { 15 }

macro public(package) fun zero_claim_window(): u64 { 16 }

macro public(package) fun wrong_round(): u64 { 17 }

macro public(package) fun overlapping_interval(): u64 { 18 }

macro public(package) fun insufficient_budget(): u64 { 19 }

macro public(package) fun wrong_round_proposal(): u64 { 20 }

macro public(package) fun treasury_changed(): u64 { 21 }

macro public(package) fun claim_deadline_overflow(): u64 { 22 }

macro public(package) fun claims_closed(): u64 { 23 }

macro public(package) fun invalid_index(): u64 { 24 }

macro public(package) fun already_claimed(): u64 { 25 }

macro public(package) fun invalid_beneficiary(): u64 { 26 }

macro public(package) fun empty_claim(): u64 { 27 }

macro public(package) fun invalid_proof(): u64 { 28 }

macro public(package) fun wrong_vault(): u64 { 29 }

macro public(package) fun reserve_settled(): u64 { 30 }

macro public(package) fun over_reserve(): u64 { 31 }

macro public(package) fun claims_still_open(): u64 { 32 }

macro public(package) fun unadmitted_issuer(): u64 { 33 }

macro public(package) fun returned_exceeds_taken(): u64 { 34 }
