// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_migrators::errors;

// === Errors ===

#[test_only]
/// `CoinA` and `CoinB` must follow the Cetus coin order.
const EInvalidCoinOrder: u64 = 0;

#[test_only]
/// The pool must be the vault's own pool.
const EPositionPoolMismatch: u64 = 1;

#[test_only]
/// `CoinA` and `CoinB` must be exactly the sale's Meme and Quote.
const EWrongCoinPair: u64 = 2;

#[test_only]
/// A Bluefin tier needs a tick spacing in 1..=400 and a fee rate in 1..=20,000.
const EInvalidTier: u64 = 3;

#[test_only]
/// A Bluefin Meme symbol must be at most 32 bytes.
const ESymbolTooLong: u64 = 4;

#[test_only]
/// Auto-LP needs positive ordered bounds containing the current pool sqrt price.
const EInvalidAutoLpPrice: u64 = 5;

macro public(package) fun invalid_coin_order(): u64 { 0 }

macro public(package) fun position_pool_mismatch(): u64 { 1 }

macro public(package) fun wrong_coin_pair(): u64 { 2 }

macro public(package) fun invalid_tier(): u64 { 3 }

macro public(package) fun symbol_too_long(): u64 { 4 }

macro public(package) fun invalid_auto_lp_price(): u64 { 5 }
