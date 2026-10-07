# OBS-1 Unified Operation Trace v0

Status: **CLOSED / FROZEN** (accepted in the same PR that implemented it;
initial state was `IN PROGRESS`).

The [Agent refactor target](../product/agent-refactor/README.md) plans detailed
Provider round terminal evidence. OBS-1 remains the event-schema, identity and
redaction authority. This documentation checkpoint adds no runtime event;
the AR-R1 implementation candidate adds the scoped successor below. Historical
OBS-1 closure does not constitute AR-R1 final CI/review acceptance.

OBS-1 adds a unified **operation correlation** layer to Shiroha v0 without
changing the runtime database schema (stays **v22**), without cloud telemetry,
and without changing the business authority of Agent / Import / F1 / RAG.

```text
correlationId
│
│├── Agent Turn trace
│││││└── RAG retrieval child trace
│
│├── ParsedArtifact generation trace
│││││└── OCR events (spans of the enclosing trace)
│
│└── Import Attempt trace
│││││└── retry → new trace (same correlation, parent = previous trace)
```

User-facing unified presentation: `诊断编号：OBS-XXXX-XXXX`. Internally the
independent fields remain: `correlationId`, `traceId`, `parentTraceId`,
`operationKind`, `taskId?`, `attemptNumber?`.

## 1. Frozen identity semantics

Three concepts are strictly distinct:

- **correlationId** — one user-level workflow / diagnosable event set. It is
  the user-visible diagnostic number: `diagnosticId == correlationId`
  (product copy "诊断编号", internal field `correlationId`). Format
  `OBS-XXXX-XXXX`: short, random (32-letter unambiguous alphabet, 40 bits),
  no time / file name / user info / conversation title semantics, safe to
  display, directly usable to filter logs. No separate unmappable
  "display id" exists.
- **traceId** — one concrete execution attempt / operation (existing
  `trace-...` semantics preserved). Different operations never share a
  traceId merely to appear unified.
- **parentTraceId** — the trace that directly triggered the current
  operation; builds the trace tree.

## 2. TraceContext v0

`lib/core/observability/trace_context.dart` extends the existing
`TraceContext` (traceId/taskId/run/createTraceId) with:

```text
correlationId
traceId
parentTraceId
operationKind
taskId
```

New enum (deliberately small, no broad taxonomy):

```dart
enum TraceOperationKind {
  agentTurn,
  importAttempt,
  parsedArtifactGeneration,
  ragRetrieval,
}
```

Minimal API:

- `runRoot(...)` — root operation: new correlation, new trace,
  `parentTraceId = null`.
- `runOperation(...)` — child operation when a trace is active: inherit
  correlation, new trace, `parentTraceId = current traceId`; without an
  enclosing trace it degrades to a root operation.
- `run(...)` — backward-compatible core; explicit `traceId` / `taskId`
  remain supported, so existing Import callers keep their explicit
  Import trace identity.

## 3. Zone propagation boundary

Dart Zone stays the propagation authority inside one execution boundary:
`await`, `Future` and nested async operations keep the current context.
Zone propagation **only** guarantees the same execution boundary; Isolate /
Process / native background boundaries must never assume automatic
inheritance; future cross-boundary work must pass correlation context
explicitly. V0 adds no Isolate / Process support.

## 4. LogRecord / AppLogger

`LogRecord` gains `correlationId?`, `traceId?`, `parentTraceId?`,
`operationKind?`, `taskId?`. `AppLogger` injects them automatically from
`TraceContext`; callers must not copy correlation fields manually.

Example record:

```json
{
  "correlationId": "OBS-7Q2M-92KD",
  "traceId": "trace-...",
  "parentTraceId": "trace-...",
  "operationKind": "ragRetrieval",
  "module": "Retrieval",
  "message": "Retrieval completed",
  "data": { "hitCount": 5, "durationMs": 43 }
}
```

## 5. Privacy — hard invariant

OBS-1 logs only: run structure, stage, counts, status, duration,
errorType / fixed failureCode, tool name, callId, provider round number,
resultCount, file count, page count, artifact revision, route name.

OBS-1 must never log: user message bodies, Assistant bodies, System Prompts,
tool arguments, tool outputs, question/answer bodies, StudyPlan bodies,
PDF/DOCX/TXT bodies, RAG query, RAG passage/hit content, OCR text,
OCR raw response, provider request/response bodies, provider reasoning,
API keys, Authorization, tokens, Base64, absolute file paths, user file
names (outside the existing frozen safe basename UI scenario), or full
`Exception.toString()`. New OBS logs use whitelist structured metadata only;
the generic AppLogger `error`/`stackTrace` parameters must not receive
sensitive runtime objects.

