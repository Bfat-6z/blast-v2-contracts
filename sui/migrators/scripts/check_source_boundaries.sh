#!/usr/bin/env bash
set -euo pipefail
python3 "$(dirname "$0")/../../../scripts/check_admin_delay.py"

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PACKAGE_DIR/sources"
BLUEFIN_SOURCE="$SOURCE_DIR/bluefin.move"
CETUS_SOURCE="$SOURCE_DIR/cetus.move"
EVENTS_SOURCE="$SOURCE_DIR/blast_events.move"
VENUE_CONFIG_SOURCE="$SOURCE_DIR/venue_config.move"
MIGRATION_MATH_SOURCE="$SOURCE_DIR/migration_math.move"
CONSTANTS_SOURCE="$SOURCE_DIR/constants.move"

fail() {
    echo "Migrator source boundary failed: $1" >&2
    exit 1
}

# Launchpad's comment- and string-stripping Move reader; see move_facts.awk for its records.
MOVE_FACTS_READER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../launchpad/scripts" && pwd)/move_facts.awk"

move_facts() {
    awk -f "$MOVE_FACTS_READER" "$1" || echo "MALFORMED	parser rejected $1"
}

# Emits the exact production declaration of one named struct or enum from move_facts records.
move_production_type() {
    awk -F'\t' -v name="$1" '
        $1 == "TYPE" && $2 == name && $5 == 0 { declaration = $8; found += 1 }
        END { if (found == 1) print declaration }
    '
}

