#!/usr/bin/env bash
# Structural gates for blast_presale administration (ADR 0097), upgrade custody (ADR 0099), and partner
# binding (ADRs 0106 and 0107).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$package_dir/sources"
python3 "$package_dir/../../scripts/check_admin_delay.py"

fail() {
  printf 'check_source_boundaries: %s\n' "$1" >&2
  exit 1
}

production() {
  sed '/^\/\/ === Test-Only Functions ===/,$d' "$1"
}

# 1. Administration comes only from the shared Blast ACL (ADR 0097): the package declares its
#    ability-free roles, and each administrator action takes exactly the one role pinned here.
if rg -n '^public struct (ACL|Authority|SuperAdminCap|AdminCap|AdminRegistry|AdminWitness)\b' "$sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
domain_source="$sources/blast_presale_domain.move"
if rg -n 'fun ' "$domain_source"; then
  fail "blast_presale_domain must only declare roles."
fi
[ "$(rg '^public struct ' "$domain_source" | sort)" == "$(printf '%s\n' \
  'public struct AdapterAdmin()' \
  'public struct CancelAdmin()' \
  'public struct PauseAdmin()' \
  'public struct UnpauseAdmin()' \
  'public struct FeeAdmin()' \
  'public struct ListingAdmin()' \
  'public struct RewardsAdmin()' \
  'public struct TreasuryAdmin()' \
  'public struct UpgradeAdmin()' | sort)" ] \
  || fail "blast_presale_domain must declare exactly the reviewed ability-free roles."
presale_roles='CancelAdmin|PauseAdmin|UnpauseAdmin|AdapterAdmin|FeeAdmin|ListingAdmin|RewardsAdmin|TreasuryAdmin|UpgradeAdmin'
admin_roles="$(for file in "$sources"/*.move; do
 awk -f "$package_dir/../launchpad/scripts/move_facts.awk" "$file" | awk -F'\t' -v module="$(basename "$file" .move)" '
 $1 == "FN" && $6 == 0 && match($9, /AdminWitness<[A-Za-z]+>/) { print module ":" $2 ":" substr($9, RSTART + 13, RLENGTH - 14) }'
done | sort)"
[ "$admin_roles" == "$(printf '%s\n' 'blast_presale:set_protocol_fees:FeeAdmin' 'blast_presale_package:pause:PauseAdmin' 'creation_policy:add_partner:FeeAdmin' 'creation_policy:cancel_migration_delay:CancelAdmin' 'creation_policy:cancel_migration_witness:CancelAdmin' 'creation_policy:remove_migration_witness:AdapterAdmin' 'creation_policy:remove_partner:FeeAdmin' 'creation_policy:schedule_migration_delay:AdapterAdmin' 'creation_policy:schedule_migration_witness:AdapterAdmin' 'creation_policy:set_quote_allowed:ListingAdmin' 'fee_policy:cancel_destination:CancelAdmin' 'fee_policy:cancel_fees:CancelAdmin' 'fee_policy:schedule_destination:TreasuryAdmin' 'fee_policy:schedule_fees:FeeAdmin' 'holder_rewards:cancel_round:CancelAdmin' 'holder_rewards:cancel_round_delay:CancelAdmin' 'holder_rewards:schedule_round:RewardsAdmin' 'holder_rewards:schedule_round_delay:RewardsAdmin' 'holder_rewards:settle_gas_reserve:RewardsAdmin' 'package_admin:authorize_upgrade:UpgradeAdmin' 'package_admin:cancel_upgrade_action:CancelAdmin' 'package_admin:commit_upgrade_and_advance:UpgradeAdmin' 'package_admin:make_immutable:UpgradeAdmin' 'package_admin:schedule_make_immutable:UpgradeAdmin' 'package_admin:schedule_upgrade:UpgradeAdmin' 'package_admin:schedule_upgrade_delay:UpgradeAdmin' 'package_admin:unpause:UnpauseAdmin' 'presale_vault:cancel_protocol_lp_fees:CancelAdmin' 'presale_vault:schedule_protocol_lp_fees:FeeAdmin' | sort)" ] || fail "Every administrator action must take its pinned role."

# 2. Publication cannot activate presales; custody intake alone shares the version.
admin_production="$(production "$sources/package_admin.move")"
marker_production="$(production "$sources/blast_presale_package.move")"
if rg -n '\bonly_additive_upgrades\b|\bonly_dep_upgrades\b' "$sources"; then
  fail "Presale custody must retain compatible, relinkable upgrades."
