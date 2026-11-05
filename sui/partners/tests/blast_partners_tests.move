// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_partners::blast_partners_tests;

// === Constants ===

const ROOT: address = @0x0;
const ADMIN: address = @0xA11CE;
const PARTNER: address = @0xB0B;
const RECIPIENT: address = @0xFEE;
const NEW_RECIPIENT: address = @0xFEE2;
const PARTNER_CREATED_AT_MS: u64 = 1_000;
const MAX_SHARE_BPS: u64 = 8_000;
const BASIS_POINTS: u64 = 10_000;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    clock: Clock,
}

// === Tests ===

#[test]
/// The package is immutable, so this is the notice every partner is guaranteed.
fun later_share_and_cap_changes_wait_seven_days() {
    assert_eq!(partners::delay_ms(), 7 * 24 * 60 * 60 * 1_000);
}

// --- Registration ---

#[test]
fun newly_registered_partner_receives_revenue_without_advancing_the_clock() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, MAX_SHARE_BPS);
    assert_eq!(fixture.now(), PARTNER_CREATED_AT_MS);
    fixture.next_tx!(ADMIN, |fixture| {
        let partner = fixture.take_partner();
        let mut fee = balance::create_for_testing<SUI>(1_000);
        assert_eq!(fixture.pay_fee(&partner, &mut fee), 800);
        assert_eq!(fee.value(), 200);
        assert_eq!(fixture.now(), PARTNER_CREATED_AT_MS);
        let payments = event::events_by_type<PartnerPaid<SUI>>();
        assert_eq!(payments.length(), 1);
        let (partner_id, amount) = payments[0].partner_paid_fields();
        assert_eq!(partner_id, object::id(&partner));
        assert_eq!(amount, 800);
        fee.destroy_for_testing();
        fixture.return_partner(partner);
    });
    fixture.next_tx!(RECIPIENT, |fixture| {
        let payment = fixture.take_payment();
        assert_eq!(payment.value(), 800);
        payment.burn_for_testing();
    });
    cap.destroy_cap();
    fixture.end();
}

#[test]
/// Registration records the recipient, and both initial terms are applied at once with
/// the fixed notice and nothing pending; each delayed event is owned by the partner.
fun registration_share_and_cap_are_live_immediately() {
    let mut fixture = start();

    let cap = fixture.register(RECIPIENT, 2_500);
    let updates = event::events_by_type<PartnerUpdated>();
    assert_eq!(updates.length(), 1);
    let (id, recipient) = updates[0].partner_updated_fields();
    assert_eq!(recipient, RECIPIENT);
    let shares = event::events_by_type<DelayedCreated<ShareKey, u64>>();
    let caps = event::events_by_type<DelayedCreated<CapKey, ID>>();
    assert_eq!(vector[shares.length(), caps.length()], vector[1, 1]);
    let (share_owner, _, share, share_delay_ms) = shares[0].delayed_created_fields();
    let (cap_owner, _, live_cap, cap_delay_ms) = caps[0].delayed_created_fields();
    assert_eq!(vector[share_owner, cap_owner], vector[id, id]);
    assert_eq!(share, 2_500);
    assert_eq!(live_cap, object::id(&cap));
    assert_eq!(vector[share_delay_ms, cap_delay_ms], vector[delay(), delay()]);

    fixture.next_tx!(ADMIN, |fixture| {
        let partner = fixture.take_partner();
        assert_eq!(object::id(&partner), id);
        assert_eq!(partner.share_bps(), 2_500);
        assert_eq!(partner.cap_id(), object::id(&cap));
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
/// The readers return the applied recipient, share, and cap, and each proposal until it is
/// applied or cancelled; a proposal changes no applied value.
fun readers_return_applied_terms_and_pending_proposals() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        assert_eq!(partner.recipient(), RECIPIENT);
        assert!(partner.pending_share_bps().is_none());
        assert!(partner.pending_cap_id().is_none());

        fixture.schedule_share(&mut partner, 1_000);
        let next_cap = fixture.reissue_cap(&mut partner);

        assert_eq!(partner.pending_share_bps().destroy_some().value(), 1_000);
        assert_eq!(partner.pending_cap_id().destroy_some().value(), object::id(&next_cap));
        assert_eq!(partner.share_bps(), 2_500);
        assert_eq!(partner.cap_id(), object::id(&cap));

        fixture.advance(delay());
        partner.apply_share(&fixture.clock);
        partner.cancel_cap(&partner_admin());

        assert!(partner.pending_share_bps().is_none());
        assert!(partner.pending_cap_id().is_none());
        assert_eq!(partner.share_bps(), 1_000);
        assert_eq!(partner.cap_id(), object::id(&cap));
        next_cap.destroy_cap();
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
fun registration_accepts_a_zero_share_and_the_maximum_share() {
    let mut fixture = start();

    let zero = fixture.register(RECIPIENT, 0);
    let top = fixture.register(RECIPIENT, MAX_SHARE_BPS);
    let shares = event::events_by_type<DelayedCreated<ShareKey, u64>>();
    let (_, _, zero_share, _) = shares[0].delayed_created_fields();
    let (_, _, top_share, _) = shares[1].delayed_created_fields();
    assert_eq!(vector[zero_share, top_share], vector[0, MAX_SHARE_BPS]);

    zero.destroy_cap();
    top.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EShareAboveMax, location = blast_partners::blast_partners)]
fun registration_rejects_a_share_one_above_the_maximum() {
    let mut fixture = start();

    fixture.register(RECIPIENT, MAX_SHARE_BPS + 1).destroy_cap();

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EInvalidRecipient, location = blast_partners::blast_partners)]
fun registration_rejects_a_zero_recipient() {
    let mut fixture = start();

    fixture.register(@0x0, 2_500).destroy_cap();

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EInvalidRecipient, location = blast_partners::blast_partners)]
fun a_zero_recipient_precedes_a_share_above_the_maximum() {
    let mut fixture = start();

    fixture.register(@0x0, MAX_SHARE_BPS + 1).destroy_cap();

    fixture.end();
}

