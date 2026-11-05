# Parked Sui packages

Packages here are on hold. They are not part of `sui/`, have no build, test,
lint, or boundary gate (the repository style gate still reads them), and must
not be published.

- `dex` (`blast_fun_dex`): the native V2 DEX and its locked-LP migration.

Auto-LP now lives in `blast_vault` and the `blast_migrators` venues (ADR 0137);
its native-DEX predecessor was deleted. The DEX still targets the ADR 0082
launchpad LP-fee ABI and does not compile against the current launchpad, whose
post-migration fees belong to `blast_vault`. It will be redesigned before
returning to `sui/`. Its manifest resolves `blast_fun` and `blast_admin` from
`../../sui/`.
