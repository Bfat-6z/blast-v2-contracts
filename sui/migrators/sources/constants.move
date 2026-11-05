// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide migrator constants exposed as zero-cost macros.
module blast_migrators::constants;

// === Package Constants ===

/// The package generation this bytecode serves.
macro public(package) fun generation(): u64 {
    1
}

/// Bluefin pool creation's own tick-spacing bound (`pool` aborts 1026 above it).
macro public(package) fun bluefin_max_tick_spacing(): u32 {
    400
}

/// Bluefin pool creation's own fee-rate bound (`pool` aborts 1027 above it).
macro public(package) fun bluefin_max_fee_rate(): u64 {
    20_000
}

/// Longest Meme symbol, in bytes, a Bluefin pool accepts: the pool and its position store the
/// symbol, and the pool name repeats it, so a longer one would make the position too large.
macro public(package) fun max_meme_symbol_length(): u64 {
    32
}

/// Lowest sqrt price a Cetus or Bluefin swap accepts as its limit; buybacks selling Quote as coin A
/// run to it and rely on the caller's minimum Meme out instead.
macro public(package) fun min_swap_sqrt_price(): u128 {
    4_295_048_017
}

/// Highest sqrt price a Cetus or Bluefin swap accepts as its limit, for buybacks selling Quote as
/// coin B.
macro public(package) fun max_swap_sqrt_price(): u128 {
    79_226_673_515_401_279_992_447_579_054
}

/// Fractional bits of a Q64.64 sqrt price.
macro public(package) fun q64_shift(): u8 {
    64
}

/// Fractional bits of a Q128 value; a fixed-A auto-LP liquidity must stay below it.
macro public(package) fun q128_shift(): u8 {
    128
}

/// Atoms of the other asset kept in reserve beyond the estimate, covering the venue's own
/// rounding of the liquidity it derives from the fixed amount.
macro public(package) fun auto_lp_margin(): u256 {
    2
}