// --- Share ---

#[test]
/// A cut waits the full notice and then an explicit apply; until then the partner keeps
/// earning its share. Proposal and application emit only the delayed events.
fun a_scheduled_share_waits_for_explicit_application_after_the_notice() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.set_time(PARTNER_CREATED_AT_MS + delay());

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let scheduled_at = fixture.now();
        fixture.schedule_share(&mut partner, 1_000);
        let (owner, _, proposed, proposed_delay_ms, ready_at_ms) = last_share_scheduled().delayed_scheduled_fields();
        assert_eq!(owner, object::id(&partner));
        assert_eq!(vector[proposed, proposed_delay_ms, ready_at_ms], vector[1_000, delay(), scheduled_at + delay()]);
        fixture.set_time(scheduled_at + delay() - 1);
        assert_eq!(partner.share_bps(), 2_500);
        fixture.set_time(scheduled_at + delay());
        assert_eq!(partner.share_bps(), 2_500);
        partner.apply_share(&fixture.clock);
        assert_eq!(partner.share_bps(), 1_000);
        let applied = event::events_by_type<DelayedApplied<ShareKey, u64>>();
        assert_eq!(applied.length(), 1);
        let (owner, _, previous, value, applied_delay_ms) = applied[0].delayed_applied_fields();
        assert_eq!(owner, object::id(&partner));
        assert_eq!(vector[previous, value, applied_delay_ms], vector[2_500, 1_000, delay()]);
        assert_eq!(event::events_by_type<PartnerUpdated>().length(), 0);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
/// A replacement keeps the share in force, cancels the pending proposal and restarts the
/// full notice; nothing Blast proposes applies sooner than the notice after its last proposal.
fun a_new_schedule_replaces_a_pending_one_and_restarts_the_notice() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.set_time(PARTNER_CREATED_AT_MS + delay());

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 0);
        fixture.advance(delay() - 1);
        let rescheduled_at = fixture.now();
        fixture.schedule_share(&mut partner, 5_000);
        let cancelled = event::events_by_type<DelayedCancelled<ShareKey, u64>>();
        assert_eq!(cancelled.length(), 1);
        let (_, _, discarded, _, _) = cancelled[0].delayed_cancelled_fields();
        assert_eq!(discarded, 0);
        let (_, _, _, _, ready_at_ms) = last_share_scheduled().delayed_scheduled_fields();
        assert_eq!(ready_at_ms, rescheduled_at + delay());
        fixture.set_time(rescheduled_at + delay() - 1);
        assert_eq!(partner.share_bps(), 2_500);
        fixture.set_time(rescheduled_at + delay());
        partner.apply_share(&fixture.clock);
        assert_eq!(partner.share_bps(), 5_000);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
