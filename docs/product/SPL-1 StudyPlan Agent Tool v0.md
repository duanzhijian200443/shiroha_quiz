# SPL-1 StudyPlan Agent Tool v0

Status: **Canonical SPL-1 StudyPlan Agent Tool v0 product/application contract.**

Current stage status:

```text
SPL-1-P0 StudyPlan Agent Tool v0 contract freeze — COMPLETE
SPL-1-D0 Domain + transient draft + planning/candidate read seams — COMPLETE
SPL-1-D1 v22 persistence + durable CAS commands — NOT STARTED
SPL-1-I0 Agent planning tool + draft/adoption Presentation — NOT STARTED
SPL-1-U0 Today / 特训 + dynamic selection + Practice seam — NOT STARTED
SPL-1-V0 Focused acceptance — NOT STARTED
SPL-1-CL Closure — NOT STARTED
SPL-1 StudyPlan Agent Tool v0 — IN PROGRESS (not COMPLETE / not CLOSED)
```

Runtime schema remains **v21**; v22 exists only as the future SPL-1-D1 additive
migration and is NOT implemented or active.

## 1. Authority and scope

This document is the focused authority for the SPL-1 StudyPlan Agent Tool v0
product/application contract. Repository-wide dependency and permission
boundaries remain authoritative in `ARCHITECTURE.md` and
`docs/architecture/adr-003-agent-mcp-and-write-boundary.md`.

Authority boundaries (unchanged by SPL-1):

- UI Finalization remains the authority for IA / Presentation / Navigation only;
- W0 remains the authority for W0 only;
- A0 remains the authority for the Agent runtime / read behavior;
- MCP v0 remains the exactly-six read-only tool contract;
- the review/FSRS semantics remain the authority for due/scheduling state.

SPL-1 v0 adds one capability: a Built-in-Agent-planned, user-adopted, durable
Active StudyPlan consumed by Today / 特训 dynamic selection. It does not add a
plan tool to MCP v0, does not rewrite or generalize W0, does not change
FSRS/review semantics, and does not change Project/File lifecycles.

## 2. Core product flow (frozen)

```text
real learning state
→ Built-in Agent planning
→ propose_study_plan
→ Application validation
→ transient StudyPlanDraft
→ deterministic preview
→ explicit user adoption
→ durable ActiveStudyPlan
→ Today / 特训 dynamic selection
```

The Agent proposes. The Agent never formally adopts or persists plan state.
Natural chat text such as "好的", "可以", "Yes", "就这样" is NOT adoption. Only an
explicit Presentation action bound to the exact draftId constitutes adoption.
The Agent must never claim a plan was saved before Application confirms durable
adoption.

## 3. Naming

New canonical types:

- `StudyPlanDraft`;
- `ActiveStudyPlan`;
- `StudyPlanPriority`.

Existing `StudyPlanBank`, `StudyPlanFolderGroup`, `StudyPlanBankCatalog`, and
`PlanConfigScreen` remain legacy/current quota/catalog terminology (bank
statistics, daily quota, current-bank selection, estimated days remaining).
SPL-1 does NOT rename or repurpose them, and no new capability reuses their
classes. The new Agent-generated plan capability is not a re-use or mutation of
the legacy catalog.

## 4. Active StudyPlan model

v0: exactly **one** `ActiveStudyPlan` globally (product-level singleton).
One-bank plan only.

Durable fields:

- `planId`
- `bankName`
- `goal?` (bounded)
- `dailyTarget`
- `priority`
- `horizonDays?`
- `sourceConversationId?`
- `sourceUserMessageId?`
- `adoptedAt`

No durable Project ownership. No persisted question-id list. No provider
payload or reasoning.

## 5. Horizon

The canonical field is `horizonDays` (not `targetDays`), 1..90 when present.
It is planning guidance only (preview / progress).

The derived state `horizonElapsed` (`adoptedAt + horizonDays < now`) is
advisory only:

- no automatic expiry;
- no auto-delete;
- no auto-stop.

The plan stays Active until explicit Stop or explicit Replace.

## 6. Daily target

`ActiveStudyPlan.dailyTarget` is the authority **only** for 特训 session
sizing.

The legacy `${bankName}_daily_quota` setting remains the authority for existing
ordinary / PlanConfig behavior. No cross-write, no fallback coupling, no
retirement of PlanConfig in SPL-1.

## 7. FSRS / review boundary

