# N0 Post-P5 Canonical Roadmap

Status: **Canonical post-P5 stage ordering**.

R1–R8 core refactor and P5 typed manual answer repair are complete. This roadmap supersedes the old near-term sequence `P5 -> P6 -> P7` as the default implementation order. Historical plans remain useful as provenance but must not be treated as current scheduling authority.

## Current-stage status amendment

The canonical sequence below records the original post-P5 dependency and stage
decisions. Delivery has since advanced some independent read-side stages ahead
of that historical order. The following stages are now complete:

```text
F0
F0.1
J0
T0
M0 / M0.1
U1-R1
U1-P0
C0
A0
```

The current-stage amendment is:

```text
C0 Conversation Foundation — COMPLETE
A0 Built-in Agent v0 — COMPLETE
W0 Safe Agent Write — COMPLETE
F1-P0 Parsed Artifact canonical contract — COMPLETE
F1-D0 Parsed Artifact domain/codec — COMPLETE
F1-D1 v20 parsed artifact persistence — COMPLETE
F1-A1 Parsed Artifact lifecycle orchestration — COMPLETE
F1-I1 Deterministic generation adapter — COMPLETE
F1-I2 Explicit OCR generation — COMPLETE
F1-CL Parsed Artifact closure — COMPLETE
F1 Parsed Artifact Lifecycle — COMPLETE
P6 Supplemental-answer matching — NOT STARTED
P7 AI answer candidates — NOT STARTED
RAG Project retrieval enhancement — NOT STARTED
Current runtime schema — v20
```

`B0 = DEFERRED, not cancelled`. C0 accepts the bounded risk of persisting User
Messages before a `.shiroha` backup/export package exists.

This amendment updates current scheduling status without rewriting the
historical sequence as if it had originally been delivered in this order.
`docs/product/u1-agent-first-ia-freeze.md` is the current authority for U1
Presentation and Navigation semantics; retained U0 domain/lifecycle semantics
remain valid as described there.
`docs/product/A0 Built-in Agent v0.md` is the current authority for the bounded
A0 runtime/product contract.
`docs/product/W0 Safe Agent Write.md` is the focused authority for the current
W0 proposal, approval, scope, replay and typed-write contract.

## 1. Product/architecture direction

Shiroha now grows around three stable layers:

```text
Typed Learning Core
  QuestionDraftV2 / RichContent / ReviewSession / PersistedQuestion
        |
        v
Learning Asset Layer
  LibraryFile / ParsedArtifact / Project
        |
        v
Intelligence & Access Layer
  Application Tools / Built-in Agent / MCP / Approval Write
```

The goal is expansion around the typed core, not another repository-wide refactor.

## 2. Canonical stage sequence

| Stage | Goal | Primary deliverable | Schema expectation |
|---|---|---|---|
| **N0** | Architecture contract synchronization | `ARCHITECTURE.md`, ADRs, this roadmap, stale-baseline markers | unchanged (v15) |
| **U0** | Information-architecture design freeze | Navigation/entry-point contract only; no fake Project data model | unchanged |
| **F0** | File Library foundation | `LibraryFile`, managed storage, ingestion lifecycle, metadata | additive migration candidate |
| **J0-P0** | Bank identity decision | Decide `bank_name` compatibility vs additive stable `bankId` registry | decision only unless separately approved |
| **J0** | Project v0 | Optional Project plus file/bank references; no file duplication | additive migration candidate |
| **U1** | Information-architecture migration | Replace the primary Subject-library navigation role with Project-aware UI while retaining compatibility surfaces | normally unchanged beyond F0/J0 |
| **B0** | Backup/export foundation | Versioned `.shiroha` package covering DB + managed user assets | unchanged unless package metadata needs additive support |
| **C0** | Conversation foundation | Persistent Conversation/User Message history and Conversation-level File context | additive v19 |
| **T0** | Application Tool Layer | Reusable query/service facade shared by UI, Agent and MCP | unchanged |
| **M0** | MCP v0 | Implement the existing exactly-six-tool `READ_ONLY` contract | unchanged |
| **A0** | Built-in Agent v0 | Supported configured provider + optional provider-native Web + local read tools | unchanged |
| **W0** | Safe Agent write | Draft/Stage -> Review -> explicit user approval -> application command -> typed persistence | preferably unchanged |
| **F1** | Parsed Artifact lifecycle | Reparse/version/cache identity needed by P6/Agent/RAG; split into F1-P0..F1-CL sub-stages | additive v20 implemented in F1-D1 |
| **P6** | Supplemental-answer matching | Produce supplemental `AnswerCandidate` values from files; do not invent a new write path | preferably unchanged |
| **P7** | AI answer candidates | Produce AI `AnswerCandidate` values; confirmation uses the same answer command boundary | unchanged |
| **RAG** | Project retrieval enhancement | full-text/chunk/embedding/hybrid retrieval behind File/Project/Agent concepts | later |
| **Future** | Platform/ecosystem expansion | Windows workbench, HarmonyOS, LAN/sync, MCP v1+ | later |

