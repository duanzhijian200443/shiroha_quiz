# Windows Codex integration for MCP vNext

This guide covers isolated stdio compatibility with an installed Windows Codex
client. [MCP contract §7](../product/agent-refactor/mcp-vnext-contract.md#7-bounded-stage-stdio-source-composition)
owns profile v2, seven tools and the closed production admission boundary.

## Launch and configuration

Use the actual `codex.exe`, rather than the npm `codex.ps1`/`codex.cmd` wrapper,
for subprocess tests. The npm Windows package contains it beneath
`node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/`;
the Desktop installation also has a bundled `codex.exe`. Resolve the installed
path and run `--version`; do not hard-code a Desktop build directory or assume
the two binaries have the same version. These checks require an installed client
with `app-server --stdio`, experimental `mcpServer/tool/call`, and
`mcpServerStatus/list` including server metadata/tools.

Codex supports stdio registration in `config.toml` using `command`, `args` and
`cwd` ([official MCP configuration](https://developers.openai.com/codex/mcp)).
Use a new, task-owned `CODEX_HOME` **only in the child environment**. Do not copy
auth/configuration from the user's home or change the running Desktop's settings.
For a manual isolated process, the equivalent server configuration is:

```toml
[mcp_servers.shiroha_vnext]
command = 'C:\path\to\flutter\bin\cache\dart-sdk\bin\dart.exe'
args = ['lib/mcp/vnext_mcp_entrypoint.dart']
cwd = 'C:\path\to\shiroha_quiz'
startup_timeout_sec = 10
tool_timeout_sec = 10
```

Use absolute paths for the Flutter SDK's **VM executable** and repository `cwd`.
Keep each argument separate; do not invoke `dart.bat`, a shell command string,
`pub get` or Flutter on the MCP stdout channel. The relative script argument
intentionally relies on the configured `cwd`. There is no database-path argument
for vNext. Keep the existing v0 registration and its read-only database path.

The test creates its own full configuration, removes inherited credential/provider
environment variables, and disables analytics, feedback, plugins, Apps and shell
snapshots. Plugin sync otherwise starts unrelated Git clone work and can retain
Windows temporary-directory handles after Codex exits. An offline placeholder
provider is configured; no `turn/start`, model request, login or auth-file copy
is performed. Ordinary Codex internal state files stay inside this disposable home;
they are not an additional Shiroha business database/writer.

## Repeatable checks

From the repository root, in a task shell:

```powershell
$env:SHIROHA_CODEX_EXE = 'C:\path\to\installed\codex.exe'
flutter test --concurrency=1 test/mcp/vnext_codex_windows_test.dart
```

Run once for each installed CLI/Desktop backend to be accepted. The test resolves
the Dart VM from the Flutter runner, uses a fresh home with spaces/non-ASCII
characters, and confirms Codex reports that exact home. It drives the installed
app server through `initialize` (experimental API opt-in), `initialized`,
`thread/start` (ephemeral), `mcpServerStatus/list`, and `mcpServer/tool/call`.
Codex itself performs MCP initialization, discovery and tool calls. This is a real
installed-client protocol check; it does not test model-selected tool use or clicks
in the Desktop UI.

The installed-client checks cover server `0.2.0`, all seven tools, serialized input
schemas, profile-v2 output declaration, READ/STAGE annotations, real context/status/
STAGE refusal, invalid input/unknown tool, a subsequent healthy call, repeated
sessions, EOF shutdown, process restart/reconnect, and missing executable/script.
Only STAGE is non-read-only; no tool is destructive/open-world. The test wrapper
records its own Dart PID and delegates directly to the production entrypoint,
with no App/credential option. Every recorded PID must be absent after Codex exits;
forced shutdown or locked-home cleanup fails the check. A separate raw-stdio check
uses the production script directly, requiring JSON-only stdout and clean EOF exit.
Stdout carries protocol only; raw stderr is drained without recording/exporting it.

Without explicit `SHIROHA_CODEX_EXE` on Windows, the three installed-client cases
are **SKIPPED**, never client acceptance. The raw-Dart check still runs. An invalid
explicit executable fails. Standing CI has no installed Windows Codex guarantee;
these results need independent Windows verification for a fixed candidate target.

Run the existing independent business and v0 regressions serially:

```powershell
flutter test --concurrency=1 test/mcp/vnext_mcp_end_to_end_test.dart test/mcp/mcp_contract_test.dart test/mcp/mcp_architecture_boundary_test.dart test/mcp/study_mcp_server_test.dart test/mcp/study_mcp_production_composition_test.dart
```

## Evidence levels and remaining connection gap

| Evidence | What it proves |
|---|---|
| Codex discovery | The installed client initializes the seven-tool server and preserves schemas/annotations. Definitions grant no business authority. |
| Codex actual call | Codex sends `tools/call`; the production entry returns `isError: true` and exactly `{profileVersion: 2, data: null, error: unavailable}` in both structured and JSON text content. This is successful protocol handling of a business refusal. |
| SDK synthetic App workflow | The existing fixture alone supplies synthetic credentials, approved targets and an isolated App-owned database. SDK clients prove STAGE, idempotency, lost-response recovery, local Review UI approval/rejection, lifecycle counts/reopen and authorization failures. |
| Codex synthetic STAGE | **Not covered.** The existing parent SDK harness handles `test/shiroha_app_call` and returns `test/shiroha_app_result` notifications. Codex does not implement that private test link, and these app-server APIs expose no notification-response forwarding into its MCP connection. Registering that fixture alone cannot connect its App port. |
| Production business access | **Not enabled.** The standalone entry has no admitted authenticated App/Bridge transport or trusted pairing/finite enablement/approved Session-target composition. SDK success and Codex discovery/refusal do not satisfy production activation. |

Codex-to-synthetic-App STAGE would require a separately bounded test-only App-link
adapter; it is not a missing Proposal, Review or lifecycle business implementation.
This integration adds no alternative transport, identity, business writer or
synthetic-credential flag to the production entry. It does not complete the wider
Windows MCP functional checklist or AR-R6B. `HOST_STABILITY_HALT = ACTIVE`,
`TRANSPORT = BLOCKED`, `AR-R6A = NOT_ACCEPTED` remain unchanged. No personal bank,
high-assurance Windows experiment, provider, DLL, Pin or Custodian is involved.
