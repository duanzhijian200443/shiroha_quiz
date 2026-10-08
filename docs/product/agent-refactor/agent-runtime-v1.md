# Agent Runtime v1

Status: **FROZEN contract; AR-R1/AR-R2/AR-R3 COMPLETE / CLOSED; AR-R4 projection
registration integration COMPLETE / CLOSED; AR-R5A storage COMPLETE / CLOSED.**

Authority/activation: [index](README.md). Current A0 and AGENT-FB behavior remains
active. Provider protocol details, business capabilities and Proposal lifecycle
are not owned by the generic loop.

## 1. Runtime responsibility split

| Component | Owns |
|---|---|
| AgentTurnCoordinator | Turn ownership, orchestration and cancellation lifecycle |
| ProviderRoundGateway | Provider invocation, stream normalization and complete outcome |
| AgentRoundEngine | Successful model round -> complete calls -> results -> next round |
| AgentToolExecutor | Agent projection -> Application CapabilityExecutor |
| AgentTurnPolicy | Shared turn budget, retry/fallback decisions |
| AgentTurnFinalizer | One final visible Assistant append and ambiguous-persistence recovery |
| AgentTurnTranscript | Bounded transient canonical history with execution receipts |

These need not each have an interface. Keep the public Runtime facade during
migration. Preserve a persisted latest User target, same-target retry without
duplicate User append, one active turn per Conversation, scope unavailability,
already-completed reply recovery and one persisted final Assistant message.
No durable in-flight turn resume is introduced.

## 2. Provider outcome and failure boundary

ProviderRoundOutcome is Completed, ToolCallsRequested, Incomplete, Failed or
Cancelled. Visible deltas may stream; complete tool calls become executable
only after a successful complete terminal. Incomplete/failed fragments are
not tools and not a completed answer. Adapter knows its protocol, not Shiroha
Question/StudyPlan/Proposal. Runtime knows normalized outcomes, not DeepSeek SSE.

| Failure boundary | Safe codes |
|---|---|
| Request/config | invalid_request, unsupported_model, unsupported_capability |
| Provider | authentication, rate_limited, content_filtered |
| Incomplete reason | max_output_tokens, incomplete_unknown |
| Protocol | clean_eof_without_terminal, malformed_event, invalid_output_item, duplicate_terminal |
| Transport | connect_timeout, stream_timeout, connection_lost, temporarily_unavailable |
| Adapter implementation | adapter_internal_error |

These codes contain no raw reason/body/exception. Unknown Provider reasons use
fixed categories. Application, tool, authorization, persistence and finalization
failures retain separate taxonomies; they are not recoverable Provider failures.

AR-R1 introduces detailed failure plus a legacy classification bridge. Even when
a parser-swallowed stream timeout becomes accurately classified, eligibility
and barriers remain identical to legacy AGENT-FB. Do not increase output tokens
to conceal incomplete output. Provider/model compatibility remains explicit.

### AR-R1 scoped implementation

`agent_provider.dart` owns fixed `ProviderFailureBoundary` / `ProviderFailureCode`
and the explicit legacy exception bridge. `provider_round.dart` owns the concrete
round result and stream settlement. The existing Runtime invokes that seam;
turn policy, persistence, dispatch and context remain in their existing owners.
AR-R2 now retains all four JSON Dispatcher facades while delegating through
Agent projections to the typed Application CapabilityExecutor and handlers.
AR-R3 now consumes their receipt-bearing methods behind AgentToolExecutor. The
public facade and legacy `dispatch()` remain. Provider protocol settlement,
persistence/recovery rules, numerical bounds and fallback policy are unchanged.

DeepSeek interprets SSE and request/body transport phases. An explicit successful
terminal and validated stream closure are required before complete calls become
executable. A second terminal or non-ignorable event after terminal fails the
round. Incomplete/failed calls remain diagnostic counts only. Hidden reasoning
remains solely inside existing adapter-private same-provider continuation, never
in normalized result content, Conversation or OBS metadata.

Legacy `AgentProviderException.failure` stays the turn/fallback mapping authority.
Body stream timeout/connection loss retain legacy `malformedResponse`; request
timeout retains `timeout`. Parser EOF retains `malformedResponse`, while a generic
Provider-port EOF retains `incompleteResponse`. Untyped adapter exceptions retain
`internalError` turn mapping and remain fallback-ineligible. `content_filtered`
uses the prior `temporarilyUnavailable` public/fallback mapping while exposing a
more precise diagnostic code. All existing eligible classes and barriers remain
unchanged. No READ continuation, usage-object persistence, output-token tuning or
new Provider is introduced.

## 3. Transient canonical transcript

