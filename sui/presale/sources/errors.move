// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_presale::errors;

// === Errors ===

#[test_only]
/// Select nonzero pause bits supported by this package.
const EInvalidPauseBits: u64 = 0;

#[test_only]
/// The requested pause change must alter the active bits.
const EPauseUnchanged: u64 = 1;

#[test_only]
/// This operation is paused.
const EPaused: u64 = 2;

#[test_only]
/// The ready action must match the requested upgrade digest or immutability.
const EWrongUpgradeAction: u64 = 3;

#[test_only]
/// A package digest must contain 32 bytes.
const EInvalidDigest: u64 = 4;

#[test_only]
/// Unpausing needs every policy notice nonzero, with no pending zero notice or admission.
const EUnguardedNotice: u64 = 5;

#[test_only]
/// An allowlist update must change whether the type or partner is allowed.
const EAllowanceUnchanged: u64 = 6;

#[test_only]
/// This Quote type is not allowed for new presales.
const EQuoteNotAllowed: u64 = 7;

#[test_only]
/// This venue is not allowed for new presales.
const EVenueNotAllowed: u64 = 8;

#[test_only]
/// A venue must be a non-framework struct, never a primitive, vector, or framework type any caller can construct.
const EInvalidVenue: u64 = 9;

#[test_only]
/// New presales may not name this partner.
const EPartnerNotAccepted: u64 = 10;

#[test_only]
/// Blast's raise and token shares must be at most 1,000 BPS and each LP fee at most 3,000.
const EInvalidFees: u64 = 11;

#[test_only]
/// The protocol destination must be a nonzero address.
const EInvalidDestination: u64 = 12;

#[test_only]
/// The sale token and Quote type must differ.
const EInvalidAssetPair: u64 = 13;

#[test_only]
/// The raise target must be positive.
const EInvalidRaiseTarget: u64 = 14;

#[test_only]
/// The supply must be positive, and token allocations unique, positive, bounded, totalling exactly 10,000 BPS with Blast's share, and apportioning to positive amounts.
const EInvalidTokenAllocation: u64 = 15;

#[test_only]
/// The commitment window must be positive, the liquidity window at least seven days, and both must end within u64 milliseconds.
const EInvalidWindow: u64 = 16;

#[test_only]
/// The eligibility policy has an invalid cap, participant bound, root, or leaf count.
const EInvalidEligibilityPolicy: u64 = 17;

#[test_only]
/// The presale is not in the lifecycle required by this operation.
const EInvalidLifecycle: u64 = 18;

#[test_only]
/// The presale commitment window has ended.
const EPresaleEnded: u64 = 19;

#[test_only]
/// The presale commitment window has not ended, and the sale cannot close early: its raise is not full under a hard cap that closes it when filled.
const EPresaleNotEnded: u64 = 20;

#[test_only]
/// A presale commitment must be positive.
const EZeroCommitment: u64 = 21;

#[test_only]
/// The wallet commitment exceeds its eligibility cap.
const EWalletCapExceeded: u64 = 22;

#[test_only]
/// The presale already contains its maximum number of participants.
const EParticipantCapacityReached: u64 = 23;

#[test_only]
/// The submitted wallet, cap, index, or proof does not match the allowlist.
const EInvalidEligibilityProof: u64 = 24;

#[test_only]
/// The commit function does not match the presale eligibility policy.
const EWrongEligibilityPolicy: u64 = 25;

#[test_only]
/// Adding the commitment would overflow the presale total.
const ETotalCommitmentOverflow: u64 = 26;

#[test_only]
/// The wallet has no undelivered presale commitment.
const ENoCommitment: u64 = 27;

#[test_only]
/// The creator capability belongs to a different presale.
const EWrongPresaleCap: u64 = 28;

#[test_only]
/// The deadline to cancel an unlaunched funded presale has not arrived.
const ELiquidityDeadlineNotReached: u64 = 29;

