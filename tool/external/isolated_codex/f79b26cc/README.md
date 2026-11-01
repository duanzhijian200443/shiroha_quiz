# Fixed Windows stdio close candidate

This directory preserves the source of an isolated verification client. It is
not an installed Codex update, a supported release or product admission. It is
separate from the older `44918ea` candidate in the parent directory. No binary,
upstream source tree, private Codex home or runtime evidence is included.

## Source identity

- Upstream: <https://github.com/openai/codex>, commit
  `f79b26ccbb3116b052544666a181012fb45dc49b`, workspace version
  `0.166.0-alpha.5.1`.
- Source archive:
  `https://codeload.github.com/openai/codex/tar.gz/f79b26ccbb3116b052544666a181012fb45dc49b`.
- Archive SHA-256:
  `8891296adbe3c02474eb9dd9fcff23c99becd171cad75e76cff88c32a8cdb209`.
- `windows-stdio-shutdown.patch` SHA-256:
  `4cc722e512d21b99d2e0f94a59ede3b4dde1ac13d9289464d156e36d93b0e241`.
  Preserve its exact bytes; the local Git attribute disables newline conversion.
  Space-only unified-diff context lines are exempt from patch-envelope trailing
  whitespace checks; `git apply --whitespace=error-all` validates source additions.

The patch changes eight Rust source/test files in `codex-rs/rmcp-client` and
`codex-rs/Cargo.lock`. The lock change stamps 170 local workspace packages from
`0.0.0` to the release version; all 1,308 external dependency entries retain
their versions, sources and checksums. Do not resolve new dependency versions.

The Windows local stdio close worker closes original input, drains original
output and waits for the original process under a three-second grace deadline.
It retains the original Job for descendant cleanup, joins streams, and shares a
cancellation-resistant result between repeated/concurrent closers. Failure or
timeout remains a failed close. Other platforms, remote executors and restart
semantics are not changed. The patch includes direct shutdown regressions and a
test-only stdio helper; it adds no production MCP shutdown tool or protocol.

Upstream source is Apache-2.0. `LICENSE` and `NOTICE` are copied from the pinned
source. The patch is a local modification, not an upstream release. Retain those
notices and any applicable bundled third-party licenses when distributing a
rebuilt client.

## Isolated preparation and build

Use Windows x64 MSVC and its Windows SDK, CMake/Ninja, Rust
`1.95.0 (59807616e 2026-04-14)` and Cargo `1.95.0 (f2d3ce0bd 2026-03-21)`.
Use the pinned source's existing `dev-small` profile and one compilation job.
Source/toolchain/dependency downloads require their own network authority.
These instructions do not authorize a download, build, real model or device run.

Extract the verified archive into a new task-local `build/codex-gc/src`; do not
overlay an existing source tree. Preserve the archive's original files and the
source/patch hashes. From that source root, check then apply this patch:

```powershell
git apply --check --whitespace=error-all <absolute-path-to-windows-stdio-shutdown.patch>
git apply --whitespace=error-all <absolute-path-to-windows-stdio-shutdown.patch>
```

Set process-local `CARGO_HOME`, `RUSTUP_HOME`, `CARGO_TARGET_DIR`, `TMP` and `TEMP`
to separate task directories; keep the target at `build/codex-gc/target` for the
verification harness. Initialize the x64 MSVC Developer environment first,
including `INCLUDE`, `LIB` and `LIBPATH`; setting PATH alone is insufficient.
Select task-local Rust/CMake/Ninja and the required MSVC/SDK tools while retaining
Windows System32, Git, `SYSTEMROOT`, `WINDIR` and `COMSPEC` for builds and the
through-cmd tests. Set `CARGO_BUILD_JOBS=1` and
`CARGO_INCREMENTAL=0`, `CARGO_PROFILE_DEV_DEBUG=0`, `CARGO_PROFILE_TEST_DEBUG=0`
and `CARGO_PROFILE_DEV_CODEGEN_UNITS=16`. Use an empty task-local
`GIT_CONFIG_GLOBAL` with `GIT_CONFIG_NOSYSTEM=1` and `GIT_TERMINAL_PROMPT=0`.
The bounded build uses `CARGO_NET_RETRY=1` and `CARGO_HTTP_TIMEOUT=60`.
Do not modify the installed Codex executable, global PATH,
private client configuration or authentication. Restore process environment
afterwards. Run through a bounded low-priority monitor; a failed or stopped build
does not authorize increasing memory/time limits or retrying indefinitely.

From `build/codex-gc/src/codex-rs`, run serially:

```text
cargo +1.95.0 build --locked --profile dev-small -p codex-rmcp-client --bin test_stdio_server
cargo +1.95.0 test --locked --profile dev-small -p codex-rmcp-client --lib windows_stdio_shutdown_tests -- --test-threads=1
cargo +1.95.0 test --locked --profile dev-small -p codex-rmcp-client --test stdio_message_limits --test mcp_2026_stdio_discovery -- --test-threads=1
cargo +1.95.0 build --locked --profile dev-small -p codex-cli --bin codex
```

The direct shutdown tests cover normal EOF, delayed cleanup, timeout, failed
exit, cancelled waiters, repeated/concurrent close and original Job descendants.
The two neighboring suites retain message-limit and MCP discovery coverage.
Keep command results separate from the process-level normal/delayed/hang matrix.

## Acceptance identity

Before selecting the result, bind the complete source manifest, patch, toolchain,
build inputs and resulting executable hash in the exact-key candidate manifest
described in the [Link verification guide](../../../link/README.md#offline-client-shutdown-fixture).
The guide also describes the isolated configuration and no-device matrix.
The commands above do not guarantee byte-identical output across environments;
a rebuilt executable with different bytes is a new candidate and cannot inherit
another executable's acceptance records.

Offline MCP/Responses fixtures do not prove Android behavior or a real model
turn. Actual Link per-call close acceptance separately requires both production
footers, exact call/resource joins and retained original-process exit witnesses.
Keep old failed/incomplete attempts, unknown historical provenance and full L01
independence acceptance separate. No version string, successful build or later
passing run can replace those missing observations.
