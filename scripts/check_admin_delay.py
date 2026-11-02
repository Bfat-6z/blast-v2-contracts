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


def governed(package, module, fields, version='package_version'):
    fs = functions(package, module)
    for field, role in fields.items():
        for phase in ('schedule', 'apply', 'cancel'):
            name = f'{phase}_{field}'
            signature, body = fs[name]
            assert body.startswith(f'{version}.assert_current();'), (package, module, name)
            if phase == 'apply':
                assert 'AdminWitness' not in signature, (module, name)
                require(signature, 'clock: &Clock')
                assert '.apply(clock)' in body or '.take_ready(clock)' in body, (module, name)
            else:
                require(signature, f'&AdminWitness<{role if phase == "schedule" else "CancelAdmin"}>')
                if phase == 'schedule': require(signature, 'delay_ms: u64', 'clock: &Clock')
        assert f'set_{field}' not in fs, (module, field)


governed('launchpad', 'runtime_config', {'treasury': 'TreasuryAdmin', 'protocol_fee_share': 'FeeAdmin'})
governed('launchpad', 'launch_config', {'creation_fee': 'FeeAdmin', 'trade_fees': 'FeeAdmin', 'protocol_allocation': 'TreasuryAdmin'})
governed('presale', 'fee_policy', {'destination': 'TreasuryAdmin', 'fees': 'FeeAdmin'})
governed('presale', 'presale_vault', {'protocol_lp_fees': 'FeeAdmin'})
governed('migrators', 'lp_fee_policy', {'protocol_destination': 'TreasuryAdmin', 'default_shares': 'FeeAdmin', 'coin_shares': 'FeeAdmin'}, 'migrators_version')

for package in ('launchpad', 'presale', 'migrators'):
    fs = functions(package, 'package_admin')
    for name in ('schedule_upgrade', 'schedule_make_immutable', 'authorize_upgrade', 'make_immutable'):
        signature, body = fs[name]
        require(signature, '&AdminWitness<UpgradeAdmin>', 'clock: &Clock')
        assert body.startswith('package_version.assert_current();'), (package, name)
    require(fs['schedule_upgrade'][1], 'digest.length() == 32', 'delayed::new_pending(action, self.delay_ms, delay_ms, clock)')
    for name, action in [('authorize_upgrade', 'Upgrade(digest)'), ('make_immutable', 'MakeImmutable')]:
        body = fs[name][1]
        action_expression = f'UpgradeAction::{action}'
        if package == 'launchpad':
            action_expression = 'events::upgrade_action(digest)' if name == 'authorize_upgrade' else 'events::immutability_action()'
        require(body, f'action == {action_expression}', 'self.pending = option::none();', 'self.delay_ms = delay_ms;')
        assert body.index('self.pending = option::none();') < body.index('self.custody.'), name
    require(fs['cancel_upgrade_action'][0], '&AdminWitness<CancelAdmin>')
    require(fs['cancel_upgrade_action'][1], 'self.pending.extract()')
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
    require(fs['schedule_migration_witness'][0], '&AdminWitness<AdapterAdmin>', 'clock: &Clock')
    require(fs['schedule_migration_witness'][1], 'delayed::new_pending(true, self.witness_delay_ms, delay_ms, clock)')
    require(fs['apply_migration_witness'][1], '.take_ready(clock)', 'self.witness_delay_ms = delay_ms;')
    assert 'AdminWitness' not in fs['apply_migration_witness'][0]
    require(fs['cancel_migration_witness'][0], '&AdminWitness<CancelAdmin>')
    require(fs['remove_migration_witness'][1], 'self.pending_witnesses.remove')
    assert 'set_migration_witness_allowed' not in fs

fs = functions('launchpad', 'launch')
require(fs['apply_cap_reassignment_delay'][1],
        '(*pending).destroy_some().take_ready(clock)', '*pending = option::none();',
        '*delay_ms = next_delay_ms;', 'events::cap_delay_changed(launch_id, metadata, next_delay_ms);')
