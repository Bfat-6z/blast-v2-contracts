// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Pins the holder-reward leaf, node, and proof bytes in `docs/vectors/holder-rewards.json`, which
/// the off-chain round builder and the SDK reproduce.
module blast_vault::reward_vector_tests;

// === Constants ===

const LEAF_0: vector<u8> = x"deb65e7b49f5e15cbb04df9a3e7ce946eea228aedf211b92587be0a480d3fbf3";
const LEAF_1: vector<u8> = x"d46b231979b019aa5a786ec4acb37c6f1bb77343c7ec74033b41d095ba9db58f";
const LEAF_2: vector<u8> = x"5a54366f5712931db217833c77abd8dc668f104cddaf7a3f3a2168f73a73c6b1";
const LEFT: vector<u8> = x"0436bb435da3045112dd67ac1ae62505abdc95eea7104692008e6f4714ce7a71";
const RIGHT: vector<u8> = x"a753d629d1cb1419de422999ead5b1c4c319730d3e513e7c1ffb3a4df7394e51";
const ROOT: vector<u8> = x"114e80767be7d15aa26dd647b7acd50850f5a341fb05a9f8b58725d09e66b2a9";

// === Tests ===

#[test]
fun the_vector_leaves_match_the_vaults_leaf_rule() {
    let vault_id = object::id_from_address(@0xd);

    assert_eq!(holder_rewards::reward_leaf_for_testing(vault_id, 0, 0, @0xa, 10, 20), LEAF_0);
    assert_eq!(holder_rewards::reward_leaf_for_testing(vault_id, 0, 1, @0xb, 30, 40), LEAF_1);
    assert_eq!(holder_rewards::reward_leaf_for_testing(vault_id, 0, 2, @0xc, 50, 60), LEAF_2);
}

#[test]
/// The odd last leaf is its own sibling, and each vector proof verifies against the root.
fun the_vector_root_and_proofs_verify() {
    assert_eq!(merkle::node(LEAF_0, LEAF_1), LEFT);
    assert_eq!(merkle::node(LEAF_2, LEAF_2), RIGHT);
    assert_eq!(merkle::node(LEFT, RIGHT), ROOT);

    assert!(merkle::verify(ROOT, LEAF_0, 0, 3, &vector[LEAF_1, RIGHT]));
    assert!(merkle::verify(ROOT, LEAF_1, 1, 3, &vector[LEAF_0, RIGHT]));
    assert!(merkle::verify(ROOT, LEAF_2, 2, 3, &vector[LEAF_2, LEFT]));
}

// === Imports ===

use blast_core::merkle;

use blast_vault::holder_rewards;

use std::unit_test::assert_eq;