#[test_only]
/// The supplied SaleToken TreasuryCap must have zero total supply.
const EInitialSupplyNotZero: u64 = 30;

#[test_only]
/// The wallet's total commitment is below the sale's minimum commitment.
const EBelowMinimumCommitment: u64 = 31;

#[test_only]
/// The minimum commitment times the slots held to it, the participant bound of an open policy or the open-to-anyone phase slots beyond any allowlist, must reach the raise target.
const EUnreachableRaise: u64 = 32;

#[test_only]
/// The raise and LP-token allocation give a seed price the venues cannot pool.
const EUnseedablePrice: u64 = 33;

#[test_only]
/// An uncapped phase must start inside the window, and an open-to-anyone phase needs a positive minimum and a participant bound between the policy's and 65,536.
const EInvalidUncappedPhase: u64 = 34;

#[test_only]
/// The presale has no uncapped phase open to any wallet, or it has not started.
const EUncappedPhaseNotOpen: u64 = 35;

#[test_only]
/// The presale has already reached its raise under its hard cap.
const EPresaleFilled: u64 = 36;

#[test_only]
/// Raise allocations must be unique, positive, bounded, leave the LP a share after Blast's, and apportion to positive amounts.
const EInvalidRaiseAllocation: u64 = 37;

#[test_only]
/// Vesting needs a positive period and period count, a cliff within its duration, and a duration of at most 2^63 milliseconds.
const EInvalidVestingTerms: u64 = 38;

#[test_only]
/// The presale commitment window has not started.
const EPresaleNotStarted: u64 = 39;

#[test_only]
/// A presale's Blast rates can change only before its commitment window starts.
const EPresaleStarted: u64 = 40;

#[test_only]
/// A presale fee update must change its stored rates.
const EProtocolFeesUnchanged: u64 = 41;

#[test_only]
/// The partner is not the one the presale named at creation.
const EWrongPartner: u64 = 42;

#[test_only]
/// The presale holds no partner payout: it has not migrated, or its partner was already paid.
const ENoPartnerPayout: u64 = 43;

#[test_only]
/// A hard cap must start inside the commitment window.
const EInvalidHardCap: u64 = 44;

#[test_only]
/// A presale needs its eligibility policy and LP-fee split set before it is finalized.
const EMissingSetting: u64 = 45;

#[test_only]
/// The sale currency must be confirmed unregulated; regulated and unknown legacy currencies are not allowed.
const ESaleTokenNotUnregulated: u64 = 46;

#[test_only]
/// A sale fee override cannot exceed the currently applied fee policy.
const EAboveFeePolicy: u64 = 47;

#[test_only]
/// A shared sale's fee override may only keep or lower each of its rates.
const EProtocolFeesIncreased: u64 = 48;

#[test_only]
/// CoinA and CoinB must follow the Cetus coin order.
const EInvalidCoinOrder: u64 = 49;

#[test_only]
/// Pool must be the one holding the position.
const EPositionPoolMismatch: u64 = 50;

#[test_only]
/// CoinA and CoinB must be exactly the presale's Meme and Quote.
const EWrongCoinPair: u64 = 51;

#[test_only]
/// Bluefin tier needs tick spacing 1..=400 and fee rate 1..=20,000.
const EInvalidTier: u64 = 52;

#[test_only]
/// The Meme symbol must be at most 32 bytes for Bluefin migration.
const ESymbolTooLong: u64 = 53;

#[test_only]
/// The Aftermath pool must hold every sale token and Quote unit the presale released.
const EPoolMismatch: u64 = 54;

#[test_only]
/// The DAO-fee pool must charge this module's fee and pay the vault.
const EDaoFeePoolMismatch: u64 = 55;

#[test_only]
/// Aftermath DAO fee needs 1..=10,000 basis points.
const EInvalidDaoFee: u64 = 56;

