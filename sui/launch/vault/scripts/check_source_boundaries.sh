#!/usr/bin/env bash
# Structural gates for blast_vault (ADR 0137): the one vault below every venue. It depends only on
# the ACL, core, and partners; imports no product or venue; creates vaults only for an admitted
# venue and an admitted issuer; keeps fee delays fixed; and keeps holder claims outside the admin
# pause.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$package_dir"

fail() { echo "blast_vault boundary violated: $1" >&2; exit 1; }

dependencies="$(sed -n '/^\[dependencies\]/,/^\[/p' Move.toml | grep -E '^[A-Za-z_]+ *=' | cut -d= -f1 | tr -d ' ' | sort | tr '\n' ' ')"
[[ "$dependencies" == "blast_admin blast_core blast_partners " ]] \
  || fail "dependencies must be exactly blast_admin, blast_core, blast_partners (found: $dependencies)"

if rg -n '\b(blast_fun|blast_presale|blast_migrators|blast_venues|cetus_clmm|bluefin_spot|amm|dao_fee_amm)::' sources tests; then
  fail "the vault must not import a product or a venue"
fi
[[ "$(rg -l '^fun init\(' sources | tr '\n' ' ')" == "sources/blast_vault_package.move " ]] \
  || fail "only blast_vault_package may initialize state"
rg -q 'registry.assert_venue<Venue>\(\);' sources/vault.move \
  || fail "vault::new must require an admitted venue witness"
rg -q 'registry.assert_package_witness\(terms.package_witness\(\)\);' sources/vault.move \
  || fail "vault::new must require an admitted issuer witness"
rg -q 'venue: type_name::with_original_ids<Venue>\(\),' sources/vault.move \
  || fail "vault::new must bind the constructing venue's original type"
share="$(sed -n '/^public fun share_with_position</,/^}/p' sources/vault.move)"
rg -q 'self.venue == type_name::with_original_ids<Venue>\(\)' <<<"$share" \
  || fail "vault sharing must assert the venue bound at construction"
if rg -n 'self\.(fee_split|protocol_bps)\.schedule(_delay)?\(' sources; then
  fail "fee-split and Blast-share changes must keep the fixed delay (schedule_value only)"
fi
claim="$(sed -n '/^public fun claim</,/^}/p' sources/holder_rewards.move)"
[[ -n "$claim" ]] || fail "holder_rewards::claim not found"
if grep -q 'assert_not_paused' <<<"$claim"; then
  fail "holder claims must never pause"
fi

echo "blast_vault source boundaries hold."
