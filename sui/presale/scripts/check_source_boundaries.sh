#!/usr/bin/env bash
# Structural gates for blast_presale administration (ADR 0097), upgrade custody (ADR 0099), partner
# binding (ADRs 0106 and 0107), and the migration hand-off (ADR 0137).
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
  'public struct TreasuryAdmin()' \
  'public struct UpgradeAdmin()' | sort)" ] \
  || fail "blast_presale_domain must declare exactly the reviewed ability-free roles."
presale_roles='CancelAdmin|PauseAdmin|UnpauseAdmin|AdapterAdmin|FeeAdmin|ListingAdmin|TreasuryAdmin|UpgradeAdmin'
admin_roles="$(for file in "$sources"/*.move; do
 awk -f "$package_dir/../launchpad/scripts/move_facts.awk" "$file" | awk -F'\t' -v module="$(basename "$file" .move)" '
 $1 == "FN" && $6 == 0 && match($9, /AdminWitness<[A-Za-z]+>/) { print module ":" $2 ":" substr($9, RSTART + 13, RLENGTH - 14) }'
done | sort)"
[ "$admin_roles" == "$(printf '%s\n' 'blast_presale:set_protocol_fees:FeeAdmin' 'blast_presale_package:pause:PauseAdmin' 'creation_policy:add_partner:FeeAdmin' 'creation_policy:cancel_venue:CancelAdmin' 'creation_policy:cancel_venue_delay:CancelAdmin' 'creation_policy:remove_partner:FeeAdmin' 'creation_policy:remove_venue:AdapterAdmin' 'creation_policy:schedule_venue:AdapterAdmin' 'creation_policy:schedule_venue_delay:AdapterAdmin' 'creation_policy:set_quote_allowed:ListingAdmin' 'fee_policy:cancel_destination:CancelAdmin' 'fee_policy:cancel_fees:CancelAdmin' 'fee_policy:schedule_destination:TreasuryAdmin' 'fee_policy:schedule_fees:FeeAdmin' 'package_admin:authorize_upgrade:UpgradeAdmin' 'package_admin:cancel_upgrade_action:CancelAdmin' 'package_admin:commit_upgrade_and_advance:UpgradeAdmin' 'package_admin:make_immutable:UpgradeAdmin' 'package_admin:schedule_make_immutable:UpgradeAdmin' 'package_admin:schedule_upgrade:UpgradeAdmin' 'package_admin:schedule_upgrade_delay:UpgradeAdmin' 'package_admin:unpause:UnpauseAdmin' | sort)" ] || fail "Every administrator action must take its pinned role."

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
#    before the sale exists (ADRs 0106 and 0110), and `migrate` seals that partner into its vault's
#    terms (ADR 0137).
presale_production="$(production "$sources/blast_presale.move")"
set_partner_body="$(sed -n '/^public fun set_partner</,/^}/p' <<<"$presale_production")"
[ "$(rg -c 'self\.partner_id = ' <<<"$presale_production")" == 1 ] \
  && rg -q '^    self: &mut PresaleInitializer<SaleToken, Quote>,$' <<<"$set_partner_body" \
  && rg -q '^    self\.partner_id = option::some\(partner_id\);$' <<<"$set_partner_body" \
  || fail "Only set_partner, on the initializer, may name a sale's partner."
# 4. A sale's window is fixed by `finalize` from its initializer, and only settle, closing it
#    early, shortens it (ADR 0110).
set_windows_body="$(sed -n '/^public fun set_windows</,/^}/p' <<<"$presale_production")"
settle_body="$(sed -n '/^public fun settle</,/^}/p' <<<"$presale_production")"
[ "$(rg -c 'self\.duration_ms = ' <<<"$presale_production")" == 2 ] \
  && rg -q '^    self: &mut PresaleInitializer<SaleToken, Quote>,$' <<<"$set_windows_body" \
  && rg -q '^    self\.duration_ms = commitment_duration_ms;$' <<<"$set_windows_body" \
  && rg -q 'self\.duration_ms = now_at_ms - self\.start_ms;$' <<<"$settle_body" \
  || fail "Only settle, closing a sale early, may shorten its window."

# 5. The hand-off (ADR 0137): only `migrate` and `prove_owner` construct the presale's package
#    witness, sealing the sale's own terms with its owner's residuals and its snapshotted LP-fee
#    rates. The sale never reaches a vault; each venue redeems with its own `Venue`, builds the
#    vault from the redeemed terms, and never transfers its position. Only Aftermath receives
#    object-owned coins, and its migration sends the LP coin to 0x0 exactly once.
migrate_body="$(sed -n '/^public fun migrate</,/^}/p' <<<"$presale_production")"
prove_owner_body="$(sed -n '/^public fun prove_owner</,/^}/p' <<<"$presale_production")"
rg -q '^public struct PackageWitness\(\) has drop;$' <<<"$presale_production" \
  && [ "$(rg -c 'PackageWitness\(\)' <<<"$presale_production")" == 4 ] \
  && [ "$(rg -c 'PackageWitness\(\)' <<<"$migrate_body")" == 2 ] \
  && [ "$(rg -c 'PackageWitness\(\)' <<<"$prove_owner_body")" == 1 ] \
  || fail "Only migrate and prove_owner may construct the presale's package witness."
