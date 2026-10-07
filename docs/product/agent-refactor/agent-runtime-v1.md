# Agent Runtime v1

Status: **FROZEN target contract; AR-R1 Provider seam implemented in candidate,
pending final-head CI and independent review. Remaining runtime split is target-only.**

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
No AR-R2 capability executor or AR-R3 coordinator/transcript is implemented.

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
