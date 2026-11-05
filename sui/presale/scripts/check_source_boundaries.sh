#!/usr/bin/env bash
# Structural gates for blast_presale administration (ADRs 0097, 0137), partner binding (ADRs 0106
# and 0107), and the migration hand-off (ADR 0137).
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

# 1. Administration comes only from the shared Blast ACL (ADR 0097) and blast_admin's generic
#    package objects (ADR 0137): product roles are blast_core::blast_domain's, package roles are
#    blast_admin::package_admin's over BLAST_PRESALE_PACKAGE, and each administrator action takes
#    exactly the one role pinned here.
if rg -n '^public struct (ACL|Authority|SuperAdminCap|AdminCap|AdminRegistry|AdminWitness|PackageAdmin|PackageVersion|Publication)\b' "$sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
for retired in blast_presale_domain package_admin cetus bluefin aftermath venue_config migration_math; do
  [ ! -e "$sources/$retired.move" ] || fail "$retired.move is retired (ADR 0137): presale keeps no local copy."
done
[ ! -e "$package_dir/interfaces" ] || fail "Presale keeps no venue interfaces; venues live in blast_migrators."
if rg -n -i '\b(cetus|bluefin|aftermath)' "$sources" "$package_dir/Move.toml"; then
  fail "Presale imports no venue: blast_migrators redeems the hand-off."
fi
[ "$(sed -n '/^\[dependencies\]/,/^\[/p' "$package_dir/Move.toml" | rg -o '^[A-Za-z_]+ =' | sort | tr '\n' ' ')" \
  == 'blast_admin = blast_core = blast_partners = ' ] \
  || fail "Presale depends on blast_admin, blast_core, and blast_partners only."
admin_roles="$(for file in "$sources"/*.move; do
 awk -f "$package_dir/../launchpad/scripts/move_facts.awk" "$file" | awk -F'\t' -v module="$(basename "$file" .move)" '
 $1 == "FN" && $6 == 0 && match($9, /AdminWitness<[A-Za-z]+(<[A-Z_]+>)?>/) { print module ":" $2 ":" substr($9, RSTART + 13, RLENGTH - 14) }'