fi
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(mut )?UpgradeCap' <<<"$admin_production"; then
  fail "No custody path may release the UpgradeCap."
fi
if rg -n 'transfer::(public_)?transfer\(' <<<"$admin_production"; then
  fail "The native capabilities must never leave shared custody."
fi
rg -Fq 'generation.share_version(ctx);' <<<"$admin_production" \
  || fail "wrap must share the operational version after custody validation."
rg -Fq 'transfer::transfer(Publication' <<<"$marker_production" \
  || fail "Publication must transfer an owned publication proof."
python3 "$package_dir/scripts/check_version_boundaries.py"

# 3. A sale's Blast partner is named only by set_partner on its initializer, so `finalize` fixes it
#    before the sale exists (ADRs 0106 and 0110), and its vault keeps that partner for good
#    (ADR 0107).
presale_production="$(production "$sources/blast_presale.move")"
set_partner_body="$(sed -n '/^public fun set_partner</,/^}/p' <<<"$presale_production")"
[ "$(rg -c 'self\.partner_id = ' <<<"$presale_production")" == 1 ] \
  && rg -q '^    self: &mut PresaleInitializer<SaleToken, Quote>,$' <<<"$set_partner_body" \
  && rg -q '^    self\.partner_id = option::some\(partner_id\);$' <<<"$set_partner_body" \
  || fail "Only set_partner, on the initializer, may name a sale's partner."
vault_production="$(production "$sources/presale_vault.move")"
if rg -q '\.partner_id = ' <<<"$vault_production"; then
  fail "A presale vault's partner is the sale's, fixed when the vault is created."
fi
# 4. A sale's window is fixed by `finalize` from its initializer, and only settle, closing it
#    early, shortens it (ADR 0110).
set_windows_body="$(sed -n '/^public fun set_windows</,/^}/p' <<<"$presale_production")"
settle_body="$(sed -n '/^public fun settle</,/^}/p' <<<"$presale_production")"
[ "$(rg -c 'self\.duration_ms = ' <<<"$presale_production")" == 2 ] \
  && rg -q '^    self: &mut PresaleInitializer<SaleToken, Quote>,$' <<<"$set_windows_body" \
  && rg -q '^    self\.duration_ms = commitment_duration_ms;$' <<<"$set_windows_body" \
  && rg -q 'self\.duration_ms = now_at_ms - self\.start_ms;$' <<<"$settle_body" \
  || fail "Only settle, closing a sale early, may shorten its window."

# 5. Aftermath's vault seams (ADR 0116): a vault built before its position, the one call that
#    shares it with one, the venue predicate, and the one object-owned coin receipt reach only
#    the Aftermath venue outside the vault, and the vault's position is never transferred.
for seam in 'vault::new\(' '\.share_with_position\(' '\.has_position\(' '\.receive_fee\('; do
  callers="$(for file in "$sources"/*.move; do
    [ "$(basename "$file")" == "presale_vault.move" ] && continue
    production "$file" | { rg -q "$seam" && basename "$file"; } || true
  done | sort | tr '\n' ' ')"
  [ "$callers" == "aftermath.move " ] \
    || fail "Only the Aftermath venue may reach the vault seam ${seam} (found: ${callers:-none})."
done
[ "$(rg -c 'transfer::public_receive\(' "$sources/presale_vault.move")" == 1 ] \
  && ! rg -q 'transfer::(public_)?receive\(|Receiving<' "$sources"/blast_presale.move "$sources"/cetus.move "$sources"/bluefin.move \
  || fail "Object-owned coins reach a vault only through presale_vault::receive_fee."
if rg -q 'transfer::(public_)?transfer\([^)]*position' "$sources"; then
  fail "A vault's position is never transferred."
fi
[ "$(rg -c 'transfer::public_transfer\(lp, @0x0\)' "$sources/aftermath.move")" == 1 ] \
  || fail "Aftermath's migration must send its LP coin to 0x0 exactly once."

# 6. The presale's Aftermath stubs, including linkage-only dependencies, match the vendor's
#    byte for byte (ADR 0116). Its ABI gate covers the consumed AMM and DAO-fee interfaces too.
vendor_interfaces="$package_dir/../vendors/aftermath_dao_presale/interfaces"
for stub in aftermath_amm aftermath_dao_fee aftermath_math aftermath_utils \
  aftermath_protocol_fee_vault aftermath_treasury aftermath_insurance_fund aftermath_referral_vault; do
  diff -r "$package_dir/interfaces/$stub" "$vendor_interfaces/$stub" >/dev/null \
    || fail "The presale's ${stub} link stub must match the vendor package's byte for byte."
