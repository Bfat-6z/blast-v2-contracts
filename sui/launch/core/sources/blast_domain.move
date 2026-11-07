// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's product administration roles in the shared Blast ACL, one set for the launchpad, the
/// presale, the vault, and the venues (ADR 0137). Package-infrastructure roles (upgrade, pause,
/// unpause) are generic over each package's one-time witness (OTW) in `blast_admin`.
///
/// A role is a type. An `AdminCap` holding `Role` signs in to `AdminWitness<Role>`, and a
/// function's witness parameter names the one role it accepts, so no role authorizes another's
/// actions.
module blast_core::blast_domain;

// === Public Types ===

/// Chooses where Blast is paid.
public struct TreasuryAdmin()

/// Sets Blast's fees and shares and the partners new sales may name.
public struct FeeAdmin()

/// Admits or removes the Quotes and Meme decimals new sales may use.
public struct ListingAdmin()

/// Admits or removes venues and vault issuers.
public struct VenueAdmin()

/// Schedules holder-reward rounds and settles their gas reserves.
public struct RewardsAdmin()

/// Swaps a vault's burn Quote for Meme to burn.
public struct BuybackAdmin()

/// Reinvests waiting auto-LP fees under price bounds from a trusted off-chain quote.
public struct AutoLpAdmin()

/// Revokes and reissues a launch's creator capabilities.
public struct CreatorAdmin()

/// Proposes and revokes the keys that may sign account claims.
public struct ClaimSignerAdmin()

/// May cancel any scheduled product administrative action.
public struct CancelAdmin()
