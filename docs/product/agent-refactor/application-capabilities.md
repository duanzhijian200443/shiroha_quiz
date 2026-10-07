# Application Capability Kernel

Status: **FROZEN target contract; not implemented by AR-R0.**

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
references and, for STAGE, durable reconciliation reference. Receipt is typed
handler/transaction evidence, never inferred from `ok`, JSON text or tool count.

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

AR-R3 moves loop/artifact consumers. AR-R7 alone changes fallback policy.
New capability work adds a semantic definition/handler, optional projections
and tests; it must not require Round Engine, Provider or unrelated controller
flags to change. Future Proposal kinds still own dedicated commands and
persistence, never a generic `commit(Map)`.