F1 is intentionally not a hard prerequisite for J0. F0 can establish original-file identity/storage first; deeper artifact persistence is introduced when a concrete use case (reparse, P6, Agent file analysis or RAG) requires it.

## 3. N0 completion contract

N0 is documentation/contract work only. It must not change production Dart code, schema, packages or runtime behavior.

N0 is complete when:

- repository-wide layering in `ARCHITECTURE.md` matches the post-R8 code direction;
- `AGENTS.md` no longer tells new work to preserve the obsolete `UI -> Service -> Repository` rule;
- accepted asset and Agent/MCP boundaries are captured in ADRs;
- R0-era baseline documents are clearly marked historical when they contain obsolete current-state facts;
- Bank identity is explicitly recorded as a J0 prerequisite decision, not silently solved during N0.

## 4. Stage invariants

### F0 — File Library

Must establish:

```text
external file
  -> FileIngestionService / equivalent application boundary
  -> app-managed storage
  -> LibraryFile metadata + fileId
```

Rules:

- original bytes are long-lived user assets;
- SQLite does not store the original file as a blob;
- durable identity uses `fileId` + managed storage key/relative identity, not absolute paths;
- importing a file into a question bank is one possible action, not the file's lifecycle owner;
- deleting/replacing a ParsedArtifact does not delete confirmed questions;
- no full artifact-history framework is required in F0.

F0.1 adds flat, manual File Library Folder classification through additive v18
metadata/relation tables. A file has at most one Folder; unclassified is the
absence of a relation; Folder and Project relations remain independent.

### J0 — Project

Project is an optional long-lived learning context, not a mandatory folder.

Recommended relation shape:

```text
Project
  <- project_files -> LibraryFile
  <- project_banks -> QuestionBank identity
```

Rules:

- one file may be referenced by multiple Projects without duplicating bytes;
- unassigned assets remain valid (`projectId = null` / Unclassified UX);
- existing subject/folder data is retained until a separately authorized migration;
- do not add `library_files.project_id` as the only ownership relation.

### J0-P0 — Bank identity decision

Before persisting Project-to-bank relations, explicitly choose one bounded strategy:

A. use current `bank_name` as a temporary compatibility relation and record migration debt; or

B. add a stable `bank_registry`/`bankId` identity while keeping current `bank_name` compatibility projection.

Choose B only if it can remain additive and does not reopen QuestionList/Practice/WrongBook typed architecture. Otherwise choose A and defer the identity migration.

### T0 — Application Tool Layer

Do not start by wrapping repositories in MCP handlers.

Implement reusable application semantics first, e.g. query/command services or a tool facade. Presentation adapters should receive safe DTOs, not repository maps.

### M0 — MCP v0

M0 implements `docs/architecture/mcp-v0-contract.md` as written. v0 stays exactly six read-only tools:

- `list_question_banks`;
- `get_study_overview`;
- `get_due_review_summary`;
- `search_questions`;
- `get_question_detail`;
- `get_weak_questions`.

Do not add File/Project tools to `mcp.study.v0`. They belong in a later contract/version.

### C0 — Conversation foundation

C0 adds a dedicated `ConversationService`, v19 Conversation/Message/File
relations, and real history navigation. New Conversation remains transient
until the first valid User Message; first persistence and all later append or
attachment recency mutations are transactional. Message ordering uses an
explicit per-conversation sequence.

Learning Space deletion preserves history through `SET NULL` without changing
the scope to Global. File context is independent of Project and Folder
membership and never owns file bytes. Bank attachment remains deferred because
the compatibility `bank_name` is not stable durable identity.

C0 does not add Provider, Agent, Web, RAG, MCP tools, or a fake Assistant reply.
It exposes only the additive Assistant-message seam needed by A0.

### A0 — Built-in Agent

A0 is complete. The Agent calls the same application query/tool layer as
UI/MCP, but does not route through MCP transport.

A0 closes the following bounded read-side behavior:

```text
conversation
+ provider-native Web (when enabled and supported)
+ Shiroha read tools
```

The current provider/model allowlist and runtime limits remain implementation
parameters rather than canonical roadmap commitments. The complete current A0
contract and accepted limitations are recorded in
`docs/product/A0 Built-in Agent v0.md`.

A0 does not include destructive writes or a generic Agent framework.

### W0 — Safe write

W0 is COMPLETE. Its first capability is frozen as a Built-in Agent proposal to
fill a missing answer on an existing typed question. The Agent may stage only
`null -> structurally non-empty` answer proposals; existing manual typed-answer
repair retains its replace and clear semantics through the shared typed
persistence authority.

