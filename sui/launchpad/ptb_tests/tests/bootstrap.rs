//! Publication must remain inactive until the original, never-upgraded cap enters custody.

use anyhow::Result;
use blast_launchpad_ptb_tests::{Expected, Harness, Outcome, build, build_timelock, call, sui_dir, timelock_dir};
use sui_types::{
    base_types::{ObjectID, SuiAddress},
    move_package::{MovePackage, UpgradeCap},
    parse_sui_type_tag,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command},
};

#[test]
fn only_fresh_matching_custody_enables_the_launchpad() -> Result<()> {
    let work = blast_launchpad_ptb_tests::test_work_dir().join("launchpad_bootstrap");
    let sui = sui_dir();
    let timelock_dir = timelock_dir()?;
    let admin_dir = sui.join("admin");
    let partners_dir = sui.join("partners");
    let mut h = Harness::new()?;
    let (timelock, _) = h.publish(build_timelock(&work)?)?;
    let (admin, admin_publication) = h.publish(build(&admin_dir, &[(&timelock_dir, timelock)], &work)?)?;
    let (partners, _) = h.publish(build(&partners_dir, &[(&timelock_dir, timelock), (&admin_dir, admin)], &work)?)?;
    assert_initial_partner_payment(&mut h, admin, &admin_publication, partners)?;
    let code = build(
        &sui.join("launchpad"),
        &[(&timelock_dir, timelock), (&admin_dir, admin), (&partners_dir, partners)],
        &work,
    )?;
    let (blast, publication) = h.publish(code.clone())?;
    assert!(publication.created(&h, "blast_fun", "PackageVersion").is_empty());
    assert!(publication.created(&h, "package_admin", "PackageAdmin").is_empty());
    assert!(publication.created(&h, "package", "Publisher").is_empty());
    let bootstrap = publication.created(&h, "blast_fun", "Publication")[0];
    let cap = publication.created(&h, "package", "UpgradeCap")[0];
    assert_eq!(bcs::from_bytes::<UpgradeCap>(&h.contents(cap))?.version, 1);
    let config = publication.created(&h, "launch_config", "LaunchConfig")[0];
    let foreign_cap = admin_publication.created(&h, "package", "UpgradeCap")[0];

    let mut b = ProgrammableTransactionBuilder::new();
    let bootstrap_arg = b.obj(h.owned(bootstrap))?;
    let cap_arg = b.obj(h.owned(foreign_cap))?;
    call(&mut b, blast, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 15 },
        &[bootstrap, cap, foreign_cap, config],
        &[h.sender],
    )?;

    // Initial routes use real ACL roles at zero delay; enabling 48h needs no Clock advance.
    let clock_before = h.contents(sui_types::SUI_CLOCK_OBJECT_ID);
    let (version, _) = h.wrap_launchpad(blast, &publication, admin, &admin_publication, parse_sui_type_tag("0x2::sui::SUI")?, parse_sui_type_tag(&format!("{blast}::blast_fun::BLAST_FUN"))?)?;
    h.unpause(blast, "blast_fun", admin, &admin_publication, version, 7)?;
    h.shared(version, false);
    assert_eq!(h.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
    // Simulacrum resolves historical owned inputs; test_scenario covers repeated intake.
    assert!(h.sim.store().get_object(&bootstrap).is_none());

    assert_delay_changes_use_the_old_notice(&mut h, blast, admin, &admin_publication, version, config)?;

    // A native upgrade is possible before wrapping, but its cap can never activate this lineage.
    let (unwrapped, publication) = h.publish(code.clone())?;
    let bootstrap = publication.created(&h, "blast_fun", "Publication")[0];
    let cap = publication.created(&h, "package", "UpgradeCap")[0];
    let config = publication.created(&h, "launch_config", "LaunchConfig")[0];
    let digest = MovePackage::compute_digest_for_modules_and_deps(&code.modules, &code.dependencies, true);
    let framework = sui_types::SUI_FRAMEWORK_PACKAGE_ID;
    let mut b = ProgrammableTransactionBuilder::new();
    let cap_arg = b.obj(h.owned(cap))?;
    let policy = b.pure(0u8)?;
    let digest = b.pure(digest.to_vec())?;
    let ticket = call(&mut b, framework, "package", "authorize_upgrade", vec![], vec![cap_arg, policy, digest]);
    let receipt = b.upgrade(unwrapped, ticket, code.dependencies, code.modules);
    call(&mut b, framework, "package", "commit_upgrade", vec![], vec![cap_arg, receipt]);
    let upgraded = h.execute(b.finish())?;
    upgraded.assert_success();
    assert_eq!(bcs::from_bytes::<UpgradeCap>(&h.contents(cap))?.version, 2);
    assert!(upgraded.created(&h, "blast_fun", "PackageVersion").is_empty());
    assert!(upgraded.created(&h, "blast_fun", "Publication").is_empty());
    let mut b = ProgrammableTransactionBuilder::new();
    let bootstrap_arg = b.obj(h.owned(bootstrap))?;
    let cap_arg = b.obj(h.owned(cap))?;
    call(&mut b, unwrapped, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 15 },
        &[bootstrap, cap, config],
        &[h.sender],
    )?;

    Ok(())
}

