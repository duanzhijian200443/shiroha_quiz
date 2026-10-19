# Windows Codex integration for MCP vNext

This guide covers isolated stdio compatibility and synthetic STAGE with an
installed Windows Codex client. [MCP contract §7](../product/agent-refactor/mcp-vnext-contract.md#7-bounded-stage-stdio-source-composition)
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

## Installed-client synthetic STAGE and local Review

With the same explicit executable setting, run:

```powershell
flutter test --concurrency=1 test/mcp/vnext_codex_synthetic_stage_test.dart
```

This suite reuses the SDK suite's `EndToEndHarness` from
`test/mcp/fixtures/vnext_mcp_test_support.dart`. The Flutter test App alone owns
the temporary synthetic database, credential proof, paired/finite-enabled Session,
current READ/STAGE grants, explicit target approval and local Review services.
The installed Codex app-server sends `mcpServer/tool/call` to the unchanged
seven-tool `VnextMcpServer`. Its test-only subprocess fixture passes each request
through a disposable file mailbox to the existing `VnextMcpAppComposition`.
Codex need not implement the SDK fixture's private notifications.

The mailbox is a test link under the isolated child home, not a production
transport or business journal. Complete request/reply files are published by
rename; each request is dispatched once, cancellation/availability is forwarded,
and waiting is bounded. The bridge holds no database, credentials, approval or
writer. Only the existing Application STAGE/Review services determine results.
No production option, listener, dependency, schema or external COMMIT is added.
Synthetic payload files are removed with the test home, never retained as logs.

Actual Codex calls cover target discovery/context opening, mixed-kind STAGE,
same-key identity reuse/conflict, unchanged formal questions before approval,
existing Inbox/Review UI approval and rejection, and original-key pending/terminal
lifecycle queries after real database close/reopen and fresh authentication.
They also cover authorized question search/detail, missing authentication,
exact-Session isolation, missing App approval/STAGE permission, invalid content,
expired Context, revoked grants and unavailable App. The response-loss case drops
the real App reply after publication, disconnects the actual Codex/MCP processes,
reopens SQLite and queries the original key without another STAGE call. Every
recorded MCP PID must exit on EOF and the child home must be removable.

The installed client may omit `isError: false` on success, as allowed by MCP;
tests require its default false meaning AND identical profile-v2 structured/text
envelopes. Error responses must still report true. All four cases are opt-in;
a skipped case is never installed-client or business acceptance. Run for each
installed binary to be accepted. No model turn or Desktop UI click is exercised.
Standing CI still requires a separate fixed-target Windows Verifier for this
installed-client acceptance.

## Evidence levels and remaining functional scope

| Evidence | What it proves |
|---|---|
| Codex discovery | The installed client initializes the seven-tool server and preserves schemas/annotations. Definitions grant no business authority. |
| Codex actual call | Codex sends `tools/call`; the production entry returns `isError: true` and exactly `{profileVersion: 2, data: null, error: unavailable}` in both structured and JSON text content. This is successful protocol handling of a business refusal. |
| SDK synthetic App workflow | SDK clients use the shared synthetic App to prove modern/legacy stdio STAGE, idempotency, Review, lifecycle and authorization semantics. This evidence alone does not prove installed Codex behavior. |
| Codex synthetic STAGE | The opt-in installed-client suite uses actual `mcpServer/tool/call` plus the test-only mailbox to reach that same App composition and persisted Proposal/Review lifecycle. Results count only when run against an explicit installed executable; SDK success or skipped cases cannot substitute. |
| Production business access | **Not enabled.** The standalone entry has no admitted authenticated App/Bridge transport or trusted pairing/finite enablement/approved Session-target composition. SDK success and Codex discovery/refusal do not satisfy production activation. |

The original private-notification connection gap is addressed only by this
bounded test fixture. The wider Windows functional checklist must still separate
unimplemented product composition from security admission. The production entry
has no authenticated App/Bridge binding or first-party pairing/finite-enablement/
target-approval composition. These are remaining product integration work, even
when their eventual activation also depends on security acceptance. Successful
authorized file selection/retrieval/passage through installed Codex is outside
this fixture's question-only grant/composition; this remains a functional
acceptance gap, not proof that the existing File READ services are absent.
Reference-plugin distribution and model-directed/Desktop-interactive usage are
separate integration scopes, not established by these app-server calls.

Production security admission independently requires the frozen Windows
credential/storage/isolation/transport/lifecycle evidence and AR-R6A/AR-R6B
exposure acceptance. `HOST_STABILITY_HALT = ACTIVE`, `TRANSPORT = BLOCKED`,
`AR-R6A = NOT_ACCEPTED` remain unchanged. No personal bank, high-assurance Windows
experiment, real provider, DLL, Pin or Custodian is involved. Synthetic functional
success never authorizes a security batch, production Host or transport activation.
