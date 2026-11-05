// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_admin::errors;

// === Errors ===

#[test_only]
const EInvalidSuperAdminCap: u64 = 0;

#[test_only]
const EInvalidAdminCap: u64 = 1;

#[test_only]
const EInvalidAdminRecipient: u64 = 2;

#[test_only]
const EAdminRoleCapacityReached: u64 = 3;

#[test_only]
const EAdminRoleAlreadyGranted: u64 = 4;

#[test_only]
const EAdminRoleNotGranted: u64 = 5;

#[test_only]
const EInvalidSuperAdminRecipient: u64 = 6;

#[test_only]
const ENotPendingSuperAdminRecipient: u64 = 7;

#[test_only]
const ESuperAdminCapStillActive: u64 = 8;

#[test_only]
const EOperationalVersionMismatch: u64 = 9;

#[test_only]
const EInvalidUpgradeCap: u64 = 10;

#[test_only]
const EInvalidPackageDigest: u64 = 11;

#[test_only]
const EUpgradeCapUnavailable: u64 = 12;

#[test_only]
const ENotReady: u64 = 13;

#[test_only]
const ENoPending: u64 = 14;

#[test_only]
const EInvalidDelay: u64 = 15;

#[test_only]
const EUnchanged: u64 = 16;

#[test_only]
const EProposalPending: u64 = 17;

#[test_only]
const EWrongChange: u64 = 18;

#[test_only]
const EInvalidPauseBits: u64 = 19;

#[test_only]
const EPauseUnchanged: u64 = 20;

#[test_only]
const EPaused: u64 = 21;

#[test_only]
const EWrongUpgradeAction: u64 = 22;

#[test_only]
const EUnguardedUpgradeNotice: u64 = 23;

#[test_only]
const EInvalidPackageWitness: u64 = 24;

#[test_only]
const EWrongUnpauseWitness: u64 = 25;

#[test_only]
const EWrongPackageWitness: u64 = 26;

macro public(package) fun invalid_super_admin_cap(): u64 { 0 }

macro public(package) fun invalid_admin_cap(): u64 { 1 }

macro public(package) fun invalid_admin_recipient(): u64 { 2 }

macro public(package) fun admin_role_capacity_reached(): u64 { 3 }

macro public(package) fun admin_role_already_granted(): u64 { 4 }

macro public(package) fun admin_role_not_granted(): u64 { 5 }

macro public(package) fun invalid_super_admin_recipient(): u64 { 6 }

macro public(package) fun not_pending_super_admin_recipient(): u64 { 7 }

macro public(package) fun super_admin_cap_still_active(): u64 { 8 }

macro public(package) fun operational_version_mismatch(): u64 { 9 }

macro public(package) fun invalid_upgrade_cap(): u64 { 10 }

macro public(package) fun invalid_package_digest(): u64 { 11 }

macro public(package) fun upgrade_cap_unavailable(): u64 { 12 }

macro public(package) fun not_ready(): u64 { 13 }

macro public(package) fun no_pending(): u64 { 14 }

macro public(package) fun invalid_delay(): u64 { 15 }

macro public(package) fun unchanged(): u64 { 16 }

macro public(package) fun proposal_pending(): u64 { 17 }

macro public(package) fun wrong_change(): u64 { 18 }

macro public(package) fun invalid_pause_bits(): u64 { 19 }

macro public(package) fun pause_unchanged(): u64 { 20 }

macro public(package) fun paused(): u64 { 21 }

macro public(package) fun wrong_upgrade_action(): u64 { 22 }

macro public(package) fun unguarded_upgrade_notice(): u64 { 23 }

macro public(package) fun invalid_package_witness(): u64 { 24 }

macro public(package) fun wrong_unpause_witness(): u64 { 25 }

macro public(package) fun wrong_package_witness(): u64 { 26 }