/// A real PTB applies a ready delay and then schedules using the newly applied policy.
fn assert_delay_changes_use_the_old_notice(h: &mut Harness, blast: ObjectID, admin: ObjectID,
    publication: &Outcome, version: ObjectID, config: ObjectID,
) -> Result<()> {
    let cap = h.configuration_admin(admin, publication, blast, "blast_fun_domain", &["UpgradeAdmin", "FeeAdmin", "CancelAdmin"])?;
    let mut b = ProgrammableTransactionBuilder::new();
    let upgrade = h.configuration_witness(&mut b, admin, publication, cap, blast, "blast_fun_domain", "UpgradeAdmin")?;
    let version_arg = b.obj(h.shared(version, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let delay = b.pure(25u64)?;
    call(&mut b, blast, "blast_fun", "schedule_admin_delay", vec![], vec![version_arg, upgrade, delay, clock]);
    h.execute(b.finish())?.assert_success();
    let decode = |h: &Harness| -> Result<(u64, Option<(u64, u64)>)> {
        let (_, _, _, delay): (ObjectID, u8, u64, (u64, Option<(u64, u64)>)) = bcs::from_bytes(&h.contents(version))?;
        Ok(delay)
    };
    let (_, scheduled_at_ms): (ObjectID, u64) = bcs::from_bytes(&h.contents(sui_types::SUI_CLOCK_OBJECT_ID))?;
    assert_eq!(decode(h)?, (172_800_000, Some((25, scheduled_at_ms + 172_800_000))));
    h.sim.advance_clock(std::time::Duration::from_millis(172_799_999));
    let mut b = ProgrammableTransactionBuilder::new();
    let version_arg = b.obj(h.shared(version, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, blast, "blast_fun", "apply_admin_delay", vec![], vec![version_arg, clock]);
    h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "delayed", code: 20 }, &[version], &[])?;
    h.sim.advance_clock(std::time::Duration::from_millis(1));

    let mut b = ProgrammableTransactionBuilder::new();
    let version_arg = b.obj(h.shared(version, true))?;
    let config_arg = b.obj(h.shared(config, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let fee = h.configuration_witness(&mut b, admin, publication, cap, blast, "blast_fun_domain", "FeeAdmin")?;
    call(&mut b, blast, "blast_fun", "apply_admin_delay", vec![], vec![version_arg, clock]);
    let value = b.pure(123u64)?;
    call(&mut b, blast, "launch_config", "schedule_creation_fee", vec![], vec![config_arg, version_arg, fee, value, clock]);
    call(&mut b, blast, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
    h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "delayed", code: 20 }, &[version, config, cap], &[])?;
    assert_eq!(decode(h)?.0, 172_800_000);

    let mut b = ProgrammableTransactionBuilder::new();
    let version_arg = b.obj(h.shared(version, true))?;
    let config_arg = b.obj(h.shared(config, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let fee = h.configuration_witness(&mut b, admin, publication, cap, blast, "blast_fun_domain", "FeeAdmin")?;
    call(&mut b, blast, "blast_fun", "apply_admin_delay", vec![], vec![version_arg, clock]);
    let value = b.pure(123u64)?;
    call(&mut b, blast, "launch_config", "schedule_creation_fee", vec![], vec![config_arg, version_arg, fee, value, clock]);
    let applied = h.execute(b.finish())?;
    applied.assert_success();
    assert_eq!(decode(h)?, (25, None));
    let scheduled = applied.events.iter().find(|event| event.type_.type_params.iter().any(|tag| tag.to_canonical_string(true).ends_with("::events::CreationFeeScheduled"))).expect("scheduled creation fee");
    assert_eq!(bcs::from_bytes::<(u64, u64)>(&scheduled.contents)?, (123, scheduled_at_ms + 172_800_000 + 25));
    h.sim.advance_clock(std::time::Duration::from_millis(25));
    let mut b = ProgrammableTransactionBuilder::new();
    let version_arg = b.obj(h.shared(version, false))?;
    let config_arg = b.obj(h.shared(config, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, blast, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
    h.execute(b.finish())?.assert_success();

    // A cap without UpgradeAdmin cannot acquire the witness needed to alter the delay.
    let forbidden = h.configuration_admin(admin, publication, blast, "blast_fun_domain", &["FeeAdmin"])?;
    let mut b = ProgrammableTransactionBuilder::new();
    h.configuration_witness(&mut b, admin, publication, forbidden, blast, "blast_fun_domain", "UpgradeAdmin")?;
    h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "blast_acl", code: 5 }, &[version, forbidden], &[])?;
    Ok(())
}

/// Real ACL registration activates the agreed share before any Clock advancement.
fn assert_initial_partner_payment(
    h: &mut Harness,
    admin: ObjectID,
    publication: &Outcome,
    partners: ObjectID,
) -> Result<()> {
    let clock_before = h.contents(sui_types::SUI_CLOCK_OBJECT_ID);
    let acl = publication.created(h, "blast_acl", "ACL")[0];
    let root = publication.created(h, "blast_acl", "SuperAdminCap")[0];
    let recipient = SuiAddress::from(ObjectID::from_single_byte(0xFE));
    let framework = sui_types::SUI_FRAMEWORK_PACKAGE_ID;
    let sui = parse_sui_type_tag("0x2::sui::SUI")?;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, true))?;
    let root_arg = b.obj(h.owned(root))?;
    let owner = b.pure(h.sender)?;
    call(&mut b, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, owner]);
    let granted = h.impersonate_cap_owner(root, b.finish())?;
    granted.assert_success();
    let admin_cap = granted.created(h, "blast_acl", "AdminCap")[0];
    let role = parse_sui_type_tag(&format!("{partners}::blast_partners::PartnerAdmin"))?;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, true))?;
    let root_arg = b.obj(h.owned(root))?;
    let cap_id = b.pure(admin_cap)?;
    call(&mut b, admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl_arg, root_arg, cap_id]);
    h.impersonate_cap_owner(root, b.finish())?.assert_success();

    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, false))?;
    let admin_arg = b.obj(h.owned(admin_cap))?;
    let witness = call(&mut b, admin, "blast_acl", "sign_in", vec![role], vec![acl_arg, admin_arg]);
    let cap = call(&mut b, partners, "blast_partners", "new_cap", vec![], vec![]);
    let cap_type = parse_sui_type_tag(&format!("{partners}::blast_partners::PartnerCap"))?;
    let cap_id = call(&mut b, framework, "object", "id", vec![cap_type], vec![cap]);
    let recipient_arg = b.pure(recipient)?;
    let share = b.pure(8_000u64)?;
    call(&mut b, partners, "blast_partners", "register", vec![], vec![witness, cap_id, recipient_arg, share]);
    b.transfer_arg(h.sender, cap);
    let registered = h.execute(b.finish())?;
    registered.assert_success();
    let partner = registered.created(h, "blast_partners", "Partner")[0];
    let updates: Vec<_> = registered.events.iter().filter(|event| event.type_.name.as_str() == "PartnerUpdated").collect();
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0].contents, h.contents(partner));

    let mut b = ProgrammableTransactionBuilder::new();
    let partner_arg = b.obj(h.shared(partner, false))?;
    let clock_arg = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let amount = b.pure(1_000u64)?;
    let Argument::Result(split) = b.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
        unreachable!("SplitCoins is a command result");
    };
    let balance = call(&mut b, framework, "coin", "into_balance", vec![sui.clone()], vec![Argument::NestedResult(split, 0)]);
    call(&mut b, partners, "blast_partners", "pay", vec![sui.clone()], vec![partner_arg, balance, clock_arg]);
    let remainder = call(&mut b, framework, "coin", "from_balance", vec![sui.clone()], vec![balance]);
    b.transfer_arg(h.sender, remainder);
    let paid = h.execute(b.finish())?;
    paid.assert_success();
    assert_eq!(paid.coins_created_for(h, recipient), vec![(sui.to_canonical_string(true), 800)]);
    assert_eq!(paid.coins_created_for(h, h.sender), vec![(sui.to_canonical_string(true), 200)]);
    let payments: Vec<_> = paid.events.iter().filter(|event| event.type_.name.as_str() == "PartnerPaid").collect();
    assert_eq!(payments.len(), 1);
    assert_eq!(bcs::from_bytes::<(ObjectID, u64)>(&payments[0].contents)?, (partner, 800));
    assert_eq!(h.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
    Ok(())
}
