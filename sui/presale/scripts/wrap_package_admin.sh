#!/usr/bin/env bash
# Finalizes initial policy, consumes Bootstrap and seals custody with operations paused.
set -euo pipefail

package_id="${1:-}"
bootstrap_id="${2:-}"
upgrade_cap_id="${3:-}"
creation_policy_id="${4:-}"
mode="${5:-}"

if [[ -z "$package_id" || -z "$bootstrap_id" || -z "$upgrade_cap_id" || -z "$creation_policy_id" ]] \
  || [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s <package-id> <bootstrap-id> <upgrade-cap-id> <creation-policy-id> [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env mainnet ptb \
  --move-call "$package_id::package_admin::wrap" "@$bootstrap_id" "@$upgrade_cap_id" "@$creation_policy_id" \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"}
