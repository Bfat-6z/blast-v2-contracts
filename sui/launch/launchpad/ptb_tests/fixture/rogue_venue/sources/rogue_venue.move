// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// An unadmitted venue whose witness an attacker can use in a public PTB.
module ptb_rogue_venue::rogue_venue;

// === Public Types ===

public struct Venue() has drop;

// === Public Functions ===

public fun witness(): Venue { Venue() }
