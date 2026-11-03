// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast presale's administration roles in the shared Blast ACL.
///
/// A role is a type. An `AdminCap` holding `Role` signs in to `AdminWitness<Role>`, and a
/// function's witness parameter names the one role it accepts, so no role authorizes another's
/// actions and a role from any other package cannot reach these operations.
module blast_presale::blast_presale_domain;

// === Public Types ===

/// Governs administrative delay and compatible upgrades with atomic version cutover.
public struct UpgradeAdmin()

/// Governs the protocol fee destination and publishes holder-reward rounds.
public struct TreasuryAdmin()

/// Sets Blast's rates for new sales, one sale before its start, and one migrated sale's vault, and
/// the partners new sales may name.
public struct FeeAdmin()

/// Admits or removes the Quotes new sales and vaults may use.
public struct ListingAdmin()

/// Admits or removes the migrators that may create sales and vaults.
public struct AdapterAdmin()

/// Settles capped gas reserves in published holder-reward rounds.
public struct RewardsAdmin()

/// May set emergency pause bits, never clear them.
public struct PauseAdmin()

/// May clear pause bits after an incident.
public struct UnpauseAdmin()

/// May cancel any scheduled administrative action.
public struct CancelAdmin()
