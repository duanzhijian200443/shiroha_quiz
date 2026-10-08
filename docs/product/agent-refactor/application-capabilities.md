# Application Capability Kernel

Status: **FROZEN contract; AR-R2 and AR-R4 registration integration
COMPLETE / CLOSED.**

Authority/activation: [index](README.md). This document owns semantic capability,
permission/effect/receipt and adapter projection boundaries. Runtime, external
identity and Proposal lifecycle have their separate owners.

## 1. Typed semantic API

| Concept | Responsibility |
|---|---|
| CapabilityId<I, O> | Stable business capability identity with typed input/output binding |
| CapabilityDefinition<I, O> | Permission, permitted effects, authorization requirements, execution/replay semantics, handler |
| CapabilityHandler<I, O> | Business behavior through an Application service/port |
| CapabilityContext | Trusted principal/scope/grants, cancellation/deadline and safe diagnostic context |
| CapabilityResult<O> | Typed output/failure, execution receipt, optional semantic artifact reference |
| ExecutionReceipt | Actual execution status/effect and reconciliation identity |
| ApplicationCapabilityRegistry | Immutable definitions/bindings and duplicate validation |
| CapabilityExecutor | Admission, authorization, budget, invocation, receipt and safe observability |

These are semantic concepts, not frozen Dart signatures. Bindings must reject
type/name mismatches; no public arbitrary Map executor or generic mutation
command is allowed. The registry holds no active turn, session or Proposal state.

Application must not depend on MCP SDK, Provider DTOs, Flutter Widgets or
JSON-RPC/HTTP transport. It owns no tool name, description, JSON Schema or MCP
annotation. Generic Provider execution ports can be protocol-neutral; concrete
Provider wire representations remain adapter-owned.

Use explicit constructor dependencies. Cross-module collaboration may use typed
Application services/ports directly; not every internal call must go through the
registry. The kernel is not a service locator or a replacement for Dart typing.

## 2. Four independent dimensions

| Dimension | Values / meaning |
|---|---|
| Permission | READ, STAGE, COMMIT, DESTRUCTIVE |
| Effect | none, derived_cache, proposal_staged, formal_mutation |
| Execution status | not_started, completed, failed_without_effect, outcome_unknown |
| Egress | Local only or explicitly allowed data category and recipient |

Permissions do not imply one another. Retrieval is a capability category, not
a permission level. A READ retrieval may write a derived cache; it cannot
write formal learning data. MCP v0's six reads remain non-mutating.

`not_started` means handler execution did not begin. `failed_without_effect`
requires authoritative evidence of zero relevant effect. `outcome_unknown`
means the effect cannot yet be established and must not be encoded as `none`.
Receipts can report known effects alongside unknown completion. Cancellation,
timeout, lost response and output encoding failure do not prove zero effect.

Execution semantics state whether safe repetition is supported, whether durable
receipt reconciliation is required, or whether automatic repeat is forbidden.
Do not add contradictory independent retry/idempotency/replay boolean flags.

Receipt fields include an App-generated execution identity, capability id,
status, known effect, fixed failure category, relevant authorization/scope
references and a reconciliation reference appropriate to the capability's
execution semantics. Receipt is typed handler/transaction evidence, never
inferred from `ok`, JSON text or tool count.

STAGE permission alone does not imply durable staging or reconciliation:

- Retained W0 proposals and SPL StudyPlanDrafts remain transient. Their typed
  receipts identify the staged effect and refer to the owning in-memory
  lifecycle only while it remains available in the same App process. Restart
  invalidates those references; no durable staging receipt, cross-restart
  reconciliation or durable idempotency is promised or added by AR-R2. An
  unavailable transient reference does not authorize automatic repetition.
- Durable generated-question STAGE requires a stable reconciliation key and
  atomically persisted Proposal/receipt evidence under its dedicated contract.
  Lost response and restart reconcile through that durable authority with
  current authorization; a transient reference cannot satisfy this requirement.

Transient STAGE receipts do not replace W0 COMMIT or SPL adoption recovery.
Those dedicated commands retain their existing formal-write reconciliation
and concurrency authorities. Neither receipt lifetime permits an unknown
execution effect to be reported as `none`.

## 3. Invocation and authorization

Protocol shape validation -> typed input -> capability admission -> current
principal/grant/scope check -> budget -> handler -> typed result/receipt ->
final output egress check -> adapter encoding.

Authorize before querying preview-visible content. Do not query globally and
then filter scoped aggregates or results. Unauthorized and nonexistent targets
share a non-enumerating failure. Output serializers cannot silently broaden
data categories. Revocation before release blocks content release; already
released data cannot be recalled.

