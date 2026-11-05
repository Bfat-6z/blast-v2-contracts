#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

# Succeeds when the cap is bound before the ticket and cap are delivered, in that order.
in_order_template() {
  local text="$1" before
  before="${text%%'let (ticket, sealed_treasury_cap) = launch_ticket::new('*}"
  [[ "$before" != "$text" ]] || return 1
  text="${text#"$before"}"
  before="${text%%'transfer::public_transfer(ticket, ctx.sender()); transfer::public_transfer(sealed_treasury_cap, ctx.sender()); }'*}"
  [[ "$before" != "$text" ]]
}

source_file='sources/meme.move'
production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$source_file")"
# Whitespace-free source, so argument checks do not depend on formatting.
compact="$(tr -d '[:space:]' <"$source_file")"

if [[ "$(rg -cF 'public struct MEME has drop {}' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^fun init\(otw: MEME, ctx: &mut TxContext\) \{' "$source_file")" != 1 ]] \
  || rg -n '^(public|entry|public\(package\)) fun ' <<<"$production" \
  || [[ "$(rg -c 'launch_ticket::new\(' "$source_file")" != 1 ]] \
  || [[ "$(rg -oF 'launch_ticket::new(otw,' <<<"$compact" | wc -l)" != 1 ]] \
  || [[ "$(rg -cF 'transfer::public_transfer(ticket, ctx.sender());' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'creator_authority::new_address\(address::from_bytes\(CREATOR_RECIPIENT_BYTES\)\)' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'creator_authority::new_account\(CREATOR_RECIPIENT_BYTES\)' "$source_file")" != 1 ]] \
  || rg -n '\b(UpgradeCap|CoinRegistry|LaunchConfig|PackageVersion|make_immutable|new_currency)\b' "$source_file"; then
  echo 'The template must expose only its one-time-witness initializer, which builds the ticket through Blast and delivers it to the publisher.' >&2
  exit 1
fi

for constant in SYMBOL NAME DESCRIPTION ICON_URL DECIMALS BURNABLE SELL_BURN_BPS; do
  if [[ "$(rg -c "^const ${constant}:" "$source_file")" != 1 ]] \
    || [[ "$(rg -o "[(,]${constant}(\\.to_string\\(\\))?," <<<"$compact" | wc -l)" != 1 ]]; then
    echo "The template must declare and pass one ${constant} replacement slot." >&2
    exit 1
  fi
done

if [[ "$(rg -c '^const CREATOR_RECIPIENT_BYTES: vector<u8> = x"[0-9a-f]{64}";$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c '^const CREATOR_IS_ACCOUNT: bool = (true|false);$' "$source_file")" != 1 ]] \
  || [[ "$(rg -c 'if \(CREATOR_IS_ACCOUNT\)' "$source_file")" != 1 ]]; then
  echo 'The template must declare its 32-byte creator recipient and recipient-kind replacement slots.' >&2
  exit 1
fi

# Comment- and string-free source from the launchpad's Move reader, so documentation may name the
# cap while code may not use it beyond the two pinned statements.
normalized="$(awk -f ../launchpad/scripts/move_facts.awk "$source_file" \
  | awk -F'\t' '$1 == "MALFORMED" { print "MALFORMED"; exit } $1 == "NORM" { print $2 }')"

if [[ -z "$normalized" || "$normalized" == MALFORMED ]] \
  || rg -q '\b(TreasuryCap|MetadataCap|mint|mint_balance|burn|make_supply_[a-z_]*|finalize|share_object|public_share_object|freeze_object|public_freeze_object|coin|balance)\b' \
    <<<"$normalized"; then
  echo 'Currency creation, supply finalization, and metadata authority must remain inside Blast.' >&2
  exit 1
fi

# launch_ticket::new returns the sealed TreasuryCap beside the ticket so the publisher can prepare
# a venue. The template only binds it and delivers it to the publisher: no mint, burn, wrap, share,
# or freeze, and no other mention.
if [[ "$(rg -oF 'let (ticket, sealed_treasury_cap) = launch_ticket::new(' <<<"$normalized" | wc -l)" != 1 ]] \
  || [[ "$(rg -oF 'transfer::public_transfer(sealed_treasury_cap, ctx.sender());' <<<"$normalized" | wc -l)" != 1 ]] \
  || [[ "$(rg -o '\bsealed_treasury_cap\b' <<<"$normalized" | wc -l)" != 2 ]] \
  || [[ "$(rg -o 'transfer::[a-z_]+\(' <<<"$normalized" | sort | uniq -c | tr -s ' ')" != ' 2 transfer::public_transfer(' ]] \
  || ! in_order_template "$normalized"; then
  echo 'The template must bind the sealed TreasuryCap from launch_ticket::new and only transfer it, with the ticket, to the publisher.' >&2
  exit 1
fi

echo 'launch_ticket_template source boundaries: OK'