/// The superseded proposal's ready time does not carry over to its replacement.
fun a_replacement_cannot_apply_at_the_superseded_ready_time() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 0);
        fixture.advance(1);
        fixture.schedule_share(&mut partner, 5_000);
        fixture.advance(delay() - 1);
        partner.apply_share(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
fun cancelling_a_pending_cut_preserves_the_applied_share() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.set_time(PARTNER_CREATED_AT_MS + delay());

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 0);
        partner.cancel_share(&partner_admin());
        let cancelled = event::events_by_type<DelayedCancelled<ShareKey, u64>>();
        assert_eq!(cancelled.length(), 1);
        let (owner, _, discarded, _, _) = cancelled[0].delayed_cancelled_fields();
        assert_eq!(owner, object::id(&partner));
        assert_eq!(discarded, 0);
        fixture.advance(10 * delay());
        assert_eq!(partner.share_bps(), 2_500);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
/// Cancellation works after readiness, and a later proposal waits the full fixed notice again.
fun ready_share_cancellation_and_a_later_proposal_keep_the_full_notice() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 1_000);
        fixture.advance(2 * delay());
        partner.cancel_share(&partner_admin());
        assert_eq!(partner.share_bps(), 2_500);
        fixture.schedule_share(&mut partner, 3_000);
        let (_, _, _, proposed_delay_ms, ready_at_ms) = last_share_scheduled().delayed_scheduled_fields();
        assert_eq!(vector[proposed_delay_ms, ready_at_ms], vector[delay(), fixture.now() + delay()]);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
/// The partner itself, holding no role, applies a ready raise; the notice stays fixed.
fun anyone_applies_a_ready_share_and_the_notice_stays_fixed() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 5_000);
        fixture.return_partner(partner);
    });
    fixture.advance(delay());
    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner();
        partner.apply_share(&fixture.clock);
        assert_eq!(partner.share_bps(), 5_000);
        fixture.return_partner(partner);
    });
    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 6_000);
        let (_, _, _, proposed_delay_ms, ready_at_ms) = last_share_scheduled().delayed_scheduled_fields();
        assert_eq!(vector[proposed_delay_ms, ready_at_ms], vector[delay(), fixture.now() + delay()]);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun scheduling_the_applied_share_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 2_500);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EUnchanged, location = blast_partners::blast_partners)]
fun repeating_the_pending_share_is_refused() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 1_000);
        fixture.schedule_share(&mut partner, 1_000);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EShareAboveMax, location = blast_partners::blast_partners)]
fun a_scheduled_share_one_above_the_maximum_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, MAX_SHARE_BPS + 1);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun share_application_refuses_before_the_notice() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 1_000);
        fixture.advance(delay() - 1);
        partner.apply_share(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun share_application_refuses_without_a_proposal() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        partner.apply_share(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun share_application_refuses_twice() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 1_000);
        fixture.advance(delay());
        partner.apply_share(&fixture.clock);
        partner.apply_share(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun share_application_refuses_after_cancellation() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 1_000);
        partner.cancel_share(&partner_admin());
        fixture.advance(delay());
        partner.apply_share(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun share_cancellation_refuses_without_a_proposal() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        partner.cancel_share(&partner_admin());
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EInvalidDelay, location = blast_admin::delayed)]
fun scheduling_rejects_an_unrepresentable_ready_time() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();
    fixture.set_time(std::u64::max_value!() - delay() + 1);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 1_000);
        fixture.return_partner(partner);
    });

    fixture.end();
}

// --- Cap ---

