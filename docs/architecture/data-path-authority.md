# DATA-PATH P1 — Application Data Path Authority

Status: **Current runtime contract**.

This contract defines the physical roots for durable application data. The
authority is independent of the Git repository, branch, worktree, and process
current directory.

## 1. Canonical root

The composition root obtains the OS-specific application-support directory
from `path_provider`. `AppDataPaths` appends the fixed `Shiroha` namespace and
one runtime environment directory:

```text
<Application Support>/Shiroha/development/
<Application Support>/Shiroha/production/
```

The environment is selected by the composition root:

- normal Debug/Profile runtime -> `development`;
- Release runtime -> `production`;
- tests and isolated smoke entrypoints remain on their existing isolated
  runtime profiles and do not use these durable roots.

The path authority never reads `Directory.current` and never derives a path
from a repository or worktree name.

## 2. Durable layout

```text
<environment>/
├─ database/shiroha_core_v1.db
├─ library/
│  ├─ content_assets/
│  └─ artifacts/
└─ runtime/
   ├─ logs/
   └─ restore/
```

The database filename remains `shiroha_core_v1.db`. Content assets remain
under the existing `content_assets/<sourceId>/<localAssetId>` storage-key
namespace below the managed library root; this contract does not introduce a
second content-asset storage layout.

## 3. Ownership and wiring

- `DatabaseHelper` receives the configured `AppDataPaths` before its singleton
  database is opened and uses `databasePath` for normal runtime access.
- `SqliteBackupDatabaseAuthority` continues to delegate its live database path
  to `DatabaseHelper`; it does not implement a second path calculation.
- The composition root passes `managedFilesRoot` to managed file, parsed
  artifact, and content asset adapters, and passes `restoreRoot` to B0.
- Parent directories for the canonical database are created by the database
  infrastructure immediately before opening the file.

## 4. Test and compatibility boundary

`FLUTTER_TEST`, in-memory smoke, `explicitFile`, and `explicitReadOnly`
profiles retain their existing isolation semantics. Path-authority tests use
injected absolute temporary support roots and never write the real user data
directory.

The Windows MCP App smoke entrypoint in
`tool/mcp_vnext_windows_app_smoke.dart` calls the existing `runShirohaQuiz`
composition with an explicit `AppDataPaths` and a credential store that rejects
every operation. Only that entrypoint consumes `SHIROHA_MCP_APP_SMOKE_ROOT`;
normal `main()` supplies no overrides. The smoke requires an existing immediate
child of the canonical OS temporary directory, the dedicated name prefix and a
regular task ownership marker; missing/relative/unowned roots fail before App
startup, with no fallback. The preparation test seeds synthetic Questions and
non-secret Profile/Grant policies only, refuses an existing database and retains
the prepared root only when explicitly selected for a manual run. Smoke HTTP
connections are rejected; no trusted MCP binding or credentials are installed.
This is a bounded test entrypoint, not an OS sandbox or a production data-path
selection option. The Windows MCP guide owns its repeatable commands and limits.

The explicitly selected Debug-only `tool/ui_rwd_driver.dart` entry enables the
Flutter SDK Driver extension for UI runtime validation. Each launch prepares a
fresh owned temporary child and passes it through the same smoke path guard;
it accepts no caller path and cannot adopt a prior installation's data. It reuses
the refusing credential store and denied HTTP configuration. Normal `main()`
does not import or enable Driver. Driver text emulation, widget-tree observations
and rendered screenshots are recorded separately from native keyboard/window
acceptance; they do not establish an independent review or whole-UI acceptance.
Native keyboard acceptance explicitly disables Driver text-entry emulation
before manual or OS input; the default emulated channel is not native-input proof.

This stage does not migrate, scan, merge, delete, or automatically discover
legacy worktree-local databases. Recovery or migration of legacy data is a
separate authorized stage.
