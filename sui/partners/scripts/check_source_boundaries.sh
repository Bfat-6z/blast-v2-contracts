#!/usr/bin/env bash
# Structural gates for blast_partners (ADR 0095): the fixed seven-day delay, PartnerAdmin
# proposals and cancellations, permissionless application, and Clock-free payment. The checks
# live in the shared administration gate, which every fresh-stack package runs.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$package_dir/../../scripts/check_admin_delay.py"

# A partner is never deleted: launches, presales, and vaults bind its ID for good.
if rg -n 'let Partner \{' "$package_dir/sources"; then
  echo "blast_partners boundary violated: a Partner must never be destroyed" >&2
  exit 1
fi