#[test]
/// The old cap keeps working until the move is applied and not after; the new one the reverse.
fun a_reissued_cap_goes_live_only_when_applied_after_the_notice() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let reissued_at = fixture.now();
        let new_cap = fixture.reissue_cap(&mut partner);
        let scheduled = event::events_by_type<DelayedScheduled<CapKey, ID>>();
        assert_eq!(scheduled.length(), 1);
        let (owner, _, proposed, proposed_delay_ms, ready_at_ms) = scheduled[0].delayed_scheduled_fields();
        assert_eq!(owner, object::id(&partner));
        assert_eq!(proposed, object::id(&new_cap));
        assert_eq!(vector[proposed_delay_ms, ready_at_ms], vector[delay(), reissued_at + delay()]);
        fixture.set_time(reissued_at + delay() - 1);
        fixture.set_recipient(&mut partner, &old_cap, NEW_RECIPIENT);
        fixture.set_time(reissued_at + delay());
        assert_eq!(partner.cap_id(), object::id(&old_cap));
        partner.apply_cap(&fixture.clock);
        let applied = event::events_by_type<DelayedApplied<CapKey, ID>>();
        assert_eq!(applied.length(), 1);
        let (_, _, previous, value, applied_delay_ms) = applied[0].delayed_applied_fields();
        assert_eq!(vector[previous, value], vector[object::id(&old_cap), object::id(&new_cap)]);
        assert_eq!(applied_delay_ms, delay());
        fixture.set_recipient(&mut partner, &new_cap, RECIPIENT);
        assert_eq!(partner.recipient(), RECIPIENT);
        assert_eq!(partner.cap_id(), object::id(&new_cap));
        new_cap.destroy_cap();
        fixture.return_partner(partner);
    });

    old_cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::ENotLiveCap, location = blast_partners::blast_partners)]
fun the_replaced_cap_is_refused_once_the_reissue_is_applied() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let new_cap = fixture.reissue_cap(&mut partner);
        fixture.advance(delay());
        partner.apply_cap(&fixture.clock);
        fixture.set_recipient(&mut partner, &old_cap, NEW_RECIPIENT);
        new_cap.destroy_cap();
        fixture.return_partner(partner);
    });

    old_cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::ENotLiveCap, location = blast_partners::blast_partners)]
fun a_reissued_cap_is_refused_before_the_notice() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let new_cap = fixture.reissue_cap(&mut partner);
        fixture.advance(delay() - 1);
        fixture.set_recipient(&mut partner, &new_cap, NEW_RECIPIENT);
        new_cap.destroy_cap();
        fixture.return_partner(partner);
    });

    old_cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::ENotLiveCap, location = blast_partners::blast_partners)]
fun a_ready_cap_cannot_set_the_recipient_before_application() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let new_cap = fixture.reissue_cap(&mut partner);
        fixture.advance(2 * delay());
        fixture.set_recipient(&mut partner, &new_cap, NEW_RECIPIENT);
        new_cap.destroy_cap();
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::ENotLiveCap, location = blast_partners::blast_partners)]
/// A newer reissue supersedes a pending one, whose cap never goes live.
fun a_superseded_reissue_never_goes_live() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let superseded = fixture.reissue_cap(&mut partner);
        let latest = fixture.reissue_cap(&mut partner);
        fixture.advance(10 * delay());
        partner.apply_cap(&fixture.clock);
        fixture.set_recipient(&mut partner, &superseded, NEW_RECIPIENT);
        superseded.destroy_cap();
        latest.destroy_cap();
        fixture.return_partner(partner);
    });

    old_cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun scheduling_the_applied_cap_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, object::id(&cap));
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EUnchanged, location = blast_partners::blast_partners)]
fun repeating_the_pending_cap_is_refused() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, @0xCAFE.to_id());
        fixture.schedule_cap(&mut partner, @0xCAFE.to_id());
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
/// Cancellation preserves the original cap, including after readiness.
fun cancelling_a_ready_move_preserves_the_live_cap() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let moved_to = fixture.reissue_cap(&mut partner);
        fixture.advance(10 * delay());
        partner.cancel_cap(&partner_admin());
        let cancelled = event::events_by_type<DelayedCancelled<CapKey, ID>>();
        assert_eq!(cancelled.length(), 1);
        let (_, _, discarded, _, _) = cancelled[0].delayed_cancelled_fields();
        assert_eq!(discarded, object::id(&moved_to));
        assert_eq!(partner.cap_id(), object::id(&cap));
        fixture.set_recipient(&mut partner, &cap, NEW_RECIPIENT);
        moved_to.destroy_cap();
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
/// Share and cap proposals are independent: applying one leaves the other pending.
fun share_and_cap_proposals_apply_independently() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 1_000);
        let new_cap = fixture.reissue_cap(&mut partner);
        fixture.advance(delay());
        partner.apply_share(&fixture.clock);
        assert_eq!(partner.share_bps(), 1_000);
        assert_eq!(partner.cap_id(), object::id(&old_cap));
        partner.apply_cap(&fixture.clock);
        assert_eq!(partner.share_bps(), 1_000);
        assert_eq!(partner.cap_id(), object::id(&new_cap));
        new_cap.destroy_cap();
        fixture.return_partner(partner);
    });

    old_cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun cap_application_refuses_before_the_notice() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, @0xCAFE.to_id());
        fixture.advance(delay() - 1);
        partner.apply_cap(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun cap_application_refuses_without_a_proposal() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        partner.apply_cap(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun cap_application_refuses_twice() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, @0xCAFE.to_id());
        fixture.advance(delay());
        partner.apply_cap(&fixture.clock);
        partner.apply_cap(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun cap_application_refuses_after_cancellation() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, @0xCAFE.to_id());
        partner.cancel_cap(&partner_admin());
        fixture.advance(delay());
        partner.apply_cap(&fixture.clock);
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun cap_cancellation_refuses_without_a_proposal() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        partner.cancel_cap(&partner_admin());
        fixture.return_partner(partner);
    });

    fixture.end();
}

