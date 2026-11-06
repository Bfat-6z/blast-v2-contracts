# blast_core

Blast's shared money vocabulary, below every launch product, vault, and venue (ADR 0137). It
depends only on `blast_admin`, `blast_partners`, and `blast_fun_vesting`, imports no product,
vault, or venue. Its canonical publication retains a native compatible
UpgradeCap at the multisig until final audit; immutability is deferred. The only state it
creates is the shared `blast_treasury::Treasury`, whose genesis address is the `blast_treasury`
named address in `Move.toml` and must be set before publication.

Integrator reference: `docs/llms/core.md` and the generated `llms/core.txt`.
Gates: `bash scripts/test_admin_delay.sh core` and `bash sui/core/scripts/check_source_boundaries.sh`.