for cap, metadata in [('curve_fee_cap', 'false'), ('metadata_cap', 'true')]:
    require(fs[f'schedule_{cap}_reassignment'][0], '&AdminWitness<CreatorAdmin>', 'clock: &Clock')
    assert 'delay_ms: u64' not in fs[f'schedule_{cap}_reassignment'][0], cap
    require(fs[f'schedule_{cap}_reassignment'][1], f'let delay_ms = self.{cap}_delay_ms;',
            'delayed::new_pending(option::some(recipient), delay_ms, delay_ms, clock)')
    require(fs[f'cancel_{cap}_reassignment'][0], '&AdminWitness<CancelAdmin>')
    require(fs[f'reassign_{cap}'][1],
            f'apply_cap_reassignment_delay( &mut self.pending_{cap}_recipient, &mut self.{cap}_delay_ms, self.id.to_inner(), {metadata}, clock, )')
    assert 'AdminWitness' not in fs[f'reassign_{cap}'][0]

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
require(acl, 'admins: Table<ID, VecSet<TypeName>>,')
assert 'MAX_ADMINS' not in acl
require((ROOT / 'sui/admin/sources/delayed.move').read_text(), 'scheduled_at_ms.checked_add(current_delay_ms)', 'clock.timestamp_ms() >= self.ready_at_ms')
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
            if '.schedule(' not in body and 'delayed::new_pending(' not in body:
                continue
            require(signature, 'clock: &Clock')
            if not (package == 'launchpad' and path.stem == 'launch'
                    and name in ('schedule_curve_fee_cap_reassignment', 'schedule_metadata_cap_reassignment')):
                require(signature, 'delay_ms: u64')
            assert 'admin_delay_ms()' not in body, (path, name)

primitive = functions('admin', 'delayed')
assert 'set_now' not in primitive and 'apply_delay' not in primitive and 'borrow' not in primitive
require(primitive['schedule'][1], 'new_pending(value, self.delay_ms, delay_ms, clock)')
require(primitive['apply'][1], 'take_ready(clock)', 'self.delay_ms = delay_ms;', 'self.value = value;', 'self.pending = option::none();')
require(primitive['new_pending'][1], 'scheduled_at_ms.checked_add(current_delay_ms)', '.destroy_or!(abort blast_admin::errors::invalid_delay!())', 'ready_at_ms.checked_add(delay_ms).is_some()')
require(primitive['take_ready'][1], 'clock.timestamp_ms() >= self.ready_at_ms', 'clock.timestamp_ms().checked_add(self.delay_ms).is_some()')
for name in ('schedule_value', 'schedule_delay'):
    require(primitive[name][1], 'self.schedule(value, delay_ms, clock)')

signer = functions('launchpad', 'runtime_config')
for name in ('set_creator_claim_signer', 'revoke_creator_claim_signer'):
    require(signer[name][0], '&AdminWitness<ClaimSignerAdmin>')
    assert signer[name][1].startswith('package_version.assert_current();')
    assert 'creator_claim_signer_public_key =' in signer[name][1]
assert 'schedule_creator_claim_signer' not in signer
require((ROOT / 'sui/migrators/sources/lp_fee_policy.move').read_text(), 'delayed::new(option::none(), self.defaults.delay_ms())')
for package in ('launchpad', 'presale', 'migrators'):
    fs = functions(package, 'package_admin')
    require(fs['schedule_upgrade_delay'][0], '&AdminWitness<UpgradeAdmin>', 'delay_ms: u64')
    require(fs['apply_upgrade_delay'][1], 'take_ready(clock)', 'self.delay_ms = delay_ms;', 'self.pending = option::none();')
    assert 'AdminWitness' not in fs['apply_upgrade_delay'][0]
    require(fs['wrap'][1], 'delay_ms: 0')
print('Per-operation notices, no bypass, immediate signer, and publication custody: OK')