#[test]
/// A partner without a live cap, destroyed or never minted, strands nothing: it
/// is still paid at its recipient, and Blast moves it to a new cap, which goes
/// live once applied after the notice.
fun a_partner_without_a_live_cap_is_moved_to_a_new_one() {
    let mut fixture = start();
    fixture.register(RECIPIENT, 2_500).destroy_cap();
    let (destroyed_id, _) = fixture.last_update().partner_updated_fields();
    fixture.register_under_id(@0xCAFE.to_id(), RECIPIENT, 2_500);
    let (never_minted_id, _) = fixture.last_update().partner_updated_fields();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut destroyed = fixture.take_partner_by_id(destroyed_id);
        let mut never_minted = fixture.take_partner_by_id(never_minted_id);
        let mut fee = balance::create_for_testing<SUI>(1_000);
        assert_eq!(fixture.pay_fee(&destroyed, &mut fee), 250);
        let new_cap = partners::new_cap(fixture.ctx!());
        fixture.schedule_cap(&mut destroyed, object::id(&new_cap));
        fixture.schedule_cap(&mut never_minted, object::id(&new_cap));
        fixture.advance(delay());
        destroyed.apply_cap(&fixture.clock);
        never_minted.apply_cap(&fixture.clock);
        fixture.set_recipient(&mut destroyed, &new_cap, NEW_RECIPIENT);
        fixture.set_recipient(&mut never_minted, &new_cap, NEW_RECIPIENT);
        assert_eq!(vector[destroyed.recipient(), never_minted.recipient()], vector[NEW_RECIPIENT, NEW_RECIPIENT]);
        assert_eq!(vector[destroyed.cap_id(), never_minted.cap_id()], vector[object::id(&new_cap), object::id(&new_cap)]);
        fee.destroy_for_testing();
        new_cap.destroy_cap();
        fixture.return_partner(destroyed);
        fixture.return_partner(never_minted);
    });

    fixture.end();
}

// --- One cap, many partners ---

