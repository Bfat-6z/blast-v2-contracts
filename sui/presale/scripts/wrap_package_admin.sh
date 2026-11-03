#!/usr/bin/env bash
# Consumes Publication and seals custody; initial configuration uses normal ACL roles at zero delay.
set -euo pipefail

package_id="${1:-}"
publication_id="${2:-}"
upgrade_cap_id="${3:-}"
mode="${4:-}"

if [[ -z "$package_id" || -z "$publication_id" || -z "$upgrade_cap_id" ]] \
  || [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s <package-id> <publication-id> <upgrade-cap-id> [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env mainnet ptb \
  --move-call "$package_id::package_admin::wrap" "@$publication_id" "@$upgrade_cap_id" \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"}
