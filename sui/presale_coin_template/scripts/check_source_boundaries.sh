#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source_file='sources/presale_coin.move'
production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$source_file")"
# Comment- and string-free source from the launchpad's Move reader, so documentation may name the
# cap while code may not touch it.
normalized="$(awk -f ../launchpad/scripts/move_facts.awk "$source_file" \
  | awk -F'\t' '$1 == "MALFORMED" { print "MALFORMED"; exit } $1 == "NORM" { print $2 }')"
[[ -n "$normalized" && "$normalized" != MALFORMED ]] || { echo 'The template source could not be read.' >&2; exit 1; }
# Whitespace-free source, so argument checks do not depend on formatting.
compact="$(tr -d '[:space:]' <<<"$normalized")"

if [[ "$(rg -cF 'public struct PRESALE_COIN has drop {}' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^fun init\(otw: PRESALE_COIN, ctx: &mut TxContext\) \{' "$source_file")" != 1 ]] \
  || rg -n '^(public|entry|public\(package\)) fun ' <<<"$production" \
  || rg -n '\b(TreasuryCap|UpgradeCap|CoinRegistry|CreationPolicy|PackageVersion|make_immutable|make_regulated|new_currency|mint|mint_balance|burn|make_supply_[a-z_]*|into_treasury_cap|treasury_cap_mut|share_object|public_share_object|freeze_object|public_freeze_object)\b' <<<"$normalized" \
  || [[ "$(rg -oF 'let(initializer,sealed_treasury_cap)=sale_token::new(otw,' <<<"$compact" | wc -l)" != 1 ]] \
  || [[ "$(rg -oF 'transfer::public_transfer(sealed_treasury_cap,ctx.sender());' <<<"$compact" | wc -l)" != 1 ]] \
  || [[ "$(rg -o '\bsealed_treasury_cap\b' <<<"$normalized" | wc -l)" != 2 ]] \
  || [[ "$(rg -oF 'initializer.finalize(ctx)' <<<"$compact" | wc -l)" != 1 ]] \
  || [[ "$(rg -oF 'initializer.finalize_and_delete_metadata_cap(ctx)' <<<"$compact" | wc -l)" != 1 ]]; then
  echo 'The template must expose only its one-time-witness initializer, which creates the currency through the presale, delivers the sealed TreasuryCap to the publisher, and finalizes the metadata.' >&2
  exit 1
fi

# Every slot is loaded once, in init, so the SDK can patch it by its unique constant-pool value.
for constant in SYMBOL NAME DESCRIPTION ICON_URL DECIMALS METADATA_MUTABLE METADATA_CAP_RECIPIENT; do
  if [[ "$(rg -c "^const ${constant}:" "$source_file")" != 1 ]] \
    || [[ "$(rg -o "[(,]${constant}(\\.to_string\\(\\))?[,)]" <<<"$compact" | wc -l)" != 1 ]]; then
    echo "The template must declare and pass one ${constant} replacement slot." >&2
    exit 1
  fi
done

if [[ "$(rg -c '^const METADATA_CAP_RECIPIENT: address = @0x[0-9a-f]+;$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^const [A-Z_]+: u8 = ' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^const [A-Z_]+: bool = ' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^const [A-Z_]+: address = ' "$source_file")" != 1 ]]; then
  echo 'No other u8, bool, or address constant may share a pool type with a replacement slot.' >&2
  exit 1
fi

echo 'presale_coin_template source boundaries: OK'