## 6. Agent Turn root trace

`requestId` is unchanged and is never replaced by a traceId. Every
`startTurn` / `startTurnWithRetrieval` that actually enters `_runTurn`
creates one root operation: `operationKind = agentTurn`, new correlation,
new trace, `parentTraceId = null`. A future Agent started inside an existing
TraceContext may inherit correlation as a child, but V0 does not expand scope
for that. Ordinary UI Agent Turns are root operations in V0. One Agent Turn
has exactly one `diagnosticId`; success and failure belong to the same
correlation.

## 7. Agent structured timeline

Events (fixed `stage` field):

```text
turn_started
config_resolved
provider_round_started
provider_round_completed
tool_call_started
tool_call_completed
fallback_attempted
proposal_staged
study_plan_draft_staged
turn_completed
turn_failed
turn_cancelled
turn_timeout
```

Structured fields only, e.g. `providerRound = 3`,
`toolName = get_weak_questions`, `callId = <strict opaque token>`,
`durationMs = 43`, `status = success`. Tool names are normalized: known
registered tool names keep their canonical form, anything else becomes
`unknown_tool`. Call ids must match a strict opaque token pattern
(letters/digits/underscore/hyphen, ≤ 64); anything else becomes
`invalid_call_id`. Tool arguments, tool output and model response text are
never logged. Provider rounds and ordinary Tool Calls are events/spans of
the **same Agent trace**; no per-round traceId is created.

### AR-R1 Provider round terminal successor

`provider_round_completed` is now the single terminal stage for every attempted
round, including unsuccessful outcomes. The success path emits no second record.
Each `provider_round_started` is paired with exactly one terminal while the process
continues running (best-effort sink delivery remains §25). Attempt numbers increase
across failures and fallback; each terminal precedes the next round start. Forced
process death leaves an unmatched start, not evidence of a particular failure.

Required whitelist fields:

| Field | Frozen value / meaning |
|---|---|
| `providerRound` | Positive per-turn attempt number |
| `adapterIdentity` | Fixed enum: `deepseekResponses`, `unknown` for other/fake ports |
| `outcome` | `completed`, `toolCallsRequested`, `incomplete`, `failed`, `cancelled` |
| `durationMs` | Non-negative elapsed round duration |
| `terminalSeen` | Whether any Provider terminal was observed before settlement |
| `completeCallCount` | Complete calls observed, including calls withheld on failure |
| `visibleCharacterCount` | Unicode rune count of observed visible deltas for this round |
| `functionCallCount` | Compatibility alias of `completeCallCount` |
| `status` | `success` for successful outcomes; otherwise the outcome token |
| `failureBoundary`, `failureCode` | Optional fixed pair below; omitted on success and user cancellation |

| Boundary | Codes |
|---|---|
| `request_config` | `invalid_request`, `unsupported_model`, `unsupported_capability` |
| `provider` | `authentication`, `rate_limited`, `content_filtered` |
| `incomplete` | `max_output_tokens`, `incomplete_unknown` |
| `protocol` | `clean_eof_without_terminal`, `malformed_event`, `invalid_output_item`, `duplicate_terminal` |
| `transport` | `connect_timeout`, `stream_timeout`, `connection_lost`, `temporarily_unavailable` |
| `adapter` | `adapter_internal_error` |

Global round deadline is `failed / transport / stream_timeout`; a user cancellation
is `cancelled`. Cancellation/deadline/stream settlement race through a single
completion guard. A successful terminal alone does not permit dispatch: closure
must validate its tail. A later second terminal or illegal event fails without
executing collected calls. Late events after settlement never mutate text/calls or
emit another terminal. Adapter cleanup cannot delay round settlement indefinitely.

No usage object or usage counters are added in AR-R1. Terminal logs contain no
prompt, response text, arguments/results, reasoning, continuation, raw reason/body,
credentials, paths, submission keys, exception text or stack trace. Unknown reasons
map to fixed codes; adapter identity never comes from profile/provider input.
Rounds and fallback retain the same Agent trace/correlation, without per-round IDs.
Legacy fallback and public failure mapping remain owned by AGENT-FB and the
`agent-runtime-v1.md` compatibility bridge, not these diagnostic fields.

## 8. RAG retrieval child trace

`retrieve_file_content` runs the real retrieval inside a child trace:

```text
Agent trace A1
│
│└── RAG retrieval: same correlation, new trace R1, parentTraceId = A1,
│││││└── operationKind = ragRetrieval
```

The RAG trace records only `requestedFileCount`, `effectiveFileCount`,
`limit`, `hitCount`, `issueCount`, `durationMs`, `status`,
`failureCode`. Query, file display names, hit.content and SourceDocument
text are never logged. `RetrievalEgressGrant`, per-turn authorization and
`serializationAllowed` keep their original authority unchanged.

## 9. Agent tool limit diagnosis

`maxToolRounds = 4` and `maxLocalCalls = 8` are unchanged hard dispatch bounds.
The runtime distinguishes two budget exhaustion mechanisms:

1. **Exact legal exhaustion**: when a legal batch executes and brings
   `toolRoundsUsed == maxToolRounds (4)` or `localCallsUsed == maxLocalCalls (8)`,
   the real tool outputs are preserved and the tool phase is immediately closed
   (`toolPhaseClosed = true`, disabling function tools and native web search)
   before constructing the next Provider request. The next Provider request
   receives the real tool outputs and empty tools, allowing the Provider to
   produce its final prose answer from the gathered evidence.
2. **Oversized requested batch**: when an incoming tool batch would exceed the
   remaining tool budget (`localCallsUsed + requestedCalls > maxLocalCalls`),
   the runtime performs an atomic whole-batch zero-dispatch (0 tool execution,
   0 proposal mutation, 0 StudyPlan mutation), returning structured
   `tool_budget_insufficient` safe rejection outputs for all requested calls and
   closing the tool phase before the next prose-only round.

The internal trace distinguishes the exhausted budget reason:

```text
reason = tool_round_limit_exceeded
toolRoundsUsed = 4, maxToolRounds = 4
```

vs.

```text
reason = local_call_limit_exceeded
localCallsUsed == maxLocalCalls (8) or localCallsUsed + requestedCalls > maxLocalCalls (8)
```

## 10. Fallback observability

AGENT-FB safe fallback invariants are fully frozen. OBS-1 records only
`fallbackAttempted = true` and `fallbackReason = <fixed safe category>`
(provider failure taxonomy names). API keys, provider raw errors, request
bodies, response bodies and prompts are never logged. A fallback is the
**same Agent trace / same correlation** — never a new User Turn or root
trace.

## 11. Proposal / StudyPlan observability

W0 Proposal / StudyPlanDraft business authority is unchanged. Logs record
only outcomes (e.g. `outcome = staged`, `studyPlanOutcome = staged`).
IDs, when needed, are internal opaque IDs only. Preview bodies, questions,
answers and goal text are never logged.

## 12. Agent diagnostic id across the transient seam

`AgentTurnSession.diagnosticId` is stable from turn creation onward. The
Presentation never generates its own id; one Agent Turn has exactly one
diagnostic id; success/failure share the same correlation. The typed
terminal result additionally carries a safe `DiagnosticSummary`. The
diagnostic id is never written into Conversation Messages or the database.

## 13. Agent UI minimum activation

Existing safe error copy is unchanged. On Agent failure the UI appends
`诊断编号：OBS-XXXX-XXXX` plus a `复制诊断信息` action that copies a
whitelist summary (see §21). No diagnostic-center redesign.

## 14. Import correlation

Existing `taskId` / `traceId` / `attemptNumber` / `attemptToken` are all
preserved. New: `correlationId`, `parentTraceId?`,
`operationKind = importAttempt`. Correlation metadata is carried by the
existing diagnostics JSON / TaskManager metadata; **no database column or
table is added**.

## 15. Initial Import semantics

An independent ImportTask first execution:

```text
taskId = T1, correlationId = OBS-AAAA-BBBB, traceId = I1,
attemptNumber = 1, attemptToken = ...
```

Without an enclosing context `parentTraceId = null`. If a future Agent Tool
formally triggers an Import it inherits the Agent correlation and sets
`parentTraceId = Agent traceId`; current master has no Agent import tool and
OBS-1 does not add one.

## 16. Import retry semantics — mandatory

The frozen semantics stay intact: same `taskId`, `attemptNumber + 1`, new
`attemptToken`, new `traceId`, plus **same `correlationId`** and
`retry.parentTraceId = previous attempt traceId`:

```text
OBS-AAAA-BBBB
│
│├── I1 attempt 1
│
│└── I2 attempt 2
│││││└── parent = I1
```