#[test]
/// A company holds one cap for every deal: each partner has its own share and
/// recipient, and the one cap sets both recipients.
fun one_cap_manages_every_partner_of_a_company() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 5_000);
    let (boosts_id, _) = fixture.last_update().partner_updated_fields();
    fixture.register_under(&cap, RECIPIENT, 800);
    let (other_id, _) = fixture.last_update().partner_updated_fields();
    let shares = event::events_by_type<DelayedCreated<ShareKey, u64>>();
    let caps = event::events_by_type<DelayedCreated<CapKey, ID>>();
    let (share_owner, _, other_share, _) = shares[1].delayed_created_fields();
    let (cap_owner, _, other_cap, _) = caps[1].delayed_created_fields();
    assert_eq!(vector[share_owner, cap_owner], vector[other_id, other_id]);
    assert_eq!(other_share, 800);
    assert_eq!(other_cap, object::id(&cap));

    fixture.next_tx!(PARTNER, |fixture| {
        let mut boosts = fixture.take_partner_by_id(boosts_id);
        let mut other = fixture.take_partner_by_id(other_id);
        fixture.set_recipient(&mut boosts, &cap, NEW_RECIPIENT);
        fixture.set_recipient(&mut other, &cap, NEW_RECIPIENT);
        assert_eq!(vector[boosts.recipient(), other.recipient()], vector[NEW_RECIPIENT, NEW_RECIPIENT]);
        assert_eq!(vector[boosts.share_bps(), other.share_bps()], vector[5_000, 800]);
        fixture.return_partner(boosts);
        fixture.return_partner(other);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
/// A cap anyone mints controls nothing until Blast registers a partner under it.
fun a_cap_minted_by_anyone_controls_nothing_until_a_partner_is_registered_under_it() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let own_cap = partners::new_cap(fixture.ctx!());
        let partner = fixture.take_partner();
        assert!(partner.cap_id() != object::id(&own_cap));
        fixture.return_partner(partner);
        own_cap.destroy_cap();
    });

    cap.destroy_cap();
    fixture.end();
}

// --- Recipient ---

#[test]
/// The recipient changes in the same transaction, with no Clock, even while a cap move is pending.
fun the_live_cap_sets_the_recipient_at_once() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, @0xCAFE.to_id());
        fixture.return_partner(partner);
    });
    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.set_recipient(&mut partner, &cap, NEW_RECIPIENT);
        let (partner_id, recipient) = fixture.last_update().partner_updated_fields();
        assert_eq!(partner_id, object::id(&partner));
        assert_eq!(recipient, NEW_RECIPIENT);
        assert_eq!(partner.recipient(), NEW_RECIPIENT);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::ENotLiveCap, location = blast_partners::blast_partners)]
fun another_partners_cap_precedes_an_invalid_recipient() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    let (partner_id, _) = fixture.last_update().partner_updated_fields();
    let other_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner_by_id(partner_id);
        fixture.set_recipient(&mut partner, &other_cap, @0x0);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    other_cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EInvalidRecipient, location = blast_partners::blast_partners)]
fun a_zero_recipient_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.set_recipient(&mut partner, &cap, @0x0);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EUnchanged, location = blast_partners::blast_partners)]
fun the_current_recipient_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.set_recipient(&mut partner, &cap, RECIPIENT);
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

// --- Payment ---

#[test]
fun payment_transfers_one_coin_to_the_recipient_and_skips_dust() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 5_000);

    fixture.next_tx!(ADMIN, |fixture| {
        let partner = fixture.take_partner();
        let mut fee = balance::create_for_testing<SUI>(1_001);
        assert_eq!(fixture.pay_fee(&partner, &mut fee), 500);
        assert_eq!(fee.value(), 501);
        let mut dust = balance::create_for_testing<SUI>(1);
        assert_eq!(fixture.pay_fee(&partner, &mut dust), 0);
        assert_eq!(dust.value(), 1);
        fee.destroy_for_testing();
        dust.destroy_for_testing();
        fixture.return_partner(partner);
    });

    fixture.next_tx!(RECIPIENT, |fixture| {
        let payment = fixture.take_payment();
        assert_eq!(payment.value(), 500);
        payment.burn_for_testing();
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
/// The initial share applies at registration; a replacement pays only once applied, even when ready.
fun a_partner_is_paid_its_share_from_registration_and_a_new_one_only_once_applied() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 5_000);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let mut fee = balance::create_for_testing<SUI>(1_000);
        assert_eq!(fixture.pay_fee(&partner, &mut fee), 500);
        fixture.schedule_share(&mut partner, MAX_SHARE_BPS);
        fixture.advance(delay() - 1);
        assert_eq!(fixture.pay_fee(&partner, &mut fee), 250);
        fixture.advance(1);
        assert_eq!(fixture.pay_fee(&partner, &mut fee), 125);
        partner.apply_share(&fixture.clock);
        assert_eq!(fixture.pay_fee(&partner, &mut fee), 100);
        assert_eq!(fee.value(), 25);
        fee.destroy_for_testing();
        fixture.return_partner(partner);
    });

    cap.destroy_cap();
    fixture.end();
}