for term in 'self.id.to_inner(),' 'self.fee_split,' 'self.protocol_fees.lp_fee_meme_bps(),' \
  'self.protocol_fees.lp_fee_quote_bps(),' 'self.partner_id,' 'migration::residuals_to_owner(),'; do
  rg -Fq "$term" <<<"$migrate_body" || fail "migrate must seal ${term%,} into its vault terms."
done
rg -Fq 'self.assert_cap(cap);' <<<"$prove_owner_body" \
  || fail "prove_owner must check the sale's creator capability."
if rg -n 'residuals_to_protocol|blast_vault' <<<"$presale_production"; then
  fail "A presale's residuals belong to its owner, and the sale never reaches a vault."
fi
for venue in cetus bluefin aftermath; do
  venue_production="$(production "$sources/$venue.move")"
  rg -q '^public struct Venue\(\) has drop;$' <<<"$venue_production" \
    && [ "$(rg -c '\.redeem\(Venue\(\)\)' <<<"$venue_production")" == 1 ] \
    && [ "$(rg -c 'vault::new<Meme, Quote, _>\(registry, &Venue\(\), vault_version, terms, pool_id, ctx\)' <<<"$venue_production")" == 1 ] \
    && [ "$(rg -c 'migration::issue_ticket\(Venue\(\)\)' <<<"$venue_production")" == 1 ] \
    || fail "$venue must issue, redeem, and build its vault under its own Venue exactly once."
  prepare_signature="$(sed -n '/^public fun prepare</,/^): VenueTicket<Meme, Quote> {$/p' <<<"$venue_production")"
  rg -q 'TreasuryCap<Meme>,$' <<<"$prepare_signature" \
    || fail "$venue::prepare must prove control of the sale token's treasury capability."
done
if rg -n 'transfer::(public_)?receive\(|transfer::public_receive' "$sources"; then
  fail "Object-owned coins reach a vault only through blast_vault's receive_coin."
fi
[ "$(for file in "$sources"/*.move; do production "$file" | rg -c '\.receive_coin\(' || true; done | paste -sd+ | bc)" == 1 ] \
  && production "$sources/aftermath.move" | rg -q '\.receive_coin\(' \
  || fail "Only the Aftermath venue receives object-owned coins into a vault."
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

# 7. Aftermath's pool-creation capability is kept under the sale token's and its LP coin's types
#    by `prepare` and leaves only with that sale's migration (ADR 0137 supersedes ADR 0116's
#    ticket): no other module removes a venue entry.
aftermath_production="$(production "$sources/aftermath.move")"
aftermath_prepare_body="$(sed -n '/^public fun prepare</,/^}/p' <<<"$aftermath_production")"
aftermath_migrate_body="$(sed -n '/^public fun migrate</,/^}/p' <<<"$aftermath_production")"
rg -Fq 'venue_config.add_object(CreatePoolCapKey<Lp, Meme>(), create_pool_cap);' <<<"$aftermath_prepare_body" \
  && rg -Fq 'venue_config.remove_object(CreatePoolCapKey<Lp, Meme>());' <<<"$aftermath_migrate_body" \
  || fail "aftermath keeps its capability under CreatePoolCapKey<Lp, Meme> from prepare to migrate."
removers="$(for file in "$sources"/*.move; do
  [ "$(basename "$file")" == "venue_config.move" ] && continue
  production "$file" | { rg -q '\.remove_object\(' && basename "$file"; } || true
done | tr '\n' ' ')"
[ "$removers" == "aftermath.move " ] || fail "Only aftermath may remove a venue entry (found: ${removers:-none})."

# 8. Every delayed operation stores blast_admin's primitive under a key its owning module declares,
#    so only that module can create or drive it and the primitive alone records its lifecycle.
require_field() {
  grep -Fqx "    $2" "$sources/$1.move" || fail "$1 must store ${2%,}."
  grep -Eq "^public struct $3\(\) has copy, drop, store;$" "$sources/$1.move" \
    || fail "$1 must declare its delayed-operation key $3."
}
require_field fee_policy 'destination: Delayed<DestinationKey, address>,' DestinationKey
require_field fee_policy 'fees: Delayed<FeesKey, ProtocolFees>,' FeesKey
require_field package_admin 'upgrade: DelayedAction<UpgradeKey, UpgradeAction>,' UpgradeKey
require_field creation_policy 'venues: DelayedSet<VenueKey, TypeName>,' VenueKey
if rg -n '\b(Pending|new_pending|take_ready|witness_delay_ms|pending_witness\w*|DelayOnly)\b|self\.(delay_ms|pending)\b' "$sources"/{fee_policy,package_admin,creation_policy}.move; then
  fail "Delayed operations keep no notice or proposal outside blast_admin's primitive."
fi
if rg -n '^public struct \w*(Scheduled|Cancelled|Changed|DelayChanged|WitnessSet)\b' \
  "$sources"/{fee_policy,package_admin,creation_policy}.move; then
  fail "The delayed primitive alone emits schedule, cancel and apply events."
fi

printf 'blast_presale source boundaries hold.\n'