macro public(package) fun invalid_pause_bits(): u64 { 0 }

macro public(package) fun pause_unchanged(): u64 { 1 }

macro public(package) fun paused(): u64 { 2 }

macro public(package) fun wrong_upgrade_action(): u64 { 3 }

macro public(package) fun invalid_digest(): u64 { 4 }

macro public(package) fun unguarded_notice(): u64 { 5 }

macro public(package) fun allowance_unchanged(): u64 { 6 }

macro public(package) fun quote_not_allowed(): u64 { 7 }

macro public(package) fun venue_not_allowed(): u64 { 8 }

macro public(package) fun invalid_venue(): u64 { 9 }

macro public(package) fun partner_not_accepted(): u64 { 10 }

macro public(package) fun invalid_fees(): u64 { 11 }

macro public(package) fun invalid_destination(): u64 { 12 }

macro public(package) fun invalid_asset_pair(): u64 { 13 }

macro public(package) fun invalid_raise_target(): u64 { 14 }

macro public(package) fun invalid_token_allocation(): u64 { 15 }

macro public(package) fun invalid_window(): u64 { 16 }

macro public(package) fun invalid_eligibility_policy(): u64 { 17 }

macro public(package) fun invalid_lifecycle(): u64 { 18 }

macro public(package) fun presale_ended(): u64 { 19 }

macro public(package) fun presale_not_ended(): u64 { 20 }

macro public(package) fun zero_commitment(): u64 { 21 }

macro public(package) fun wallet_cap_exceeded(): u64 { 22 }

macro public(package) fun participant_capacity_reached(): u64 { 23 }

macro public(package) fun invalid_eligibility_proof(): u64 { 24 }

macro public(package) fun wrong_eligibility_policy(): u64 { 25 }

macro public(package) fun total_commitment_overflow(): u64 { 26 }

macro public(package) fun no_commitment(): u64 { 27 }

macro public(package) fun wrong_presale_cap(): u64 { 28 }

macro public(package) fun liquidity_deadline_not_reached(): u64 { 29 }

macro public(package) fun initial_supply_not_zero(): u64 { 30 }

macro public(package) fun below_minimum_commitment(): u64 { 31 }

macro public(package) fun unreachable_raise(): u64 { 32 }

macro public(package) fun unseedable_price(): u64 { 33 }

macro public(package) fun invalid_uncapped_phase(): u64 { 34 }

macro public(package) fun uncapped_phase_not_open(): u64 { 35 }

macro public(package) fun presale_filled(): u64 { 36 }

macro public(package) fun invalid_raise_allocation(): u64 { 37 }

macro public(package) fun invalid_vesting_terms(): u64 { 38 }

macro public(package) fun presale_not_started(): u64 { 39 }

macro public(package) fun presale_started(): u64 { 40 }

macro public(package) fun protocol_fees_unchanged(): u64 { 41 }

macro public(package) fun wrong_partner(): u64 { 42 }

macro public(package) fun no_partner_payout(): u64 { 43 }

macro public(package) fun invalid_hard_cap(): u64 { 44 }

macro public(package) fun missing_setting(): u64 { 45 }

macro public(package) fun sale_token_not_unregulated(): u64 { 46 }

macro public(package) fun above_fee_policy(): u64 { 47 }

macro public(package) fun protocol_fees_increased(): u64 { 48 }

macro public(package) fun invalid_coin_order(): u64 { 49 }

macro public(package) fun position_pool_mismatch(): u64 { 50 }

macro public(package) fun wrong_coin_pair(): u64 { 51 }

macro public(package) fun invalid_tier(): u64 { 52 }

macro public(package) fun symbol_too_long(): u64 { 53 }

macro public(package) fun pool_mismatch(): u64 { 54 }

macro public(package) fun dao_fee_pool_mismatch(): u64 { 55 }

macro public(package) fun invalid_dao_fee(): u64 { 56 }
