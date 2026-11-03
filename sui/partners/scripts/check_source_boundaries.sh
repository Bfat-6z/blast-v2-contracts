#!/usr/bin/env bash
# Structural gates for blast_partners (ADR 0095): the fixed seven-day notice, PartnerAdmin
# proposals and cancellations, permissionless application, and Clock-free payment. The checks
# live in the shared administration gate, which every fresh-stack package runs.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$package_dir/../../scripts/check_admin_delay.py"