Context comes from the trusted entrypoint, not model arguments or `clientInfo`.
READ/STAGE external routes cannot invoke a UI approval command. Natural language,
client-side tool approval, an artifact reference or a trace id is not COMMIT
authority. Dedicated Application commands own every formal mutation.

Initial budgets retain call/round/time/output bounds. Weighted tool costs and
a general budget DSL are deferred. Counters measure budgets, not side effects.

## 4. Separate projections

AgentToolProjection owns tool name, description, Provider-facing input/output
schemas, typed parsing/encoding, exposure and optional prompt guidance.
McpCapabilityProjection owns MCP names, schemas, annotations, result encoding
and protocol compatibility. Either binds to the same typed capability.

Exposure is adapter-specific; authorization is Application-specific. Hidden
tools must still reject direct unauthorized calls. Enabled projections are
deterministic and duplicates fail before serving requests.

Optional artifacts are semantic kind/reference/revision values, not Widgets,
approval tokens or JSON preview parsing rules. A module registers its presenter
and dedicated action handler. Missing presenters show safe unavailability and
no generic approve button. Runtime never switches on Proposal/tool names.

## 5. Migration and acceptance

AR-R2 migrates existing study/retrieval/W0/SPL dispatch to typed handlers with
existing I/O/error/scope parity. Legacy JSON Dispatchers delegate to the typed
path, not the reverse; they do not reconstruct receipts from JSON. Registry
duplicates/type mismatch, direct-call authorization, output egress, resource
bounds and encoding-after-effect failures require deterministic tests.

Receipt acceptance must cover W0/SPL staging with known `proposal_staged`
effect, same-process lifecycle reconciliation, restart invalidation and zero
durable staging writes. Lost/failed output encoding must preserve known effects
without inventing a durable receipt or enabling automatic repeat. Durable
generated STAGE reconciliation is accepted with its own persistence stage.

AR-R3 moves loop/artifact consumers. AR-R7 alone changes fallback policy.
New capability work adds a semantic definition/handler, optional projections
and tests; it must not require Round Engine, Provider or unrelated controller
flags to change. Future Proposal kinds still own dedicated commands and
persistence, never a generic `commit(Map)`.

## 6. AR-R2 Dart implementation and accepted AR-R4 registration

`lib/application/capabilities/capability.dart` implements the eight frozen
semantic concepts as immutable concrete values, enums, one explicit registry and
one executor. `CapabilityHandler<I, O>` wraps a typed Application function;
`CapabilityEvidence<O>` is owning-service evidence before release. No transport,
JSON Schema, Provider DTO, UI approval or service locator participates in binding.
Registry construction freezes registration order and validates duplicate business
identities and input/output/handler binding. A typed lookup with a wrong type
fails immediately; there is no `execute(String, Map)` API.

The four dimensions are independent: permission, permitted/known effect, execution
status and release authorization. `knownEffect == null` means unknown, never
`none`. App-generated UUID execution identities and typed receipts contain only
capability/status/effect/fixed failure, trusted principal/scope and opaque source/
turn/recipient references plus an optional transient reconciliation reference.
They contain no arguments, preview, question text, RAG content or output. They
are neither persisted nor logged and add no OBS taxonomy or receipt database.

| Stable id | Permission | Permitted effects | Success evidence | Execution semantics |
|---|---|---|---|---|
| `list_question_banks` | READ | none | none | repeatableRead |
| `get_study_overview` | READ | none | none | repeatableRead |
| `get_due_review_summary` | READ | none | none | repeatableRead |
| `search_questions` | READ | none | none | repeatableRead |
| `get_question_detail` | READ | none | none | repeatableRead |
| `get_weak_questions` | READ | none | none | repeatableRead |
| `retrieve_file_content` | READ | none, derived_cache | transaction-confirmed none or derived_cache; otherwise unknown | repeatableRead |
| `propose_missing_answer` | STAGE | none, proposal_staged | proposal_staged | transientStage |
| `propose_study_plan` | STAGE | none, proposal_staged | proposal_staged | transientStage |

Only READ/STAGE handlers exist. `repeatableRead` requires a fresh invocation of
admission, principal/capability/permission, current scope/grant and final egress.
`transientStage` forbids automatic repeats; the executor implements no retry or
replay mechanism. Manual calls retain the owning services' existing semantic
deduplication. Neither semantics changes AGENT-FB barriers.

