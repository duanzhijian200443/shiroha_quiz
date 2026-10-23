# Windows Codex integration for MCP vNext

This guide covers isolated stdio compatibility, synthetic File READ and STAGE
with an installed Windows Codex client. [MCP contract §7](../product/agent-refactor/mcp-vnext-contract.md#7-bounded-stage-stdio-source-composition)
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

The `tool_timeout_sec = 10` setting above is intentionally sized for the isolated
synthetic/refusal checks below. Codex's official default `tool_timeout_sec` is
`60` seconds. When an explicitly enabled first-party STAGE human-approval wait
window (up to 120 seconds human wait, 132 seconds post-upload response/EOF, 142
seconds total Bridge exchange; see external boundary §8) is exercised by an MCP
caller, configure `tool_timeout_sec` above `142` (for example `150` seconds);
a shorter caller timeout (such as `10` or default `60` seconds) will cancel the
pending request early and fail closed before STAGE handler entry.

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
recorded MCP process identity must be gone after EOF and the child home must be
removable.

The installed client may omit `isError: false` on success, as allowed by MCP;
tests require its default false meaning AND identical profile-v2 structured/text
envelopes. Error responses must still report true. All four cases are opt-in;
a skipped case is never installed-client or business acceptance. Run for each
installed binary to be accepted. No model turn or Desktop UI click is exercised.
Standing CI still requires a separate fixed-target Windows Verifier for this
installed-client acceptance.

## Installed-client synthetic File READ

With the same explicit executable setting, run:

```powershell
flutter test --concurrency=1 test/mcp/vnext_codex_file_read_test.dart
```

This suite composes the existing `FileReadHarness` and P6 read service with the
same App gateway/dispatch/composition and test-only mailbox as the STAGE suite.
Only the App/test process owns its synthetic files, SQLite, Profile/Grant and
credential proof. F1 publishes and verifies real managed sidecars from the
existing synthetic generator; P6 uses the production deterministic chunker,
RAG service and SQLite FTS5. No retrieval or passage result is substituted.
The test checks actual index generation/revision/payload-digest bindings.

Actual Codex `mcpServer/tool/call` discovers the authorized parent target,
lists opaque file choices, selects a subset into a separate File Context,
retrieves lexical hits and reads server-returned PassageRefs through cursor
exhaustion. The original parent remains file-empty. P4 parent-target discovery
still requires READ/questionContent/exact bank-Project authority; that existing
prerequisite never substitutes for independent READ/fileContent/exact File-Project
checks. File selection itself supplies no STAGE approval; the unchanged App target
approval and STAGE permission gates still apply. READ-only grants can read files
without STAGE permission. No client supplies paths, raw File IDs or grants.

The suite rejects forged/cross-Context File/Passage/cursor references, absent
fileContent or File scope, foreign Project scopes, expiry, revoke, narrowing,
Project detach, changed file digest, reparse and corrupt F1 payloads, including
old references against a warm index. Revocation after real FTS results suppresses
final release. Real SQLite reopen and fresh authentication require new selections;
old Contexts/PassageRefs/cursors remain unusable. Codex and recorded MCP processes
must exit on EOF; cleanup records each MCP server's creation time at connect,
confirms that identity is gone (or the PID was reused) and fails closed when the
query cannot confirm exit. The isolated home and synthetic database/files are
removed.

Assertions retain the existing 6,000-byte content/24,000-byte page bounds, at most
eight complete passage chunks, structural exclusions and coverage flags. Ranked
hits, middle-document passages and cursor exhaustion do not assert whole-document
coverage. Existing P6 offline regressions additionally exercise reduced budgets,
formula boundaries, source/policy races and cache-settlement semantics.

All 13 cases are opt-in. Without Windows and explicit `SHIROHA_CODEX_EXE`, they
are **SKIPPED / UNVERIFIED**, never SDK substitutes for client acceptance.
Standing CI cannot prove these installed-Windows-client calls; independent
fixed-target Windows verification remains required before merge.

### Executed evidence, 2026-10-19

For `MCP-VNEXT-CODEX-FILE-READ-E2E`, the Executor ran the three suites above
serially for each explicitly selected installed executable:

| Installed executable | `--version` | File READ | STAGE/Review/lifecycle | Compatibility |
|---|---|---|---|---|
| npm CLI vendor `bin/codex.exe` | `codex-cli 0.144.1` | 13 PASS | 4 PASS | 4 PASS |
| Desktop package `26.1013.4894.0`, `app/resources/codex.exe` | `codex-cli 0.163.0-alpha.10.2` | 13 PASS | 4 PASS | 4 PASS |

No installed-client case was skipped. Compatibility's four cases include the
direct Dart production-stdio check plus three installed-client cases; that raw
Dart case is not counted as a Codex business call. Each File READ run includes
actual authorized selection/retrieval/passage, all specified safe refusals and
normal process/home cleanup. These are Executor results for this candidate,
not independent Verifier/Reviewer approval or a supported-version floor.
Model-selected calls, Desktop UI interaction, reference-plugin distribution and
production App/Bridge activation remain **UNVERIFIED** by these tests.

The process-identity cleanup and read warm-up repair was re-run with the
documented per-suite commands: CLI and Desktop File READ 13/13 and STAGE 4/4
each, with every cleanup verifying the recorded server identity. Compatibility is
unchanged and was not rerun for the repair. Two transient `outcome_unknown`
results were observed (one combined two-file invocation and one separate Desktop
File READ run) and did not reproduce in the documented per-suite reruns;
independent verification must repeat each suite separately.

The eight-suite offline regression run passed 81 cases: the five business/v0
suites listed above plus `test/application/external/external_file_read_test.dart`,
`test/application/external/external_file_read_backup_test.dart` and
`test/core/database/rag1_fts5_capability_test.dart`. Focused analysis of the new
test and both changed support files, the read-only format gate and
`git diff --check` passed. Repository/global acceptance remains NOT_EVALUATED.

## Installed-client Bridge v3 READ/File/Proposal acceptance

Run this additional suite separately for each installed binary, with the same
explicit child-only configuration described above:

```powershell
$env:SHIROHA_CODEX_EXE = 'C:\path\to\installed\codex.exe'
flutter test --no-pub --concurrency=1 test/mcp/vnext_codex_bridge_v3_test.dart
```

The existing `CodexSyntheticClient` drives actual `mcpServer/tool/call`. The
existing disposable mailbox now accepts the existing `VnextMcpPort` interface;
this suite selects the shared `VnextV3AppLink`, extracted from the standing SDK
Bridge cases. Each call constructs a fresh test-only connection around the
existing `VnextMcpBridgePort` and `WindowsTlsBridge`. Public mathematical/Fake
Native fixtures and Fake TLS reach the same App P9/P10 v3 binder, P8/P7 and
isolated SQLite owners. No response is replaced with an SDK result. Production
files, startup, authentication, TLS policy and business services are unchanged.

The 13 opt-in cases cover all six non-STAGE tools: target/READ Context creation,
question search/detail, explicit File choices/separate Context, real F1/FTS
retrieval/Passage with cursor exhaustion, and independent original-SubmissionKey
lifecycle metadata. The success path asserts v3 frames and distinct authenticated
Sessions and execution Contexts for every connection. Lifecycle uses a Proposal
seeded through the original synthetic App STAGE service, then changes policy to
READ/proposalMetadata only, invalidating old READ handles. Its original key
succeeds; the P9 correlation ID cannot select it. That seed never travels through
Bridge STAGE and provides no approval to a Bridge connection.

Safe refusals cover forged/wrong-kind/cross-Context references, an independently
authenticated foreign Principal, substitution of another Session's execution
Context, expired handles after fresh enablement, revoked grants, forged
File/Passage/cursor selections and file-empty parent access. Each refusal must
return an authorization result (`capability.accessDenied`,
`capability.externalReadDenied`, `capability.externalReadStale` or
`capability.externalReadDataCorrupt`), with `unauthenticated` only where P8
admission rejects the Session, and must prove it crossed the Bridge as exactly one
v3 frame on one fresh connection. `outcome_unknown`, `unavailable`, `cancelled`,
`invalidRequest` and `invalidResult` never count as a refusal. Trust disable after
binding is the one case that closes the owning connection before any business
frame: it releases no data and publishes nothing, but its caller outcome is
`outcome_unknown`, so it is recorded as withheld data and not as an authorization
refusal.
Actual Codex STAGE refusal asserts no Bridge frame, no App binding and no Proposal
publication. A separate object probe at the SAME Bridge port additionally proves
zero Submission encoding; JSON-RPC/mailbox input serialization is a distinct
operation and necessarily occurs for actual client calls. No test identity or
preapproved target removes the unconditional Windows Bridge STAGE block.

Dropping a real App reply on the Fake TLS response path produces
`outcome_unknown`; it never retries that request. Actual Codex EOF/reconnect then
uses a new authenticated connection to revalidate a same-Principal READ handle.
Mailbox withdrawal during pending binding forwards cancellation, closes the
original connection and waits for binding/Host settlement. Reconnect uses a fresh
mailbox directory, so old request files cannot be replayed. Existing PID-creation
identity checks, clean EOF exit, zero transport reservations and removable child
homes remain mandatory. All 13 cases are SKIPPED / UNVERIFIED without Windows and
an explicit executable; unavailable versions never count as PASS.

These calls prove installed-client source integration through a test-only link.
They do not prove model-selected tools, Desktop UI interaction, real TLS/Windows
security acceptance or production App/Bridge process composition. Fixed-candidate
independent Windows verification remains necessary because standing CI cannot
establish installed Windows client behavior.

### Executed Bridge v3 evidence, 2026-10-22

For `MCP-VNEXT-CODEX-BRIDGE-V3-E2E`, the Executor started from merged #322's
verified remote-default commit `4ef10a627fa0248c39eca45bbd83df9454243c36` on a new
dedicated branch. Each explicitly resolved installed executable ran the suite
above separately and serially:

| Installed executable | `--version` | Bridge v3 | Compatibility | STAGE/Review | File READ |
|---|---|---|---|---|---|
| npm CLI vendor `bin/codex.exe` | `codex-cli 0.144.1` | 13 PASS | 4 PASS | 4 PASS | 13 PASS |
| Desktop package `26.1016.6573.0`, `app/resources/codex.exe` | `codex-cli 0.163.0-alpha.11` | 13 PASS | 4 PASS | 4 PASS | 13 PASS |

The table counts full runs with the final test source; no client case was skipped.
No production compatibility repair was necessary. These are Executor results,
not independent Verifier/Reviewer approval or acceptance of other client versions.
Repository/global acceptance remains NOT_EVALUATED.

Each of the three original installed-client suites was also run separately with
`flutter test --no-pub --concurrency=1`; File READ's results are the full final
runs after the bounded assertion correction below. Compatibility's four cases
include one direct Dart production-stdio check and three installed-client cases;
that raw-Dart check is not a Codex business call. Focused analysis of all five
changed/new Dart files, their read-only format gate, `git diff --check` and
`powershell -NoProfile -ExecutionPolicy Bypass -File tool/external/check_tls_source.ps1`
passed. The execution-policy option applies only to that check process and does
not modify machine/user policy or enable a security experiment.

The serial ten-suite offline regression passed 291 cases: the five business/v0
suites under Repeatable checks, plus
`test/data/external/ipc_command_projection_test.dart`,
`test/data/external/ipc_command_schema_test.dart`,
`test/data/external/ipc_envelope_codec_test.dart`,
`test/data/external/windows_tls_transport_test.dart` and
`test/data/external/windows_tls_source_guard_test.dart`, using
`flutter test --no-pub --concurrency=1` with those explicit targets. This retains
P10 v1/v2/v3, modern/legacy vNext, MCP v0, synthetic STAGE/Review, response-loss
recovery and the standing Bridge resource/EOF/deadline regressions.

The original CLI File READ regression initially reported 12 PASS / 1 FAIL: its
revoke case expected only later capability-layer errors, whereas #322's v3
authentication/P8 admission rejects the revoked Session as `unauthenticated`.
The user explicitly authorized a bounded test correction. Only that case now
requires the exact profile-v2 authentication failure for retrieval, Passage and
cursor calls, plus unchanged F1-read and FTS-search observations. Other refusal
allowlists and production behavior remain unchanged; this does not turn an
unknown transport outcome into an authorization PASS.

### Review-driven refusal-attribution correction, 2026-10-22

The first review of this candidate rejected the shared refusal helper: it accepted
`data: null` with any non-null error, so `outcome_unknown`, `unavailable`,
`cancelled`, `invalidRequest` and `invalidResult` all counted as a safe refusal.
That could not distinguish the P4/P8 boundary each case claims from an unrelated
transport or local failure. The corrected suite requires an explicit authorization
result per case, and additionally asserts that each refused call used exactly one
fresh Bridge connection with exactly one v3 frame, so a locally short-circuited or
pre-transport failure cannot satisfy it.

Attribution observed with the corrected assertions on the CLI binary
(`codex-cli 0.144.1`): forged, wrong-kind, foreign-Principal, foreign-execution and
expired handles return `capability.accessDenied`; cross-Context detail and every
forged File/Passage/cursor or file-empty parent call return
`capability.externalReadDenied`; a revoked grant returns `unauthenticated`. Trust
disable after binding produced `outcome_unknown` under the previous permissive
helper, which is exactly the mis-attribution this correction removes; that case is
now labelled as withheld data without a business result and is not counted as an
authorization refusal.

Re-ran `flutter test --no-pub --concurrency=1 test/mcp/vnext_codex_bridge_v3_test.dart`
with `SHIROHA_CODEX_EXE` bound to the npm CLI vendor binary: 13/13 PASS, no skip.
Only the CLI binary was re-run against the corrected assertions; the Desktop
package result in the table above was recorded before this correction and must be
repeated by the fixed-target Verifier. Production code, the wiring and the
business services are unchanged by this correction.

## Isolated Windows Flutter App smoke

The smoke entrypoint reuses the actual Windows runner and `main.dart` App
composition, including `McpVnextAppIntegration`, the authorization page and
existing Proposal/Review owners. It injects explicit temporary `AppDataPaths`
before any normal application-support lookup and a rejecting engine credential
store; HTTP connection creation is denied. It installs no MCP authentication,
TrustCore, App/Bridge binding or production listener. Flutter's Debug VM service
is development tooling, not an MCP listener. No normal Debug/Release data root,
personal bank, saved key or private document is needed.

Prepare a fresh task-owned temporary root, then run the preparation/isolation
tests before launching. Use a task shell in the repository root:

```powershell
$taskSmokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('shiroha_mcp_app_smoke_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskSmokeRoot | Out-Null
[System.IO.File]::WriteAllText((Join-Path $taskSmokeRoot '.smoke-owner'), 'MCP-VNEXT-WINDOWS-APP-FUNCTIONAL-SMOKE')
flutter test --concurrency=1 "--dart-define=SHIROHA_MCP_APP_SMOKE_ROOT=$taskSmokeRoot" test/tool/mcp_vnext_windows_app_smoke_test.dart
if ($LASTEXITCODE -ne 0) { throw 'Smoke preparation failed; do not launch' }
flutter run --no-pub -d windows --target tool/mcp_vnext_windows_app_smoke.dart "--dart-define=SHIROHA_MCP_APP_SMOKE_ROOT=$taskSmokeRoot"
```

The preparation uses the existing repository/authorization owners to create one
synthetic question in `MCP Smoke Folder` / `MCP Smoke Bank` and two non-secret,
unpaired Profiles (`Smoke READ`, `Smoke READ + STAGE`). It refuses to reseed an
existing database. Without a supplied root, the same test creates and removes
its own temporary fixture. The App entrypoint refuses a missing, relative,
unowned or non-temporary root before calling the App, with no default fallback.
The marker identifies a test fixture, not a security credential or authorization
proof. This is not an OS sandbox; do not open personal files, import documents
or use provider/native/network features during this bounded smoke.

For a cold restart, close the window and confirm process exit, then launch the
SAME `build/windows/x64/runner/Debug/shiroha_quiz.exe` bundle. Its compiled define
retains this isolated root. Do not rebuild another entrypoint or use normal
`flutter run`/Release as a substitute. Preserve the fixture until manual evidence
is recorded; do not delete a live runtime's files.

### Executed App evidence, 2026-10-20

The Executor built and launched this isolated desktop App on the merged #315
baseline. It observed the existing `我的 -> 外部 Agent 授权` page, both synthetic
Profiles, READ/STAGE/exact-bank/Egress policy display, the 5/10/30-minute menu,
and the selected Profile remaining unconnected with access disabled. Clicking
the disabled finite-enable and STAGE-target controls did not enable access or
open an approval. Returning to the page reconstructed its controls and retained
the disabled state. The fixture's database and runtime log were under the
explicit temporary root; no real credential backend was used.

The user then took over the window and reported all supplied checks normal:
page/Profile/policy display, unavailable controls, page reconstruction, window
close/process exit and cold restart with the same bundle, retained synthetic
Profiles and ordinary synthetic bank browsing/answer/save behavior. Exit/cold
restart and ordinary App bank behavior are **user-attested manual evidence**;
they were not independently observed or recorded by a Verifier. No authenticated
real Session or target approval was created. Invalidation of previously active
Sessions/approvals remains separately proved by the synthetic product-root tests,
not by this dormant desktop run.

Executor regression evidence for the unchanged executable implementation:

| Run | Result |
|---|---|
| Smoke root/credential/HTTP/preparation and existing AppDataPaths tests | 8 PASS |
| Product control/authorization architecture and UI, SDK vNext E2E, four v0 suites and Proposal approval/edit/preview | 96 PASS |
| Question repository v2, typed/legacy question list and bank detail | 109 PASS |
| Installed Codex CLI 0.144.1: compatibility, synthetic STAGE/Review, File READ (separate serial commands) | 4 + 4 + 13 PASS; no skips |

The Desktop backend was not rerun in this smoke assignment. Its prior fixed-head
Windows acceptance is recorded on #314/#315, not counted as a new run here.
The smoke adds no production pairing, transport, external COMMIT or security
experiment evidence. Fixed-candidate standing CI and independent review remain
delivery gates; manual user confirmation is not `[VERIFICATION APPROVAL]`.

## Evidence levels and remaining functional scope

| Evidence | What it proves |
|---|---|
| Codex discovery | The installed client initializes the seven-tool server and preserves schemas/annotations. Definitions grant no business authority. |
| Codex actual call | Codex sends `tools/call`; the production entry returns `isError: true` and exactly `{profileVersion: 2, data: null, error: unavailable}` in both structured and JSON text content. This is successful protocol handling of a business refusal. |
| SDK synthetic App workflow | SDK clients use the shared synthetic App to prove modern/legacy stdio STAGE, idempotency, Review, lifecycle and authorization semantics. This evidence alone does not prove installed Codex behavior. |
| Codex synthetic STAGE | The opt-in installed-client suite uses actual `mcpServer/tool/call` plus the test-only mailbox to reach that same App composition and persisted Proposal/Review lifecycle. Results count only when run against an explicit installed executable; SDK success or skipped cases cannot substitute. |
| Codex synthetic File READ | The separate opt-in suite reaches existing P6/F1/RAG/FTS5 through actual Codex calls, explicit file selection and bounded passages, including authorization/source invalidation and cleanup. Only executed cases against the named installed binary establish client evidence. |
| Codex Bridge v3 | The separate opt-in Bridge suite sends actual installed-client calls through the existing mailbox, single-request Fake TLS Bridge and App P10 v3/P8/P7. It checks fresh authentication/Context binding, six non-STAGE tools, refusal, response loss and cleanup. Bridge STAGE remains zero-send; this supplies no production process/security binding. |
| Codex Windows App/Bridge functional composition | `windows_app_transport_codex_test.dart` exercises all seven tools through the product App composition, P27 Handoff, owned Host and `McpVnextWindowsBridge` (executed with `codex-cli 0.144.1` and Desktop `codex-cli 0.163.0-alpha.11.1`), including explicit same-Session first-party STAGE confirmation and original-key lifecycle query. Uses the existing test mailbox, Fake TLS and temporary SQLite; Draft #327's short-deadline cancellation compatibility remains BLOCKED. |
| First-party App controls | The product root and local Profile/finite-enable/target-confirm/disable controls are proved with synthetic credentials and temporary SQLite under MCP contract §9. The real desktop smoke above additionally checks dormant display/refusal and records user-confirmed restart/bank behavior. It supplies no real authentication. |
| Production business access | **Not enabled.** The standalone entry has no admitted authenticated App/Bridge transport or real pairing/credential binding. SDK success and Codex discovery/refusal do not satisfy production activation. |

The original private-notification connection gap is addressed only by this
bounded test fixture. The wider Windows functional checklist must still separate
the dormant product App controls from security admission. The production entry
has no authenticated App/Bridge transport or real first-party pairing/credential
binding. [MCP contract §9](../product/agent-refactor/mcp-vnext-contract.md#9-first-party-app-composition-and-controls)
owns the supplied finite-enablement/target-confirmation composition and its
offline evidence; it does not activate that remaining integration. Successful
authorized file selection/retrieval/passage through installed Codex is covered
by the separate synthetic File READ fixture above. This closes that isolated
client-fixture gap only; it supplies no production App/Bridge or approval UI.
Reference-plugin distribution and model-directed/Desktop-interactive usage are
separate integration scopes, not established by these app-server calls.

The current completion assessment is bounded: the seven-tool business workflow,
isolated installed-client protocol/READ/STAGE/Review/recovery and dormant App
controls have evidence. [MCP contract §10](../product/agent-refactor/mcp-vnext-contract.md#10-inactive-first-party-pairing-integration)
adds inactive first-party request/confirmation/proof/status wiring through the
existing P15/P12/P0 owners, with an adapter over the same P27 candidate and
independent authenticated Session custody. Its tests use synthetic credentials
and public mathematical/fake-Native fixtures only; they are not actual Windows
or installed App/Bridge pairing acceptance. [MCP contract §11](../product/agent-refactor/mcp-vnext-contract.md#11-inactive-first-party-bridge-onboarding-controls)
adds inactive Bridge local controls over the original Enrollment and two explicit
human comparisons, with isolated public-math/Fake Native evidence. [MCP contract §12](../product/agent-refactor/mcp-vnext-contract.md#12-inactive-app-bridge-pairing-handoff)
adds the inactive public Submission/export/actual-completion handoff using the
same owners and two explicit comparisons. [MCP contract §13](../product/agent-refactor/mcp-vnext-contract.md#13-inactive-bounded-bridge-ipc-client)
adds bounded single-request Bridge P9 communication through the existing verified
channel; Fake TLS exercises real App P10/P8 READ/STAGE. [MCP contract §14](../product/agent-refactor/mcp-vnext-contract.md#14-inactive-bridge-seven-tool-protocol-projection)
adds shared seven-tool/P10 v3 projection and trusted App Context binding. The
installed-client Bridge suite above exercises six non-STAGE tools through that
source using a test-only process mailbox and Fake TLS. [MCP contract §15](../product/agent-refactor/mcp-vnext-contract.md#15-inactive-windows-process-side-functional-composition)
completes the inactive App/Bridge process-boundary composition (`McpVnextWindowsTransport`
and `McpVnextWindowsBridge`), connecting the product App root, P27 Handoff, owned
TLS Host, auxiliary local-connection drain and single-connection-per-call Bridge
ownership across all seven tools and opt-in same-Session STAGE confirmation.
Actual protected credential acquisition, real OS process bootstrap/transfer and
admitted runtime channels remain
**product implementation/integration work**.
Draft #327's installed-client short-deadline cancellation compatibility remains
separately BLOCKED. They must not be reported as security-approval-only blockers. Reference-package
distribution/Windows executable discovery and supported-version acceptance in
MCP contract §5/AR-R9 are separate unfinished client-integration scope; model-led
and Codex Desktop-interactive use remain unverified. No business reimplementation
or experiment resumption follows from this assessment.

Production security admission independently requires the frozen Windows
credential/storage/isolation/transport/lifecycle evidence and AR-R6A/AR-R6B
exposure acceptance. `HOST_STABILITY_HALT = ACTIVE`, `TRANSPORT = BLOCKED`,
`AR-R6A = NOT_ACCEPTED` remain unchanged. No personal bank, high-assurance Windows
experiment, real provider, DLL, Pin or Custodian is involved. Synthetic functional
success never authorizes a security batch, production Host or transport activation.
