#[test_only]
/// One-time old-vs-new run (ADR 0137 step 4): the presale vault's LP-fee split (Blast's share
/// rounded up, then `apportion_fee` over the recipients and holder rewards) against `blast_vault`'s
/// (core `apply_up`, then `fee_split::apportion` over the same routes in the same order). Deleted
/// with the old code.
module blast_presale::zz_fee_differential_tests;

const BATCH: u64 = 25;

#[test]
fun batch_0() { run(0); }

#[test]
fun batch_1() { run(1); }

#[test]
fun batch_2() { run(2); }

#[test]
fun batch_3() { run(3); }

#[test]
fun batch_4() { run(4); }

#[test]
fun batch_5() { run(5); }

#[test]
fun batch_6() { run(6); }

#[test]
fun batch_7() { run(7); }

#[test]
fun batch_8() { run(8); }

#[test]
fun batch_9() { run(9); }

#[test]
fun batch_10() { run(10); }

#[test]
fun batch_11() { run(11); }

#[test]
fun batch_12() { run(12); }

#[test]
fun batch_13() { run(13); }

#[test]
fun batch_14() { run(14); }

#[test]
fun batch_15() { run(15); }


fun run(batch: u64) {
    let mut seed = 0x5EED_0137u64 + batch;
    let mut checked = 0u64;
    BATCH.do!(|case| {
        seed = next(seed);
        let recipient_count = 1 + seed % 16;
        let weights = vector::tabulate!(recipient_count + 1, |_| {
            seed = next(seed);
            1_000 + seed % 1_000
        });
        let rates = to_rates(&weights);
        let shares = vector::tabulate!(recipient_count, |i| {
            blast_presale::recipient_share(address_of(i), old_bps::new(rates[i]))
        });
        let old_split = blast_presale::fee_split(
            shares,
            old_bps::new(rates[recipient_count]),
        );
        let mut routes = vector::tabulate!(recipient_count, |i| {
            fee_split::route(fee_split::address_destination(address_of(i)), core_bps::new(rates[i]))
        });
        routes.push_back(
            fee_split::route(
                fee_split::holder_rewards_destination(),
                core_bps::new(rates[recipient_count]),
            ),
        );
        let new_split = fee_split::new(routes);

        seed = next(seed);
        let protocol_bps = seed % 3_001;
        totals(case, seed).do!(|gross| {
            let old_cut = old_bps::new(protocol_bps).apply_up(gross);
            let new_cut = core_bps::new(protocol_bps).apply_up(gross);
            assert_eq!(old_cut, new_cut);
            assert_eq!(new_split.apportion(gross - new_cut), old_split.apportion_fee(gross - old_cut));
            checked = checked + 1;
        });
    });
    std::debug::print(&checked);
}

fun to_rates(weights: &vector<u64>): vector<u64> {
    let total = (*weights).fold!(0, |sum, weight| sum + weight);
    let mut rates = weights.map_ref!(|weight| *weight * 10_000 / total);
    let assigned = rates.fold!(0, |sum, rate| sum + rate);
    let last = rates.length() - 1;
    *&mut rates[last] = rates[last] + 10_000 - assigned;
    rates
}

fun totals(case: u64, seed: u64): vector<u64> {
    let fixed = vector[0, 1, 2, 3, 7, 99, 100, 101, 999, 1_001, 9_999, 10_000, 10_001, 123_457];
    let mut all = vector[fixed[case % fixed.length()]];
    all.push_back(seed % 1_000_000_007);
    all.push_back(seed);
    all.push_back(std::u64::max_value!() - case);
    all
}

fun next(seed: u64): u64 {
    (((seed as u128) * 6364136223846793005 + 1442695040888963407) % 18446744073709551616) as u64
}

fun address_of(i: u64): address { sui::address::from_u256((0xAD00 + i) as u256) }

use blast_core::{bps as core_bps, fee_split};
use blast_presale::{blast_presale, bps as old_bps};
use std::unit_test::assert_eq;