Transcript contains bounded persisted visible history, current User message,
successful complete Assistant visible text, canonical complete ToolCalls and
paired ToolResults/ExecutionReceipts. It never enters Conversation DB or logs.
The settled final answer is separate terminal evidence, outside the budget for
subsequent Provider context. Recording it cannot reject an otherwise valid final
answer or prevent finalization, including when the current User fills the history
byte budget or the history message limit is one.

Failed/incomplete round calls, fragments and partial text are not replayable.
An execution with unknown outcome stays in a reconciliation ledger, not replay.
A completed tool business-error result may pair with its complete call. Keep
necessary scope/egress/receipt references as transient side metadata, not model
authority. Reauthorize before replay or result release.

Retain existing history/turn bounds initially. Prune only whole messages or
call/result groups; never truncate JSON or orphan a call. If the minimum safe
group cannot fit, terminate with a safe budget failure rather than omit authority.

Provider-private continuation is an adapter-only same-Provider protocol
optimization, not the sole canonical history. It never becomes durable,
cross-Provider state or visible history; hidden reasoning/raw Provider bodies
are not copied into the transcript, diagnostics or Conversation storage.

### AR-R3 Dart implementation candidate

`ShirohaAgentRuntime` retains constructor/start/session APIs and only forwards
starts to `AgentTurnCoordinator`. Concrete owners share a Runtime library via
Dart `part` files so existing private turn state and failure values do not require
new public ports, factories or a DI framework. The standalone transcript library
has no repository, SQLite, MCP, observability or private-continuation dependency.

- Coordinator owns active-Conversation locking, mutation lease, root trace,
  event/result shutdown, cancellation and the single global timeout timer.
- Policy owns the one running budget clock, deadline, counters, phase-closure
  decisions and the unchanged AGENT-FB eligibility/barriers. Kernel receipt
  `deadlineExceeded` uses the same shared deadline and maps to turn timeout even
  when it settles before Coordinator's timer callback; status/effect stay intact.
- Engine owns Provider compatibility, round progression, completed-round text,
  duplicate-call validation, current outputs and same-Provider continuation.
- Gateway invokes R1 `normalizeProviderRound()` without interpreting SSE or
  changing failure classes. Only settled successful text reaches the transcript.
- ToolExecutor freezes an explicit projection binding table; all business calls
  use `dispatchWithReceipt()` -> projection -> CapabilityExecutor. Tool names do
  not choose business authority in Runtime/Engine. STAGE barriers use receipt
  effect; existing preview events continue to use the legacy encoded preview.
- Finalizer owns latest-User/already-completed validation, the process-local
  pending final text and unchanged ambiguous-append recovery. Target/history
  validation keeps the existing configuration/compatibility ordering.

`AgentTurnTranscript` composes the exact identities selected by the existing
`AgentHistoryBuilder`; its persisted-history selection algorithm is unchanged.
Typed `AgentTranscriptVisibleMessage` entries carry visible content and identify
the preserved current User. An indivisible `AgentToolGroup` carries one validated
complete call, matching result, real Application receipt and optional trusted
`AgentToolEgressMetadata` (recipient, scope, grant). Business errors with resolved
receipt evidence remain groups. `outcomeUnknown` records only call identity and
receipt in `AgentUnresolvedExecution`; it terminates the turn through existing
cancel/timeout/internal-error mapping, without Provider continuation, fallback or
automatic repeat. Failed/incomplete round fragments never enter either groups or
visible transcript content.