Regression proof required: taskId unchanged, correlationId unchanged,
traceId changed, attemptToken changed, attemptNumber incremented.

## 17. Batch import

`batchId` (product batch identity) is never merged with correlationId. V0
gives every ImportTask its own correlationId. No new ImportBatch database
entity is created.

## 18. ParsedArtifact generation trace

`ParsedArtifactGenerationRouter.generate` runs the real generation inside
`operationKind = parsedArtifactGeneration`: same correlation / new trace /
parent = Agent trace when an enclosing operation exists; new correlation /
new trace / parent = null for a standalone File Detail trigger. Logs:
`parserRoute` (the effective route resolved by the frozen F1 plan; the
user's original `routeSelection` is resolved by the F1 port and is not
re-logged, because the frozen plan contract carries only `parserRoute`),
`artifactId` (opaque UUID), `durationMs`, `status`, fixed
errorType. SourceDocument content, file paths and user file names are never
logged.

## 19. OCR semantics

The OCR pipeline is not refactored. OCR batch / provider requests are
spans/events of the enclosing operation trace; no per-batch traceId is
created. The OCR abstractions have no safe injection point in V0, so the
upper layer logs `parserRoute = ocr_pdf / ocr_image`, status and duration
only. Provider bodies and OCR content are never logged.

## 20. Pipeline separation

OBS-1 unifies observability only. RAG ParsedArtifact → Question Import
authority, Import OCR → F1 authority, shared intermediate artifacts,
QuestionRegion redesign and shared OCR caches are all **forbidden** by this
task. Any future ParsedArtifact reuse must be a separate task based on real
OBS-1 timing/duplication evidence.

## 21. Diagnostic copy formatter

`lib/core/observability/diagnostic_summary.dart` defines
`DiagnosticSummary` (whitelist fields only) and
`DiagnosticSummaryFormatter` (fixed field names, total cap 2000; returns
null when unsafe, so callers simply hide the affordance). The diagnostic id
must strictly match the frozen OBS-1 correlation format
(`^OBS-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$` / `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`,
`DiagnosticSummaryFormatter.isValidDiagnosticId`); every other field (failure/status/lastTool/taskId/
traceId) must match the fixed safe token pattern
(`^[A-Za-z0-9_-]{1,64}$`) or the field is omitted. UI affordances
(diagnostic number, copy action) only appear after this strict validation
passes. No arbitrary `Map<String, dynamic>` copy path is allowed.

## 22. Import UI minimum activation

Task Center is not redesigned. Failed Imports get a minimal addition:
`诊断编号：OBS-XXXX-XXXX` plus `复制诊断信息`. Technical traceId stays
available in the diagnostics sheet; ordinary users see the correlation /
诊断编号 primarily.

## 23. No telemetry / no diagnostic database

V0 forbids: diagnostics tables, trace tables, OpenTelemetry backends, Sentry,
Datadog, Firebase Crashlytics integration, remote upload, cloud telemetry,
log-search screens, diagnostic history pages, ZIP diagnostic export, and
automatic support upload. Logs continue to use the current rotating local
log. Runtime schema stays **v22**; no v23.

## 24. No Agent retry persistence expansion

V0 adds no Conversation / Message / DB fields for Agent retry correlation.
Each new `startTurn()` may create a new root correlation. Only **Import
retry** must keep the same correlation. Agent retry cross-session lineage is
a separate future task.

## 25. Failure behavior

Observability failure (log sink write failure, formatter failure) never
changes business results. Trace/logging is best effort; Agent / Import /
RAG / ParsedArtifact remain the business authority. Log failure never
becomes an Agent Turn failure or an Import rollback.

## 26. Allowed production paths

```text
lib/core/observability/trace_context.dart
lib/core/observability/log_record.dart
lib/core/observability/app_logger.dart
lib/core/observability/diagnostic_summary.dart

lib/application/agent/agent_turn.dart
lib/application/agent/agent_runtime.dart

lib/services/import_pipeline/import_task_coordinator.dart
lib/services/task_manager.dart

lib/services/parsed_artifacts/parsed_artifact_generation_router.dart

lib/ui/assistant/conversation_controller.dart
lib/ui/assistant/assistant_screen.dart

lib/ui/pages/task_center_screen.dart
```

`lib/application/agent/agent_retrieval_tool.dart` was intentionally not
modified: the RAG child trace wraps the dispatcher call in the runtime,
where the grant/serialization authority already lives. Files listed but not
touched are not force-edited.

