#[test_only]
/// One-time old-vs-new run (ADR 0137 step 4): the migrators vault's LP-fee split (Blast's share
/// rounded up, then `allocation::apportion_fee_split`) against `blast_vault`'s (core `apply_up`,
/// then `fee_split::apportion` over the same routes in the same order). Deleted with the old code.
module blast_fun::zz_fee_differential_tests;

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
        let recipient_count = seed % 17;
        let mut weights = vector::tabulate!(4 + recipient_count, |i| {
            seed = next(seed);
            if (i < 4 && seed % 3 == 0) 0 else 1_000 + seed % 1_000
        });
        if (weights.all!(|weight| *weight == 0)) { *&mut weights[0] = 1_000; };
        let rates = to_rates(&weights);

        let routes = vector::tabulate!(recipient_count, |i| {
            allocation::route(address_of(i), blast_fun::bps::new(rates[4 + i]))
        });
        let old_split = allocation::fee_split(
            blast_fun::bps::new(rates[0]),
            blast_fun::bps::new(rates[1]),
            blast_fun::bps::new(rates[2]),
            blast_fun::bps::new(rates[3]),
            routes,
        );
        let mut new_routes = vector[];
        let specials = vector[
            fee_split::owner_destination(),
            fee_split::auto_lp_destination(),
            fee_split::holder_rewards_destination(),
            fee_split::burn_destination(),
        ];
        let mut positions = vector[];
        rates.length().do!(|i| if (rates[i] > 0) {
            let destination = if (i < 4) specials[i] else fee_split::address_destination(address_of(i - 4));
            new_routes.push_back(fee_split::route(destination, core_bps::new(rates[i])));
            positions.push_back(i);
        });
        let new_split = fee_split::new(new_routes);

        seed = next(seed);
        let protocol_bps = seed % 3_001;
        totals(case, seed).do!(|gross| {
            let old_cut = blast_fun::bps::new(protocol_bps).apply_up(gross);
            let new_cut = core_bps::new(protocol_bps).apply_up(gross);
            assert_eq!(old_cut, new_cut);

            let (creator, auto_lp, rewards, burn, recipients) = old_split.apportion_fee_split(gross - old_cut);
            let mut old_amounts = vector[creator, auto_lp, rewards, burn];
            old_amounts.append(recipients);
            let new_amounts = new_split.apportion(gross - new_cut);
            positions.length().do!(|j| assert_eq!(new_amounts[j], old_amounts[positions[j]]));
            rates.length().do!(|i| if (rates[i] == 0) assert_eq!(old_amounts[i], 0));
            checked = checked + 1;
        });
    });
    std::debug::print(&checked);
}

fun to_rates(weights: &vector<u64>): vector<u64> {
    let total = (*weights).fold!(0, |sum, weight| sum + weight);
    let mut rates = weights.map_ref!(|weight| *weight * 10_000 / total);
    let assigned = rates.fold!(0, |sum, rate| sum + rate);
    let mut last = rates.length() - 1;
    while (rates[last] == 0) last = last - 1;
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
use blast_fun::allocation;
use std::unit_test::assert_eq;