StudyPlan is a strategy/selection layer. FSRS / current Review state remains
the authority for:

- due state;
- review scheduling;
- interval / stability / difficulty state;
- post-answer review mutation.

Plan adoption changes ZERO review state. Plan selection changes ZERO review
state. `masteryReached` is advisory and is never a scheduling override.

### Mastery is NOT terminal

- `masteryReached = (masteredCount == questionCount)` is derived
  advisory/progress state only.
- state=3 / mastered questions:
  - may still later become due;
  - may still be selected through due semantics;
  - if `lapses > 0` may remain weak candidates;
  - are NOT automatically removed merely because state == 3.
- `ActiveStudyPlan` remains active until explicit Stop or explicit Replace.
- No automatic completion or deactivation.

## 8. Dynamic selection

No persisted question IDs. At session start the Application queries live
candidates against current FSRS/review state.

Producer-neutral `StudyPlanCandidate` may carry only bounded selection fields
such as:

```text
storageId
bankName
due
nextReviewAt
lapses
difficulty
classification
```

Never `Question`, `PersistedQuestion`, SQL rows, or repository maps across the
Application selection boundary.

Pools:

- **due**: `next_review_time <= now`; order `next_review_time ASC, storageId ASC`;
- **weak**: `lapses > 0`; order `lapses DESC, difficulty DESC, storageId ASC`;
- **new**: canonical never-reviewed / state=0 semantics; order `storageId ASC`.

A candidate may belong to multiple pools. Selected `storageId` dedup is
mandatory.

Priority:

- `due_first`: due → weak → new;
- `weak_first`: weak → due → new;
- `new_first`: new → due → weak;
- `balanced`: round-robin due → weak → new, skipping duplicates and exhausted
  pools, repeating until `dailyTarget` reached or no candidates remain.

Do NOT exclude mastered / state=3 questions merely because they are mastered,
if current FSRS state makes them due or current weak semantics makes them weak.
`masteryReached` does not empty the queue by itself.

Selection is recomputed fresh at each session start from live review state; no
AI/provider call is required when Today / 特训 opens.

## 9. Practice integration boundary

Future U0 flow:

```text
Application StudyPlan selection
→ stable selected storage identities / safe DTO
→ narrow materialization adapter
→ existing Practice interaction
```

No second PracticePage, no second review writer, no second scheduler. Future
materialization must preserve selected order and use the existing typed/legacy
question decoding authority. Nothing is implemented in P0.

## 10. Agent planning tool

Built-in-Agent-only tool: `propose_study_plan`, in a separate
`AgentStudyPlanToolCatalog`.

It is NOT added to:

- the `AgentStudyToolCatalog` six read tools;
- the MCP v0 six tools.

Model controls only bounded fields:

- `bank_name`
- `goal?` (bounded)
- `daily_target?`
- `priority?`
- `horizon_days?`

Runtime controls:

- `sourceConversationId`
- `sourceMessageId`
- `sourceScope`
- `draftId`
- timestamps
- lifecycle state
- authority context

No model-supplied scope, identity, or adoption state. The model cannot spoof
Conversation identity, User Message identity, scope/project authority, or
adoption state.

### Canonical input bounds and defaults (frozen)

- `bank_name`: trimmed non-empty, 1..200 characters.
- `goal`: optional; when present, non-empty after normalization, maximum 120
  characters, no control-character payload.
- `daily_target`: integer 1..200, default 40.
- `priority`: exactly one of `balanced`, `due_first`, `weak_first`,
  `new_first`, default `balanced`.
- `horizon_days`: optional integer 1..90.

Optional values MUST be normalized by the Application before `StudyPlanDraft`
construction. Therefore omitted `daily_target` is canonically equal to an
explicit `daily_target = 40`, and omitted `priority` is canonically equal to an
explicit `priority = "balanced"`. The `StudyPlanDraft` fingerprint MUST use the
normalized canonical values, never raw provider omission/presence. With all
other fields equal, these two tool calls produce the same semantic plan inputs
for fingerprint purposes:

```json
{ "bank_name": "Math" }
{ "bank_name": "Math", "daily_target": 40, "priority": "balanced" }
```

Provider omission is never part of plan identity.

## 11. Scope admission

The draft binds `sourceScope` (runtime-injected; the model cannot provide or
override it).

- Global scope: any otherwise valid real bank.
- LearningSpace(projectId): the bank must currently belong to
  `project_banks(projectId, bankName)` before preview-visible staging succeeds.

