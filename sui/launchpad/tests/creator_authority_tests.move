// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Creator recipients and the claim they authorize. Address claims through a launch are covered in
/// `launch_tests`; this suite proves the Blast account attestation.
module blast_fun::creator_authority_tests;

// === Constants ===

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const NOW_AT_MS: u64 = 1_000_000;

const EXPIRES_AT_MS: u64 = 2_000_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;

public struct OTHER_MEME() has drop;

/// A runtime configuration whose signer is live and a clock at `NOW_AT_MS`.
public struct ClaimFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

// --- Recipients ---

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorRecipient, location = blast_fun::creator_authority)]
fun address_recipient_rejects_the_zero_address() {
    creator_authority::new_address(@0x0);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidAccountCommitment, location = blast_fun::creator_authority)]
fun account_recipient_rejects_a_commitment_that_is_not_32_bytes() {
    creator_authority::new_account(x"1122");
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimAttestation, location = blast_fun::creator_authority)]
fun address_claim_rejects_an_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(creator_authority::new_address(CREATOR), option::some(attestation()));
    });

    fixture.end();
}

// --- Account claims ---

#[test]
/// The backend signs the BCS claim message binding the Meme type, the account, the claimant, and
/// the expiry; the claimant presents it and receives both caps.
fun account_claim_with_the_backend_signature_issues_both_caps() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        assert_eq!(
            creator_authority::creator_claim_message_bytes_for_testing<TEST_MEME>(
                account_commitment(),
                CREATOR,
                EXPIRES_AT_MS,
            ),
            x"64303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633a3a63726561746f725f617574686f726974795f74657374733a3a544553545f4d454d452011223344556677889900aabbccddeeffffeeddccbbaa009988776655443322110000000000000000000000000000000000000000000000000000000000c0ffee80841e0000000000",
        );

        let (curve_fee_cap, metadata_cap) = creator_authority::claim_creator_caps<TEST_MEME>(
            account_recipient(),
            f.config.creator_claim_signer(),
            option::some(attestation()),
            &f.clock,
            f.ctx!(),
        );

        assert!(object::id(&curve_fee_cap) != object::id(&metadata_cap));
        curve_fee_cap.destroy_curve_fee_cap();
        metadata_cap.destroy_metadata_cap();
    });

    fixture.end();
}

#[test]
fun account_claim_is_accepted_at_the_expiry() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.clock.set_for_testing(EXPIRES_AT_MS);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun account_claim_requires_an_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::none());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_that_is_not_64_bytes() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut signature = signature();
        signature.pop_back();
        let attestation = creator_authority::new_creator_claim_attestation_for_testing(
            EXPIRES_AT_MS,
            signature,
        );

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimAttestation, location = blast_fun::creator_authority)]
fun account_claim_rejects_trailing_attestation_bytes() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut attestation = attestation();
        attestation.push_back(0);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorClaimExpired, location = blast_fun::creator_authority)]
fun account_claim_rejects_an_expired_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.clock.set_for_testing(EXPIRES_AT_MS + 1);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_claimant() {
    let mut fixture = start();

    fixture.next_tx!(@0xBAD, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_meme() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<OTHER_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_account() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let other_account = creator_authority::new_account(
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );

        f.claim<TEST_MEME>(other_account, option::some(attestation()));
    });

    fixture.end();
}

// --- Signer rotation ---

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_an_attestation_from_a_rotated_signer() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.set_creator_claim_signer_for_testing(
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
/// An empty signer key revokes account claims: even a correctly signed attestation fails.
fun account_claim_rejects_every_attestation_once_the_signer_is_revoked() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.set_creator_claim_signer_for_testing(vector[]);
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test]
fun restoring_the_signer_reenables_account_claims() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.set_creator_claim_signer_for_testing(vector[]);
        f.set_creator_claim_signer_for_testing(signer_public_key());
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

// === Test Helpers ===

macro fun claim_next_tx(
    $fixture: &mut ClaimFixture,
    $sender: address,
    $fn: |&mut ClaimFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun claim_ctx($fixture: &mut ClaimFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): ClaimFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let config = runtime_config::new_zero_fee_share_with_signer_for_testing(signer_public_key(), scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_AT_MS);

    ClaimFixture { scenario, package_version, config, clock }
}

/// Claims as the current sender with the live signer key and discards both caps.
fun claim_claim<Meme>(
    self: &mut ClaimFixture,
    recipient: CreatorRecipient,
    attestation: Option<vector<u8>>,
) {
    let (curve_fee_cap, metadata_cap) = creator_authority::claim_creator_caps<Meme>(
        recipient,
        self.config.creator_claim_signer(),
        attestation,
        &self.clock,
        self.scenario.ctx(),
    );

    curve_fee_cap.destroy_curve_fee_cap();
    metadata_cap.destroy_metadata_cap();
}

fun claim_set_creator_claim_signer(self: &mut ClaimFixture, signer_public_key: vector<u8>) {
    let admin_witness = blast_acl::witness_for_testing<ClaimSignerAdmin>();

    if (signer_public_key.is_empty()) self.config.revoke_creator_claim_signer(&self.package_version, &admin_witness)
    else self.config.set_creator_claim_signer(&self.package_version, &admin_witness, signer_public_key);
}

fun claim_end(self: ClaimFixture) {
    destroy(self);
}

fun account_recipient(): CreatorRecipient {
    creator_authority::new_account(account_commitment())
}

/// The backend's attestation for `CREATOR` claiming `TEST_MEME` for `account_commitment()`.
fun attestation(): vector<u8> {
    creator_authority::new_creator_claim_attestation_for_testing(EXPIRES_AT_MS, signature())
}

fun account_commitment(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

// Public test fixture: Ed25519 seed [7; 32], signing the BCS message above for
// the harness's synthetic launchpad address 0xc. Never used outside tests.
fun signer_public_key(): vector<u8> {
    x"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"
}

fun signature(): vector<u8> {
    x"ff0ced0a7390306e2da4210845558a93f6594f4c30836e2499ad400e38a9fbadc4591d9188fa6aaaac9ff3575a7c212f62fc451d1266ea744b847b4c7afc6a04"
}

// === Imports ===

use blast_admin::blast_acl;

use blast_fun::{
    blast_fun_domain::ClaimSignerAdmin,
    creator_authority::{Self, CreatorRecipient},
    blast_fun::{Self as package_version, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};

use fun claim_claim as ClaimFixture.claim;

use fun claim_ctx as ClaimFixture.ctx;

use fun claim_end as ClaimFixture.end;

use fun claim_next_tx as ClaimFixture.next_tx;

use fun claim_set_creator_claim_signer as ClaimFixture.set_creator_claim_signer_for_testing;
