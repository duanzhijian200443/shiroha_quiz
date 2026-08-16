# OBS-1 Unified Operation Trace v0

Status: **CLOSED / FROZEN** (accepted in the same PR that implemented it;
initial state was `IN PROGRESS`).

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
  "correlationId": "OBS-7Q2M-91KD",
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

`maxToolRounds = 4` and `maxLocalCalls = 8` are unchanged. The public
failure `AgentTurnFailure.toolLimitExceeded` is unchanged (Presentation
contract does not drift). The internal trace distinguishes:

```text
failureCode = tool_round_limit_exceeded
toolRoundsUsed = 5, maxToolRounds = 4
```

vs.

```text
failureCode = local_call_limit_exceeded
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
(`^OBS-[A-Z0-9]{4}-[A-Z0-9]{4}$`, `DiagnosticSummaryFormatter
.isValidDiagnosticId`); every other field (failure/status/lastTool/taskId/
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
  same-trace provider rounds, tool-call whitelist logging, both overflow
  failureCodes, fallback single-event same-trace, cancellation/timeout
  terminal events, StudyPlan outcome-only staging and the RAG child trace.
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