Bounds retain 40 whole canonical units / 64 KiB of context payload, 16 KiB per
tool argument and 64 KiB per result. Persisted history initially exactly matches
the existing 40-message selection. On append, prune the oldest whole visible
message or complete ToolGroup, preserving the current User and entire newly
required batch. Never truncate JSON or discard a receipt alone. If the minimum
required batch plus target cannot fit, fail atomically with existing public
`historyLimitExceeded`; no new public failure enum or summary is introduced.
The individual 64 KiB tool-result bound is not a promise that every valid result
fits the aggregate 64 KiB canonical context: target, complete call and result all
consume that context budget. Likewise, individually valid results in one batch
may collectively exceed it. AR-R3's frozen minimum-context rule deliberately
fails closed after execution in these cases, rather than retaining the legacy
unbounded current-tool envelope. No next Provider request or automatic repeat is
issued; JSON is never truncated, and the batch is never partially published.
Default-bound regressions cover a near-64-KiB READ result, a two-result batch,
RAG's 24,000-byte hit payload plus a large target, and prior W0/SPL staging.
Confirmed completed cache/STAGE receipts additionally remain in bounded transient
`completedEffects` side metadata (at most the turn's eight actual calls). This
keeps effects/reconciliation truthful even if a whole group is pruned or a required
payload cannot fit after execution. It holds no call arguments or tool result,
is never Provider context, and cannot replay/retry/restore a staged artifact.

Provider requests retain the fixed initial `AgentHistoryBuilder` persisted-visible
history envelope throughout the turn, independent of canonical whole-unit
pruning. The retained envelope is itself bounded by the original history limits;
it is transient and cleared with the transcript. Requests also retain
actual current-round outputs with the existing same-Provider continuation
optimization. Completed current-turn visible text remains canonical evidence
without duplicating text already held by that same-Provider protocol state. Continuation
is an Engine-local variable, never a transcript field; fallback clears it and
current outputs and cannot reuse tool groups. RAG retains pre-query and release
checks in R2, plus Runtime's live check immediately before sending current
retrieval outputs. Release denial replaces the entire canonical result while
preserving the receipt's known cache effect. Transcript metadata never grants
release, commit, approval or adoption authority.
`AgentTurnTranscriptSnapshot.finalAssistant` holds the complete settled final
visible answer as a typed terminal message, separate from bounded `entries`.
Intermediate successful round text still participates in canonical context
bounds. The final answer follows the existing Provider output-token/persistence
rules; terminal evidence adds no new result-size limit or durable write.

The mutable transcript is cleared at turn shutdown. `AgentTurnSession.transcript`
provides an immutable process-only inspection snapshot (live during execution,
terminal evidence owned only by that session). Runtime stores no completed turn
history, and nothing encodes/persists/logs this snapshot. Receipts and W0/SPL
reconciliation remain tied to their existing process-local service lifecycles;
restart invalidates them. Only the final visible Assistant is appended to the
Conversation. No in-flight resume, schema/B0 change, memory, compression, external Host or
READ continuation is implemented. AR-R4 source registration now supplies a
frozen Agent surface at the Runtime facade; the legacy Dispatcher constructor
remains a compatibility bridge. Generic lifecycle/round/transcript/fallback
semantics remain this accepted AR-R3 authority; `module-system.md` owns composition.

## 4. Fallback migration barrier and later policy

AR-R1 through AR-R6 preserve every current AGENT-FB barrier, eligible class,
at-most-once switch, shared budget and final-message persistence rule.
Tool counters remain policy inputs until the separately accepted policy change.

AR-R7 adds opt-in bounded READ continuation using receipts and the transcript:

- Configured fallback, at most once, no switch back, no third attempt.
- Not cancelled/globally timed out; remaining shared budget.
- No visible Assistant text or native Web progress.
- No STAGE/formal mutation/unknown execution outcome.
- Only complete READ call/result groups with acceptable effects.
- Reauthorize and verify target Provider representation/capabilities.
- Reuse results rather than rerun completed READ handlers.
- No Provider-private continuation transfer; one final Assistant append.

Derived cache is not a formal mutation but must be known in receipts. First
AR-R7 still prohibits file retrieval grant cross-Provider continuation: existing
RAG grants are recipient-bound. A future recipient change needs separate
explicit egress authorization. Policy can be disabled independently of MCP.

## 5. Observability target

OBS-1 remains identity/redaction/event-schema authority. AR-R1 must add one
safe round terminal event, including round number, adapter identity, outcome,
fixed failure boundary/code, elapsed time, terminal-seen and complete-call /
visible-character / available safe usage counts. Preserve existing success
events where needed without double terminal recording.

Each started round has exactly one finished event while the process remains
running, including throw, deadline and cancellation races. Forced process death
cannot guarantee a terminal log; an unmatched start is absence of terminal
evidence, not proof of a specific Provider failure.

No prompt, body, tool input/output, answer, file content, private continuation,
reasoning, path, credential/token/handle/submission key or unsafe exception is
logged. Cross-process correlation is explicit and validated, never authorization.

## 6. First implementation acceptance

AR-R1 is limited to Provider seam/adapter/parser, local round normalization and
OBS/tests/docs. No tool wiring, Proposal, MCP, IA, fallback or token-tuning change.
Fixtures cover successful text/tools, incomplete/max tokens/unknown reason,
clean EOF, malformed event, invalid item, duplicate terminal, request/stream
timeout, connection loss, cancel/timeout/terminal race and hidden-reasoning
isolation. Every start has one terminal; incomplete tools never execute.

Preserve the full legacy fallback matrix, including two completed READ rounds
followed by Provider failure: still no fallback, now with detailed evidence.
AR-R3 requires turn/persistence/recovery parity and transcript bounds/pairs.
AR-R7 requires separate allowed/denied replay and recipient-safety tests.
These stages must not be collapsed into one PR.
