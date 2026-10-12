# Application Capability Kernel

Status: **FROZEN contract; AR-R2 and AR-R4 registration integration
COMPLETE / CLOSED; P7 unpublished external integration accepted in merged PR #256;
P8 offline Host dispatch accepted in merged PR #258.**

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

The unpublished P3 generated external Application/Data entry now supplies typed
`CapabilityEvidence<ExternalStageSummary>` from the owning SQLite transaction
and current-authority reconciliation, as specified in GeneratedQuestion §11.
Its acknowledgement has only Proposal id/original submission key. It does not
register a general CapabilityExecutor/Host operation or mint `ExecutionReceipt`
with a forged `mcpStudyV0` principal. Existing `ExecutionReceipt`, W0/SPL transient
references and execution semantics remain unchanged. General external principal
and projection integration is added only by the unpublished P7 amendment in
section 7 below, without Host activation.

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
P7 adds a separate durable-key reference under section 7 below.
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
principal, permission, scope, grant or recipient. The R2 principal enum had
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
Host/IPC and AR-R7 READ continuation remain unimplemented. AR-R5A is an
implementation candidate: GeneratedQuestion contributes an internal typed READ
with current local authorization and no Agent/MCP/UI projection. Durable stage,
review flush and formal approve/reject use dedicated trusted Application commands,
not R2 transient STAGE effects. The COMMIT boundary remains explicit local
confirmation with exact revision/selection. Schema v32 and B0 retained Proposal
validation are owned globally; package v2 and existing recovery commands remain.

## 7. P7 trusted external Kernel integration (accepted unpublished scope)

P7 adds an Application-only `ExternalCapabilityGateway`, using the existing
typed registry, executor, results, effects and receipts. It registers an explicit
external allowlist rather than copying Built-in definitions. No production Host,
MCP, transport, Provider, credential adapter or module route is activated.

`ExternalExecutionContext` and its authorization metadata have private
constructors. Trusted App composition first supplies the P3-P6 owning services
sharing exactly one `ExternalRuntimeAdmission`. Admission uses the authenticated,
management-bound Session and an immutable current Grant snapshot. Each execution
Context binds the exact ExternalSession, Principal/Profile, runtime generation,
Grant revision, exact bank/Project and selected-file scope (or bounded current
scopes for target selection/reconciliation), categories, owning-Profile recipient
and a finite expiry no later than its owning READ/STAGE Context. Discovery and
key reconciliation have at most fifteen minutes. There is no wildcard grant.

The public legacy `CapabilityContext` constructor rejects the external enum
value, even when supplied arbitrary allowlists or callbacks. Only the private
Kernel construction path can bind an external call after Session admission.
The gateway checks that the execution Context belongs to this composition and
the exact invoking Session. Another Session cannot reuse that execution Context.
Existing P4-P6 READ Context/Question/File/Passage/cursor references retain their
Principal + generation + current authorization/lifecycle semantics: another
valid Session for the same Principal may use them, including when minting a fresh
P7 execution Context. P3 STAGE Contexts remain exact-Session bound.

| Typed external capability | Permission | Permitted effect | Semantics |
|---|---|---|---|
| list targets / create READ Context | READ | none | repeatableRead |
| search questions / get question detail | READ | none | repeatableRead |
| list file selections / create file Context / get passage | READ | none | repeatableRead |
| retrieve file content | READ | none, derived_cache | repeatableRead |
| stage generated questions / reconcile original key | STAGE | none, proposal_staged | durableStage |

Each definition delegates to its existing owning service. P7 adds neither a
business writer nor business permission logic. The Kernel checks its explicit
allowlist/permission and current bound Grant revision before handler entry.
Owning services still perform scope-first Data access, current independent
category/recipient checks, resource admission, strict projection, output-size
checks and final release. Kernel final release delegates again to those same
Question/File/Proposal ports after result construction; it cannot authorize
output solely from an earlier snapshot. Metadata results (file selections,
Context tokens) are revalidated at the current authorization, relationship and
verified Artifact-tuple level, never by reloading document bodies; full F1
payload re-verification applies only to references that release passage
content. Withheld new READ references are removed.

READ's single two-second maximum applies across the complete P7 call, including
admission and final release, using a trusted timer and the existing cooperative
control. Caller cancellation/deadline is forwarded. Existing shared READ
16/4 slots, Registry capacities and response limits remain unchanged. STAGE
retains P3's 16-global/4-per-Session pending-only guard and transaction authority.
The gateway has a bounded pending-only guard across pre-authorization, handler
and release, using the owning 16/4 ceilings (READ per Principal, STAGE per
Session). Interrupted underlying authorization and owning work keep that slot
until actual settlement; draining may conservatively wait for the composition's
owning services to become idle. No completed key/Receipt journal is retained.
Interrupted owning work keeps its slot until real settlement; Kernel does not
retry, reclaim the owning slot or promise SQLite preemption.