# Succeeds when every literal needle occurs exactly once in stdin, in the given order.
in_order() {
    local text needle rest offset=-1
    text="$(cat)"
    for needle in "$@"; do
        rest="${text//"$needle"/}"
        (( ${#text} - ${#rest} == ${#needle} )) || return 1
        rest="${text%%"$needle"*}"
        (( ${#rest} > offset )) || return 1
        offset=${#rest}
    done
}

require_pattern() {
    local source="$1"
    local pattern="$2"
    local description="$3"

    rg -q "$pattern" "$source" || fail "missing $description"
}

reject_pattern() {
    local pattern="$1"
    local description="$2"

    if rg -q "$pattern" "$SOURCE_DIR"; then
        fail "$description"
    fi
}

move_function_section() {
    local source="$1"
    local name="$2"

    awk -v name="$name" '
        function declaration(line) {
            return line ~ /^[[:space:]]*(public(\(package\))?[[:space:]]+)?(entry[[:space:]]+)?fun[[:space:]]+/
        }
        function target(line) {
            return declaration(line) && line ~ ("fun[[:space:]]+" name "[<(]")
        }
        target($0) { active = 1 }
        active && !target($0) && declaration($0) { exit }
        active { print }
    ' "$source"
}

production_section() {
    sed '/^\/\/ === Test-Only Functions ===/,$d' "$1"
}

require_exact_count() {
    local pattern="$1"
    local required_count="$2"
    local description="$3"
    shift 3
    local count

    count="$(cat "$@" | rg -o -F "$pattern" | wc -l || true)"
    [[ "$count" -eq "$required_count" ]] || fail "$description"
}

# Emits a source's comment-free text with whitespace collapsed (the move_facts NORM record).
move_norm() {
    move_facts "$1" | awk -F'\t' '$1 == "NORM" { print $2 }'
}

# Body of one constants.move macro, whitespace removed.
constant_body() {
    move_facts "$CONSTANTS_SOURCE" | awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' \
        | tr -d '[:space:]'
}

# Fails with the description unless the text equals stdin exactly.
require_text() {
    [[ "$1" == "$(cat)" ]] || fail "$2"
}

# Pins a source's coded errors, as `code name message` lines in source order, to stdin.
require_errors() {
    local source="$1"
    local description="$2"
    local table

    table="$(rg -U -o --replace '$1 $2 $3' \
        '#\[error\(code = ([0-9]+)\)\]\s*const (\w+): vector<u8> =\s*b"([^"]*)";' "$source" || true)"
    [[ "$table" == "$(cat)" && "$(rg -c '#\[error' "$source")" -eq "$(wc -l <<<"$table")" ]] || \
        fail "$description"
}


# === Package surface ===
#
# The package is exactly these modules, and each file declares only its own, so any new module (a
# future venue included) fails here until it extends this gate explicitly. No module declares an
# `entry` function, and every module's public and package functions are pinned below with their
# exact signatures, so no helper or type parameter can lend a venue witness, the reserved creation
# cap, or a vault's position to a new caller. Vault custody, LP-fee collection, and holder rewards
# belong to `blast_vault`; the retired migrator vault, LP-fee policy, holder rewards, and Merkle
# modules may not return.
[[ "$(find "$SOURCE_DIR" -mindepth 1 -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" \
    == 'blast_events.move blast_fun_migrators.move bluefin.move cetus.move constants.move migration_math.move package_admin.move venue_config.move ' ]] || \
    fail "sources must be exactly the pinned module set; a new module must extend this gate"
for source in "$SOURCE_DIR"/*.move; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    [[ "$facts" != *MALFORMED* ]] || fail "the Move reader rejected ${module}.move"
    [[ "$(awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" | rg -o '\bmodule [^ ;{]+')" \
        == "module blast_fun_migrators::${module}" ]] || \
        fail "${module}.move must declare exactly its own module"
    if awk -F'\t' '$1 == "FN" && $4 == 1 { found = 1 } END { exit !found }' <<<"$facts"; then
        fail "${module}.move must not declare an entry function; every route is a pinned public function"
    fi
    # Production checks skip `#[test_only]` declarations, so the attribute and the test-only
    # marker must agree in both directions.
    if awk -F'\t' '($1 == "FN" && $6 != $7) || ($1 == "TYPE" && $5 != $6) { found = 1 }
        END { exit !found }' <<<"$facts"; then
        fail "${module}.move must keep every #[test_only] declaration, and only those, below its test-only marker"
    fi
done
# The non-private production functions of every module are pinned with their exact signatures:
# visibility, type parameters and their abilities, parameters, and return type. A new public or
# package function, an added type parameter or return value (a generic `Lent: key + store` that
# lends the reserved creation cap), or a changed parameter fails here until this pin is extended
# deliberately.
package_surface="$(for source in "$SOURCE_DIR"/*.move; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && $7 == 0 && $3 != "private" { print module ":" $3 ":" $9 }'
done | LC_ALL=C sort)"
require_text "$package_surface" \
    "the package's public and package functions must have exactly the pinned signatures" <<'EOF'
blast_events:package:fun bluefin_pool_tier_recorded<Meme, Quote>(tick_spacing: u32, fee_rate: u64)
blast_events:package:fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32)
blast_fun_migrators:package:fun advance(self: &mut PackageVersion)
blast_fun_migrators:package:fun assert_current(self: &PackageVersion)
blast_fun_migrators:package:fun assert_next(self: &PackageVersion)
blast_fun_migrators:package:fun destroy( self: Publication ): (Publisher, OperationalVersion<BLAST_FUN_MIGRATORS>)
blast_fun_migrators:package:fun share_version( generation: OperationalVersion<BLAST_FUN_MIGRATORS>, ctx: &mut TxContext )
bluefin:public:fun buyback_and_burn<Meme, Quote>( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, quote_in: u64, min_meme_out: u64, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun collect_fees<Meme, Quote>( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun migrate<Meme, Quote>( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig, currency: &mut Currency<Meme>, quote_currency: &Currency<Quote>, venue_config: &VenueConfig, bluefin_config: &mut GlobalConfig, registry: &mut VaultRegistry, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, creation_fee: Coin<SUI>, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun prepare<Meme, Quote>( migrators_version: &MigratorsVersion, venue_config: &mut VenueConfig, _: &TreasuryCap<Meme>, tick_spacing: u32, fee_rate: u64, ): VenueTicket<Meme, Quote>
bluefin:public:fun settle_and_apply_fee_split<Meme, Quote>( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun buyback_and_burn<Meme, Quote, CoinA, CoinB>( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, pool: &mut Pool<CoinA, CoinB>, quote_in: u64, min_meme_out: u64, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun collect_fees<Meme, Quote, CoinA, CoinB>( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, burn_manager: &BurnManager, pool: &mut Pool<CoinA, CoinB>, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun migrate<Meme, Quote, CoinA, CoinB>( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig, currency: &mut Currency<Meme>, venue_config: &VenueConfig, cetus_config: &GlobalConfig, pools: &mut Pools, burn_manager: &mut BurnManager, registry: &mut VaultRegistry, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun prepare<Meme, Quote>( migrators_version: &MigratorsVersion, venue_config: &mut VenueConfig, cetus_config: &GlobalConfig, pools: &mut Pools, treasury_cap: &mut TreasuryCap<Meme>, tick_spacing: u32, ctx: &mut TxContext, ): VenueTicket<Meme, Quote>
cetus:public:fun settle_and_apply_fee_split<Meme, Quote, CoinA, CoinB>( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, burn_manager: &BurnManager, pool: &mut Pool<CoinA, CoinB>, clock: &Clock, ctx: &mut TxContext, )
constants:package:fun auto_lp_margin(): u256
constants:package:fun bluefin_max_fee_rate(): u64
constants:package:fun bluefin_max_tick_spacing(): u32
constants:package:fun max_swap_sqrt_price(): u128
constants:package:fun min_swap_sqrt_price(): u128
constants:package:fun q128_shift(): u8
constants:package:fun q64_shift(): u8
constants:package:fun sqrt_upper_bound_shift(): u8
migration_math:package:fun auto_lp_fixed_side( sqrt_lower: u128, sqrt_price: u128, sqrt_upper: u128, amount_a: u64, amount_b: u64, ): (bool, u64)
migration_math:package:fun seed_fixed_side( preferred: bool, available_a: u64, available_b: u64, needed_a: u64, needed_b: u64, ): bool
migration_math:package:fun sqrt_price_x64( meme_amount: u64, quote_amount: u64, meme_is_coin_a: bool, ): u128
package_admin:public:fun apply_upgrade_delay( self: &mut PackageAdmin, package_version: &PackageVersion, clock: &Clock )
package_admin:public:fun authorize_upgrade( self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, digest: vector<u8>, clock: &Clock, ): UpgradeTicket
package_admin:public:fun cancel_upgrade_action( self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<CancelAdmin> )
package_admin:public:fun commit_upgrade_and_advance( self: &mut PackageAdmin, package_version: &mut PackageVersion, _: &AdminWitness<UpgradeAdmin>, receipt: UpgradeReceipt, )
package_admin:public:fun make_immutable( self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, clock: &Clock )
package_admin:public:fun schedule_make_immutable( self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, clock: &Clock )
package_admin:public:fun schedule_upgrade( self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, digest: vector<u8>, clock: &Clock )
package_admin:public:fun schedule_upgrade_delay( self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, delay_ms: u64, clock: &Clock )
package_admin:public:fun wrap(publication: Publication, upgrade_cap: UpgradeCap, ctx: &mut TxContext)
venue_config:package:fun add_object<Key: copy + drop + store, Object: key + store>( self: &mut VenueConfig, key: Key, object: Object, )
venue_config:package:fun add_value<Key: copy + drop + store, Value: store>( self: &mut VenueConfig, key: Key, value: Value, )
venue_config:package:fun object<Key: copy + drop + store, Object: key + store>( self: &VenueConfig, key: Key, ): &Object
venue_config:package:fun value<Key: copy + drop + store, Value: store>( self: &VenueConfig, key: Key, ): &Value
EOF
# `blast_admin::upgrade_custody::new` requires this package's Publisher and its never-upgraded
# cap, and at version one `BLAST_FUN_MIGRATORS` is the package's only one-time witness, so custody
# declares no publisher check or error of its own.
if rg -q 'from_module' "$SOURCE_DIR/package_admin.move"; then
    fail "package admin must leave publisher validation to blast_admin's upgrade custody"
fi
# Every rename in the package is pinned. The rules here match protected types and calls by name,
# so a type, function, or method alias under a new name (`Venue as Seal`, a `use fun` that
# shadows `assert_current`) would hide them; each alias must be extended here deliberately.
package_aliases="$(for source in "$SOURCE_DIR"/*.move; do
    move_norm "$source" | rg -o -P '[\w:]+ as (?!u(8|16|32|64|128|256)\b(?!\.))[\w.]+' \
        | sed "s|^|$(basename "$source" .move): |"
done | LC_ALL=C sort)"
require_text "$package_aliases" \
    "every rename and method alias in the package must be exactly the pinned set" <<'EOF'
bluefin: blast_fun_migrators::PackageVersion as MigratorsVersion
bluefin: collect_position_fees as Vault.collect_position_fees
bluefin: compound as Vault.compound
bluefin: fixed_side as Pool.fixed_side
bluefin: full_range_tick_range as GlobalConfig.full_range_tick_range
bluefin: is_meme_seed_side as Pool.is_meme_seed_side
bluefin: package_version::PackageVersion as VaultVersion
bluefin: pool_name as Currency.pool_name
bluefin: seed as Pool.seed
bluefin: settle_fees as Vault.settle_fees
cetus: add_liquidity as Vault.add_liquidity
cetus: blast_fun_migrators::PackageVersion as MigratorsVersion
cetus: cast as UID.cast
cetus: collect_position_fees as Vault.collect_position_fees
cetus: compound as Vault.compound
cetus: fixed_side as Pool.fixed_side
cetus: package_version::PackageVersion as VaultVersion
cetus: pool_creation_cap as VenueConfig.pool_creation_cap
cetus: settle_fees as Vault.settle_fees
cetus: swap as Pool.swap
cetus: swap_quote_for_meme as Pool.swap_quote_for_meme
package_admin: blast_fun_migrators::blast_fun_migrators::share_version as OperationalVersion.share_version
venue_config: dynamic_field::add as UID.add_dynamic_field
venue_config: dynamic_field::borrow as UID.dynamic_field
venue_config: dynamic_object_field::add as UID.add_dynamic_object_field
venue_config: dynamic_object_field::borrow as UID.dynamic_object_field
EOF
# `MigratorsVersion` must name this package's generation, not the launchpad's, and `VaultVersion`
# must be `blast_admin`'s generic package version, which each venue route types to the vault
# package.
for module in bluefin cetus; do
    [[ "$(move_norm "$SOURCE_DIR/${module}.move" | rg -o 'use [^;]*\bMigratorsVersion\b[^;]*;' \
        | rg -c '^use blast_fun_migrators::\{')" == 1 ]] || \
        fail "${module}.move must import MigratorsVersion once, from this package's marker module"
    [[ "$(move_norm "$SOURCE_DIR/${module}.move" | rg -o 'use [^;]*\bVaultVersion\b[^;]*;')" \
        == 'use blast_admin::{blast_acl::AdminWitness, package_version::PackageVersion as VaultVersion};' ]] || \
        fail "${module}.move must import VaultVersion once, as blast_admin's package version"
done
# Every source error is an explicitly coded constant, so the per-module code pins see them all.
if rg -q '#\[error\]|\bconst E\w*\s*:\s*u(8|16|32|64|128|256)\b' "$SOURCE_DIR"; then
    fail "source errors must be #[error(code = N)] constants, never uncoded or bare integers"
fi

# === Release venue matrix ===
#
# Cetus and Bluefin are the release's only venues (ADR 0137). A venue reaches the hand-off seams
# (issuing a `VenueTicket`, migrating a launch, and redeeming its `Migration`) only by constructing
# its own sealed `Venue()`, so the matrix is exactly the modules that declare a venue witness and
# name those seams. Each prepares its coins through `prepare`, which ends by issuing the ticket,
# and migrates by redeeming the hand-off and creating a `blast_vault` vault from the redeemed terms,
# with its position attached, under its own witness; only Cetus needs local normalized venue
# interfaces. A future venue extends this matrix explicitly. The retired migration witness may
# not return.
matrix_venue_modules=""
matrix_seam_modules=""
for source in "$SOURCE_DIR"/*.move; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    if awk -F'\t' '$1 == "TYPE" && $2 == "Venue" { found = 1 } END { exit !found }' <<<"$facts"; then
        matrix_venue_modules+="$module"$'\n'
    fi
    if awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" | rg -q \
        '\b(issue_ticket|redeem_ticket)\b|\.redeem\(|launch\s*\.\s*migrate\(|\bvault::new\b'; then
        matrix_seam_modules+="$module"$'\n'
    fi
done
matrix_venue_modules="$(LC_ALL=C sort <<<"$matrix_venue_modules" | tr '\n' ' ' | sed 's/^ *//')"
matrix_seam_modules="$(LC_ALL=C sort <<<"$matrix_seam_modules" | tr '\n' ' ' | sed 's/^ *//')"
[[ "$matrix_venue_modules" == 'bluefin cetus ' ]] || \
    fail "only Cetus and Bluefin may declare a venue witness (found: ${matrix_venue_modules:-none})"
[[ "$matrix_seam_modules" == 'bluefin cetus ' ]] || \
    fail "only Cetus and Bluefin may reach the hand-off seams (found: ${matrix_seam_modules:-none})"
if rg -q '\bstruct Witness\b|\bWitness\(\)' "$SOURCE_DIR"; then
    fail "the retired migration witness is forbidden; each venue's one witness is its Venue"
fi
for module in $matrix_venue_modules; do
    venue_facts="$(move_facts "$SOURCE_DIR/${module}.move")"
    [[ "$(move_production_type Venue <<<"$venue_facts")" == 'struct Venue() has drop;' ]] || \
        fail "${module}::Venue must be a field-free drop-only witness"
    # The ticket is issued once, at the end of `prepare`, and the hand-off is redeemed once, at the
    # start of `migrate`'s custody, each under the module's own witness.
    [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "issue_ticket") > 0 { print $2 }' \
        <<<"$venue_facts")" == 'prepare' ]] \
        && [[ "$(awk -F'\t' '$1 == "FN" && $2 == "prepare" && $6 == 0 { print $10 }' <<<"$venue_facts" \
            | tr -d '[:space:]')" == 'migrators_version.assert_current();'*';migration::issue_ticket(Venue())' ]] || \
        fail "${module}::prepare alone must check this package's generation first and end by issuing its own venue's ticket"
    custody_body="$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, ".redeem(") > 0 { print $2 "|" $10 }' \
        <<<"$venue_facts" | tr -d '[:space:]')"
    [[ "$custody_body" == 'migrate|migrators_version.assert_current();'* ]] \
        && in_order \
            '.migrate(package_version,config,currency,ctx).redeem(Venue());' \
            'vault::new<Meme,Quote,_>(registry,&Venue(),vault_version,terms,pool_id).share_with_position(&Venue(),treasury,' \
            <<<"$custody_body" || \
        fail "${module}::migrate alone must redeem the hand-off under its own witness, then create and share a blast_vault vault from the redeemed terms"
done
[[ -n "$(find "$PACKAGE_DIR/interfaces" -mindepth 1 -maxdepth 1 -printf '%f\n')" \
    && -z "$(find "$PACKAGE_DIR/interfaces" -mindepth 1 -maxdepth 1 -printf '%f\n' \
        | rg -v '^cetus(_[a-z_]+)?$')" ]] || \
    fail "only Cetus packages may have local venue interfaces; an excluded venue keeps no interface"
# A sealed witness never leaves its venue: no venue function, whatever its visibility, names the
# witness in its signature, so none returns it or fills a caller's container with it. Only the
# two `prepare` routes return a ticket, and no route returns the hand-off.
for module in $matrix_venue_modules; do
    if move_facts "$SOURCE_DIR/${module}.move" | awk -F'\t' '
        $1 == "FN" && $9 ~ /[^A-Za-z0-9_]Venue([^A-Za-z0-9_]|$)/ { found = 1 }
        END { exit !found }'; then
        fail "${module}::Venue must never appear in any ${module} function signature"
    fi
done
[[ "$(for source in "$SOURCE_DIR"/*.move; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && index($9, "VenueTicket") > 0 { print module ":" $2 }'
done | LC_ALL=C sort | tr '\n' ' ')" == 'bluefin:prepare cetus:prepare ' ]] || \
    fail "only the venues' prepare routes may return a VenueTicket"
if rg -q '\bMigration<' "$SOURCE_DIR"; then
    fail "no migrator function may name the hand-off type; each migrate redeems it in place"
fi
# Each venue records its prepared coin's tier under a key of its own module, so one venue can
# never read another's tier.
for module in $matrix_venue_modules; do
    [[ "$(move_production_type PoolTierKey <<<"$(move_facts "$SOURCE_DIR/${module}.move")")" \
        == 'struct PoolTierKey<phantom Meme>() has copy, drop, store;' ]] || \
        fail "${module} must key its prepared tier by its own PoolTierKey<Meme>"
done

# Migration math is the venues' shared seed-price derivation and liquidity side selection, and
# nothing else: pure package-only arithmetic.
[[ "$(rg -o '^public\(package\) fun \w+' "$MIGRATION_MATH_SOURCE" | LC_ALL=C sort | tr '\n' ';')" \
    == 'public(package) fun auto_lp_fixed_side;public(package) fun seed_fixed_side;public(package) fun sqrt_price_x64;' ]] || \
    fail "migration math must expose exactly its package-only seed price and liquidity side selection"
if rg -q '^public fun |^entry fun |^public entry fun ' "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must not expose a public transaction or composition ABI"
fi
require_pattern "$MIGRATION_MATH_SOURCE" \
    'module blast_fun_migrators::migration_math;' \
    'migrator-owned migration math module'
# Seed balances come only from the redeemed hand-off, which carries a positive amount of each
# asset, so the math declares no errors of its own.
if rg -q '#\[error|\bconst E\w*' "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must declare no errors; its seed balances are the launch's positive hand-off"
fi
require_pattern "$MIGRATION_MATH_SOURCE" \
    'integer_sqrt\(ratio_q128\(meme_amount, quote_amount, meme_is_coin_a\)\)' \
    'exact Q128 price derivation'
# Auto-LP side selection adds nothing unless the price is strictly inside the range, checked first
# so every later subtraction is positive, and then prefers fixing coin A. Each side's check needs
# positive liquidity (below 2^128 when fixing A) and leaves the pinned margin of the other unused;
# an empty side yields zero liquidity or a need it cannot meet.
math_body() {
    move_facts "$MIGRATION_MATH_SOURCE" | awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' \
        | tr -d '[:space:]'
}
[[ "$(math_body seed_fixed_side)" == 'if(needed_a<=available_a&&needed_b<=available_b)preferredelse!preferred' ]] || \
    fail "seed side selection must keep the preference only when both quoted requirements fit"
[[ "$(constant_body auto_lp_margin)" == '2' ]] \
    && [[ "$(math_body auto_lp_fixed_side)" == 'if(sqrt_price<=sqrt_lower||sqrt_price>=sqrt_upper)return(true,0);let(lower,price,upper)=(sqrt_lowerasu256,sqrt_priceasu256,sqrt_upperasu256);if(can_fix_a(lower,price,upper,amount_a,amount_b))return(true,amount_a);if(can_fix_b(lower,price,upper,amount_a,amount_b))return(false,amount_b);(true,0)' ]] \
    && [[ "$(math_body can_fix_a)" == 'letone=1u256<<constants::q64_shift!();letliquidity=(amount_aasu256)*(price*upper/one)/(upper-price);if(liquidity==0||liquidity>=(1u256<<constants::q128_shift!()))returnfalse;letneeded_b=(liquidity*(price-lower)).div_ceil(one);needed_b+constants::auto_lp_margin!()<=(amount_basu256)' ]] \
    && [[ "$(math_body can_fix_b)" == 'letliquidity=((amount_basu256)<<constants::q64_shift!())/(price-lower);if(liquidity==0)returnfalse;letneeded_a=(liquidity<<constants::q64_shift!()).div_ceil(price)-(liquidity<<constants::q64_shift!())/upper;needed_a+constants::auto_lp_margin!()<=(amount_aasu256)' ]] || \
    fail "auto-LP side selection must first skip out-of-range prices, prefer coin A, and keep a two-atom margin"
if rg -q '\b(blast_fun::(constants|errors)|UID|key|Balance|Coin|TxContext|transfer::|blast_events::|RuntimeConfig)\b' \
    "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must remain a pure migrator-owned arithmetic module"
fi
if rg -U -q 'use blast_fun::\{[^}]*migration_math' "$SOURCE_DIR"; then
    fail "venue modules must use migrator-owned migration math"
fi

# === Events ===
#
# The package's two replay facts are the pool tier each venue records while preparing a pair: the
# Cetus pool reservation, written only by `cetus::prepare`, and the Bluefin pool tier, written only
# by `bluefin::prepare` after it stores the tier and before it issues the ticket. Each is a direct,
# strongly typed payload with exactly one emitting helper. Vault creation, LP-fee collection,
# auto-LP, buybacks, owner claims, and holder rewards are `blast_vault` events, and delayed
# settings and upgrade custody record their lifecycle through `blast_admin`, so no migrator event
# may restate them.
[[ "$(move_facts "$EVENTS_SOURCE" | awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' \
    | LC_ALL=C sort | tr '\n' ' ')" == 'BluefinPoolTierRecorded CetusPoolReserved ' ]] || \
    fail "blast_events.move must declare exactly the Cetus pool reservation and Bluefin pool tier payloads"
[[ "$(move_production_type CetusPoolReserved <<<"$(move_facts "$EVENTS_SOURCE")")" \
    == 'struct CetusPoolReserved has copy, drop { meme: TypeName, quote: TypeName, pool_creation_cap_id: ID, tick_spacing: u32, }' ]] || \
    fail "CetusPoolReserved must record the pair, the reserved capability, and the tick spacing"
[[ "$(move_production_type BluefinPoolTierRecorded <<<"$(move_facts "$EVENTS_SOURCE")")" \
    == 'struct BluefinPoolTierRecorded has copy, drop { meme: TypeName, quote: TypeName, tick_spacing: u32, fee_rate: u64, }' ]] || \
    fail "BluefinPoolTierRecorded must record the pair, the tick spacing, and the fee rate"
[[ "$(rg -c 'sui::event::emit\(CetusPoolReserved \{' "$EVENTS_SOURCE" || true)" -eq 1 \
    && "$(rg -c 'sui::event::emit\(BluefinPoolTierRecorded \{' "$EVENTS_SOURCE" || true)" -eq 1 \
    && "$(rg -o 'sui::event::emit' "$EVENTS_SOURCE" | wc -l)" -eq 2 ]] || \
    fail "CetusPoolReserved and BluefinPoolTierRecorded must be the only payloads, each emitted directly by exactly one helper"
[[ "$(move_facts "$EVENTS_SOURCE" | awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "sui::event::emit(CetusPoolReserved {") > 0 { print $2 }')" == 'cetus_pool_reserved' \
    && "$(move_facts "$EVENTS_SOURCE" | awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "sui::event::emit(BluefinPoolTierRecorded {") > 0 { print $2 }')" == 'bluefin_pool_tier_recorded' ]] || \
    fail "each migrator event must be emitted only by its own typed helper"
if rg -q 'sui::event::emit' "$SOURCE_DIR" --glob '*.move' --glob '!blast_events.move'; then
    fail "state modules must emit only through typed events helpers"
fi
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Meme>' 'Meme type facts'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Quote>' 'Quote type facts'
reject_pattern 'protocol_meme_fee_total|creator_meme_fee_total|protocol_quote_fee_total|creator_quote_fee_total' \
    'derivable fee totals are forbidden in migrator events'
if rg -q '\b(VenueTierUpdated|venue_tier_updated|RoutesChanged|routes_changed|PolicySnapshot)\b' \
    "$SOURCE_DIR"; then
    fail "venue tiers and fee routes are launch settings and the Blast share is sealed in the vault terms; no admin tier, route, or snapshot record may return"
fi
reservation_writers="$(for source in "$SOURCE_DIR"/*.move; do
    [[ "$source" == "$EVENTS_SOURCE" ]] && continue
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && index($10, "blast_events::cetus_pool_reserved<") > 0 { print module ":" $2 }'
done | LC_ALL=C sort | tr '\n' ' ')"
[[ "$reservation_writers" == 'cetus:prepare ' ]] || \
    fail "CetusPoolReserved must be emitted only by cetus:prepare (found: ${reservation_writers:-none})"
tier_writers="$(for source in "$SOURCE_DIR"/*.move; do
    [[ "$source" == "$EVENTS_SOURCE" ]] && continue
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && index($10, "blast_events::bluefin_pool_tier_recorded<") > 0 { print module ":" $2 }'
done | LC_ALL=C sort | tr '\n' ' ')"
[[ "$tier_writers" == 'bluefin:prepare ' ]] || \
    fail "BluefinPoolTierRecorded must be emitted only by bluefin:prepare (found: ${tier_writers:-none})"

# === Vault custody ===
#
# The package holds no value of its own: every position, residual, and LP fee lives in the
# `blast_vault` vault each migration creates, which pays Blast through the core treasury and owns
# the fee split, auto-LP, buyback, and holder-reward balances. No migrator type stores a balance or
# a coin, and no module declares a vault, a fee policy, a treasury destination, or a round.
for source in "$SOURCE_DIR"/*.move; do
    if move_facts "$source" | awk -F'\t' '
        $1 == "TYPE" && $5 == 0 && $8 ~ /(^|[^A-Za-z0-9_])(Balance|Coin|Table|Bag)</ { found = 1 }
        END { exit !found }'; then
        fail "$(basename "$source") must hold no balance, coin, or collection; vault custody belongs to blast_vault"
    fi
done
if rg -q '\b(LpVault|LpFeePolicy|lp_fee_policy|blast_holder_rewards|Round<|merkle::|protocol_destination)\b' \
    "$SOURCE_DIR"; then
    fail "the retired migrator vault, LP-fee policy, holder rewards, and Merkle paths are forbidden"
fi
if rg -q 'vault::(create|share_for_testing)\b|share_for_testing' "$SOURCE_DIR"; then
    fail "venues must share their vault only through blast_vault's share_with_position"
fi

# === Venue config ===

require_pattern "$VENUE_CONFIG_SOURCE" 'public struct VenueConfig has key' \
    'shared venue-owned entry singleton'
require_pattern "$VENUE_CONFIG_SOURCE" 'transfer::share_object\(VenueConfig' \
    'shared venue config creation'
# The whole production API is package-only: write-once objects and plain records added under keys
# only a venue module constructs, and their immutable reads. Pool tiers are the creator's
# preparation settings, so no admin tier, reservation policy, or tier error may return.
require_text "$(move_facts "$VENUE_CONFIG_SOURCE" \
    | awk -F'\t' '$1 == "FN" && $6 == 0 { print $3 ":" $9 }' | LC_ALL=C sort)" \
    "VenueConfig must expose exactly its package-only object and record functions" <<'EOF'
package:fun add_object<Key: copy + drop + store, Object: key + store>( self: &mut VenueConfig, key: Key, object: Object, )
package:fun add_value<Key: copy + drop + store, Value: store>( self: &mut VenueConfig, key: Key, value: Value, )
package:fun object<Key: copy + drop + store, Object: key + store>( self: &VenueConfig, key: Key, ): &Object
package:fun value<Key: copy + drop + store, Value: store>( self: &VenueConfig, key: Key, ): &Value
private:fun init(ctx: &mut TxContext)
EOF
# Venue entries are write-once: no function borrows, replaces, or removes an entry.
if move_norm "$VENUE_CONFIG_SOURCE" | rg -q '\bborrow_mut\b|_field_mut\b|\bremove(_if_exists|_opt)?\b|\breplace\b' \
    || rg -q '#\[error' "$VENUE_CONFIG_SOURCE" \
    || rg -q '\b(TierKey|ReservationKey|set_tier|has_tier|effective_tier|reserved_tick_spacing|add_policy|has_policy)\b' \
        "$SOURCE_DIR"; then
    fail "venue entries must be write-once, and no admin tier or reservation policy may return"
fi
# Only the two preparations write records, and only the two migrations read them.
venue_record_sites="$(for module in bluefin cetus; do
    move_facts "$SOURCE_DIR/${module}.move" | awk -F'\t' -v module="$module" '
        $1 == "FN" && $6 == 0 && index($10, "venue_config.add_value(") > 0 { print module ":" $2 " adds" }
        $1 == "FN" && $6 == 0 && index($10, "venue_config.value(") > 0 { print module ":" $2 " reads" }'
done | LC_ALL=C sort | tr '\n' ' ')"
[[ "$venue_record_sites" == 'bluefin:migrate reads bluefin:prepare adds cetus:migrate reads cetus:prepare adds ' ]] || \
    fail "only each venue's prepare may record its tier and only its migrate may read it (found: ${venue_record_sites:-none})"

# === Bluefin ===

require_pattern "$BLUEFIN_SOURCE" 'public struct Venue\(\) has drop;' 'sealed Bluefin venue witness'
# Bluefin has exactly one preparation, one atomic migrate route, one collection entry, one settled
# update entry, and one buyback entry. Preparation checks the creator's tier against Bluefin's
# bounds, records it, emits the tier, and issues the ticket; migration reads that tier, redeems
# the hand-off, creates and funds the pool, creates and shares the vault holding the venue
# position, then shares the pool; and every fee exit splits the collected position's fees
# through the vault and adds the auto-LP share back to the same position. The buyback swaps the
# admin's `quote_in` of the vault's burn Quote for Meme in the vault's own pool and hands the
# result to the vault, which checks the admin's minimum and burns it.
bluefin_facts="$(move_facts "$BLUEFIN_SOURCE")"
[[ "$bluefin_facts" != *MALFORMED* ]] || fail "the Move reader rejected bluefin.move"
bluefin_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$bluefin_facts" \
    | sort | tr '\n' ' ')"
[[ "$bluefin_public" == 'buyback_and_burn collect_fees migrate prepare settle_and_apply_fee_split ' ]] || \
    fail "Bluefin must expose exactly prepare, migrate, collect_fees, settle_and_apply_fee_split, and buyback_and_burn"
bluefin_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' <<<"$bluefin_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
[[ "$(bluefin_body prepare)" == 'migrators_version.assert_current();assert!(tick_spacing>0&&tick_spacing<=constants::bluefin_max_tick_spacing!()&&fee_rate>0&&fee_rate<=constants::bluefin_max_fee_rate!(),EInvalidTier);venue_config.add_value(PoolTierKey<Meme>(),PoolTier{tick_spacing,fee_rate});blast_events::bluefin_pool_tier_recorded<Meme,Quote>(tick_spacing,fee_rate);migration::issue_ticket(Venue())' ]] \
    && [[ "$(move_production_type PoolTier <<<"$bluefin_facts")" == 'struct PoolTier has copy, drop, store { tick_spacing: u32, fee_rate: u64, }' ]] \
    && [[ "$(constant_body bluefin_max_tick_spacing)" == '400' ]] \
    && [[ "$(constant_body bluefin_max_fee_rate)" == '20_000' ]] || \
    fail "bluefin::prepare must bound the tier to Bluefin's 1..=400 tick spacing and 1..=20,000 fee rate, record it, emit its tier event, then issue the ticket"
bluefin_migrate_body="$(bluefin_body migrate)"
# Migration reads the recorded tier and the full-range bounds from Bluefin's config, redeems the
# hand-off, creates the named pool priced from the handed-off balances with the caller's whole
# creation fee, opens and seeds a full-range position, creates and shares the vault holding the
# position under the redeemed terms, then shares the pool.
[[ "$bluefin_migrate_body" == 'migrators_version.assert_current();letPoolTier{tick_spacing,fee_rate}=*venue_config.value(PoolTierKey<Meme>());let(lower_tick,upper_tick)=bluefin_config.full_range_tick_range(tick_spacing);let(meme,quote,terms)=launch.migrate(package_version,config,currency,ctx).redeem(Venue());letmutpool=pool::create_pool_and_get_object<Meme,Quote,SUI>(clock,bluefin_config,currency.pool_name(quote_currency),b"",currency.symbol().into_bytes(),currency.decimals(),b"",quote_currency.symbol().into_bytes(),quote_currency.decimals(),quote_currency.icon_url().into_bytes(),tick_spacing,fee_rate,migration_math::sqrt_price_x64(meme.value(),quote.value(),true),creation_fee.into_balance(),ctx);letmutposition=pool::open_position(bluefin_config,&mutpool,lower_tick,upper_tick,ctx);let(residual_meme,residual_quote)=pool.seed(bluefin_config,&mutposition,meme,quote,clock);letpool_id=position.pool_id();letliquidity=position.liquidity();vault::new<Meme,Quote,_>(registry,&Venue(),vault_version,terms,pool_id).share_with_position(&Venue(),treasury,position,liquidity,residual_meme,residual_quote,ctx);pool.share_pool_object();' ]] \
    && [[ "$(bluefin_body full_range_tick_range)" == 'let(minimum_tick,maximum_tick)=bluefin_config.get_tick_range();letspacing=i32::from(tick_spacing);(minimum_tick.div(spacing).mul(spacing).as_u32(),maximum_tick.div(spacing).mul(spacing).as_u32())' ]] || \
    fail "Bluefin migrate must redeem the launch, create and fund the pool, create and share the vault holding the position, then share the pool"
# The pool and the position record no Meme icon, as Cetus: the position stores the URL it is given,
# and the metadata capability can lengthen the Meme icon URL past Sui's object size limit. The pool
# name, which the position stores twice, is exactly the two symbols around a one-byte separator
# (the reader masks string contents); launch intake bounds the Meme symbol, and no mutable Meme
# metadata may join it.
[[ "$(bluefin_body pool_name)" == 'letmutname=currency.symbol().into_bytes();name.append(b"_");name.append(quote_currency.symbol().into_bytes());name' \
    && "$(grep -o 'pool_name' <<<"$bluefin_migrate_body" | wc -l)" -eq 1 \
    && "$(move_norm "$BLUEFIN_SOURCE" | grep -o 'create_pool_and_get_object' | wc -l)" -eq 1 \
    && "$(move_norm "$BLUEFIN_SOURCE" | grep -o 'icon_url()' | wc -l)" -eq 1 ]] || \
    fail "bluefin::migrate must name the pool by the two symbols and pass an empty Meme icon URL"
# The seed prefers to fix the side with more atoms, Meme on a tie, and fixes the other side when
# Bluefin's own liquidity math, at the position's bounds and the new pool's price, says the
# preferred side would overdraw its partner; nearly equal amounts can do that by one atom.
[[ "$(bluefin_body seed)" == 'letfix_meme=pool.is_meme_seed_side(position,meme.value(),quote.value());letfixed_amount=if(fix_meme)meme.value()elsequote.value();let(_,_,residual_meme,residual_quote)=pool::add_liquidity_with_fixed_amount(clock,bluefin_config,pool,position,meme,quote,fixed_amount,fix_meme);(residual_meme,residual_quote)' ]] \
    && [[ "$(bluefin_body is_meme_seed_side)" == 'letprefer_meme=meme_amount>=quote_amount;let(_,needed_meme,needed_quote)=pool::get_liquidity_by_amount(position.lower_tick(),position.upper_tick(),pool.current_tick_index(),pool.current_sqrt_price(),if(prefer_meme)meme_amountelsequote_amount,prefer_meme);migration_math::seed_fixed_side(prefer_meme,meme_amount,quote_amount,needed_meme,needed_quote)' ]] || \
    fail "Bluefin migrate must fix the larger side, Meme on a tie, unless Bluefin's own math says it overdraws the other side"
# Both fee exits settle through one helper: collect the position's fees, split them through the
# vault under Bluefin's witness, and add the auto-LP share back. Application checks the stored
# proposal readiness first and commits the new split only after settling under the current one.
[[ "$(bluefin_body settle_fees)" == 'let(meme_fee,quote_fee)=self.collect_position_fees(vault_version,bluefin_config,pool,clock);self.split_fees(&Venue(),vault_version,treasury,currency,meme_fee,quote_fee,ctx);self.compound(vault_version,bluefin_config,pool,clock);' ]] \
    && [[ "$(bluefin_body collect_fees)" == 'migrators_version.assert_current();self.settle_fees(vault_version,treasury,currency,bluefin_config,pool,clock,ctx);' ]] || \
    fail "Bluefin collection must split the collected position's fees through the vault, then add the auto-LP share back"
[[ "$(bluefin_body settle_and_apply_fee_split)" == 'migrators_version.assert_current();self.assert_fee_split_ready(clock);self.settle_fees(vault_version,treasury,currency,bluefin_config,pool,clock,ctx);self.apply_fee_split(&Venue(),vault_version,clock);' ]] || \
    fail "Bluefin settled application must check stored proposal readiness before collecting, then split the accrued fees under the current split before committing a new one"
[[ "$(bluefin_body buyback_and_burn)" == 'migrators_version.assert_current();assert!(self.pool_id()==object::id(pool),EPositionPoolMismatch);let(quote,receipt)=self.take_buyback_quote(&Venue(),admin_witness,vault_version,quote_in);let(meme,quote)=pool::swap(clock,bluefin_config,pool,balance::zero(),quote,false,true,quote_in,0,constants::max_swap_sqrt_price!());self.burn_buyback(&Venue(),vault_version,receipt,currency,meme,quote,min_meme_out,ctx);' ]] || \
    fail "the Bluefin buyback must check the vault's pool, take the admin's quote_in of the burn Quote under the buyback admin, swap all of it Quote-to-Meme, and let the vault check and burn"
in_order \
    'self.position_mut<_,_,_,Position>(&Venue(),vault_version);' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'let(_,_,meme_fee,quote_fee)=pool::collect_fee(clock,bluefin_config,pool,position);' \
    '(meme_fee,quote_fee)' \
    <<<"$(bluefin_body collect_position_fees)" || \
    fail "Bluefin collection must check the custodied position's pool once, before the venue call"
# Auto-LP adds the waiting balances to the custodied position, fixing the side the shared
# selection chooses from the pool's price and the position's own tick bounds, and keeps the rest.
[[ "$(bluefin_body compound)" == 'let(meme,quote,receipt)=self.take_auto_lp(&Venue(),vault_version);letposition=self.position_mut<_,_,_,Position>(&Venue(),vault_version);let(fix_meme,fixed_amount)=pool.fixed_side(position,meme.value(),quote.value());let(_,_,meme,quote)=if(fixed_amount>0){pool::add_liquidity_with_fixed_amount(clock,bluefin_config,pool,position,meme,quote,fixed_amount,fix_meme)}else{(0,0,meme,quote)};self.keep_auto_lp(&Venue(),vault_version,receipt,meme,quote);' ]] \
    && [[ "$(bluefin_body fixed_side)" == 'letticks=pool.get_tick_manager();letsqrt_lower=ticks.get_tick_from_manager(position.lower_tick()).sqrt_price();letsqrt_upper=ticks.get_tick_from_manager(position.upper_tick()).sqrt_price();migration_math::auto_lp_fixed_side(sqrt_lower,pool.current_sqrt_price(),sqrt_upper,meme_amount,quote_amount)' ]] || \
    fail "Bluefin auto-LP must add to the custodied position on the side the shared selection fixes and keep the rest"
require_errors "$BLUEFIN_SOURCE" "Bluefin must use codes 0-1 for its position-pool and tier checks" <<'EOF'
0 EPositionPoolMismatch Custodied position must belong to the supplied pool.
1 EInvalidTier Bluefin tier needs a tick spacing in 1..=400 and a fee rate in 1..=20,000.
EOF
# Bluefin's public routes share one parameter order: preparation takes this package's generation
# and the venue config first; migration takes the launch, this package's generation, then the
# launchpad generation and policy; every vault route takes the vault, this package's generation,
# then the vault generation. Split application consumes only the stored ready proposal.
for entry in prepare migrate collect_fees settle_and_apply_fee_split buyback_and_burn; do
    case "$entry" in
        prepare) expected="( migrators_version: &MigratorsVersion, venue_config: &mut VenueConfig," ;;
        migrate) expected="( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig, currency: &mut Currency<Meme>," ;;
        collect_fees|settle_and_apply_fee_split) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>," ;;
        buyback_and_burn) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>," ;;
        *) fail "unhandled venue entry ${entry}" ;;
    esac
    [[ "$(awk -F'\t' -v name="$entry" '$1 == "FN" && $2 == name && $6 == 0 { print $9 }' \
        <<<"$bluefin_facts")" == *"$expected"* ]] || \
        fail "bluefin::${entry} must take the shared venue parameter order"
done
if rg -q 'fun [a-z_]*_meme_b\b|meme_is_coin_a|is_meme_coin_a' "$BLUEFIN_SOURCE"; then
    fail "Bluefin must use only the deterministic Meme-A/Quote-B orientation"
fi
BLUEFIN_COMPACT_SOURCE="$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")"
BLUEFIN_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect|settle)[^{]+\{' "$BLUEFIN_SOURCE" || true)"
if [[ "$BLUEFIN_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:|amount|liquidity) ]]; then
    fail "caller-supplied Bluefin price, orientation, tier, or amount is forbidden after preparation"
fi
# The caller's SUI coin is the whole creation fee; Bluefin enforces the exact configured amount.
# The only constructed balance is the buyback swap's empty Meme input.
[[ "$(rg -o 'into_balance' "$BLUEFIN_SOURCE" | wc -l)" -eq 1 ]] \
    && [[ "$BLUEFIN_COMPACT_SOURCE" == *'creation_fee:Coin<SUI>,'* ]] \
    && [[ "$bluefin_migrate_body" == *',creation_fee.into_balance(),ctx);'* ]] \
    && [[ "$(grep -o 'balance::zero()' <<<"$BLUEFIN_COMPACT_SOURCE" | wc -l)" -eq 1 ]] \
    && [[ "$(bluefin_body buyback_and_burn)" == *'pool,balance::zero(),quote,'* ]] \
    && ! [[ "$BLUEFIN_COMPACT_SOURCE" =~ balance::(create|from|withdraw|split)|creation_fee\.(split|balance_mut) ]] || \
    fail "the Bluefin creation fee must be the caller's whole SUI coin"
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*[^A-Za-z0-9_]Venue([^A-Za-z0-9_]|$) ]]; then
    fail "public or package Bluefin venue exposure is forbidden"
fi
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ publicfun[^\{]*Position ]]; then
    fail "public Bluefin position exposure is forbidden"
fi

# === Cetus ===

require_pattern "$CETUS_SOURCE" 'public struct Venue\(\) has drop;' 'sealed Cetus venue witness'
# Cetus has one preparation and one migrate, collection, settled-update, and buyback route, each
# serving both coin orders (ADR 0100). Preparation checks that Cetus registers the creator's tick
# spacing, then reserves pool creation before any Meme can leave the launch ticket: it mints the
# Meme type's cap from the treasury capability, registers the pair at that tick spacing, stores
# the cap and the tick spacing, records the reservation, and issues the ticket. Every later route
# takes the pool's coin types as `CoinA` and `CoinB`, checks this package's generation first, and
# then proves `(CoinA, CoinB)` is exactly `{Meme, Quote}`; migration also requires Cetus's own
# coin order before that. Migration redeems the hand-off, creates the pair's pool only with the
# reserved cap at the recorded tick spacing, prices it from the handed-off balances in the pool's
# coin order, fixes the larger side (Meme on a tie) unless Cetus's own liquidity math says it
# overdraws the other, burns the position through Cetus LP Burn, and creates and shares a vault
# holding the burn proof. Every fee exit collects the burn proof's and the auto-LP position's fees,
# splits them through the vault, and adds the auto-LP share to the auto-LP position. Each buyback
# checks the vault's own pool, swaps the admin's `quote_in` of the vault's burn Quote for Meme,
# repays exactly what Cetus asks, and hands the result to the vault, which checks the admin's
# minimum and burns it.
cetus_facts="$(move_facts "$CETUS_SOURCE")"
[[ "$cetus_facts" != *MALFORMED* ]] || fail "the Move reader rejected cetus.move"
cetus_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$cetus_facts" \
    | LC_ALL=C sort | tr '\n' ' ')"
[[ "$cetus_public" == 'buyback_and_burn collect_fees migrate prepare settle_and_apply_fee_split ' ]] || \
    fail "Cetus must expose exactly prepare and one migrate, collect, settled-update, and buyback route for both coin orders"
cetus_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' <<<"$cetus_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
[[ "$(cetus_body prepare)" == 'migrators_version.assert_current();let_=config::get_fee_rate(tick_spacing,cetus_config);letpool_creation_cap=factory::mint_pool_creation_cap(cetus_config,pools,treasury_cap,ctx);factory::register_permission_pair<Meme,Quote>(cetus_config,pools,tick_spacing,&pool_creation_cap,ctx);letpool_creation_cap_id=object::id(&pool_creation_cap);venue_config.add_object(CreationCapKey<Meme>(),pool_creation_cap);venue_config.add_value(PoolTierKey<Meme>(),tick_spacing);blast_events::cetus_pool_reserved<Meme,Quote>(pool_creation_cap_id,tick_spacing);migration::issue_ticket(Venue())' ]] \
    && [[ "$(cetus_body pool_creation_cap)" == 'venue_config.object(CreationCapKey<Meme>())' ]] || \
    fail "cetus::prepare must check Cetus registers the tick spacing, then mint the cap once, register the pair with it, store the cap and the tick spacing, record the reservation, and issue the ticket"
pair_proof='letmeme_is_a=is_meme_coin_a<Meme,Quote,CoinA,CoinB>();'
[[ "$(cetus_body migrate)" == "migrators_version.assert_current();assert!(factory::is_right_order<CoinA,CoinB>(),EInvalidCoinOrder);${pair_proof}"* ]] \
    && in_order \
        'lettick_spacing=*venue_config.value(PoolTierKey<Meme>());' \
        'let(tick_lower,tick_upper)=pool_creator::full_range_tick_range(tick_spacing);' \
        'let(meme,quote,terms)=launch.migrate(package_version,config,currency,ctx).redeem(Venue());' \
        'letmeme_amount=meme.value();letquote_amount=quote.value();' \
        'letsqrt_price=migration_math::sqrt_price_x64(meme_amount,quote_amount,meme_is_a);' \
        'letfix_a=is_coin_a_seed_side(tick_lower,tick_upper,sqrt_price,meme_amount,quote_amount,meme_is_a);' \
        'let(coin_a,coin_b)=reorder(meme.into_coin(ctx),quote.into_coin(ctx),meme_is_a,ctx);' \
        'let(position,residual_a,residual_b)=pool_creator::create_pool_v3_with_creation_cap<CoinA,CoinB>(cetus_config,pools,venue_config.pool_creation_cap<Meme>(),tick_spacing,sqrt_price,b"".to_string(),tick_lower,tick_upper,coin_a,coin_b,fix_a,clock,ctx);' \
        'let(residual_meme,residual_quote):(Coin<Meme>,Coin<Quote>)=reorder(residual_a,residual_b,meme_is_a,ctx);' \
        'letpool_id=position.pool_id();' \
        'letliquidity=position.liquidity();' \
        'letburn_proof=lp_burn::burn_lp_v2(burn_manager,position,ctx);' \
        'vault::new<Meme,Quote,_>(registry,&Venue(),vault_version,terms,pool_id).share_with_position(&Venue(),treasury,burn_proof,liquidity,residual_meme.into_balance(),residual_quote.into_balance(),ctx);' \
        <<<"$(cetus_body migrate)" \
    && [[ "$(cetus_body migrate)" == *'ctx);' ]] \
    && [[ "$(cetus_body is_coin_a_seed_side)" == 'let(amount_a,amount_b)=if(meme_is_a)(meme_amount,quote_amount)else(quote_amount,meme_amount);letprefer_a=(meme_amount>=quote_amount)==meme_is_a;let(_,needed_a,needed_b)=clmm_math::get_liquidity_by_amount(i32::from_u32(tick_lower),i32::from_u32(tick_upper),i32::zero(),sqrt_price,if(prefer_a)amount_aelseamount_b,prefer_a);migration_math::seed_fixed_side(prefer_a,amount_a,amount_b,needed_a,needed_b)' ]] || \
    fail "cetus::migrate must check the generation, Cetus's coin order, and the pair first, then create the pool in that order with the reserved cap at the recorded tick spacing, fix the larger side (Meme on a tie) unless Cetus's own math says it overdraws the other, burn the position, and create the vault holding the burn proof"
[[ "$(cetus_body settle_fees)" == 'let(meme_fee,quote_fee)=self.collect_position_fees(vault_version,cetus_config,burn_manager,pool,meme_is_a,ctx);self.split_fees(&Venue(),vault_version,treasury,currency,meme_fee,quote_fee,ctx);self.compound(vault_version,cetus_config,pool,meme_is_a,clock,ctx);' ]] \
    && [[ "$(cetus_body collect_fees)" == "migrators_version.assert_current();${pair_proof}self.settle_fees(vault_version,treasury,currency,cetus_config,burn_manager,pool,meme_is_a,clock,ctx);" ]] || \
    fail "cetus::collect_fees must check the generation and the pair, split the collected fees through the vault, then add the auto-LP share back"
[[ "$(cetus_body settle_and_apply_fee_split)" == "migrators_version.assert_current();${pair_proof}self.assert_fee_split_ready(clock);self.settle_fees(vault_version,treasury,currency,cetus_config,burn_manager,pool,meme_is_a,clock,ctx);self.apply_fee_split(&Venue(),vault_version,clock);" ]] || \
    fail "cetus::settle_and_apply_fee_split must check the pair and stored proposal readiness before collecting, then split the accrued fees under the current split before committing a new one"
[[ "$(cetus_body buyback_and_burn)" == "migrators_version.assert_current();${pair_proof}assert!(self.pool_id()==object::id(pool),EPositionPoolMismatch);let(quote,receipt)=self.take_buyback_quote(&Venue(),admin_witness,vault_version,quote_in);let(meme,quote)=pool.swap_quote_for_meme(cetus_config,quote,meme_is_a,clock,ctx);self.burn_buyback(&Venue(),vault_version,receipt,currency,meme,quote,min_meme_out,ctx);" ]] \
    && [[ "$(cetus_body swap_quote_for_meme)" == 'let(a,b)=reorder(balance::zero<Meme>(),quote,meme_is_a,ctx);let(a,b)=pool.swap(cetus_config,a,b,!meme_is_a,clock);reorder(a,b,meme_is_a,ctx)' ]] || \
    fail "cetus::buyback_and_burn must check the pair and the vault's pool, take the admin's quote_in of the burn Quote under the buyback admin, swap all of it Quote-to-Meme, and let the vault check and burn"
[[ "$(cetus_body compound)" == 'let(meme,quote,receipt)=self.take_auto_lp(&Venue(),vault_version);let(a,b)=reorder(meme,quote,meme_is_a,ctx);let(a,b)=self.add_liquidity(vault_version,cetus_config,pool,a,b,clock,ctx);let(meme,quote)=reorder(a,b,meme_is_a,ctx);self.keep_auto_lp(&Venue(),vault_version,receipt,meme,quote);' ]] || \
    fail "Cetus auto-LP must take the waiting balances in its pool's coin order and keep what the pool did not take"
# The pair proof is pure and total: `(CoinA, CoinB)` must be exactly `{Meme, Quote}` by original
# type name, in either order, and Meme's side is the answer. Every retype goes through one
# dynamic-field round trip on a fresh transient UID that is deleted afterwards, so the framework's
# `dynamic_field::remove` aborts unless the value keeps its exact type; nothing else in Cetus
# touches a dynamic field or names `CastKey`.
[[ "$(cetus_body is_meme_coin_a)" == 'let(meme,quote)=(type_name::with_original_ids<Meme>(),type_name::with_original_ids<Quote>());let(a,b)=(type_name::with_original_ids<CoinA>(),type_name::with_original_ids<CoinB>());assert!((meme==a&&quote==b)||(meme==b&&quote==a),EWrongCoinPair);meme==a' ]] \
    && [[ "$(cetus_body reorder)" == 'letmutscratch=object::new(ctx);let(first,second)=if(meme_is_a){(scratch.cast(x),scratch.cast(y))}else{(scratch.cast(y),scratch.cast(x))};scratch.delete();(first,second)' ]] \
    && [[ "$(cetus_body cast)" == 'dynamic_field::add(scratch,CastKey(),value);dynamic_field::remove(scratch,CastKey())' ]] \
    && [[ "$(move_production_type CastKey <<<"$cetus_facts")" == 'struct CastKey() has copy, drop, store;' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "dynamic_field::") > 0 { print $2 }' <<<"$cetus_facts")" == 'cast' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && $10 ~ /(^|[^A-Za-z0-9_])cast\(/ { print $2 }' <<<"$cetus_facts")" == 'reorder' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "CastKey") > 0 { print $2 }' <<<"$cetus_facts")" == 'cast' ]] || \
    fail "Cetus must prove the coin pair by type name and retype only through one checked dynamic-field round trip on a transient UID"
# Migration burns the full-range position through Cetus LP Burn exactly once (pinned in order
# above), before the vault takes custody of the burn proof and the residuals.
[[ "$(move_norm "$CETUS_SOURCE" | grep -o 'burn_lp_v2' | wc -l)" -eq 1 ]] || \
    fail "Cetus migration must burn the position through LP Burn exactly once"
# Collection checks the vault's own pool first, collects the burn proof only through LP Burn, and
# collects the auto-LP position only once it exists.
[[ "$(cetus_body collect_position_fees)" == 'assert!(self.pool_id()==object::id(pool),EPositionPoolMismatch);let(fee_a,fee_b)=lp_burn::collect_fee(burn_manager,cetus_config,pool,self.position_mut<_,_,_,CetusLPBurnProof>(&Venue(),vault_version),ctx);letmutfee_a=fee_a.into_balance();letmutfee_b=fee_b.into_balance();if(self.has_auto_lp_position(&Venue())){letposition=self.auto_lp_position<_,_,_,Position>(&Venue());let(auto_lp_a,auto_lp_b)=pool::collect_fee(cetus_config,pool,position,true);fee_a.join(auto_lp_a);fee_b.join(auto_lp_b);};reorder(fee_a,fee_b,meme_is_a,ctx)' ]] || \
    fail "Cetus collection must check the vault's pool first, collect the burn proof through LP Burn, and the auto-LP position only once it exists"
# The burn proof leaves LP Burn only for the vault, and is borrowed only to collect its fees: the
# vault's main slot is never read under another type or for any other call.
[[ "$(move_norm "$CETUS_SOURCE" | grep -o 'CetusLPBurnProof' | wc -l)" -eq 2 ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 { print $10 }' <<<"$cetus_facts" | tr -d '[:space:]' \
        | grep -o '\.position\(_mut\)\?<[^>]*>' | tr '\n' ' ')" == '.position_mut<_,_,_,CetusLPBurnProof> ' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 { print $10 }' <<<"$cetus_facts" | tr -d '[:space:]' \
        | grep -o 'burn_proof[^A-Za-z_]' | tr '\n' ' ')" == 'burn_proof= burn_proof, ' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'lp_burn::collect_fee' | wc -l)" -eq 1 ]] || \
    fail "the burn proof must be borrowed only to collect its fees through LP Burn"
# Auto-LP opens at most one full-range position in the vault's pool, on first use, then adds with
# Cetus's own fixed-coin math, fixing coin A first when coin B covers it, and repays exactly what
# the receipt asks.
[[ "$(cetus_body add_liquidity)" == 'if(a.value()==0||b.value()==0)return(a,b);if(!self.has_auto_lp_position(&Venue())){let(tick_lower,tick_upper)=pool_creator::full_range_tick_range(pool.tick_spacing());letposition=pool::open_position(cetus_config,pool,tick_lower,tick_upper,ctx);self.attach_auto_lp_position(&Venue(),vault_version,position);};letposition=self.auto_lp_position_mut<_,_,_,Position>(&Venue(),vault_version);let(fix_a,fixed_amount)=pool.fixed_side(position,a.value(),b.value());if(fixed_amount==0)return(a,b);letreceipt=pool::add_liquidity_fix_coin(cetus_config,pool,position,fixed_amount,fix_a,clock);let(paid_a,paid_b)=receipt.add_liquidity_pay_amount();pool::repay_add_liquidity(cetus_config,pool,a.split(paid_a),b.split(paid_b),receipt);(a,b)' ]] \
    && [[ "$(cetus_body fixed_side)" == 'let(lower,upper)=position.tick_range();lettick=pool.current_tick_index();letprice=pool.current_sqrt_price();let(liquidity_a,_,needed_b)=clmm_math::get_liquidity_by_amount(lower,upper,tick,price,amount_a,true);let(liquidity_b,needed_a,_)=clmm_math::get_liquidity_by_amount(lower,upper,tick,price,amount_b,false);if(liquidity_a>0&&needed_b<=amount_b)return(true,amount_a);if(liquidity_b>0&&needed_a<=amount_a)return(false,amount_b);(true,0)' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'open_position' | wc -l)" -eq 1 ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'add_liquidity_fix_coin' | wc -l)" -eq 1 ]] || \
    fail "Cetus auto-LP must open at most one full-range auto-LP position, then add with the fixed-coin receipt and repay it exactly"
# A swap runs all of its input to the widest price limit, since the admin's minimum is the
# protection, and repays exactly what the receipt asks.
in_order \
    'let(amount_in,sqrt_price_limit)=if(a2b)(a.value(),constants::min_swap_sqrt_price!())else(b.value(),constants::max_swap_sqrt_price!());' \
    'let(out_a,out_b,receipt)=pool::flash_swap(cetus_config,pool,a2b,true,amount_in,sqrt_price_limit,clock);' \
    'letpaid=receipt.swap_pay_amount();' \
    'let(pay_a,pay_b)=if(a2b)(a.split(paid),balance::zero())else(balance::zero(),b.split(paid));' \
    'pool::repay_flash_swap(cetus_config,pool,pay_a,pay_b,receipt);' \
    'a.join(out_a);b.join(out_b);(a,b)' \
    <<<"$(cetus_body swap)" \
    && [[ "$(constant_body min_swap_sqrt_price)" == '4_295_048_017' ]] \
    && [[ "$(constant_body max_swap_sqrt_price)" == '79_226_673_515_401_279_992_447_579_054' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'flash_swap' | wc -l)" -eq 2 ]] || \
    fail "Cetus buybacks must swap through one flash swap at the widest limit and repay exactly the receipt"
require_errors "$CETUS_SOURCE" "Cetus must use sequential codes 0-2 for coin order, vault-pool, and coin-pair checks" <<'EOF'
0 EInvalidCoinOrder CoinA and CoinB must follow the Cetus coin order.
1 EPositionPoolMismatch Pool must be the vault's own pool.
2 EWrongCoinPair CoinA and CoinB must be exactly the launch's Meme and Quote.
EOF
# Cetus's public routes share Bluefin's parameter order, with the LP Burn manager among the venue
# inputs.
for entry in prepare migrate collect_fees settle_and_apply_fee_split buyback_and_burn; do
    case "$entry" in
        prepare) expected="( migrators_version: &MigratorsVersion, venue_config: &mut VenueConfig," ;;
        migrate) expected="( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig, currency: &mut Currency<Meme>," ;;
        collect_fees|settle_and_apply_fee_split) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>," ;;
        buyback_and_burn) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &MigratorsVersion, vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>," ;;
        *) fail "unhandled venue entry ${entry}" ;;
    esac
    [[ "$(awk -F'\t' -v name="$entry" '$1 == "FN" && $2 == name && $6 == 0 { print $9 }' \
        <<<"$cetus_facts")" == *"$expected"* ]] || \
        fail "cetus::${entry} must take the shared venue parameter order"
done
CETUS_COMPACT_SOURCE="$(tr -d '[:space:]' < "$CETUS_SOURCE")"
if [[ "$CETUS_COMPACT_SOURCE" =~ abort0 ]]; then
    fail "production Cetus abort stubs are forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*[^A-Za-z0-9_]Venue([^A-Za-z0-9_]|$) ]]; then
    fail "public or package Cetus venue exposure is forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ publicfun[^\{]*(Position|CetusLPBurnProof) ]]; then
    fail "public Cetus position or burn-proof exposure is forbidden"
fi
# The creator chooses only the tick spacing when preparing a coin; Cetus fixes its fee rate, and
# no later route takes a tier, price, or orientation from the caller.
CETUS_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect|settle)[^{]+\{' "$CETUS_SOURCE" || true)"
CETUS_PREPARE_SIGNATURE="$(rg -U 'public fun prepare[^{]+\{' "$CETUS_SOURCE" || true)"
if [[ "$CETUS_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]] \
    || [[ "$CETUS_PREPARE_SIGNATURE" =~ (sqrt_price|orientation|meme_is|fee_rate:) ]]; then
    fail "caller-supplied Cetus price, orientation, fee rate, or post-preparation tier is forbidden"
fi
# Only the reserved capability creates the pool: never an unreserved creation or a released
# reservation.
[[ "$(rg -c 'pool_creator::create_pool_v3_with_creation_cap<' "$CETUS_SOURCE" || true)" -eq 1 ]] || \
    fail "the Cetus migration route must create its pool with the reserved capability"
if rg -q 'create_pool_v3[[:space:]]*[<(]|unregister_permission_pair|policy_mut' "$CETUS_SOURCE"; then
    fail "Cetus must neither create an unreserved pool nor release a reservation"
fi
# The capability is minted once, from the treasury capability `cetus::prepare` borrows mutably;
# Bluefin only reads its caller's capability, and no other module names one.
[[ "$(rg -c 'factory::mint_pool_creation_cap\(' "$CETUS_SOURCE" || true)" -eq 1 ]] \
    && [[ "$(for source in "$SOURCE_DIR"/*.move; do
        move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
            '$1 == "FN" && $6 == 0 && index($9, "TreasuryCap<") > 0 { print module ":" $2 ":" ($9 ~ /&mut TreasuryCap</ ? "mut" : "ref") }'
    done | LC_ALL=C sort | tr '\n' ' ')" == 'bluefin:prepare:ref cetus:prepare:mut ' ]] || \
    fail "the Cetus capability must be minted once from the treasury capability cetus::prepare borrows, and only the two preparations may take one"

# === Delayed operations ===
#
# Upgrade custody stores one of `blast_admin`'s keyed delayed primitives, owned by the object that
# holds it and keyed by a sealed type of its own module, so the primitive alone validates, waits,
# and records the lifecycle. Its one action slot holds only an exact digest or immutability, and it
# authorizes only the action it asked for. The retired raw proposal API may not return.
PACKAGE_ADMIN_FACTS="$(move_facts "$SOURCE_DIR/package_admin.move")"
[[ "$PACKAGE_ADMIN_FACTS" != *MALFORMED* ]] || fail "the Move reader rejected package_admin.move"
package_admin_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' <<<"$PACKAGE_ADMIN_FACTS" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
[[ "$(move_production_type PackageAdmin <<<"$PACKAGE_ADMIN_FACTS")" \
    == 'struct PackageAdmin has key { id: UID, custody: UpgradeCustody<BLAST_FUN_MIGRATORS>, upgrade: DelayedAction<UpgradeKey, UpgradeAction>, }' ]] \
    && [[ "$(move_production_type UpgradeKey <<<"$PACKAGE_ADMIN_FACTS")" == 'struct UpgradeKey() has copy, drop, store;' ]] \
    && [[ "$(move_production_type UpgradeAction <<<"$PACKAGE_ADMIN_FACTS")" == 'enum UpgradeAction has copy, drop, store { Upgrade(vector<u8>), MakeImmutable, }' ]] || \
    fail "PackageAdmin must store upgrade custody's notice and proposal as one keyed DelayedAction of digest or immutability"
[[ "$(package_admin_body authorize_upgrade)" == 'package_version.assert_current();letcustodian_id=self.id.to_inner();letaction=self.upgrade.take_action(clock);assert!(action==UpgradeAction::Upgrade(digest),EWrongUpgradeAction);self.custody.authorize_upgrade(custodian_id,digest)' ]] \
    && [[ "$(package_admin_body make_immutable)" == 'package_version.assert_current();letaction=self.upgrade.take_action(clock);assert!(action==UpgradeAction::MakeImmutable,EWrongUpgradeAction);self.custody.make_immutable(self.id.to_inner());' ]] \
    && [[ "$(package_admin_body wrap)" == *'letupgrade=delayed_action::new(UpgradeKey(),&id,INITIAL_UPGRADE_DELAY_MS);transfer::share_object(PackageAdmin{id,custody,upgrade});'* ]] || \
    fail "upgrade custody must start at its 48-hour notice and act only on the exact ready action it asked for"
require_errors "$SOURCE_DIR/package_admin.move" "package_admin must use sequential codes 0-1 for its action and digest checks" <<'EOF'
0 EWrongUpgradeAction The ready action must match the requested upgrade digest or immutability.
1 EInvalidDigest A package digest must contain 32 bytes.
EOF
reject_pattern '\b(new_pending|take_ready|Pending)\b' \
    'the retired raw delayed proposal API is forbidden; store a keyed Delayed, DelayedAction, DelayedSet, or DelayedMap'

# === Package-wide custody rules ===

# The one removal is Cetus's checked retype, pinned above, which removes only the value it added
# to its own transient UID in the same call.
[[ "$(rg -o 'dynamic(_object)?_field::(remove(_opt)?|replace)' "$SOURCE_DIR" | LC_ALL=C sort | tr '\n' ' ')" \
    == "${CETUS_SOURCE}:dynamic_field::remove " ]] || \
    fail "dynamic-field removal or replacement is forbidden outside Cetus's transient checked retype"
reject_pattern 'events_wrapper|public struct Event<' \
    'generic venue event envelopes are forbidden'
reject_pattern 'protocol_treasury|residual_treasury' \
    'address-based residual treasury routing is forbidden'
reject_pattern 'remove_liquidity' 'principal removal is forbidden'
reject_pattern 'decrease_liquidity|withdraw_liquidity' 'principal withdrawal is forbidden'
reject_pattern 'close_position' 'position closure is forbidden'
# Cetus's LP Burn call is pinned above as the one sanctioned burn; nothing else may burn or
# destroy a position.
reject_pattern 'burn_position|destroy_position' 'position destruction is forbidden'
reject_pattern 'gauge|stake_position|staking' 'position gauge staking is forbidden'
reject_pattern '(position\.(burn|delete|destroy)|((burn|delete|destroy)[[:space:]]*\([^)]*position))' \
    'position burn or destruction is forbidden'
reject_pattern '(sequence|revision|nonce|schema_version|action_tag):' \
    'application-level event ordering fields are forbidden'
COMPACT_SOURCE="$(sed -n 'p' "$SOURCE_DIR"/*.move | tr -d '[:space:]')"
if [[ "$COMPACT_SOURCE" =~ transfer::(public_)?transfer\([^\)]*position ]]; then
    fail "position transfer is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*(cetus|bluefin)::Venue ]]; then
    fail "cross-module venue exposure is forbidden"
fi
# Object custody paths: `VenueConfig`'s object API, whose only caller stores the Meme type's Cetus
# pool-creation capability while preparing a coin; positions live in `blast_vault`. Call sites are
# counted, not imports: `venue_config` names `dynamic_object_field::add` only in its one alias,
# and `add_object` is named only by its declaration and the Cetus preparation. No module renames a
# dynamic field module or imports its members, so none reaches a field function under another
# name.
for source in "$SOURCE_DIR"/*.move; do
    if move_norm "$source" | rg -q '\bdynamic_(object_)?field( as |::\{)'; then
        fail "$(basename "$source") must import dynamic field modules by name only"
    fi
done
object_custody_sites="$(for source in "$SOURCE_DIR"/*.move; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    awk -F'\t' -v module="$module" '$1 == "FN" {
        for (calls = gsub(/add_dynamic_object_field/, "", $10); calls > 0; calls--) print module "::" $2 " adds"
    }' <<<"$facts"
    awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" \
        | rg -o '\bdynamic_object_field::add\b[^;]*|[.:]?\badd_object\b.' | sed "s/^/${module} names /" || true
done | LC_ALL=C sort)"
require_text "$object_custody_sites" \
    "only venue_config::add_object adds object fields; only Cetus calls add_object" <<'EOF'
cetus names .add_object(
venue_config names add_object<
venue_config names dynamic_object_field::add as UID.add_dynamic_object_field
venue_config::add_object adds
EOF
# Functions with a natural first receiver are called with Move 2024 dot syntax, in sources and
# tests alike.
if rg -n \
    'vault::(split_fees|take_auto_lp|keep_auto_lp|take_buyback_quote|burn_buyback|assert_fee_split_ready|apply_fee_split|schedule_fee_split|cancel_fee_split|claim_owner_balances|pay_protocol_fees_with_partner|share_with_position|attach_auto_lp_position|position_mut|auto_lp_position|auto_lp_position_mut|has_auto_lp_position|pool_id)[[:space:]]*(<[^>]*>)?\(|pool::add_liquidity_pay_amount[[:space:]]*\(|coin::from_balance[[:space:]]*\(|(^|[^.[:alnum:]_])collect_position_fees[[:space:]]*\(' \
    "$SOURCE_DIR" "$PACKAGE_DIR/tests"; then
    fail "functions with a natural first receiver must use Move 2024 dot syntax"
fi


# === Shared administration boundary ===
#
# Migrators takes the Launchpad's roles in the shared blast_admin ACL for its own custody, and the
# core domain's buyback role that `blast_vault` checks. It must never reimplement the reusable ACL,
# declare a role of its own, reimplement generation arithmetic or native custody, or treat the
# Launchpad generation as its own.

for forbidden in acl.move blast_acl.move; do
    [[ -e "$SOURCE_DIR/$forbidden" ]] && \
        fail "Migrators must not define a local $forbidden"
done

if rg -n '^public struct (ACL|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)\b' \
    "$SOURCE_DIR"; then
    fail "administration types must come from blast_admin, never from a local copy"
fi

if rg -n 'fun (grant_admin|revoke_admin|sign_in)\(' "$SOURCE_DIR"; then
    fail "Migrators must not manage administrators"
fi

# The roles are the Launchpad and core domains' ability-free role types, which their gates pin.
LAUNCHPAD_ROLES="$(move_facts "$PACKAGE_DIR/../launchpad/sources/blast_fun_domain.move" \
    | awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' | paste -sd '|')"
CORE_ROLES="$(move_facts "$PACKAGE_DIR/../core/sources/blast_domain.move" \
    | awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' | paste -sd '|')"
[[ -n "$LAUNCHPAD_ROLES" && -n "$CORE_ROLES" ]] || fail "the Launchpad and core role types must be readable"
if rg -n "^public struct (${LAUNCHPAD_ROLES}|${CORE_ROLES})\\b" "$SOURCE_DIR"; then
    fail "Migrators must take the Launchpad's and core's roles, never declare a same-named copy"
fi
# The witness type is each administrator action's role check, so every witness a source names is
# borrowed and names one concrete role; a generic or foreign role fails here.
admin_witness_violations="$(for source in "$SOURCE_DIR"/*.move; do
    move_norm "$source" | { rg -o '&?AdminWitness<[^>]*>' || true; } \
        | { rg -v -x "&AdminWitness<(${LAUNCHPAD_ROLES}|${CORE_ROLES})>" || true; } \
        | sed "s|^|$(basename "$source"): |"
done)"
[[ -z "$admin_witness_violations" ]] || \
    fail "every administrator witness must be a borrowed AdminWitness of one concrete role: ${admin_witness_violations}"
# Upgrade custody takes the Launchpad's roles; the buybacks take the core buyback role, the one
# `blast_vault::vault::take_buyback_quote` requires.
[[ "$(move_norm "$SOURCE_DIR/package_admin.move" | rg -o 'use blast_fun::blast_fun_domain::\{[^}]*\};')" \
    == 'use blast_fun::blast_fun_domain::{CancelAdmin, UpgradeAdmin};' ]] || \
    fail "package_admin must take its roles from the Launchpad domain"
for module in bluefin cetus; do
    move_norm "$SOURCE_DIR/${module}.move" | rg -q 'use blast_core::\{ blast_domain::BuybackAdmin,' \
        && ! move_norm "$SOURCE_DIR/${module}.move" | rg -q 'blast_fun_domain' || \
        fail "${module} buybacks must take the core domain's BuybackAdmin, the role blast_vault checks"
done

for required in blast_fun_migrators.move package_admin.move; do
    [[ -f "$SOURCE_DIR/$required" ]] || \
        fail "Migrators must own $required"
done

rg -q '^public struct PackageVersion has key \{$' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "Migrators must own one canonical generation container"
rg -q 'generation: OperationalVersion<BLAST_FUN_MIGRATORS>,' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "the generation value must be the shared typed value"
rg -q '^const PACKAGE_VERSION: u64 = 1;$' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "Migrators must compile its current generation constant"
rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "Migrators must compile its cutover target constant"
if rg -n '\.checked_add\(|fun activate\(' "$SOURCE_DIR/blast_fun_migrators.move"; then
    fail "generation arithmetic and separate activation belong to blast_admin"
fi

rg -q 'custody: UpgradeCustody<BLAST_FUN_MIGRATORS>,' "$SOURCE_DIR/package_admin.move" || \
    fail "Migrators custody must hold the shared typed value"
rg -q 'public fun commit_upgrade_and_advance\(' "$SOURCE_DIR/package_admin.move" || \
    fail "Migrators must expose one atomic commit-and-advance finalizer"
if rg -n '^public fun commit_upgrade\(|^public fun activate' "$SOURCE_DIR/package_admin.move"; then
    fail "a separate receipt commit or activation entry point is forbidden"
fi
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
    "$SOURCE_DIR/package_admin.move"; then
    fail "no custody path may release the sealed Publisher or UpgradeCap"
fi
CUSTODY_ROLE_GATES="$(move_facts "$SOURCE_DIR/package_admin.move" | awk -F'\t' '
    $1 == "FN" && ($2 == "authorize_upgrade" || $2 == "commit_upgrade_and_advance") \
        && index($9, "_: &AdminWitness<UpgradeAdmin>,") > 0 { count++ }
    END { print count + 0 }
')"
[[ "${CUSTODY_ROLE_GATES:-0}" -eq 2 ]] || \
    fail "every governed custody transition must require Launchpad's upgrade-admin role"
# Upgrade authorization checks the current generation first, so a retired generation cannot
# authorize, and the finalizer proves the exact next generation first.
[[ "$(move_facts "$SOURCE_DIR/package_admin.move" \
    | awk -F'\t' '$1 == "FN" && $2 == "authorize_upgrade" { print $10 }')" \
    == 'package_version.assert_current();'* ]] || \
    fail "authorize_upgrade must check the current generation first"
[[ "$(move_facts "$SOURCE_DIR/package_admin.move" \
    | awk -F'\t' '$1 == "FN" && $2 == "commit_upgrade_and_advance" { print $10 }')" \
    == 'package_version.assert_next();'* ]] || \
    fail "commit_upgrade_and_advance must check the next generation first"
# Every administrator action takes exactly one role, the one pinned here, so no role reaches
# another role's action. A new function that takes a witness fails until it is mapped
# deliberately. The buybacks hand their witness to `blast_vault`'s `take_buyback_quote`, whose
# calls are pinned above.
admin_roles="$(for source in "$SOURCE_DIR"/*.move; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" '
        $1 == "FN" && $6 == 0 && index($9, "AdminWitness<") > 0 {
            rest = $9
            roles = ""
            while (match(rest, /AdminWitness<[^>]*>/)) {
                roles = roles (roles == "" ? "" : ",") substr(rest, RSTART + 13, RLENGTH - 14)
                rest = substr(rest, RSTART + RLENGTH)
            }
            print module ":" $2 ":" roles
        }
    '
done | LC_ALL=C sort)"
require_text "$admin_roles" \
    "every administrator action must take exactly its pinned role witness" <<'ROLES'
bluefin:buyback_and_burn:BuybackAdmin
cetus:buyback_and_burn:BuybackAdmin
package_admin:authorize_upgrade:UpgradeAdmin
package_admin:cancel_upgrade_action:CancelAdmin
package_admin:commit_upgrade_and_advance:UpgradeAdmin
package_admin:make_immutable:UpgradeAdmin
package_admin:schedule_make_immutable:UpgradeAdmin
package_admin:schedule_upgrade:UpgradeAdmin
package_admin:schedule_upgrade_delay:UpgradeAdmin
ROLES
# ADR 0134 permits delayed immutability. While upgradeable, every commit advances the
# generation, so the policy must remain compatible: narrower policies cannot change
# generation constants and would freeze the package at its next upgrade.
if rg -n '\brestrict_to_' "$SOURCE_DIR"; then
    fail "the migrators package must retain the compatible policy until delayed immutability"
fi

# Every production public function in the venue modules is a protected mutation. The set comes
# from the Move reader, so spacing or line breaks cannot hide a function, and each one must take
# this package's generation and check it before doing anything else.
for guard_module in bluefin cetus; do
    guard_facts="$(move_facts "$SOURCE_DIR/${guard_module}.move")"
    [[ "$guard_facts" != *MALFORMED* ]] || fail "the Move reader rejected ${guard_module}.move"
    unguarded="$(awk -F'\t' '
        $1 != "FN" || $3 != "public" || $6 != 0 { next }
        index($9, " migrators_version: &MigratorsVersion,") == 0 \
            || index($10, "migrators_version.assert_current();") != 1 { print $2 }
    ' <<<"$guard_facts")"
    [[ -z "$unguarded" ]] || \
        fail "${guard_module} must take this package's generation and assert it first in every protected mutation (unguarded: ${unguarded//$'\n'/ })"
done

# In the venue modules `package_version` names the Launchpad object. It may be passed through to
# a composed Launchpad call, but it may never stand in for this package's own guard.
# (`package_admin.move` owns no Launchpad input: its `package_version` parameter is this package's
# own container.) `vault_version` is `blast_vault`'s generation, which the vault checks itself.
for guard_module in bluefin cetus; do
    if rg -n '^[[:space:]]+(package_version|vault_version)\.assert_current\(' \
        "$SOURCE_DIR/${guard_module}.move"; then
        fail "${guard_module}.move must not assert the Launchpad or vault generation as if it were its own"
    fi
done

# T-010's cross-package conformance venue redeems the hand-off, then builds and shares a
# `blast_vault` vault holding the child position, and exposes no protected return. Only order
# anchors are pinned, on whitespace-free text so formatting cannot change the verdict.
ATOMIC_MIGRATION_TEST="$PACKAGE_DIR/tests/atomic_migration_tests.move"
[[ -f "$ATOMIC_MIGRATION_TEST" ]] || fail "missing T-010 atomic migration venue fixture"
atomic_facts="$(move_facts "$ATOMIC_MIGRATION_TEST")"
[[ "$atomic_facts" != *MALFORMED* ]] || fail "the Move reader rejected the atomic migration fixture"
atomic_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" { print $2 ":" $9 }' <<<"$atomic_facts")"
atomic_body="$(awk -F'\t' '$1 == "FN" && $2 == "mock_adapter_with" { print $10 }' <<<"$atomic_facts" \
    | tr -d '[:space:]' | sed 's/,)/)/g')"

[[ "$atomic_public" == mock_adapter:* && "$atomic_public" != *$'\n'* && "$atomic_public" != *'):'* ]] || \
    fail "the atomic fixture's only public function must be the unit-returning mock_adapter"
in_order \
    'launch.migrate(version,config,currency,ctx).redeem(Venue());' \
    'vault::new<_,_,_>(registry,&Venue(),vault_version,terms,pool_id).share_with_position(&Venue(),treasury,position,liquidity,' \
    'transfer::share_object(pool)' \
    <<<"$atomic_body" || \
    fail "atomic venue must redeem the hand-off, then create and share the vault holding the position"

# No public migrator function, in any source or the atomic fixture, may hand out a raw balance, a
# position, a vault, the hand-off, a pool, or the reserved pool creation capability.
protected_returners="$(for file in "$SOURCE_DIR"/*.move "$ATOMIC_MIGRATION_TEST"; do move_facts "$file"; done \
    | awk -F'\t' '
        $1 == "MALFORMED" { print "MALFORMED" }
        $1 == "FN" && $3 == "public" && $6 == 0 && index($9, "):") > 0 {
            if (substr($9, index($9, "):") + 2) ~ /(^|[^A-Za-z0-9_])(Balance|Vault|Migration|Position|Pool|PoolCreationCap)([^A-Za-z0-9_]|$)/) print $2
        }')"
[[ -z "$protected_returners" ]] || \
    fail "public functions must not return balances or custody objects: $protected_returners"

echo "Migrator source boundaries passed"
