#!/usr/bin/env python3
"""Check the ADR 0134 authority, storage and pause boundaries against production functions."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / 'sui/launchpad/scripts/move_facts.awk'


def facts(package, module):
    path = ROOT / 'sui' / package / 'sources' / f'{module}.move'
    rows = subprocess.check_output(['awk', '-f', str(READER), str(path)], text=True).splitlines()
    assert not any(row.startswith('MALFORMED') for row in rows), path
    return [row.split('\t') for row in rows]


def functions(package, module):
    return {row[1]: (row[8], row[9]) for row in facts(package, module)
            if row[0] == 'FN' and row[5] == '0'}


def require(text, *parts):
    for part in parts:
        assert part in text, f'missing {part}'


def governed(package, module, fields, version='package_version', shared_notice=()):
    """Fields in `shared_notice` wait a notice shared with other entries, so their schedules
    take no delay of their own; the shared notice is governed as `<field>_delay`."""
    fs = functions(package, module)
    for field, role in fields.items():
        for phase in ('schedule', 'apply', 'cancel'):
            name = f'{phase}_{field}'
            signature, body = fs[name]
            assert body.startswith(f'{version}.assert_current();'), (package, module, name)
            if phase == 'apply':
                assert 'AdminWitness' not in signature, (module, name)
                require(signature, 'clock: &Clock')
                assert re.search(r'\.apply\([^;]*clock\);', body), (module, name)
            else:
                require(signature, f'&AdminWitness<{role if phase == "schedule" else "CancelAdmin"}>')
                if phase == 'schedule':
                    require(signature, 'clock: &Clock')
                    if field in shared_notice:
                        assert 'delay_ms: u64' not in signature, (module, name)
                    else:
                        require(signature, 'delay_ms: u64')
                require(body, '.schedule(' if phase == 'schedule' else '.cancel(')
        assert f'set_{field}' not in fs, (module, field)


governed('launchpad', 'runtime_config', {'treasury': 'TreasuryAdmin', 'protocol_fee_share': 'FeeAdmin'})
governed('launchpad', 'launch_config', {'creation_fee': 'FeeAdmin', 'trade_fees': 'FeeAdmin', 'protocol_allocation': 'TreasuryAdmin'})
governed('presale', 'fee_policy', {'destination': 'TreasuryAdmin', 'fees': 'FeeAdmin'})
governed('presale', 'presale_vault', {'protocol_lp_fees': 'FeeAdmin'})
governed('migrators', 'lp_fee_policy', {'protocol_destination': 'TreasuryAdmin', 'default_shares': 'FeeAdmin', 'coin_shares': 'FeeAdmin'}, 'migrators_version', shared_notice=('coin_shares',))
coin_notice = functions('migrators', 'lp_fee_policy')
require(coin_notice['schedule_coin_shares_delay'][0], '&AdminWitness<FeeAdmin>', 'delay_ms: u64', 'clock: &Clock')
require(coin_notice['schedule_coin_shares_delay'][1], 'self.coins.schedule_delay(delay_ms, clock)')
require(coin_notice['apply_coin_shares_delay'][1], 'self.coins.apply_delay(clock)')
assert 'AdminWitness' not in coin_notice['apply_coin_shares_delay'][0]
require(coin_notice['cancel_coin_shares_delay'][0], '&AdminWitness<CancelAdmin>')
require(coin_notice['schedule_clear_coin_shares'][1], 'self.coins.schedule(type_name::with_original_ids<Meme>(), option::none(), clock)')
require((ROOT / 'sui/migrators/sources/lp_fee_policy.move').read_text(), 'coins: DelayedMap<CoinSharesKey, TypeName, SharePair>,')

for package in ('launchpad', 'presale', 'migrators'):
    fs = functions(package, 'package_admin')
    source = (ROOT / 'sui' / package / 'sources' / 'package_admin.move').read_text()
    require(source, 'upgrade: DelayedAction<UpgradeKey, UpgradeAction>,', 'public struct UpgradeKey() has copy, drop, store;')
    assert 'DelayOnly' not in source and 'delay_ms: u64,\n' not in source.split('public struct PackageAdmin')[1].split('}')[0], package
    for name in ('schedule_upgrade', 'schedule_make_immutable', 'authorize_upgrade', 'make_immutable'):
        signature, body = fs[name]
        require(signature, '&AdminWitness<UpgradeAdmin>', 'clock: &Clock')
        assert body.startswith('package_version.assert_current();'), (package, name)
    require(fs['schedule_upgrade'][1], 'digest.length() == 32', 'self.upgrade.schedule(UpgradeAction::Upgrade(digest), clock)')
    require(fs['schedule_make_immutable'][1], 'self.upgrade.schedule(UpgradeAction::MakeImmutable, clock)')
    for name in ('schedule_upgrade', 'schedule_make_immutable'):
        assert 'delay_ms: u64' not in fs[name][0], (package, name)
    for name, action in [('authorize_upgrade', 'Upgrade(digest)'), ('make_immutable', 'MakeImmutable')]:
        body = fs[name][1]
        require(body, 'self.upgrade.take_action(clock)', f'action == UpgradeAction::{action}')
        assert body.index('self.upgrade.take_action(clock)') < body.index(f'action == UpgradeAction::{action}') < body.index('self.custody.'), name
    require(fs['cancel_upgrade_action'][0], '&AdminWitness<CancelAdmin>')
    require(fs['cancel_upgrade_action'][1], 'self.upgrade.cancel()')
    require(fs['wrap'][1], 'upgrade_custody::new')
    require(fs['wrap'][0], 'publication: Publication')
    require(fs['wrap'][1], 'publication.destroy()', 'generation.share_version(ctx)')
    assert fs['wrap'][1].index('upgrade_custody::new') < fs['wrap'][1].index('generation.share_version(ctx)')
    assert fs['commit_upgrade_and_advance'][1].startswith('package_version.assert_next();')
    require(fs['commit_upgrade_and_advance'][1], 'self.custody.commit_upgrade(custodian_id, receipt); package_version.advance();')
    for signature, _ in fs.values():
        assert not re.search(r'\):\s*&?(?:mut )?(Publisher|UpgradeCap)', signature)

for package, module in [('launchpad', 'launch_config'), ('presale', 'creation_policy')]:
    fs = functions(package, module)
    source = (ROOT / 'sui' / package / 'sources' / f'{module}.move').read_text()
    require(source, 'migration_witnesses: DelayedSet<MigrationWitnessKey, TypeName>,')
    assert 'witness_delay_ms' not in source and 'pending_witness' not in source, package
    require(fs['schedule_migration_witness'][0], '&AdminWitness<AdapterAdmin>', 'clock: &Clock')
    assert 'delay_ms: u64' not in fs['schedule_migration_witness'][0], package
    body = fs['schedule_migration_witness'][1]
    require(body, 'witness.is_primitive()', 'origin != @0x1 && origin != @0x2', 'self.migration_witnesses.schedule_add(witness, clock)')
    assert body.index('origin != @0x1') < body.index('schedule_add'), package
    require(fs['apply_migration_witness'][1], 'self.migration_witnesses.apply_add(')
    assert 'AdminWitness' not in fs['apply_migration_witness'][0]
    require(fs['cancel_migration_witness'][0], '&AdminWitness<CancelAdmin>')
    require(fs['cancel_migration_witness'][1], 'self.migration_witnesses.cancel_add(')
    require(fs['remove_migration_witness'][0], '&AdminWitness<AdapterAdmin>')
    require(fs['remove_migration_witness'][1], 'self.migration_witnesses.remove(')
    require(fs['schedule_migration_delay'][0], '&AdminWitness<AdapterAdmin>', 'delay_ms: u64', 'clock: &Clock')
    require(fs['schedule_migration_delay'][1], 'self.migration_witnesses.schedule_delay(delay_ms, clock)')
    require(fs['apply_migration_delay'][1], 'self.migration_witnesses.apply_delay(clock)')
    assert 'AdminWitness' not in fs['apply_migration_delay'][0]
    require(fs['cancel_migration_delay'][0], '&AdminWitness<CancelAdmin>')
    assert 'set_migration_witness_allowed' not in fs

fs = functions('launchpad', 'launch')
source = (ROOT / 'sui/launchpad/sources/launch.move').read_text()
assert 'apply_cap_reassignment_delay' not in fs and '_delay_ms: u64,' not in source.split('public struct Launch<')[1].split('\n}')[0]
for cap in ['curve_fee_cap', 'metadata_cap']:
    require(fs[f'schedule_{cap}_reassignment'][0], '&AdminWitness<CreatorAdmin>', 'clock: &Clock')
    assert 'delay_ms: u64' not in fs[f'schedule_{cap}_reassignment'][0], cap
    require(fs[f'schedule_{cap}_reassignment'][1], f'.schedule(recipient, clock)')
    require(fs[f'cancel_{cap}_reassignment'][0], '&AdminWitness<CancelAdmin>')
    require(fs[f'cancel_{cap}_reassignment'][1], '.cancel()')
    require(fs[f'schedule_{cap}_delay'][0], '&AdminWitness<CreatorAdmin>', 'delay_ms: u64', 'clock: &Clock')
    require(fs[f'schedule_{cap}_delay'][1], '.schedule_delay(delay_ms, clock)')
    require(fs[f'apply_{cap}_reassignment'][1], '.take_action(clock)')
    require(fs[f'apply_{cap}_delay'][1], '.apply_delay(clock)')
    for phase in ('reassignment', 'delay'):
        assert 'AdminWitness' not in fs[f'apply_{cap}_{phase}'][0], (cap, phase)

for package, module, actions in [
    ('launchpad', 'launch', {
        'new': 'constants::create_pause_bit!()',
        'finalize': 'constants::create_pause_bit!()',
        'share': 'constants::create_pause_bit!()',
        'buy': 'constants::trading_pause_bit!()',
        'join_opening_round': 'constants::trading_pause_bit!()',
        'settle_opening_round': 'constants::trading_pause_bit!()',
        'sell': 'constants::trading_pause_bit!()',
        'migrate': 'constants::migration_pause_bit!()',
    }),
    ('presale', 'blast_presale', {'new': 1, 'share': 1, 'commit_open': 2, 'commit_allowlisted': 2, 'commit_uncapped': 2, 'migrate': 8}),
]:
    fs = functions(package, module)
    for name, bit in actions.items():
        body = fs[name][1]
        assert body.startswith(f'package_version.assert_current(); package_version.assert_not_paused({bit});'), (package, name)
    for name, (_, body) in fs.items():
        if name not in actions: assert 'assert_not_paused' not in body, (package, name)

acl = (ROOT / 'sui/admin/sources/blast_acl.move').read_text()
require(acl, 'admins: Table<ID, VecSet<TypeName>>,', 'super_admin_transfer: DelayedAction<SuperAdminTransfer, address>,')
assert 'MAX_ADMINS' not in acl and 'Timelocked' not in acl
print('ADR 0134 administration boundaries: OK')

# Publication proves unique native custody intake; it never authorizes policy changes.
for package, marker in [('launchpad', 'blast_fun'), ('presale', 'blast_presale_package'), ('migrators', 'blast_fun_migrators')]:
    marker_fs = functions(package, marker)
    require(marker_fs['init'][1], 'transfer::transfer(Publication', 'sui::package::claim(otw, ctx)')
    assert 'share_object' not in marker_fs['init'][1]
    require(marker_fs['destroy'][0], 'self: Publication')
    assert {name for name, (_, body) in marker_fs.items() if re.search(r'\bPublication\s*{', body)} == {'init', 'destroy'}
    assert marker_fs['init'][0].startswith('fun init(')
    source = (ROOT / 'sui' / package / 'sources' / f'{marker}.move').read_text()
    require(source, 'public struct Publication has key {')
    assert 'admin_delay' not in source
    if package != 'migrators':
        assert 'paused: 0' not in marker_fs['share_version'][1]
    for path in (ROOT / 'sui' / package / 'sources').rglob('*.move'):
        production = path.read_text().split('// === Test-Only Functions ===')[0]
        assert 'Bootstrap' not in production, path
        assert 'set_now' not in production, path
        if path.stem not in (marker, 'package_admin'):
            assert 'Publication' not in production, path
        for name, (signature, body) in functions(package, str(path.relative_to(ROOT / 'sui' / package / 'sources').with_suffix(''))).items():
            if not re.search(r'\.schedule(_add|_value)?\(', body):
                continue
                continue
            require(signature, 'clock: &Clock')
            action_only = (
                path.stem == 'package_admin' and name in ('schedule_upgrade', 'schedule_make_immutable')
                or path.stem in ('launch_config', 'creation_policy') and name == 'schedule_migration_witness'
                or package == 'launchpad' and path.stem == 'launch'
                and name in ('schedule_curve_fee_cap_reassignment', 'schedule_metadata_cap_reassignment')
                or package == 'migrators' and path.stem == 'lp_fee_policy'
                and name in ('schedule_coin_shares', 'schedule_clear_coin_shares')
            )
            if action_only:
                assert 'delay_ms: u64' not in signature, (path, name)
            else:
                require(signature, 'delay_ms: u64')
            assert 'admin_delay_ms()' not in body, (path, name)
            assert 'new_pending' not in body and 'take_ready' not in body, (path, name)

primitive = functions('admin', 'delayed')
assert not any(name.startswith(('set_', 'force', 'bypass')) for name in primitive)
assert 'new_pending' not in primitive and 'take_ready' not in primitive
require(primitive['ready_at_ms_after'][1], 'clock.timestamp_ms().checked_add(applied_delay_ms)', '.destroy_or!(abort blast_admin::errors::invalid_delay!())', 'ready_at_ms.checked_add(next_delay_ms).is_some()')
require(primitive['assert_ready_at'][1], 'clock.timestamp_ms() >= ready_at_ms', 'clock.timestamp_ms().checked_add(next_delay_ms).is_some()')
require(primitive['schedule'][1], 'ready_at_ms_after(self.delay_ms, delay_ms, clock)')
require(functions('admin', 'delayed_set')['schedule_add'][1], 'delayed::ready_at_ms_after(self.delay_ms, 0, clock)')
require(functions('admin', 'delayed_map')['schedule'][1], 'delayed::ready_at_ms_after(self.delay_ms, 0, clock)')
for module in ('delayed_action', 'delayed_set', 'delayed_map'):
    assert not any(name.startswith(('set_', 'force', 'bypass')) for name in functions('admin', module)), module
require(primitive['apply'][1], 'self.assert_ready(clock)', 'self.value = value;', 'self.delay_ms = delay_ms;')
for name in ('schedule_value', 'schedule_delay'):
    require(primitive[name][1], 'self.schedule(value, delay_ms, clock)')

# Creator-controlled migrated-vault policy follows the same delayed value invariant,
# but its authority is the operation-specific live creator cap rather than an admin role.
require(primitive['assert_ready'][0], 'self: &Delayed<K, T>', 'clock: &Clock')
require(primitive['assert_ready'][1], 'self.pending.is_some()', 'errors::no_pending!()', 'assert_ready_at(')
assert 'self.pending =' not in primitive['assert_ready'][1]
for package, module, version, authority in (
    ('migrators', 'vault', 'migrators_version', 'launch.assert_curve_fee_cap(curve_fee_cap);'),
    ('presale', 'presale_vault', 'package_version', 'self.assert_cap(cap);'),
):
    fs = functions(package, module)
    source = (ROOT / 'sui' / package / 'sources' / f'{module}.move').read_text()
    require(source, 'fee_split: Delayed<FeeSplitKey, FeeSplit>', 'DEFAULT_FEE_SPLIT_DELAY_MS: u64 = 48 * 60 * 60 * 1_000')
    for name in ('schedule_fee_split', 'cancel_fee_split'):
        signature, body = fs[name]
        assert body.startswith(f'{version}.assert_current(); {authority}'), (package, name)
        assert 'AdminWitness' not in signature
    require(fs['schedule_fee_split'][1], 'self.fee_split.schedule(proposed, delay_ms, clock)')
    require(fs['cancel_fee_split'][1], 'self.fee_split.cancel()')
    require(fs['assert_fee_split_ready'][1], 'self.fee_split.assert_ready(clock)')
    require(fs['apply_fee_split'][1], 'self.fee_split.apply(clock)')
    visibility = {row[1]: row[2] for row in facts(package, module) if row[0] == 'FN'}
    assert visibility['apply_fee_split'] == 'package'
    assert visibility['assert_fee_split_ready'] == 'package'
    for venue in ('bluefin', 'cetus'):
        signature, body = functions(package, venue)['settle_and_apply_fee_split']
        assert body.startswith(f'{version}.assert_current();')
        assert 'FeeSplit' not in signature and 'Cap' not in signature
        settlement = 'self.settle_fees(' if package == 'migrators' else 'collect_fees('
        assert body.index('.assert_fee_split_ready(clock)') < body.index(settlement) < body.index('.apply_fee_split(clock)')
aftermath = functions('presale', 'aftermath')['apply_fee_split'][1]
assert aftermath.startswith('package_version.assert_current();')
assert aftermath.index('vault.has_position(&Venue())') < aftermath.index('vault.assert_fee_split_ready(clock)') < aftermath.index('vault.apply_fee_split(clock)')

signer = functions('launchpad', 'runtime_config')
for name in ('set_creator_claim_signer', 'revoke_creator_claim_signer'):
    require(signer[name][0], '&AdminWitness<ClaimSignerAdmin>')
    assert signer[name][1].startswith('package_version.assert_current();')
    assert 'creator_claim_signer_public_key =' in signer[name][1]
assert 'schedule_creator_claim_signer' not in signer
require(functions('migrators', 'lp_fee_policy')['schedule_coin_shares'][1], 'self.coins.schedule(meme, option::some(SharePair { meme_bps, quote_bps }), clock)')
for package in ('launchpad', 'presale', 'migrators'):
    fs = functions(package, 'package_admin')
    require(fs['schedule_upgrade_delay'][0], '&AdminWitness<UpgradeAdmin>', 'delay_ms: u64')
    require(fs['schedule_upgrade_delay'][1], 'self.upgrade.schedule_delay(delay_ms, clock)')
    require(fs['apply_upgrade_delay'][1], 'self.upgrade.apply_delay(clock)')
    assert 'AdminWitness' not in fs['apply_upgrade_delay'][0]
    require(fs['wrap'][1], 'delayed_action::new(UpgradeKey(), &id, INITIAL_UPGRADE_DELAY_MS)')
print('Per-operation notices, no bypass, immediate signer, and publication custody: OK')