#[test]
/// Every fee from 0 to 200 atoms at every share boundary pays the rounded-down
/// reference; the fee keeps exactly the rest, so Blast keeps every remainder. (Each
/// payment emits an event, so the sweep stays under the per-transaction event limit.)
fun payment_matches_the_rounded_down_reference() {
    let mut ctx = tx_context::dummy();
    let shares = vector[0, 1, 3_333, 5_000, MAX_SHARE_BPS - 1, MAX_SHARE_BPS];

    shares.do_ref!(|share_bps| {
        let partner = partners::new_for_testing(RECIPIENT, *share_bps, &mut ctx);
        201u64.do!(|amount| {
            let mut fee = balance::create_for_testing<SUI>(amount);
            let expected = ((amount as u128) * (*share_bps as u128) / (BASIS_POINTS as u128)) as u64;
            assert_eq!(partner.pay(&mut fee, &mut ctx), expected);
            assert_eq!(fee.value(), amount - expected);
            fee.destroy_for_testing();
        });
        destroy(partner);
    });

    destroy(ctx);
}

#[test]
fun payment_of_the_largest_fee_at_the_maximum_share_does_not_overflow() {
    let mut ctx = tx_context::dummy();
    let partner = partners::new_for_testing(RECIPIENT, MAX_SHARE_BPS, &mut ctx);
    let max = std::u64::max_value!();
    let mut fee = balance::create_for_testing<SUI>(max);

    let paid = partner.pay(&mut fee, &mut ctx);

    assert_eq!(paid, ((max as u128) * (MAX_SHARE_BPS as u128) / (BASIS_POINTS as u128)) as u64);
    assert_eq!(fee.value(), max - paid);
    fee.destroy_for_testing();
    destroy(partner);
    destroy(ctx);
}

#[test]
/// Every payment emits what the partner received; a payment of nothing emits nothing.
fun every_payment_emits_what_the_partner_received() {
    let mut ctx = tx_context::dummy();
    let partner = partners::new_for_testing(RECIPIENT, 5_000, &mut ctx);
    let mut fee = balance::create_for_testing<SUI>(1_001);

    assert_eq!(partner.pay(&mut fee, &mut ctx), 500);
    let mut dust = balance::create_for_testing<SUI>(1);
    assert_eq!(partner.pay(&mut dust, &mut ctx), 0);

    let payments = event::events_by_type<PartnerPaid<SUI>>();
    assert_eq!(payments.length(), 1);
    let (partner_id, amount) = payments[0].partner_paid_fields();
    assert_eq!(partner_id, object::id(&partner));
    assert_eq!(amount, 500);
    fee.destroy_for_testing();
    dust.destroy_for_testing();
    destroy(partner);
    destroy(ctx);
}

#[test]
/// Each deal under one cap is paid and reported on its own, at its own share.
fun each_deal_is_paid_and_reported_at_its_own_share() {
    let mut ctx = tx_context::dummy();
    let boosts = partners::new_for_testing(RECIPIENT, 5_000, &mut ctx);
    let other = partners::new_for_testing(RECIPIENT, 800, &mut ctx);
    let mut boosts_fee = balance::create_for_testing<SUI>(1_000);
    let mut other_fee = balance::create_for_testing<SUI>(1_000);

    assert_eq!(boosts.pay(&mut boosts_fee, &mut ctx), 500);
    assert_eq!(other.pay(&mut other_fee, &mut ctx), 80);

    let payments = event::events_by_type<PartnerPaid<SUI>>();
    let (first_id, first_amount) = payments[0].partner_paid_fields();
    let (second_id, second_amount) = payments[1].partner_paid_fields();
    assert_eq!(vector[first_id, second_id], vector[object::id(&boosts), object::id(&other)]);
    assert_eq!(vector[first_amount, second_amount], vector[500, 80]);
    boosts_fee.destroy_for_testing();
    other_fee.destroy_for_testing();
    destroy(boosts);
    destroy(other);
    destroy(ctx);
}

// === Test Helpers ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    scenario.next_tx(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(PARTNER_CREATED_AT_MS);

    Fixture { scenario, clock }
}