done | sort)"
[ "$admin_roles" == "$(printf '%s\n' 'blast_presale:set_protocol_fees:FeeAdmin' 'creation_policy:add_partner:FeeAdmin' 'creation_policy:cancel_venue:CancelAdmin' 'creation_policy:cancel_venue_delay:CancelAdmin' 'creation_policy:remove_partner:FeeAdmin' 'creation_policy:remove_venue:VenueAdmin' 'creation_policy:schedule_venue:VenueAdmin' 'creation_policy:schedule_venue_delay:VenueAdmin' 'creation_policy:set_quote_allowed:ListingAdmin' 'creation_policy:unpause:UnpauseAdmin<BLAST_PRESALE_PACKAGE>' 'fee_policy:cancel_fees:CancelAdmin' 'fee_policy:schedule_fees:FeeAdmin' | sort)" ] || fail "Every administrator action must take its pinned role."
for file in "$sources"/*.move; do
  if rg -q 'AdminWitness<(FeeAdmin|CancelAdmin|VenueAdmin|ListingAdmin)>' <<<"$(production "$file")"; then
    rg -q 'blast_domain::' "$file" || fail "$(basename "$file") must take product roles from blast_core::blast_domain."
  fi
done

# 2. Publication, version, pause, and upgrades are blast_admin's generic objects; only the
#    presale's unpause clears bits, after every presale delay is guarded.
python3 "$package_dir/scripts/check_version_boundaries.py"

# 2b. Errors have one numeric registry; event payloads are raw structs emitted only by events.move,
#     except PresaleCreated, which stays beside the sale terms it records (a module cycle otherwise).
for file in "$sources"/*.move; do
  [ "$(basename "$file")" == errors.move ] && continue
  if rg -n '#\[error\(|^[[:space:]]*const E[A-Z]' "$file"; then
    fail "$(basename "$file"): define presale errors in sources/errors.move."
  fi
  case "$(basename "$file")" in
    events.move) ;;
    blast_presale.move)
      [ "$(production "$file" | rg -c 'event::emit\(')" == 1 ] \
        && rg -q 'sui::event::emit\(PresaleCreated<SaleToken, Quote> \{' <<<"$(production "$file")" \
        || fail "blast_presale emits only PresaleCreated directly; every other event goes through events.move."
      ;;
    *)
      if production "$file" | rg -n 'event::emit'; then
        fail "$(basename "$file"): emit presale events through sources/events.move."
      fi
      ;;
  esac
done

# 2c. Payouts, Blast's fees, and partner acceptance are core's and partners' one implementation.
presale_production="$(production "$sources/blast_presale.move")"
if rg -n 'linear_vesting|public_transfer|fun pay_or_vest|fun pay\b|struct VestingTerms|struct ProtocolFeesPaid' <<<"$presale_production"; then
  fail "Presale pays only through blast_core::payout and its protocol-fee ledger."
fi
rg -Fq 'fee_ledger: Ledger<SaleToken, Quote>,' <<<"$presale_production" \
  && rg -Fq 'let fee_ledger = protocol_fees::new(' <<<"$presale_production" \
  || fail "Each sale holds Blast's fees in one core ledger bound to its partner."
rg -Fq 'partners: PartnerList,' "$sources/creation_policy.move" \
  || fail "The creation policy keeps its partners in blast_partners::partner_list."

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

# 5. The hand-off (ADR 0137): the package witness, pinned at publication, is constructed only by
#    `blast_presale_package::package_witness`, which only `finalize` (the fee ledger), `migrate`,
#    `prove_owner`, and `creation_policy::unpause` call, sealing the sale's own terms with its owner's residuals and its
#    snapshotted LP-fee rates. The sale never reaches a vault or a venue; the venue the stored
#    witness names redeems the hand-off.
migrate_body="$(sed -n '/^public fun migrate</,/^}/p' <<<"$presale_production")"
prove_owner_body="$(sed -n '/^public fun prove_owner</,/^}/p' <<<"$presale_production")"
finalize_body="$(sed -n '/^public fun finalize</,/^}/p' <<<"$presale_production")"
otw_production="$(production "$sources/blast_presale_package.move")"
rg -q '^public struct PackageWitness\(\) has drop;$' <<<"$otw_production" \
  && [ "$(rg -c 'PackageWitness\(\)' <<<"$otw_production")" == 2 ] \
  && [ "$(for file in "$sources"/*.move; do production "$file" | rg -c 'package_witness\(\)' || true; done | paste -sd+ | bc)" == 6 ] \
  && [ "$(production "$sources/creation_policy.move" | rg -c 'package_witness\(\)')" == 1 ] \
  && [ "$(rg -c 'blast_presale_package::package_witness\(\)' <<<"$presale_production")" == 4 ] \
  && [ "$(rg -c 'package_witness\(\)' <<<"$migrate_body")" == 2 ] \
  && [ "$(rg -c 'package_witness\(\)' <<<"$prove_owner_body")" == 1 ] \
  && [ "$(rg -c 'package_witness\(\)' <<<"$finalize_body")" == 1 ] \
  || fail "Only finalize, migrate, prove_owner and unpause may take the presale's package witness."
for term in 'self.id.to_inner(),' 'self.fee_split,' 'self.protocol_fees.lp_fee_meme_bps(),' \
  'self.protocol_fees.lp_fee_quote_bps(),' 'self.partner_id,' 'migration::residuals_to_owner(),'; do
  rg -Fq "$term" <<<"$migrate_body" || fail "migrate must seal ${term%,} into its vault terms."
done
rg -Fq 'self.assert_cap(cap);' <<<"$prove_owner_body" \
  || fail "prove_owner must check the sale's creator capability."
if rg -n 'residuals_to_protocol|blast_vault|blast_migrators' <<<"$presale_production"; then
  fail "A presale's residuals belong to its owner, and the sale never reaches a vault."
fi
rg -Fq 'migration::is_seedable_price(' <<<"$presale_production" \
  || fail "Creation refuses a sale whose seed price no CLMM venue can pool (blast_core::migration)."

# 8. Every delayed operation stores blast_admin's primitive under a key its owning module declares,
#    so only that module can create or drive it and the primitive alone records its lifecycle.
require_field() {
  grep -Fqx "    $2" "$sources/$1.move" || fail "$1 must store ${2%,}."
  grep -Eq "^public struct $3\(\) has copy, drop, store;$" "$sources/$1.move" \
    || fail "$1 must declare its delayed-operation key $3."
}
require_field fee_policy 'fees: Delayed<FeesKey, ProtocolFees>,' FeesKey
require_field creation_policy 'venues: DelayedSet<VenueKey, TypeName>,' VenueKey
if rg -n 'destination' "$sources/fee_policy.move" | rg -v '^\S*:[0-9]+:\s*///'; then
  fail "Blast's fees are paid to blast_core's treasury; the fee policy keeps no destination."
fi
if rg -n '\b(Pending|new_pending|take_ready|witness_delay_ms|pending_witness\w*|DelayOnly)\b|self\.(delay_ms|pending)\b' "$sources"/{fee_policy,creation_policy}.move; then
  fail "Delayed operations keep no delay or proposal outside blast_admin's primitive."
fi
if rg -n '^public struct \w*(Scheduled|Cancelled|Changed|DelayChanged|WitnessSet)\b' \
  "$sources"/{fee_policy,creation_policy}.move; then
  fail "The delayed primitive alone emits schedule, cancel and apply events."
fi

printf 'blast_presale source boundaries hold.\n'
