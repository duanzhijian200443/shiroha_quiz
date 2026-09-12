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

This stage does not migrate, scan, merge, delete, or automatically discover
legacy worktree-local databases. Recovery or migration of legacy data is a
separate authorized stage.