Unauthorized and nonexistent targets use bounded non-enumerating failure
semantics.

At adoption the Application revalidates the source Conversation / User Message /
role / scope plus the scope-specific bank authorization (see §14).

After adoption the plan is NOT Project-owned. Later Project membership changes
do not auto-delete the plan. Bank disappearance makes `planUnavailable` until
user Stop/Replace.

## 12. Draft lifecycle

`StudyPlanDraft` is transient only (no table; disappears on restart).

- One active/pending draft per source User turn.
- Fingerprint uses the normalized canonical values (after Application
  normalization, §10) and includes: source conversation, source user message,
  source scope/project identity, operation, bank, goal, dailyTarget, priority,
  horizonDays. Raw provider omission/presence is never part of the fingerprint.
- Same semantic fingerprint → reuse the draft identity and its current outcome.
- Different payload → new draft supersedes the old pending draft.
- Passive dismissal: no state mutation.
- Committed drafts are never reactivated by provider replay.

### Transient lifecycle authority (atomic gate)

The transient `StudyPlanDraft` lifecycle has its own authority: one atomic
in-memory lifecycle gate. It is authoritative for transient draft state only;
it is NOT the durable concurrency authority (that is the SQLite
transaction-level CAS, §13). Neither authority substitutes for the other.

All draft transitions pass through the same gate:

- adoption entry: `pending -> committing` (atomic);
- explicit Reject: `pending -> rejected` (same gate);
- supersession by a revised proposal: `pending -> superseded` (same gate).

Exactly one competing transition may win.

- **If adoption wins first** (`pending -> committing`): a later Reject cannot
  transition the draft to rejected and supersession cannot transition it to
  superseded; neither may cancel or interfere with the formal adoption
  transaction; both observe/report the current committing or final outcome. A
  revised proposal for the same source User turn must NOT cancel or replace a
  draft already in committing state, and no second active/pending draft is
  created for that source turn while the earlier draft is committing; a bounded
  non-mutating response is acceptable (exact internal representation is an
  implementation detail).
- **If Reject wins first** (`pending -> rejected`): a later adoption starts
  ZERO durable writes and observes the terminal rejected outcome.
- **If supersession wins first** (`pending -> superseded`): a later adoption
  starts ZERO durable writes and observes the terminal superseded outcome.

Only after `pending -> committing` wins may the Application enter the formal
durable adoption transaction. SQLite then independently enforces the
`expectedActivePlanId` CAS, source-turn revalidation, scope admission, and bank
admission (§13, §14). Persistence success maps `committing -> committed`. The
exact safe mapping for a transaction that makes zero durable change (stale
scope / stale ActivePlan / bounded persistence failure) is a D1 implementation
decision, but it MUST NOT allow a rejected or superseded draft to commit.

## 13. Durable CAS (adoption / replacement / stop)

Two separate authorities are frozen; neither substitutes for the other:

- **A. Transient `StudyPlanDraft` lifecycle authority** — one atomic in-memory
  lifecycle gate (§12). It is authoritative for transient draft state only
  (the `pending` / `committing` / `rejected` / `superseded` transitions).
- **B. Durable `ActiveStudyPlan` concurrency authority** — the SQLite
  transaction-level compare-and-set. It is authoritative for durable plan
  state only.

The formal durable adoption transaction may start only after the transient
gate's `pending -> committing` transition has won (§12).

Adopt command binds:

- `draftId`
- `expectedActivePlanId`
- `replacementConfirmed` when applicable

Rules:

- **No-active adoption**: `expectedActivePlanId = null`; the transaction
  requires that no current ActivePlan row exists.
- **Replacement**: the explicit replacement confirmation is bound to the exact
  old `planId` the user saw; the transaction requires
  `currentPlanId == expectedActivePlanId`.
- **Stop**: binds the exact active `planId`; `DELETE` by the exact expected id;
  affected rows == 1.

Two competing replacements from the same baseline: at most one succeeds. Stop
vs replacement from the same baseline: at most one succeeds. No
last-writer-wins with both operations reporting committed.

## 14. Adoption revalidation (source-turn validity)

At formal adoption, one transaction revalidates:

1. source Conversation exists;
2. source User Message exists;
3. Message belongs to source Conversation;
4. Message role is User;
5. current Conversation scope structurally equals draft `sourceScope`;
6. Global → target bank still exists;
7. LearningSpace(projectId) → current `project_banks(projectId, bankName)`
   still authorizes;