fun end(self: Fixture) {
    let Fixture { scenario, clock } = self;
    clock.destroy_for_testing();
    scenario.end();
}

macro fun next_tx($self: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

macro fun ctx($self: &mut Fixture): &mut TxContext {
    let fixture = $self;
    fixture.scenario.ctx()
}

fun pay_fee(self: &mut Fixture, partner: &Partner, fee: &mut balance::Balance<SUI>): u64 {
    partner.pay(fee, self.scenario.ctx())
}

fun take_payment(self: &Fixture): sui::coin::Coin<SUI> {
    assert_eq!(test_scenario::ids_for_address<sui::coin::Coin<SUI>>(RECIPIENT).length(), 1);
    assert_eq!(test_scenario::ids_for_address<sui::coin::Coin<SUI>>(ADMIN).length(), 0);
    self.scenario.take_from_address(RECIPIENT)
}

fun delay(): u64 {
    partners::delay_ms()
}

fun now(self: &Fixture): u64 {
    self.clock.timestamp_ms()
}

fun set_time(self: &mut Fixture, now_at_ms: u64) {
    self.clock.set_for_testing(now_at_ms);
}

fun advance(self: &mut Fixture, elapsed_duration_ms: u64) {
    self.clock.increment_for_testing(elapsed_duration_ms);
}

/// Mints a company's cap and registers its first partner under it; the partner
/// is shared from the next transaction on.
fun register(self: &mut Fixture, recipient: address, share_bps: u64): PartnerCap {
    let cap = partners::new_cap(self.ctx!());
    self.register_under(&cap, recipient, share_bps);
    cap
}

/// Registers another partner under an existing cap.
fun register_under(self: &mut Fixture, cap: &PartnerCap, recipient: address, share_bps: u64) {
    self.register_under_id(object::id(cap), recipient, share_bps);
}

/// Registers a partner under any ID with its initial terms in force.
fun register_under_id(self: &mut Fixture, cap_id: ID, recipient: address, share_bps: u64) {
    let witness = partner_admin();
    partners::register(&witness, cap_id, recipient, share_bps, self.ctx!());
}

fun schedule_share(self: &Fixture, partner: &mut Partner, share_bps: u64) {
    let witness = partner_admin();
    partner.schedule_share(&witness, share_bps, &self.clock);
}

/// Mints a new cap and schedules the partner to move to it.
fun reissue_cap(self: &mut Fixture, partner: &mut Partner): PartnerCap {
    let cap = partners::new_cap(self.ctx!());
    self.schedule_cap(partner, object::id(&cap));
    cap
}

fun schedule_cap(self: &Fixture, partner: &mut Partner, cap_id: ID) {
    let witness = partner_admin();
    partner.schedule_cap(&witness, cap_id, &self.clock);
}

fun set_recipient(_self: &Fixture, partner: &mut Partner, cap: &PartnerCap, recipient: address) {
    partner.set_recipient(cap, recipient);
}

fun last_update(_self: &Fixture): PartnerUpdated {
    let updates = event::events_by_type<PartnerUpdated>();
    updates[updates.length() - 1]
}

fun last_share_scheduled(): DelayedScheduled<ShareKey, u64> {
    let scheduled = event::events_by_type<DelayedScheduled<ShareKey, u64>>();
    scheduled[scheduled.length() - 1]
}

fun take_partner(self: &Fixture): Partner {
    self.scenario.take_shared<Partner>()
}

/// One partner by ID, when several are shared.
fun take_partner_by_id(self: &Fixture, partner_id: ID): Partner {
    self.scenario.take_shared_by_id<Partner>(partner_id)
}

fun return_partner(_self: &mut Fixture, partner: Partner) {
    test_scenario::return_shared(partner);
}

fun partner_admin(): AdminWitness<PartnerAdmin> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    delayed::{DelayedApplied, DelayedCancelled, DelayedCreated, DelayedScheduled}
};

use blast_partners::blast_partners::{
    Self as partners,
    CapKey,
    Partner,
    PartnerAdmin,
    PartnerCap,
    PartnerPaid,
    PartnerUpdated,
    ShareKey
};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, clock::{Self, Clock}, event, sui::SUI, test_scenario::{Self, Scenario}};
