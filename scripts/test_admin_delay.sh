#!/usr/bin/env bash
# Fresh-stack unit checks: synthetic identities are restored even on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_backup=$(mktemp -d)
find sui -name Published.toml -not -path "*/interfaces/*" -not -path "*/build/*" -print > "$fixture_backup/publications"
tar -T "$fixture_backup/publications" -cf "$fixture_backup/publications.tar"
for pkg in core launchpad presale migrators; do cp "sui/launch/$pkg/Move.toml" "$fixture_backup/$pkg.toml"; done
find sui -name Move.lock -not -path '*/build/*' -print0 | tar --null -T - -cf "$fixture_backup/locks.tar"
restore_source() {
 for pkg in core launchpad presale migrators; do cp "$fixture_backup/$pkg.toml" "sui/launch/$pkg/Move.toml"; done
 tar -xf "$fixture_backup/locks.tar"
 tar -xf "$fixture_backup/publications.tar"
 rm -rf "$fixture_backup"
}
trap restore_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
while IFS= read -r publication; do rm "$publication"; done < "$fixture_backup/publications"
python3 - <<'PY'
from pathlib import Path
import re
for package in ['core', 'launchpad', 'presale', 'migrators']:
    p = Path(f'sui/launch/{package}/Move.toml')
    s = re.sub(r'blast_treasury = "[^"]*"', 'blast_treasury = "0xa"', p.read_text())
    # Native upgrade-cap fixtures require a nonzero package identity.
    if package == 'launchpad':
        s = s.replace('blast_fun = "0x0"', 'blast_fun = "0xc"')
    if package == 'migrators':
        s = s.replace('blast_migrators = "0x0"', 'blast_migrators = "0xd"')
    if package == 'presale':
        s = s.replace('blast_presale = "0x0"', 'blast_presale = "0xb"')
    p.write_text(s)
PY
boundaries_only=0
if [ "${1:-}" = --boundaries-only ]; then boundaries_only=1; shift; fi
coverage_args=()
if [ "${1:-}" = --coverage ]; then coverage_args=(--coverage); shift; fi
if [ "$#" -eq 0 ]; then
 set -- admin partners core vault launchpad presale migrators
 if [ "$boundaries_only" -eq 0 ]; then
  set -- "$@" presale_testkit vendors/aftermath_dao_presale
 fi
fi
for package in "$@"; do
 case "$package" in
  admin) package_dir=sui/governance/admin ;;
  presale_testkit) package_dir=sui/testing/presale_testkit ;;
  *) package_dir="sui/launch/$package" ;;
 esac
 if [ "$boundaries_only" -eq 1 ]; then
  if [ "$package" = admin ]; then
   bash sui/governance/admin/scripts/verify.sh boundaries
  else
   bash "$package_dir/scripts/check_source_boundaries.sh"
  fi
  continue
 fi
 sui move lint --path "$package_dir" --build-env mainnet --warnings-are-errors
 sui move test --path "$package_dir" --build-env mainnet --threads 1 --lint --warnings-are-errors "${coverage_args[@]}" ${MOVE_TEST_FILTER:+"$MOVE_TEST_FILTER"}
 if [ "${#coverage_args[@]}" -gt 0 ]; then
  if [ -n "${BLAST_FORK_COVERAGE_DIR:-}" ] && [[ "$package" = presale || "$package" = migrators ]]; then
   repo_root=$PWD
   fork_trace_dir=$(realpath "$BLAST_FORK_COVERAGE_DIR")
   (
    cd sui/launch/launchpad/ptb_tests
    cargo run --locked --offline --features fork-coverage --bin merge-fork-coverage -- "$fork_trace_dir" "$repo_root/$package_dir"
   )
  fi
  sui move coverage summary --path "$package_dir" --build-env mainnet --test --summarize-functions
 fi
done