8. durable ActivePlan CAS precondition passes (§13).

Any failure → zero formal mutation. This does NOT make `ActiveStudyPlan`
Project-owned. After successful adoption the `ActiveStudyPlan` is still the
global/product-level singleton.

## 15. Persistence

- `StudyPlanDraft`: transient, no table.
- `ActiveStudyPlan`: durable.

Future D1 migration: schema v21 → v22, additive only. Likely one singleton
`study_plans` table. No modification of existing tables. No opaque Settings
JSON workaround. No provider payload persistence.

Exact DDL is deferred to D1, but durable constraints — including non-null plan
identity, e.g. `plan_id TEXT PRIMARY KEY NOT NULL` — must enforce this
canonical contract. Runtime schema remains v21 until D1 implements the
migration.

## 16. Privacy / provider egress

The Provider may use the existing six safe Agent read tools.

Raw planning-context results, `StudyPlanCandidate` query results, SQL rows, and
repository maps remain Application-internal.

The `propose_study_plan` tool may return only explicitly whitelisted bounded
deterministic preview fields. Those returned fields ARE provider-visible
tool-result content — for example bounded aggregate values such as
`questionCount`, `masteredCount`, `dueCount`, `weakCount`, only when already
admitted and required for the preview.

Never expose:

- SQL;
- raw DB;
- repository maps;
- credentials;
- file bytes;
- absolute paths;
- raw provider data;
- review-log dumps;
- answers/explanations not required by planning;
- hidden reasoning;
- chain-of-thought;
- `reasoning_content`.

Plan persistence stores no provider request/response, no `reasoning_content`,
no chain-of-thought, no credentials, no debug payloads.

## 17. Failure taxonomy and derived states

Bounded Application failure categories (never raw SQLite/provider error text):

```text
invalidPlan
notFound
targetUnavailable
staleScope
staleActivePlan
alreadyActive
superseded
persistenceFailed
temporarilyUnavailable
internalError
```

Derived non-failure states:

- `noCandidates` — 特训 shows an empty "今日暂无任务" style state; no fabricated
  counts;
- `planUnavailable` — plan bank disappeared; remains until user Stop/Replace;
- `horizonElapsed` — advisory only;
- `masteryReached` — advisory only.

None of `horizonElapsed` / `masteryReached` automatically deactivates the plan.

## 18. Today / 特训

No ActiveStudyPlan: retain the current real dependency-not-ready state; no fake
plan data.

ActiveStudyPlan: future U0 may show plan summary, current workload, 开始特训,
停止计划. No Today redesign, no new primary navigation destination, no fake
plan, no provider call when opening 特训.

## 19. Non-goals (frozen)

- automatic daily replanning;
- autonomous background Agent;
- revision history;
- sync/cloud;
- MCP planning;
- RAG planning;
- Memory;
- calendar;
- notifications;
- FSRS replacement;
- automatic adoption;
- automatic plan modification;
- generic workflow engine;
- generic W0 rewrite;
- bank registry migration;
- Project redesign;
- whole Today redesign;
- persisted provider reasoning;
- multi-bank v0 plans.

## 20. Substage graph

```text
SPL-1-P0 Contract freeze (this document)
→ SPL-1-D0 Domain + transient draft + planning/candidate read seams
→ SPL-1-D1 v22 persistence + durable CAS commands
→ SPL-1-I0 Agent planning tool + draft/adoption Presentation
→ SPL-1-U0 Today / 特训 + dynamic selection + Practice seam
→ SPL-1-V0 Focused acceptance
→ SPL-1-CL Closure
```

All stages are SERIAL; each checkpoint must complete and freeze before the next
starts, and later stages never auto-activate.

## 21. Documentation authority

- `ARCHITECTURE.md` — repository-wide boundary;
- `docs/product/SPL-1 StudyPlan Agent Tool v0.md` — this document, the focused
  SPL-1 authority;
- `docs/architecture/n0-post-p5-roadmap.md` — stage ordering and status;
- `docs/product/W0 Safe Agent Write.md` — W0 authority (unchanged);
- `docs/product/A0 Built-in Agent v0.md` — A0 authority (unchanged);
- `docs/architecture/mcp-v0-contract.md` — MCP v0 authority (unchanged);
- `docs/product/ui-finalization-ia-freeze.md` — UI Finalization IA authority
  (unchanged).