Permission model:

```text
READ        autonomous inside granted scope
DRAFT/STAGE proposal only
COMMIT      explicit user approval
DESTRUCTIVE extra approval or unavailable
```

Agent/MCP never call SQLite directly. Formal question creation/answer mutation must converge on typed application commands and existing typed persistence semantics.

Proposal staging must complete scope/target admission before loading or
returning preview-visible target content. Learning Space staging uses the
current Project and current name-based `project_banks` relation as compatibility
authority. Unauthorized and nonexistent targets share a safe non-enumerating
failure boundary.

COMMIT requires an explicit Presentation approval bound to one exact transient
proposal. One dedicated data-layer transaction must revalidate the source
Conversation/User Message, scope, current Project relation, target bank, full
typed-draft compare-and-set and formal typed write. Application must not compose
independent repository checks and call them atomic. W0 adds no schema migration
and does not expand MCP v0.

Deterministic proposal fingerprints deduplicate semantic replay. Each source
User turn has at most one active/pending write proposal; a different payload
creates a new identity and supersedes the older active proposal.

W0 is COMPLETE. The W0-CL canonical closure checkpoint confirmed focused
verification, semantic review and no unresolved P0/P1/P2 findings, and did not
automatically activate F1, P6 or P7.

See `docs/product/W0 Safe Agent Write.md`.

### F1 — Parsed Artifact lifecycle

F1-P0 is COMPLETE and wrote canonical documents only; it implemented no
production code, tests, or schema migration. F1-D0 (ParsedArtifact domain and
codecs), F1-D1 (v20 parsed artifact persistence), and F1-A1 (Application
lifecycle seam and orchestration) are also COMPLETE. F1-I1 (deterministic
production generation adapter for `pdf_text`/`docx_text`/`txt`/`markdown`)
is COMPLETE and reuses the existing parser truth. F1-I2 (explicit
`ocr_pdf`/`ocr_image` ParsedArtifact generation through
`OcrDocumentClient -> OcrSourceDocumentAdapter`) is COMPLETE with offline/mock
testing only; `auto` never triggers OCR, and the question OCR pipeline is not
part of artifact generation. F1-CL is COMPLETE: focused verification PASS,
final full semantic review APPROVE, closure repair merged via PR #65, and no
open P0/P1/P2/P3 findings. F1 Parsed Artifact Lifecycle v0 is COMPLETE. P6
and later stages are NOT STARTED. There is no UI, Agent, or MCP activation.

Frozen stage graph:

```text
F1-P0 -> F1-D0 -> F1-D1 -> F1-A1 -> F1-I1 -> F1-I2 -> F1-CL
```

Schema expectation: the current runtime schema is v20; F1-D1 implemented the
approved additive v20 (two new tables) without modifying earlier tables.

Governance:

- all F1 stages are `SERIAL`; a checkpoint must complete and freeze before the
  next stage starts, and later stages never auto-activate;
- F1-CL is the closure point: focused verification followed by the final full
  semantic review;
- mid-stage review escalation is allowed only for a truly unresolved Class C
  decision or still-unfrozen schema/CAS semantics;
- there is no F1-U; UI entry/redesign remains deferred.

See `docs/architecture/f1-parsed-artifact-lifecycle.md`.

### P6/P7 — Answer candidate producers

The long-term shared shape is:

```text
Manual / Supplemental file / AI
              |
              v
       AnswerCandidate
              |
              v
       Preview / Review
              |
        user confirmation
              |
              v
 AnswerRepairCommandService (or equivalent application command)
              |
              v
      typed answer mutation
```

P6/P7 must not each create their own database-write protocol.

## 5. Explicit non-goals for this roadmap

Until separately authorized:

- no R9-style global refactor;
- no physical retirement of legitimate V1 compatibility rows/readers;
- no mandatory Project assignment for files/banks;
- no original file blobs in SQLite;
- no durable absolute paths as file identity;
- no built-in Agent -> MCP self-call;
- no MCP v0 scope expansion;
- no autonomous destructive Agent writes;
- no user-facing standalone "RAG knowledge base" product object;
- no simultaneous F0 + J0 + Agent + UI + schema mega-stage.

## 6. Documentation authority

- `ARCHITECTURE.md` is the current repository-wide boundary.
- ADRs under `docs/architecture/adr-*` record accepted post-P5 decisions.
- This file is the canonical stage ordering.
- `mcp-v0-contract.md` remains the authority for MCP v0 semantics.
- `docs/product/W0 Safe Agent Write.md` is the focused W0 write-boundary
  authority.
- R7/R8 focused documents remain the authority for frozen typed persistence/consumer invariants.
- `docs/architecture/f1-parsed-artifact-lifecycle.md` is the focused F1
  authority.
- R0-era files marked historical describe the migration origin, not the current runtime state.
