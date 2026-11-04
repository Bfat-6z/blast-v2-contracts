// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Positional Blake2b-256 proofs independent of the leaf's application domain. Each consumer
/// hashes its own leaves under its own domain prefix.
module blast_core::merkle;

// === Public Functions ===

/// Hashes one ordered pair as an internal node, under a domain no leaf prefix may take.
public fun node(left: vector<u8>, right: vector<u8>): vector<u8> {
    let mut bytes = vector[1u8];
    bytes.append(left);
    bytes.append(right);

    hash::blake2b256(&bytes)
}

/// Verifies a positional proof of `digest` at `index` among `leaves` leaves under `root`.
/// Returns false, before hashing, for a malformed root or digest, an empty tree, an index outside
/// it, a proof of the wrong depth, or a malformed sibling.
public fun verify(
    root: vector<u8>,
    mut digest: vector<u8>,
    mut index: u64,
    leaves: u64,
    proof: &vector<vector<u8>>,
): bool {
    if (
        root.length() != constants::digest_length!()
            || digest.length() != constants::digest_length!()
            || leaves == 0
            || index >= leaves
    ) return false;
    if (
        proof.length() != proof_depth(leaves)
            || !proof.all!(|sibling| sibling.length() == constants::digest_length!())
    ) return false;

    proof.do_ref!(|sibling| {
        digest = if (index % 2 == 0) node(digest, *sibling) else node(*sibling, digest);
        index = index / 2;
    });

    digest == root
}

// === Private Functions ===

/// The number of tree levels above `leaves` leaves, one sibling each in a proof: an odd node at
/// any level is its own sibling.
fun proof_depth(leaves: u64): u64 {
    let mut width = leaves;
    let mut depth = 0;
    while (width > 1) {
        width = width.div_ceil(2);
        depth = depth + 1;
    };

    depth
}

// === Imports ===

use blast_core::constants;

use sui::hash;
