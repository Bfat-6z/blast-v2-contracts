#!/usr/bin/env bash
# Structural gates for blast_core (ADR 0137): an immutable package below every product, vault, and
# venue. It depends only on the ACL, partners, and vesting; imports no product, vault, or venue;
# holds no upgrade, publisher, or version machinery; and only the treasury initializes state.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$package_dir"

fail() { echo "blast_core boundary violated: $1" >&2; exit 1; }

dependencies="$(sed -n '/^\[dependencies\]/,/^\[/p' Move.toml | grep -E '^[A-Za-z_]+ *=' | cut -d= -f1 | tr -d ' ' | sort | tr '\n' ' ')"
[[ "$dependencies" == "blast_admin blast_fun_vesting blast_partners " ]] \
  || fail "dependencies must be exactly blast_admin, blast_fun_vesting, blast_partners (found: $dependencies)"

if rg -n '\b(blast_fun|blast_presale|blast_fun_migrators|blast_vault|blast_venues|cetus_clmm|bluefin_spot|amm|dao_fee_amm)::' sources tests; then
  fail "core must not import a product, the vault, or a venue"
fi
if rg -n '\b(UpgradeCap|Publisher|OperationalVersion|UpgradeCustody|package::claim)\b' sources; then
  fail "core is immutable: no upgrade, publisher, or version machinery"
fi
[[ "$(rg -l '^fun init\(' sources | tr '\n' ' ')" == "sources/blast_treasury.move " ]] \
  || fail "only blast_treasury may initialize state"
rg -q 'public struct Migration<phantom Meme, phantom Quote> \{' sources/migration.move \
  && rg -q 'public struct VenueBinding \{' sources/migration.move \
  && rg -q 'public struct OwnerProof \{' sources/owner_proof.move \
  || fail "hand-off, binding, and owner proof must have no abilities"
rg -q "assert!\(venue == type_name::with_original_ids<Venue>\(\), blast_core::errors::wrong_venue!\(\)\);" sources/migration.move \
  || fail "redeem must check the stored venue's original witness type"

echo "blast_core source boundaries hold."