Trusted entrypoints construct `CapabilityContext`; parsed inputs cannot supply
principal, permission, scope, grant or recipient. The current principal enum has
Built-in Agent, MCP v0 study and denied callers. A frozen typed capability allowlist,
explicit independent permissions and bound scope are checked in Application;
optional current-authorization and existing budget/cancellation/deadline evidence
are checked before handler entry and before release. Rejection before entry is
`not_started`; owning-service zero-effect results are `failed_without_effect`.
Timeout/cancellation/unknown throws after entry are `outcome_unknown`, retaining
any already-confirmed effect. Interrupted/failed final egress or encoding strips
output while retaining completed handler evidence and reconciliation identity.

The retained six Study tools use the existing global local-user StudyQueryService
semantics. Their projection contexts explicitly authorize global READ; the
executor rejects a context claiming Project-restricted Study reads before any
query, because no Project-filtered Study query port exists in this stage. This
does not alter the prior Agent/MCP global study behavior. W0/SPL continue to pass
the trusted ConversationScope to their owning admission services before any
preview-visible read; missing and unauthorized targets retain non-enumeration.

Study inputs are dedicated immutable values and outputs are the existing typed
Study DTOs. `MissingAnswerInput` contains only the bounded target/answer payload;
W0 admission and AgentWriteProposalService still own staging. The Agent projection
retains W0's exact pre-activation encoded-size gate. `ProposeStudyPlanInput` goes
through StudyPlanDraftService normalization/admission and transient lifecycle;
there is no adopt/commit capability. Successful staging receipts refer privately
to the owning service instance plus opaque artifact id. Typed reconciliation
reads the current same-instance lifecycle; another service instance, including
restart/recomposition, rejects that reference even if an id is reused. This is
not a durable receipt, approval token or formal-commit/adoption recovery.

Retrieval keeps model inputs to query/file ids/limit. The context carries the
original RetrievalEgressGrant, exact turn/Conversation/User/Provider recipient,
current file snapshot and mandatory serializationAllowed callback. The grant's
Application owner is now `application/retrieval/retrieval_egress_grant.dart`,
with the previous Agent path retained as a compatibility export. The executor
checks recipient and approved/current files plus the live serializationAllowed
authorization gate before retrieval. A revoked or unavailable current grant,
scope or recipient is rejected before handler entry with `not_started` and
`none`, including direct executor calls. The same live gate is checked again
before projection encoding. Retrieval service access denial has its own fixed
typed failure category, preserving legacy `accessDenied` business encoding;
executor/grant denial remains `access_denied`. Runtime's subsequent
pre-Provider release check remains unchanged. SqliteRetrievalIndexRepository
reports unchanged versus derived-cache commit only after its existing transaction
settles; no SQL/schema/bounds change is introduced. A legacy index adapter that
provides no transaction evidence yields unknown effect rather than fabricated
none. Revoked release cannot erase a committed cache effect.

`AgentStudyToolProjection`, `AgentRetrievalToolProjection`,
`AgentWriteProposalToolProjection` and `AgentStudyPlanToolProjection` own parsing
and legacy encoding; catalogs retain all nine original schemas/descriptions.
`McpCapabilityProjection` binds only the same six typed Study definitions and
preserves names, schemas, annotations and exact v0 envelopes/stdio errors.
The four Dispatchers remain thin compatibility facades; none is called by a
handler. AR-R4 contributions register the same nine definitions into the one
registry/executor and build immutable Agent projections over it. The independent
MCP v0 process composes only Study and consumes the same six typed handlers.

Focused kernel/authorization/receipt/cache/encoding/projection tests and retained
compatibility suites run in hard-failing standing PR contracts. Runtime tests
exercise a real study facade/executor/handler chain and preserve exact budget
closure, no fallback after READ and terminal persistence. AR-R3 now consumes
receipt-bearing Dispatcher methods in a bounded ToolExecutor and retains receipt
evidence in transient atomic transcript groups; the Kernel, permissions, effects,
registry, W0/SPL lifecycle and MCP semantics are unchanged. AR-R4 source module
registration is accepted under `module-system.md`; external
authority/IPC and AR-R7 READ continuation remain unimplemented. AR-R5A is an
implementation candidate: GeneratedQuestion contributes an internal typed READ
with current local authorization and no Agent/MCP/UI projection. Durable stage,
review flush and formal approve/reject use dedicated trusted Application commands,
not R2 transient STAGE effects. The COMMIT boundary remains explicit local
confirmation with exact revision/selection. Schema v32 and B0 retained Proposal
validation are owned globally; package v2 and existing recovery commands remain.
