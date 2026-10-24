# Isolated Windows Codex EOF compatibility patch

This is a reproducible **test client**, not an installed-client update, supported
release or production admission. It changes only the Windows local stdio launcher
of official Codex `rust-v0.144.1`, pinned to
`44918ea10c0f99151c6710411b4322c2f5c96bea`. The upstream source is Apache-2.0;
retain the source archive's LICENSE and NOTICE when distributing a built client.
No client binary, Rust dependencies or upstream source tree is committed here.

The original launcher forcibly terminates the Bridge tree before closing stdin.
`windows-eof.patch` instead keeps the original Tokio child and rmcp byte transport,
closes its writer first, drains the sole stdout consumer and stderr, and waits for
the same child. Clean settlement requires stdout EOF, successful stream drain and
exit 0 within five seconds. Error/timeout uses the original child handle for
bounded forced cleanup and retains a failed result for later closers. This does
not add an MCP message, broker, process rediscovery or authenticated mode. Other
platforms and executor-backed remote process behavior are unchanged.

Build only in the task workspace, using Windows x64 MSVC and the original source
toolchain Rust 1.95.0. The tested portable layout is:

```text
.dart_tool/ar-r6b-isolated-codex/rustup/  RUSTUP_HOME
.dart_tool/cg/bin/                       cargo/rustup/rustfmt shims
.dart_tool/ar-r6b-isolated-codex/bin/    just 1.59.0, cargo-nextest 0.9.149
.dart_tool/ct/                          CARGO_TARGET_DIR
```

Short Cargo/target paths avoid libgit2's Windows path-length checkout failure.
Use official rustup with `--no-modify-path --profile minimal --default-toolchain
1.95.0` and those task-local `RUSTUP_HOME`/`CARGO_HOME` values; install rustfmt into
that toolchain. `just` and `cargo-nextest` are the official prebuilt Windows x64
tools. These setup operations and public dependency downloads require explicit
runtime/network authority. Do not use private Codex homes or copy authentication.

```powershell
pwsh -NoProfile -File tool/external/isolated_codex/build.ps1
$env:SHIROHA_CODEX_EXE = "$PWD/.dart_tool/ct/dev-small/codex.exe"
flutter test --no-pub --concurrency=1 test/mcp/windows_trusted_bootstrap_test.dart
```

The build script verifies the pinned public source archive SHA-256, applies the
four-file patch, runs the four scoped lifecycle tests through upstream `just
test`, and builds `codex-cli` with two compilation jobs. It normalizes only the
132 local workspace versions left at `0.0.0` in the official release lock file to
the release's `0.144.1`; external versions, sources and checksums do not change.
`-PrepareOnly` performs source preparation without compiling. The script restores
its process environment and never writes the installed Codex location.

Codex status discovery creates a temporary MCP manager. The acceptance driver
discovers before creating its business thread, waits for that discovery process
to settle, then starts the business lifetime. It retains the seven-tool inventory
assertion and refuses any overlapping Owner. A live status snapshot must not
create a second credential owner.

The selected-client acceptance uses a fresh isolated Codex home, offline provider
configuration and no model turn. The compiled Bridge fixture imports product
Bootstrap/P26/TLS Bridge code while injecting existing Fake Native/TLS only at
test boundaries. The receiving App exercises the real P15/P0/P8/P10 and original
Proposal/Review Writer. Selecting this binary cannot enable the formal AOT.

Original installed-client failure, isolated-client success and formal default
refusal are distinct evidence. See the [Windows evidence guide](../../../docs/architecture/mcp-vnext-windows-codex.md)
and [MCP contract](../../../docs/product/agent-refactor/mcp-vnext-contract.md).
This patch does not resolve the separate #327 cancellation compatibility issue.
