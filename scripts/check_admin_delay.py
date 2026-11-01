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
                if phase == 'schedule': require(signature, 'clock: &Clock')
        assert f'set_{field}' not in fs, (module, field)


governed('launchpad', 'runtime_config', {'treasury': 'TreasuryAdmin', 'protocol_fee_share': 'FeeAdmin', 'creator_claim_signer': 'ClaimSignerAdmin'})
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
    require(fs['schedule_upgrade'][1], 'digest.length() == 32', 'delayed::new_pending(action, clock)')
    for name, action in [('authorize_upgrade', 'Upgrade(digest)'), ('make_immutable', 'MakeImmutable')]:
        body = fs[name][1]
        action_expression = f'UpgradeAction::{action}'
        if package == 'launchpad':
            action_expression = 'events::upgrade_action(digest)' if name == 'authorize_upgrade' else 'events::immutability_action()'
        require(body, f'take_ready(clock) == {action_expression}', 'self.pending = option::none();')
        assert body.index('self.pending = option::none();') < body.index('self.custody.'), name
    require(fs['cancel_upgrade_action'][0], '&AdminWitness<CancelAdmin>')
    require(fs['cancel_upgrade_action'][1], 'self.pending.extract()')
    require(fs['wrap'][1], 'upgrade_custody::new')
    require(fs['wrap'][0], 'bootstrap: Bootstrap')
    require(fs['wrap'][1], 'bootstrap.destroy()', 'generation.share_version(ctx)')
    assert fs['wrap'][1].index('upgrade_custody::new') < fs['wrap'][1].index('generation.share_version(ctx)')
    assert fs['commit_upgrade_and_advance'][1].startswith('package_version.assert_next();')
    require(fs['commit_upgrade_and_advance'][1], 'self.custody.commit_upgrade(custodian_id, receipt); package_version.advance();')
    for signature, _ in fs.values():
        assert not re.search(r'\):\s*&?(?:mut )?(Publisher|UpgradeCap)', signature)

for package, module in [('launchpad', 'launch_config'), ('presale', 'creation_policy')]:
    fs = functions(package, module)
    require(fs['schedule_migration_witness'][0], '&AdminWitness<AdapterAdmin>', 'clock: &Clock')
    require(fs['schedule_migration_witness'][1], 'delayed::new_pending(true, clock)')
    require(fs['apply_migration_witness'][1], '.take_ready(clock)')
    assert 'AdminWitness' not in fs['apply_migration_witness'][0]
    require(fs['cancel_migration_witness'][0], '&AdminWitness<CancelAdmin>')
    require(fs['remove_migration_witness'][1], 'self.pending_witnesses.remove')
    assert 'set_migration_witness_allowed' not in fs

for cap in ('curve_fee_cap', 'metadata_cap'):
    fs = functions('launchpad', 'launch')
    require(fs[f'schedule_{cap}_reassignment'][0], '&AdminWitness<CreatorAdmin>', 'clock: &Clock')
    require(fs[f'cancel_{cap}_reassignment'][0], '&AdminWitness<CancelAdmin>')
    require(fs[f'reassign_{cap}'][1], '.take_ready(clock)')
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
require((ROOT / 'sui/admin/sources/delayed.move').read_text(), '48 * 60 * 60 * 1_000', 'clock.timestamp_ms() >= self.ready_at_ms')
print('ADR 0134 administration boundaries: OK')

# Bootstrap is a publication-only linear resource, never a pause-dependent administrative mode.
for package, marker in [('launchpad', 'blast_fun'), ('presale', 'blast_presale_package'), ('migrators', 'blast_fun_migrators')]:
    marker_fs = functions(package, marker)
    require(marker_fs['init'][1], 'transfer::transfer(Bootstrap', 'sui::package::claim(otw, ctx)')
    assert 'share_object' not in marker_fs['init'][1]
    require(marker_fs['destroy'][0], 'self: Bootstrap')
    # The only constructor is private publication init; destroy only destructures it.
    assert {name for name, (_, body) in marker_fs.items() if re.search(r'\bBootstrap\s*{', body)} == {'init', 'destroy'}
    assert marker_fs['init'][0].startswith('fun init(')
    assert 'public struct Bootstrap has key {' in (ROOT / 'sui' / package / 'sources' / f'{marker}.move').read_text()
    for path in (ROOT / 'sui' / package / 'sources').rglob('*.move'):
        source = path.read_text().split('// === Test-Only Functions ===')[0]
        if path.stem != marker:
            assert not re.search(r'\bBootstrap\s*{', source), path
    assert 'Bootstrap' not in marker_fs.get('unpause', ('', ''))[1]
    if package != 'migrators':
        assert 'paused: 0' not in marker_fs['share_version'][1]
        require(functions(package, 'package_admin')['wrap'][1], '.assert_bootstrap_ready();')
for package, module, names in [
    ('launchpad', 'runtime_config', ['bootstrap']),
    ('launchpad', 'launch_config', ['bootstrap', 'bootstrap_quote', 'bootstrap_migration_witness']),
    ('presale', 'fee_policy', ['bootstrap']),
    ('presale', 'creation_policy', ['bootstrap_quote', 'bootstrap_migration_witness']),
    ('migrators', 'lp_fee_policy', ['bootstrap']),
]:
    fs = functions(package, module)
    for name in names:
        require(fs[name][0], '_: &Bootstrap')
        assert 'PackageVersion' not in fs[name][0]
        assert 'paused' not in fs[name][1]
print('One-time Bootstrap authority and paused finalization: OK')
