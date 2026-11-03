# Move module layout

Every module under `sui/` orders its sections top to bottom as follows, and skips any section it
does not need:

1. `// === Constants ===`
2. `// === Public Types ===`
3. `// === Public Functions ===`
4. `// === Private Functions ===`
5. `// === Test-Only Functions ===`
6. `// === Events ===`: structs the module itself emits with `event::emit`
7. `// === Errors ===`: `#[error(code = N)]` constants
8. `// === Imports ===`: `use` statements

Test modules follow the same rule: imports go last.

`#[error]` abort codes encode source line numbers, so moving code in a published package changes
its abort codes. Verify published source at its publish commit.