Application purity: the Application layer may import only the exact
pure-Dart observability seam — `log_record.dart`, `trace_context.dart`,
`log_writer.dart` and `diagnostic_summary.dart`. The platform-backed
logger (`app_logger.dart`: dart:io, Flutter foundation, path_provider) is
rejected by the architecture gate; `AppLogger` delegates record production
to the pure `LogWriter` seam, so Agent/Import logging behavior is
identical while `agent_runtime.dart` never transitively depends on
Flutter/path_provider/dart:io.

## 27. Verification summary (self-check evidence, not semantic approval)

- New focused suite `test/core/observability/unified_operation_trace_test.dart`
  covers TraceContext root/child/async/explicit/sibling contracts, logger
  auto-injection, sentinel absence and the formatter limits.
- `agent_runtime_test.dart` OBS group covers diagnostic id stability,
  same-trace provider rounds, tool-call whitelist logging, both tool-budget
  closure reasons (tool_round_limit_exceeded and local_call_limit_exceeded),
  fallback single-event same-trace, cancellation/timeout terminal events,
  StudyPlan outcome-only staging and the RAG child trace.
- `import_task_coordinator_test.dart` covers initial attempt identity,
  retry lineage (task/correlation unchanged; trace/token/attempt changed;
  parent = previous trace) and batch/correlation independence.
- `parsed_artifact_generation_router_test.dart` covers root and child
  generation traces and the no-content logging invariant.
- `conversation_controller_test.dart` and
  `task_center_diagnostics_widget_test.dart` cover the diagnostic number
  exposure and the whitelist-only copy for Agent and Import failures.
- Existing Agent/Import/RAG/ParsedArtifact/architecture suites still pass
  (regression items of the task package).

## 28. Excluded (frozen out of scope)

No runtime schema change (v22), no telemetry backend, no log upload, no
Conversation/Message correlation persistence, no MCP contract change, no
new Agent import tool, no F1/Question-Import pipeline merge, no
user-content/Tool-output/RAG-passage logging requirement, no OCR provider
refactor, no cross-boundary (Isolate/Process) propagation, no change to
Agent Safe Write authority, no change to RetrievalEgressGrant authority.

## 29. Post-OBS-1 extension note — DM-D5

OBS-1 v0 above remains historically CLOSED/FROZEN. DM-D5 later adds
`TraceOperationKind.destructiveMutation` as a successor extension for
user-authorized destructive Application commands. This value was not part of
the original OBS-1 v0 taxonomy and does not retroactively change its scope.

The successor keeps OBS-1 identity, propagation, privacy and best-effort
logging invariants. Its fixed lifecycle and safe field whitelist are frozen in
`dm-d5-destructive-presentation-and-tool-boundary.md`. It adds no telemetry,
schema, user-content logging, autonomous Agent authority or MCP tool.

## 30. Post-OBS-1 extension note — P6 supplemental-answer diagnostics

OBS-1 v0 above remains historically CLOSED/FROZEN. The P6 supplemental-answer
flow later adopts the OBS-1 correlation/trace identity as a successor
extension; this does not retroactively change OBS-1 v0 scope.

- Each direct acquisition (`addSourceAndStart`) and each activation
  (`startSession`) runs as an operation: a new correlation when none is
  supplied, a new trace, and `parentTraceId = null` unless a valid parent is
  supplied. An explicit OCR continuation (`continueWithOcr`) is a new
  operation that keeps the acquisition correlation and sets `parentTraceId`
  to the acquisition trace (the frozen Import retry lineage shape).
  Unrecognized correlation/trace values are replaced with fresh ones instead
  of being propagated.
- The P6 review session carries the identity of the operation that created
  it, and every review transition preserves it.
- User-facing P6 diagnostics display `诊断编号：OBS-XXXX-XXXX` and the
  technical `Trace ID：trace-...` on the review banner, the acquisition
  failure/notice surfaces, and the OCR confirmation. The affordances and the
  `复制诊断信息` action appear and copy only after the §21 strict validation
  passes (`DiagnosticSummaryFormatter.isValidDiagnosticId` for the diagnostic
  id; the fixed safe token pattern for the trace id); values that fail the
  validation are omitted.
- P6 diagnostic records stay structured whitelist metadata only (event,
  stage, status, counts, durations, fixed `failureCode`/`errorType`, opaque
  structural fragment ids). Question/answer content, file paths, provider
  bodies and raw exceptions are never logged; logging remains best effort.
- This extension adds no `TraceOperationKind` value, no schema change, no
  telemetry, and no P6 matching/write-authority change.