done

# 7. The ticket `aftermath::new` returns beside the initializer has no abilities and only
#    `aftermath::finalize` consumes it (ADR 0116), so a creation transaction that finalizes an
#    Aftermath sale through the core ends holding the ticket and fails.
aftermath_production="$(production "$sources/aftermath.move")"
rg -q '^public struct FinalizeTicket<phantom Meme, phantom Quote>\(\)$' <<<"$aftermath_production" \
  || fail "aftermath::FinalizeTicket must be an ability-free hot potato."
aftermath_finalize_body="$(sed -n '/^public fun finalize</,/^}/p' <<<"$aftermath_production")"
[ "$(rg -c 'FinalizeTicket\(\)' <<<"$aftermath_production")" == 2 ] \
  && rg -q '^    let FinalizeTicket\(\) = ticket;$' <<<"$aftermath_finalize_body" \
  || fail "aftermath::FinalizeTicket is constructed only by new and consumed only by finalize."

# 8. Every delayed operation stores blast_admin's primitive under a key its owning module declares,
#    so only that module can create or drive it and the primitive alone records its lifecycle.
require_field() {
  grep -Fqx "    $2" "$sources/$1.move" || fail "$1 must store ${2%,}."
  grep -Eq "^public struct $3\(\) has copy, drop, store;$" "$sources/$1.move" \
    || fail "$1 must declare its delayed-operation key $3."
}
require_field fee_policy 'destination: Delayed<DestinationKey, address>,' DestinationKey
require_field fee_policy 'fees: Delayed<FeesKey, ProtocolFees>,' FeesKey
require_field presale_vault 'fee_split: Delayed<FeeSplitKey, FeeSplit>,' FeeSplitKey
require_field presale_vault 'protocol_fees: Delayed<ProtocolLpFeesKey, ProtocolFees>,' ProtocolLpFeesKey
require_field package_admin 'upgrade: DelayedAction<UpgradeKey, UpgradeAction>,' UpgradeKey
require_field presale_vault 'round_publication: DelayedAction<RoundPublicationKey, RoundTerms>,' RoundPublicationKey
require_field creation_policy 'migration_witnesses: DelayedSet<MigrationWitnessKey, TypeName>,' MigrationWitnessKey
if rg -n '\b(Pending|new_pending|take_ready|witness_delay_ms|pending_witness\w*|DelayOnly)\b|self\.(delay_ms|pending)\b' "$sources"/{fee_policy,presale_vault,package_admin,creation_policy}.move; then
  fail "Delayed operations keep no notice or proposal outside blast_admin's primitive."
fi
if rg -n '^public struct \w*(Scheduled|Cancelled|Changed|DelayChanged|WitnessSet)\b' \
  "$sources"/{fee_policy,presale_vault,package_admin,creation_policy}.move; then
  fail "The delayed primitive alone emits schedule, cancel and apply events."
fi

# 9. A holder-reward round is funded only by permissionless publication of the ready round its
#    vault's delayed slot holds, and only holder_rewards reaches that slot or builds round terms.
for seam in '\.fund_round\(' '\.take_round_publication\(' '\.schedule_round_publication\(' 'new_round_terms\('; do
  callers="$(for file in "$sources"/*.move; do
    [ "$(basename "$file")" == "presale_vault.move" ] && continue
    production "$file" | { rg -q "$seam" && basename "$file"; } || true
  done | sort | tr '\n' ' ')"
  [ "$callers" == "holder_rewards.move " ] \
    || fail "Only holder_rewards may reach the vault round seam ${seam} (found: ${callers:-none})."
done
rg -q '^const DEFAULT_ROUND_NOTICE_MS: u64 = 2 \* 60 \* 60 \* 1_000;$' "$sources/presale_vault.move" \
  && rg -q '^public struct RoundTerms has copy, drop, store \{$' "$sources/presale_vault.move" \
  && [ "$(rg -c 'delayed_action::new\(RoundPublicationKey\(\), &id, DEFAULT_ROUND_NOTICE_MS\)' "$sources/presale_vault.move")" == 2 ] \
  || fail "Every vault constructor must create its round-publication slot at the default notice."

printf 'blast_presale source boundaries hold.\n'
