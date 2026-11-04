# Upgrading Blast SUI

Use this runbook only for an existing Blast SUI deployment. Record the result
as required by [`deployments/README.md`](../../deployments/README.md).

1. Build, verify and audit the candidate bytecode against the published ABI and
   stored layouts. Its `PACKAGE_VERSION` must be exactly the deployed generation
   plus one. The finalizer runs the outgoing bytecode, which advances the shared
   generation to its own compiled next value; candidate bytecode that keeps the
   old `PACKAGE_VERSION` would reject every gated call, both redemptions included,
   and could never be upgraded again. `NEXT_PACKAGE_VERSION` is derived from it.
2. Sign in as `blast_sui_domain::UpgradeAdmin` and call
   `package_admin::schedule_upgrade` with the exact 32-byte digest and `Clock`.
   Publish the digest and the action's `ready_at_ms`; holders may exit during the
   notice. `CancelAdmin` can cancel until execution.
3. After `ready_at_ms`, in one PTB, sign in as `UpgradeAdmin`, call
   `package_admin::authorize_upgrade` with the scheduled digest and `Clock`,
   execute the native upgrade, and pass the matching receipt to
   `package_admin::commit_upgrade_and_advance`. It commits the receipt into the
   sealed cap **and** advances the operational generation in the same
   transaction. A failure at any step rolls back authorization, the native
   upgrade, cap state and generation state together.
4. Verify old-generation mutations fail, new-generation mutations succeed, both
   coin redemptions remain usable, and deposit receipts still cancel without the
   shared vault.
5. Run the complete `scripts/verify.sh` gate and record the digest, policy,
   transaction, source verification, generation and smoke-test evidence.

Administration comes from the singleton Blast ACL in the immutable `blast_admin`
package through this package's own roles. No other package's role can authorize
any step above.

No call narrows the upgrade policy: under a narrowed policy the generation could
never advance again. `package_admin::make_immutable` is the only irreversible
step; it waits its own scheduled notice, destroys the native `UpgradeCap`, and
leaves Publisher custody, all three sealed children and the final operational
generation in place, so every vault call keeps working.