For P7 status, Handler means the Kernel definition's handler. Denial before that
boundary is not_started/none. An owning-service pre-entry rejection after the
Kernel wrapper entered proves failed_without_effect/none, rather than claiming
the Kernel never entered. Owning zero-effect rollback remains authoritative.
Interrupted or unconfirmed work is outcome_unknown, with null meaning unknown
effect. P3's outcome_unknown with confirmed proposal_staged remains unchanged.
RAG evidence confirms derived_cache only from owning transaction evidence;
unconfirmed builds do not become none. An interruption or loss of final output
preserves any already-confirmed status/effect while stripping output.

`durableStage` adds no automatic repeat. `DurableStageReconciliationReference`
is typed correlation containing the authenticated Profile/original submission
key, separate from the unchanged transient W0/SPL reference. The existing
Proposal/SubmissionKey owner alone establishes durable STAGE facts, including
absence remaining outcome_unknown. Receipt and authorization metadata remain
transient, local Application evidence with no decoder, encoder, log or second
persistence table. Fresh authenticated reconciliation rechecks current authority
and may use the original key across restart without an old execution Context.
No formal local COMMIT Receipt is returned to the external surface.
App composition closes and drains the gateway and owning services before B0
swap/runtime replacement; closing never prematurely frees pending work.

The distinct fixed P3/P4-P6 failure enums map one-to-one to external/generated
Kernel categories; cancellation, deadline and response loss stay distinct.
Existing Built-in/MCP v0 definitions, receipts, transient reconciliation and
six-tool projection remain unchanged. SQLite v34 and B0 package v2 stay fixed.
P7 does not accept AR-R6A, lift HOST_STABILITY_HALT or activate MCP vNext.

The R4 retained-source gate keeps its original Kernel baseline hash. Its P7
compatibility projection removes only exact enumerated source amendments,
including their external-only control paths; no region is ignored and no
replacement Kernel hash is accepted. Negative regressions prove that changing
either the external admission amendment or retained legacy Kernel source fails
the corresponding check. Runtime/Provider/MCP/storage hashes stay unchanged.

## 8. P8 offline Host dispatch (accepted unpublished scope)

External boundary §3 owns the trusted startup/entry/shutdown contract of
`LocalHostDispatchCore`. It reuses exactly the ten P7 typed definitions, original
results and Receipts and owning P3-P6 services. No Kernel source amendment,
business permission, string/Map execution path, new persistence, encoder,
transport or default composition is added. Host pre-admission denials use the
existing Kernel `reject` with a denied Principal and no authorization metadata;
after admission, P7 retains evidence and final authorization authority.
Interrupted caller return never substitutes for owning settlement during drain.
This offline foundation does not activate the external Host or MCP vNext.

P9's infrastructure Envelope/Codec is owned by external boundary §7. Its output
is untrusted text with no capability, identity, Context or Receipt projection.
It adds no Application dependency, execution authority or wire serialization of
the local transient Receipt/authorization objects.

P10's accepted offline infrastructure projection (merged PR #261) is owned by external boundary
§8. It authenticates and obtains a current P8 binding before decoding its fixed
business schema, then maps only these ten typed inputs. Execution Contexts remain
trusted P8 composition parameters, never JSON authority. P7 final release still
owns all READ/STAGE egress. Only the declared operation whitelist is encoded;
Receipt/authorization objects remain local. Projection or encoding failure
retains the original result/effect evidence and never repeats STAGE. P3-P9
source/contracts and Built-in/MCP v0 semantics are unchanged.

P11's accepted first-party policy management (merged PR #262) is owned by external
boundary §9.
Its local Application views and bounded metadata queries are not registered
Capabilities and are never injected into Agent/MCP/Host projections. They mint
no Principal, Session, execution Context, Receipt or runtime Enablement. Saving
READ/STAGE/Scope/Egress configures non-secret rules only; pairing and actual
external access remain disabled pending separate production acceptance.

P12's offline trust coordinator candidate is owned by external boundary §10.
It supplies existing P0 Sessions through opaque Profile registration, original
pairing/proof and explicit finite enablement; P4 bindings are generation-bound.
P8/P7 per-call and final current Grant/Scope/Revision/Egress checks remain
mandatory. No new capability definition, Kernel amendment, business writer or
production credential/Host/MCP composition is introduced.
