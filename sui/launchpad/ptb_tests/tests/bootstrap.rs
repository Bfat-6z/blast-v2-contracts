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
    let bootstrap = publication.created(&h, "blast_fun", "Bootstrap")[0];
    let cap = publication.created(&h, "package", "UpgradeCap")[0];
    assert_eq!(bcs::from_bytes::<UpgradeCap>(&h.contents(cap))?.version, 1);
    let config = publication.created(&h, "launch_config", "LaunchConfig")[0];
    let foreign_cap = admin_publication.created(&h, "package", "UpgradeCap")[0];

    let mut b = ProgrammableTransactionBuilder::new();
    let (bootstrap_arg, config_arg) = h.bootstrap_launchpad_route(&mut b, blast, &publication, parse_sui_type_tag("0x2::sui::SUI")?, parse_sui_type_tag(&format!("{blast}::blast_fun::BLAST_FUN"))?)?;
    let cap_arg = b.obj(h.owned(foreign_cap))?;
    call(&mut b, blast, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg, config_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 15 },
        &[bootstrap, cap, foreign_cap, config],
        &[h.sender],
    )?;

    // Every initial policy is usable at publication time, before any Clock advance.
    let clock_before = h.contents(sui_types::SUI_CLOCK_OBJECT_ID);
    let mut b = ProgrammableTransactionBuilder::new();
    let bootstrap_arg = b.obj(h.owned(bootstrap))?;
    let runtime = publication.created(&h, "runtime_config", "RuntimeConfig")[0];
    let config_arg = b.obj(h.shared(config, true))?;
    let runtime_arg = b.obj(h.shared(runtime, true))?;
    let mut rates = Vec::new();
    for value in [100u64, 200, 300, 400, 500] {
        let value = b.pure(value)?;
        rates.push(call(&mut b, blast, "bps", "new", vec![], vec![value]));
    }
    let creation_fee = b.pure(123u64)?;
    call(&mut b, blast, "launch_config", "bootstrap", vec![],
        vec![config_arg, bootstrap_arg, rates[0], rates[1], rates[2], rates[3], creation_fee]);
    let signer = b.pure(vec![0x11u8; 32])?;
    let treasury = b.pure(h.sender)?;
    call(&mut b, blast, "runtime_config", "bootstrap", vec![],
        vec![runtime_arg, bootstrap_arg, signer, rates[4], treasury]);
    h.execute(b.finish())?.assert_success();
    let version = h.wrap_launchpad(blast, &publication, parse_sui_type_tag("0x2::sui::SUI")?, parse_sui_type_tag(&format!("{blast}::blast_fun::BLAST_FUN"))?)?;
    h.unpause(blast, "blast_fun", admin, &admin_publication, version, 7)?;
    h.shared(version, false);
    assert_eq!(h.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
    // Simulacrum resolves historical owned inputs; test_scenario covers repeated intake.
    assert!(h.sim.store().get_object(&bootstrap).is_none());

    // A native upgrade is possible before wrapping, but its cap can never activate this lineage.
    let (unwrapped, publication) = h.publish(code.clone())?;
    let bootstrap = publication.created(&h, "blast_fun", "Bootstrap")[0];
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
    assert!(upgraded.created(&h, "blast_fun", "Bootstrap").is_empty());
    let mut b = ProgrammableTransactionBuilder::new();
    let (bootstrap_arg, config_arg) = h.bootstrap_launchpad_route(&mut b, unwrapped, &publication, parse_sui_type_tag("0x2::sui::SUI")?, parse_sui_type_tag(&format!("{unwrapped}::blast_fun::BLAST_FUN"))?)?;
    let cap_arg = b.obj(h.owned(cap))?;
    call(&mut b, unwrapped, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg, config_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 15 },
        &[bootstrap, cap, config],
        &[h.sender],
    )?;

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
