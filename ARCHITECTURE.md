# Shiroha Quiz Architecture Contract

Status: **Canonical architecture contract after R1–R8 and P5**.

This file describes the current dependency direction and the boundaries that all new post-P5 work must preserve. Historical R0/R1 migration documents remain useful as design provenance, but they are not current-state authority.

## Reading guide

Read sections 1–3 and 7–8 for the shared architecture baseline, then the
sections and focused contracts that own the affected capability. A reference in
an unrelated section does not require loading that contract. This guide changes
reading order only; all existing contracts and historical amendments remain valid.

| Task boundary | Relevant sections |
|---|---|
| Typed content / rendering / imports | 3–4 and the focused RichContent contracts |
| File Library / artifacts / retrieval | 4 and its focused lifecycle/RAG contracts |
| Conversation / Agent / MCP / write approval | 5–6; Agent refactor target index below |
| Credentials / provider configuration | 9 |
| Supplemental / single-question AI answers | 10–11 and Answer Completion v0 |
| Navigation / Practice / Today | 12 and applicable product contracts |
| StudyPlan | 13 |
| Runtime data locations | 14 |
| Review repair / photo answers | 15–16 |
| TrainingContent / StudyActivity / TaskCenter | `docs/product/home-training-v3.md` canonical contract |

Stage order and durable capability state belong to the focused canonical contract
and roadmap; Git/PR/CI/Reviewer own exact execution history. The stage
summaries below retain their recorded context and do not replace those sources.

## 1. Canonical dependency direction

```text
Flutter UI ───────────────┐
Built-in Agent Adapter ───┼──> Application Layer ──> Domain Layer
External MCP Adapter ─────┘
                                  ^
                                  |
                    Data / Infrastructure Adapters
                    - Repositories / SQLite
                    - Managed file storage
                    - OCR / AI / Web providers
```

`main.dart` and other explicit composition-root code may know concrete implementations in order to assemble the dependency graph. Feature code must not use the composition root as a service locator.

### Migration rule

The repository still contains pre-N0 screens/services that directly call repositories. N0 does **not** trigger a repository-wide rewrite. However, new post-P5 modules must not add new presentation-to-repository dependencies. When an existing direct dependency is touched for a new cross-surface capability, prefer introducing the smallest application service/facade needed by that capability.

## 2. Layer responsibilities

### Presentation adapters

Includes Flutter UI, the built-in Agent adapter, and the external MCP adapter.

Responsibilities:

- render or translate user/protocol interaction;
- collect bounded input;
- invoke application use cases/tools;
- project safe application results to UI/protocol DTOs.

Forbidden:

- direct SQLite / `DatabaseHelper` access;
- raw SQL or raw database-row handling;
- joining `question_v2_payloads` in presentation code;
- making a new post-P5 feature depend directly on a repository;
- treating provider DTOs or file-system paths as domain truth.

### Application layer

Owns use-case orchestration and cross-surface semantics, including:

- query services;
- command services;
- application tool facade used by Agent/MCP/UI;
- Project-context resolution;
- Draft / Review / Approval flows;
- business validation that spans repositories or external ports.

Application code may use repositories and infrastructure ports, but must not expose raw database maps, SQL, provider payloads, or absolute paths to presentation adapters.

### Domain layer

Owns stable business meaning and value objects, including the typed learning core:

- `SourceDocument` / `SourcePart` / `SourceRef`;
- `QuestionRegion` boundaries and typed assembly concepts;
- `RichContent` and typed content nodes;
- `QuestionDraftV2` and typed answers/options;
- `ReviewSession` semantics;
- `PersistedQuestion` typed/legacy union semantics.
- `Conversation`, `ConversationScope`, and ordered `ConversationMessage`
  semantics.

Domain code must not import Flutter widgets, SQLite, `DatabaseHelper`, provider DTOs, HTTP clients, or file-system APIs.

### Data / infrastructure

Owns physical persistence and external integration:

- SQLite schema, transactions, migrations and row mapping;
- repositories;
- managed file storage;
- OCR/AI/Web provider clients and DTO adaptation.

Persistence formats and provider formats are implementation details, not public application contracts.

## 3. Frozen typed-learning-core invariants

R1–R8 and P5 are closed architecture stages. New features build on them rather than reopening them.

1. For a typed persisted question, the `QuestionDraftV2` sidecar is the content authority.
2. The V1 `questions` row is a compatibility projection for typed rows, not a second content truth.
3. A corrupt/unsafe typed sidecar hard-fails; typed consumers must not silently fall back to V1 content.
4. `null` and explicit typed empty content remain distinct where the typed contract distinguishes them.
5. `QuestionList`, Practice and WrongBook consume typed questions through the typed-aware persisted-question seam.
6. Typed content mutation must not pass through the legacy editor or reconstruct authority from a V1 projection.
7. Review/FSRS state is separate from typed question content mutation.
8. `RichContent` is structural: a persisted `TextNode` is not reparsed later as Markdown/math/image syntax.
9. Current database schema is **v31**: the frozen v15 typed sidecar remains
   authoritative, with the additive v16 File Library, v17 Project, v18 flat
   File Library Folder, v19 Conversation, and v20 parsed-artifact tables, the
   additive RAG-1 derived lexical-retrieval cache and FTS5 objects, the
   additive v22 `study_plans` table, the additive v23 `answer_attempts` table,
   the additive v24 Provider / Model Registry / capability authority, v25 model
   origin/binding policy, v26 image AnswerAttempt modality, the v27 derived
   ContentAsset reclamation-observation table, and the v28 durable
   `ImportedQuestionSet` / ordered-membership schema with database-owned
   relationship invariants, plus the v29 TrainingContent / members / Category
   preferences configuration schema, v30 StudyActivity sessions/segments and v31
   nullable ImportTask current-attempt event timestamps.
   The v27 table records only
   continuous grace evidence; it is neither an ownership registry, a refcount,
   nor a persisted live-set authority. V26 only extends
   the modality CHECK; all columns, indexes, nullable correctness and append-only
   semantics remain unchanged. Image payload v1 requires a durable
   `source_file_id` soft evidence reference, permits optional/empty transcription
   and bounded feedback, and never duplicates correctness. Missing evidence does
   not invalidate history. Question/Explanation remain RichContent; student
   image answers are AnswerAttempt plus optional retained image evidence.
   `answer_attempts` is append-only durable answer
   history, separate from mutable Review/FSRS scheduling state in
   `review_states`; changing or resetting scheduling state does not rewrite or
   delete answer history.

### RichContent Foundation Phase 0

The FINAL/FROZEN additive architecture target for first-class `ImageNode` and
`TableNode`, draft-level asset inventory authority, codec evolution, recursive
privacy admission, compatibility projection, durable asset lifetime, and
block-native structural ownership is
`docs/architecture/rich-content-foundation.md`. The bounded Phase 2A/Train B
implementation now conforms for typed image/table admission, managed asset
durability, B0 package v2 coverage, and explicit resolver-backed rendering;
final live acceptance remains deferred. The D0 successor for ContentAsset
retention, writer ownership, inventory, and collection is
`docs/architecture/dm-p0-content-asset-lifecycle.md`; its lifecycle stages are
activated and closed together, and destructive collection runs only through that
document's gated maintenance path under an explicit user confirmation.

## 4. Learning asset expansion boundary

Post-P5 asset work introduces new objects around the typed core rather than replacing it.

```text
LibraryFile
  original user-owned file metadata + managed storage identity
        |
        v
ParsedArtifact / SourceDocument
  reproducible parser/OCR-derived structure
        |
        v
QuestionDraftV2 -> Review -> PersistedQuestion
  confirmed learning data
```

Rules:

- Original file bytes belong in app-managed storage, not SQLite blobs.
- SQLite stores stable file metadata and a managed storage key/relative identity, never a durable absolute platform path.
- `ParsedArtifact` is derived data and must not replace the original file as the user's source asset.
- Formal question/review data must survive artifact cache replacement/removal.
- `Project` is an optional organization/context layer. Assets may exist with no Project.
- Projects reference files/banks; they do not own or duplicate original file bytes.
- A File Library Folder is a flat, optional manual classification for
  `LibraryFile` only. One file has at most one Folder, while Project/Learning
  Space relations remain independently many-to-many.
- Folder deletion removes Folder membership only; the `LibraryFile`, managed
  bytes, Project relations, banks, questions, sidecars, and review state remain.

### ParsedArtifact lifecycle invariants

- Identity is generation-scoped: `SourceDocument.sourceId = artifactId`, never
  `fileId`; page, block, asset, and issue provenance bind to one specific
  artifact generation.
- Confirmed learning data is independent: artifact replacement, removal, or
  corruption never deletes or rewrites a confirmed `QuestionDraftV2`, persisted
  questions, or review/FSRS state, and the draft's existing `SourceRef` values
  remain unchanged.
- F1 v0 keeps one current artifact per file; it implements no artifact history
  or tombstone registry, and replaced or deleted historical artifacts are not
  guaranteed to be re-dereferenceable from unchanged `SourceRef` values.
- Consumers reach artifacts only through the Application lifecycle seam with
  safe outcomes and typed failures; adapters never receive SQLite rows,
  absolute paths, `ParsedDocument`, or provider DTOs.
- Storage is SQLite current metadata plus managed immutable sidecars; the
  SQLite commit is the only publish visibility point, and CAS conflicts
  preserve the current artifact.
- Persisted payloads admit only `SourceDocument`/`SourcePart`/`SourceRef`/
  `RichContent`/`ImportIssue`/safe `AssetRef` metadata, never provider bodies,
  raw diagnostics, absolute paths, or binary image bytes.
- A verified current `parsed_artifacts` row and its decoded `SourceAssetPart`
  identities form a derived runtime ContentAsset retention root. A revision
  head alone does not; an unreadable current payload blocks destructive scans.
  OCR artifact generation is also an ordinary runtime ContentAsset byte writer;
  B0 restore writes ContentAssets through a separate journaled recovery path.
  See `docs/architecture/dm-p0-content-asset-lifecycle.md` for the activated
  lifecycle stages, the acceptance evidence per row, and the rows that remain
  unproven.
- F1-D1 implemented the additive v20 artifact tables without modifying any
  earlier table. RAG-1 subsequently raised the runtime schema to v21 at its
  closure with derived lexical-retrieval cache tables and a dedicated FTS5
  index; the current runtime is v31.

See `docs/architecture/f1-parsed-artifact-lifecycle.md`.

### RAG-1 successor amendment

RAG-1 consumes only verified current F1 artifacts, preserves File/Project as
the product authority, and adds deterministic lexical retrieval behind an
Application seam. Local readability never implies provider egress: Built-in
Agent file-content access requires a transient per-turn grant and an
independent retrieval tool. MCP v0 remains exactly six read-only tools. See
`docs/architecture/rag1-project-retrieval.md`.

## 5. Conversation foundation boundary

Conversation Presentation consumes a dedicated `ConversationService` alongside
the existing workspace facade. The service owns safe application failures and
uses a `ConversationRepositoryPort`; SQLite wiring remains in the composition
root.

- A new conversation is a transient draft until its first valid User Message.
- First persistence atomically creates the Conversation, sequence-1 Message,
  and selected `conversation_files` relations.
- Message order is the explicit per-conversation `sequence`, never a timestamp.
- A Conversation is either Global or scoped to a Learning Space. Project
  deletion uses `SET NULL` while preserving `scope_kind = learning_space`, so
  the orphan remains readable but unavailable for further message appends.
- Conversation/File relations are context references, independent of Project
  and Folder membership. They never own or duplicate file bytes.
- Conversation deletion cascades only to Messages and Conversation/File
  relations. File deletion removes only the relation.
- C0 persists User Messages only. Assistant persistence is an additive A0 seam;
  C0 does not synthesize an Assistant reply.
- Bank attachments, Provider, Web, RAG, Agent runtime, and MCP expansion remain
  outside C0.
- Existing subject/folder structures remain compatibility/product concepts until a separately authorized migration changes them.
- Bank identity is a J0 prerequisite decision. N0 does not introduce `bank_registry` or change current bank persistence.

See `docs/architecture/adr-002-learning-asset-lifecycle.md`.

## 6. Agent, MCP and application tools

Built-in Agent and external MCP are **peer adapters** over the same application capabilities:

```text
Built-in Agent
      |
      v
Application Tool / Query / Command Layer
      ^
      |
MCP Adapter <- External GPT / Claude / other MCP client
```

The built-in Agent must not call the app's own MCP transport. Shared business semantics live in the application layer, not in MCP protocol code.

MCP v0 remains the exactly-six-tool read-only contract frozen in `docs/architecture/mcp-v0-contract.md`. File/Project tools are MCP v1+ concerns unless that contract is explicitly revised.

Future mutation permissions follow:

```text
READ        -> adapter may execute within permission scope
DRAFT/STAGE -> may create a proposal, not formal data
COMMIT      -> requires explicit user approval through an application command
DESTRUCTIVE -> additional approval; may remain unavailable in early versions
```

No Agent or MCP tool may directly execute SQL or bypass the typed persistence/review boundary.

See `docs/architecture/adr-003-agent-mcp-and-write-boundary.md`.

The frozen Agent Runtime v1 / external capability / source-module / MCP vNext
target is indexed in [docs/product/agent-refactor/README.md](docs/product/agent-refactor/README.md).
That documentation-only checkpoint does not activate the target or supersede
A0, AGENT-FB, W0, SPL-1, RAG-1, MCP v0 or OBS-1 runtime behavior. Implementation
stages must preserve the current boundaries until their scoped transition is
accepted. In particular, Provider failure normalization does not relax fallback.

AR-R1's bounded Provider round seam is delivered and accepted (COMPLETE / CLOSED).
`agent-runtime-v1.md` owns its failure compatibility; OBS-1 owns terminal evidence.
AR-R2 adds the accepted typed Application Capability Kernel:
Agent and MCP projections invoke one CapabilityExecutor, whose immutable registry
binds typed identities to handlers over existing Application services. Permission,
actual effect, execution status and output egress are separate semantics. Direct
calls still require Application authorization; projection exposure grants none.
Legacy Dispatchers parse/encode through projections and delegate to this typed
path. The kernel has no Provider/MCP/JSON Schema/UI dependency. W0/SPL references
are transient service-lifecycle references; retrieval uses transaction cache
evidence and retains its Provider-bound grant and final serialization gate.
Schema/B0 and formal W0 commit/SPL adoption authority stay unchanged.
AR-R2 and AR-R3 are accepted merged stages under AGENTS.md's historical
merged-stage rule. The retained Runtime facade delegates to concrete
Coordinator/Engine/Policy/Finalizer responsibilities; ToolExecutor invokes
receipt-bearing projections; transient canonical transcript groups retain
complete calls/results/receipts. Provider-private continuation remains separate,
unresolved executions never replay, and history prunes only whole units.
No transcript/receipt reaches storage or logs.

AR-R4's implementation candidate adds explicit source contributions in
`application/modules`: validate the complete dependency graph, register/freeze
one ApplicationCapabilityRegistry, validate/freeze Agent/MCP/finite UI surfaces,
then publish one immutable composition. The production list captures explicit
services for Study, Retrieval, MissingAnswer and StudyPlan. Registered Agent
projections own their guidance; source removal removes those runtime surfaces
while global migrations/readers/validators and B0 compatibility remain.
The current UI IA and exactly-six MCP v0 wire owner are retained. Generic turn
lifecycle/round execution, Provider protocol, permissions/effects, transcript,
W0/SPL business lifecycles, fallback, schema v31 and B0 package v2 stay unchanged.
External Host/IPC, generated durable Proposal and READ continuation remain targets.
See `docs/product/agent-refactor/module-system.md` for this candidate's finite
registration and compatibility scope; final acceptance still needs standing
CI and independent semantic review.

## 7. Evolution discipline

- Do not start another R0–R8-scale rewrite merely to add File Library, Project, Agent, MCP or RAG.
- Prefer additive, bounded stages around the stable typed core.
- Do not migrate source model, persistence, Project, Agent and UI in one stage.
- New cross-surface business capabilities should be introduced once in the application layer and reused by UI/Agent/MCP.
- RAG is a retrieval implementation behind File/Project/Agent concepts, not a separate user-facing knowledge-base domain.
- Historical compatibility code is removed only when its legitimate responsibility is proven obsolete; code is not retired merely because it is old.

The canonical project roadmap and current stage/status authority is maintained in `docs/architecture/shiroha-project-roadmap.md`.

## 8. Architecture document authority

Current-state authority, in order:

1. `ARCHITECTURE.md` — repository-wide dependency and boundary contract;
2. active focused contracts in `docs/architecture/` and `docs/product/` (for example MCP v0, F1 parsed-artifact lifecycle, typed-persistence contracts and focused product capabilities); the Agent refactor directory explicitly distinguishes frozen targets from active runtime authority;
3. ADRs for accepted post-P5 architectural decisions;
4. `docs/architecture/shiroha-project-roadmap.md` for stage ordering and deferred decisions.

Files explicitly marked **Historical baseline** describe how a migration was planned or characterized at that time. They must not override this current contract.

## 9. Secure credential storage boundary (S0)

S0 Secure Credential Storage is COMPLETE. Stage status: S0-P0 (canonical
contract), S0-D0 (core seam), S0-D1 (real secure adapter), S0-D2 (legacy
migration + production wiring), and S0-CL (closure) are COMPLETE. Production
activation occurred strictly at S0-D2; the following is current runtime truth.

Provider credentials (AI/OCR/Agent engine API keys) are never persisted in
SQLite as plaintext and are never a runtime SQLite fallback.

- The secure credential store is the sole credential authority, keyed by a
  stable `engine.<engineId>` namespace.
- SQLite stores non-secret engine metadata only. New metadata writes always
  scrub `api_key`; legacy plaintext may temporarily remain only as migrator
  retry input until migration DONE (plaintext = 0), and is never read by any
  runtime path.
- Runtime hydration reads the secure store only: missing -> incomplete,
  unavailable -> typed transient failure, corrupt -> typed hard failure.
- UI, Agent, MCP, and providers never access the secure store directly; all
  access goes through the bounded credential port/adapter and the repository
  seam.
- No cross-store atomicity is claimed; save/delete define explicit commit
  points, compensation, and reconciliation (see the S0 focused contract).
- Credentials never enter MCP/public/query/persisted DTOs, logs, or exports
  (including `.shiroha`). They may exist inside bounded runtime provider
  value/request types whose string/log representation is REDACTED.

See `docs/architecture/s0-secure-credential-storage.md`.

### Provider and Model Registry boundary (schema v24)

Schema v24 separates Provider credential identity, discovered models,
capability claims, and capability bindings. New AI configuration writes use
this authority only; retained `ai_engines` rows are migration/rollback
evidence, not a second write target. Existing `AiEngineProfile` consumers are
served through a temporary repository projection.

Provider identity is the stable `provider_id`, also used by the unchanged S0
key `engine.<providerId>`. Runtime adapter selection uses explicit
`provider_kind`, never Base URL inference. Capability resolution uses strict
source priority and an exact-key Shiroha registry; model-name heuristics are
forbidden. Binding changes are CAS-protected and fail closed for stale,
missing, unavailable, unknown, or explicitly unsupported models, except that
migrated `legacyPreserved` bindings may retain unknown claims.

See `docs/architecture/ai-config-provider-model-registry.md`.

## 10. Supplemental-answer matching boundary (P6)

P6-P0 froze the focused canonical contract in
`docs/architecture/p6-supplemental-answer-matching.md`; P6-P0 is docs-only
and COMPLETE, and P6-D0 through P6-V0 implemented the frozen contract and are
COMPLETE. The following durable boundary applies to the P6 implementation:

Current product availability: file-based supplemental answering (P6) is
shelved. The ordinary Answer Completion queue/detail exposes only
single-question AI answering (P7), with no source-picker or P6 review launch.
P6 services, dependency wiring, diagnostic entrypoint and offline tests remain
retained but are not ordinary product entries. This does not remove File
Library, normal document import, committed data, or shared Candidate/Review
and typed-answer persistence authority. Reopening P6 requires separately
authorized implementation and acceptance under its retained contracts.

- P6 consumes the current F1 `ParsedArtifact` explicitly through the
  Application lifecycle seam (`getCurrentArtifact(fileId)`), never sidecars,
  SQLite rows, or managed paths directly, and never an implicit
  ensure/reparse/OCR.
- The target scope is explicit: `QuestionBankScope(bankName)` |
  `ProjectScope(projectId)` | `ExplicitQuestionScope(ordered storageIds)`,
  paired with exactly one explicitly selected supplemental `LibraryFile`.
- Matching is deterministic only: no LLM, embedding, semantic model,
  edit-distance auto-write, filename inference, sequence-only match, or
  automatic pairing of files.
- `AnswerCandidate` is transient and binds `artifactId` + artifact
  `revision` + expected `QuestionDraftV2`; explanation and supplemental
  `SourceRef` remain Preview/Review-only.
- Any write happens only after explicit user confirmation and reuses the
  existing typed answer mutation authority (`TypedAnswerCommand` /
  `TypedAnswerPersistencePort` / `TypedAnswerPersistenceKernel`); P6 creates
  no second answer write protocol.
- Confirm revalidates the artifact generation and the full typed target in
  one caller-owned transaction (artifact + target stale CAS); any drift means
  `staleTarget` with zero mutation, and the atomic boundary may not be
  degraded to a non-atomic double check.
- P6 adds no schema change and no persisted candidate/provenance/explanation.
- The old paired/combined/automatic two-PDF merge remains permanently dead;
  `reference_answer_merger` and `multi_file_question_merge_service` are not
  P6 seams.

## 11. AI answer candidate boundary (P7-P0)

P7-P0 froze the focused canonical contract in
`docs/architecture/p7-ai-answer-candidates.md`; P7-P0 (docs-only), P7-D0a
(producer-neutral Candidate/origin), P7-D0b (generic review-decision core),
P7-D1 (bounded AI answer provider port + strict HTTP adapter / typed
output validation), P7-I0 (AI generation Application use case), P7-C0
(confirmation + transactional answer-only persistence), P7-U0
(minimal typed-question Presentation integration), P7-V0 (focused
validation / privacy / concurrency / acceptance), and P7-CL (canonical
closure) are COMPLETE; P7 v0 is CLOSED / FROZEN. The following durable
boundary remains frozen and applies to any future P7 extension:

- P7 adds exactly one capability: AI -> typed `AnswerCandidate` producer
  through `explicit action on one typed question -> safe-content admission
  -> bounded provider request -> strict normalization / typed validation ->
  unified transient AnswerCandidate -> shared fill/noOp/replace review
  semantics -> explicit confirmation -> existing
  TypedAnswerPersistenceKernel`. AI never owns direct formal answer write
  authority.
- P7 and P6 share one producer-neutral `AnswerCandidate` concept with a
  typed/sealed producer origin; no `AiAnswerCandidate`, AI-specific review
  entity, AI candidate/job table, or second review/confirmation system.
  The Supplemental origin keeps every P6 invariant
  (`supplementalFileId`, `artifactId`, positive `artifactRevision`,
  non-empty ordered bound `SourceRefs`, match evidence).
- P7 v0 is text/math only: provider input admission happens before any
  network request and admits only `TextNode` / `InlineMathNode` /
  `BlockMathNode`. Questions containing `RawFallbackNode`, depending on
  assets/images unavailable to P7 v0, or requiring silent content deletion
  yield `unsupportedQuestionContent` with zero provider calls and zero
  mutation.
- `singleChoice` AI Candidates contain exactly one existing option ID
  (singular provider schema); zero/multiple/duplicate/unknown options are
  `validationFailed`. `fillBlank` / `shortAnswer` use structurally non-empty
  `ContentAnswer`. No new question kind and no per-blank schema.
- P7 is answer-only: explanation is never requested as Candidate data, and
  provider-internal reasoning, if any, is outside the Application contract
  and must never be surfaced, persisted, logged, or used as formal answer
  authority (`reviewOnlyExplanation` stays `null`).
- Provider access flows Presentation -> Application use case -> bounded AI
  Answer provider port -> provider adapter; Presentation never calls the
  provider SDK, Domain never imports provider DTOs, and Repository never
  calls the provider. Raw provider responses are transient, strictly
  bounded, never logged/persisted/returned raw, and never placed into a
  Candidate.
- Any write happens only after explicit user confirmation and reuses the
  existing typed answer mutation authority; confirm revalidates the captured
  target (`storageId` + `bankName` + complete `QuestionDraftV2`) in one
  transactional CAS boundary; any drift means `staleTarget` with zero
  mutation, and late results of cancelled/superseded generations are
  discarded.
- fill/noOp/replace follow the frozen P6 semantics; P6 F1 artifact stale
  checking, complete target snapshot binding, review/session semantics,
  transactional CAS, and `TypedAnswerPersistenceKernel` authority are not
  weakened.
- P7 v0 never calls RAG, never reads File Library / Conversation
  attachments / Learning Space files, never reuses `RetrievalEgressGrant`,
  and never calls `retrieve_file_content`; MCP v0 stays exactly six
  READ_ONLY tools, A0 stays exactly six tools, and W0 is not a P7 workflow.
- P7 adds no schema change and no persisted candidate/generation state/
  provenance/provider request/result/review state; runtime schema was v21 at
  P7 closure. The current runtime is v31.

## 12. UI Finalization Presentation boundary

The global light/dark/colorful appearance presets, shared visual tokens and
appearance-only local-theme compatibility are governed by
`docs/product/shiroha-appearance.md`. They share page structure and behavior;
no schema, application semantics or navigation hierarchy changes are implied.

The final Presentation / Navigation IA authority is
`docs/product/ui-finalization-ia-freeze.md`. The final primary navigation
is Today / Assistant / Profile (user-facing labels 今日 / 助手 / 我的),
and the original 普通 / 特训 / 考试 organization remains historical UI
Finalization v0 truth. The current unified Today dashboard and lightweight
single-plan detail are governed by `docs/product/today-home-refresh-freeze.md`:
ordinary new/due entries prepare separate typed-aware pools through an
Application launch port before opening normal Practice; plan selection/CAS
semantics remain unchanged. The 2026-10-06 amendment in
`docs/product/home-training-v3.md` §1.6 retires the Home calendar/duration
display and user-visible MockExam entry, retaining Activity timing, exam
implementation and historical data. The focused UI Finalization contract
governs only those Presentation decisions and does not alter any domain,
application, persistence, provider, or schema boundary recorded in this
document.

The current Practice presentation is governed by
`docs/product/practice-ui-refresh-freeze.md`: reading cards and fixed actions
preserve the existing typed/legacy, attempt, FSRS and preview boundaries.

## 13. StudyPlan boundary (SPL-1)

StudyPlan is a strategy/selection layer above the existing review/FSRS
semantics; it never schedules, never mutates review state, and never
deactivates itself. The Built-in Agent may stage a bounded plan draft through
the separate `propose_study_plan` capability; only explicit user adoption
through an Application command with a durable transaction-level
  compare-and-set may persist the single global `ActiveStudyPlan`. MCP v0
  remains exactly six READ_ONLY tools and the A0 read catalog remains exactly
  six tools. SPL-1-D1 introduced the v22 `study_plans` table; runtime schema
  was v24 at SPL-1 closure. ActiveStudyPlan durable singleton persistence exists;
  formal adoption
  remains Application-controlled; Agent planning and Assistant draft/adoption
  Presentation are implemented; Today / 当前计划 consumes the adopted plan through
  the deterministic `StudyPlanSelectionService` (live candidate pools,
  priority selection, dailyTarget cap, advisory states only), and 开始特训
  materializes the exact ordered selected storage IDs through the narrow
  non-preview Practice seam (never `PracticePage.initialQuestions`, which
  remains preview-only). SPL-1 StudyPlan Agent Tool v0 is CLOSED / FROZEN
  (P0–D0–D1–I0–U0–V0–CL COMPLETE; stage schema v22, v24 at closure;
  current runtime v31).

  The focused SPL-1 authority is
`docs/product/SPL-1 StudyPlan Agent Tool v0.md`.

## 14. Application data path boundary (DATA-PATH P1)

Durable runtime paths are owned by the application-support-based
`AppDataPaths` authority. Normal Debug/Profile runtime uses
`<Application Support>/Shiroha/development/`; Release runtime uses
`<Application Support>/Shiroha/production/`. Database, managed files, content
assets, parsed artifacts, logs, and B0 restore working state are composed from
that authority; they must not depend on `Directory.current`, repository roots,
or Git worktrees. Tests and isolated smoke entrypoints retain their existing
in-memory, temporary, explicit-file, and read-only profiles.

The focused current contract is
`docs/architecture/data-path-authority.md`. Legacy worktree-local data is not
automatically migrated by this boundary.

## 15. Review repair boundary

Review-time AI repair has two explicit strategies. Structural question issues
retain the bounded question-level JSON proposal flow. A pure
`latex_unrenderable` issue uses the fragment-level flow frozen in
`docs/architecture/review-repair-v1.md`: Application-owned snapshot alignment
identifies one exact typed math node, a dedicated bounded provider port returns
only a replacement LaTeX fragment, and local validation plus the existing
review CAS remain authoritative.

Presentation and renderers never own fragment identity. Fragment repair never
falls back to question-level rewriting, provider reasoning, retry, or expanded
context. The accepted fragment is persisted only as bounded digests and a
typed node locator; no prompt, LaTeX source, provider body, or reasoning is
stored. This boundary adds no database schema or dependency change.

## 16. Photo answer boundary

Practice fillBlank / shortAnswer photo answers use Application-owned direct
Vision judgement and explicit user confirmation before managed image ingestion
and AnswerAttempt append. Text answering remains available; question-import OCR
is unchanged. Student images are soft evidence references, not RichContent or
FSRS grading authority. See `docs/architecture/photo-answer-v1.md`.
## Answer Completion v0 — CLOSED / FROZEN

`docs/architecture/answer-completion-question-sets.md` is the canonical design authority for the Answer Completion / `ImportedQuestionSet` capability.

The design keeps Presentation behind Answer Completion Application services, preserves `PersistedQuestion.storageId` as Question identity, reuses existing P6/P7 answer mutation authority, and makes the existing task-bound `QuestionRepository` transaction the only import transaction owner. `LibraryFile`, `ParsedArtifact`, and `ImportTask` do not become QuestionSet identity.

**ANSWER-COMP-D1 implemented this relation as the additive v28 schema; the current runtime is v31.** The `imported_question_sets` / `imported_question_set_items` tables, their constraints, the bank lookup index, and the required relationship triggers exist and are strictly validated, while historical questions remain ungrouped.

Seed capture, the QuestionRepository-owned atomic set/member writer with per-document dispatch, the Answer Completion read projection, the queue/detail Presentation, and set-scoped P6 plus single-question P7 activation are implemented. ANSWER-COMP-P0, ANSWER-ENTRY-GUARD, D0/D1/B0, I0a/I0b/I0c, Q0/U0/P6/P7, V0 and CL are COMPLETE; Answer Completion v0 is CLOSED / FROZEN. These durable boundaries apply:

- The task-bound `QuestionRepository` transaction stays the only writer of Questions plus set/member rows; historical questions stay ungrouped and are never backfilled.
- The queue/detail projection is read in one short transaction. Presentation consumes that projection only, so counts, eligibility and set category are never composed from independent repository reads or re-derived in widgets.
- The retained, shelved P6 binding resolves complete set membership as a full-set `ExplicitQuestionScope` and revalidates it when the supplemental session binds; the existing P6 review and typed-commit authority is reused, and no second answer write path is added. Opening set detail currently exposes P7 only.
- Single-question AI answering reuses the existing P7 generation/review/commit boundary through a transient surface where dismissal is zero mutation.
- This stage adds no schema beyond v28, no persisted candidate or generation state, and no new provider call site.
- Source-file deletion, artifact replacement/removal, task cleanup and folder moves preserve committed set identity and membership. Answer/content edits preserve membership and review state; query counts reflect current typed answers, including explicit-empty as answered. Question deletion or bank movement removes membership, and the final removal deletes the empty set.
- B0 preserves set identity and ordered membership while treating provenance as soft evidence; strict v28 schema/trigger and relationship validation remains mandatory. V0/CL adds no production mutation path and does not activate typed-admission R1, stable bank identity, batch AI or RAG-2.

## Home Training V3 — configuration, launch, Activity and TaskCenter backend implemented

`docs/product/home-training-v3.md` freezes
`SHIROHA-HOME-TRAINING-IPF-V3` as the planned successor to the current
Today/Home and ordinary-training configuration contracts: Category-driven
TrainingContent configuration (Category → TrainingContent → ordinary
new-question pools, Category-scoped due review pools), Today/Home v2, durable
StudyActivity timing, ImportTask attempt event timestamps, and a TaskCenter
Application facade. P1a Domain values and P1b Application contracts exist;
P1c implements additive v29 TrainingContent persistence; P4b implements additive
v30 StudyActivity persistence. B1 implements additive v31 ImportTask event
timestamps and the TaskCenter Application backend.

Runtime schema is v31. The three configuration tables and independent
`app_settings.current_training_category` use canonical CategoryKey encoding;
the upgrade transaction seeds only the eligible old current bank once, without
changing learning data. B0 includes configuration and validates bindings,
weights and references before restore swap, retaining invalidated bindings and
unavailable-but-existing current content. There is no bank foreign key or new
bank registry. P2a implements the read-only TrainingCatalog and TrainingContent
queries plus atomic create/update/delete, separate preference CAS, current
selection and Category Visual writes through TrainingConfigurationRepository.
Application projects usability from the captured catalog and resolves
deterministic runtime fallback without persisting it. All admission and CAS
checks run in the writing transaction and reuse the v29 ordinary-bank eligibility
adapter. Deleting configuration preserves learning data and advances a referencing
preference's independent revision while clearing only its current content.
P2b maintains persistent binding invalidation through one caller-transaction
final-state helper. Single/bank deletion, legacy/preview bank movement, folder
updates (including import/batch folder writers), and clear-all invalidate only
valid relations when the final bank is missing, ineligible or in another Category.
Each affected content revision advances once per reconciliation pass; weights,
preferences and persisted current references remain unchanged. Temporary
delete/replace with a legal final bank does not invalidate. Drift inherited from
P2a (a valid relation whose bank was already missing, ineligible or moved) is
reconciled by a narrow same-transaction preflight pass in writers that can
recreate or re-map a bank; there is no startup sweep and no schema change.
Same-name recreation,
move-back, reads, startup and migration never restore a relation. The explicit
rebind command revalidates content CAS and fresh bank admission, restores only the
target member and advances the content revision atomically. P2b added no schema change.
P3a adds read-only bounded selection through ReviewRepository and the narrow
TrainingQuestionSelection Data seam. Domain TrainingAllocation caps initial
quotas and refills shortages with original positive weights and Largest
Remainder; zero weights never count or refill. A caller-injected Random owns
both ordered ID-window offsets (at most two per positive bank) and final
distinct-ID shuffle. Counts, windows and exact typed materialization share one
read transaction. Home batches are immutable and capped at 100; Category review
independently admits all ordinary eligible real banks, sorts due state>0 IDs by
next review time then storage ID, and caps at 40 without randomness. Existing
QuestionV2PersistenceMapper remains the union decoding authority through a
shared transaction-bound exact materializer; Home requires ReviewState and
selection-predicate consistency, while StudyPlan retains its 200-ID semantics.
Missing/unsafe/corrupt selected rows fail the entire batch with no replacement.
No learning/configuration state, queue, cache or schema is written. SQL OFFSET
can scan metadata; returned-row bounds do not imply constant query cost or
uniform subset sampling, and the existing bank-name index may be absent on a
fresh DB until the historical catalog writer has created it.
P3b implements DefaultTrainingSessionApplicationService behind the existing
Application launch contract. New training admits the exact contentId/revision
through a transaction-bound configuration reader shared with configuration CRUD;
parent, members, eligibility, live NEW counts/windows and typed materialization
use one short read snapshot. Deleted/revised targets return staleConfiguration;
valid empty pools return empty; malformed/admission/storage failures return
unavailable. Category review captures one injected clock value and remains
independent of TrainingContent. Only a complete successful batch calls the
existing initPreparedStudySession seam once, after the read transaction ends,
preserving exact P3a order; every failed preparation leaves the old queue intact.
RNG is injected per new launch. No launch writes learning/configuration state or
adds a durable queue. CP2-T implementation is complete.
Legacy bank-scoped and StudyPlan launchers remain independent. Home/Today
activation is implemented by B4; TaskCenter Presentation is implemented by B5;
ordinary Practice composition uses the prepared session with normal
attribution, while StudyPlan retains focused attribution and its 200-ID bound.
P4a implements the pure StudyActivity lifecycle/time core. Application's
StudyActivityTransitionEngine proposes an immutable single-owner state,
existing lifecycle snapshot and confirmed segment drafts; publication belongs
to the caller, after atomic persistence. Four explicit scenes are
admitted; the definition-only fifth scene and runtime interruption reasons
remain rejected. Pause/resume check both owner identities, repeated pause/resume
are no-ops, and ended proposals release the owner and reject later events.
Injected coherent monotonic/wall samples and immutable local calendar mappings
own time input; confirmed duration comes only from integer monotonic deltas.
Domain splitting walks actual local-midnight/offset-transition UTC intervals,
including multi-day and 23/25-hour DST days, emitting local date and observed
offset with deterministic sequences. An explicit source mapping revision marks
observed wall/zone changes: elapsed until observation keeps the old mapping,
subsequent anchors use the new one, and no unobserved change instant is guessed.
Invalid samples/splits produce safe failures without partially advancing state.
No IANA ID/package, duration total cache, timer, queue payload or platform object
is introduced.
P4b implements StudyActivityPersistence as an Application port and
StudyActivityRepository as the Data adapter. V30 stores sessions and immutable
segment facts, with soft context references and a segment-to-session cascade;
there is no owner token, queue, cumulative-duration cache or persisted quality.
PersistentStudyActivityService serializes immutable P4a proposals, captures event
time before awaiting prior writes, and publishes owner/state only after a short
gated transaction commits. Exact checkpoint replay is idempotent; conflicting
segment facts and stale/terminal append fail without partial writes. Failed
recording stops that session's attribution and marks process-local quality partial;
exit still releases the local owner. Explicit startup recovery closes active/paused
residue at its last successful checkpoint without estimating elapsed or restoring
an owner. B0 closes only the snapshot copy as snapshotInterrupted, preserves facts,
and rejects malformed or nonterminal portable Activity before swap. Weekly reads
sum persisted local-date segment durations for seven Monday–Sunday dates, using an
injected current local date; read failure remains unavailable. P4b is merged via
PR #224, and CP2-A is PASSED after independent T3 verification and fresh review.
Runtime is v31. B3 implements Practice/MockExam Activity wiring and production
composition. A composition creates one PersistentStudyActivityService after B0
startup recovery and DB readiness, attempts Activity startup recovery before
exposing routes, and injects the same service/query through a dependency scope.
Restore recomposition creates a fresh service and disposes the old route scope.
Practice launchers supply explicit ordinaryPractice/studyPlanPractice descriptors;
the prepared Category review seam accepts categoryReview without inferring it
from AnswerAttempt attribution. Preview does not begin Activity. A shared route
binding owns opaque route tokens, bounded 30-second checkpoint scheduling,
background/temporary-cover pause and same-owner resume, plus single-shot
queueFinished/submitted/exited dispatch. Exam submitted follows durable submission
success only; failed submit resumes and permits retry. Activity failures never
gate answering, grading, navigation or background exam grading.
The system adapter supplies Stopwatch elapsed and observed system local-date /
offset boundaries as immutable calendar facts, including offset transitions.
Within a continuous mapping revision, UTC advances exactly by confirmed
monotonic elapsed; raw wall observations establish an anchor only on a new
revision. Wall/zone observations change revision without rewriting old samples;
out-of-horizon attribution fails unavailable rather than consulting changed
calendar rules. No timezone dependency or schema change is introduced.
PR #232 is merged, so B3/I1 is historical accepted delivery under the merged-PR recovery rule. Home V2 composes the
TrainingContent ports, prepared ordinary launch and this Activity query. PR #234 is
also merged, so B4/I2 is current runtime truth. B5 implements TaskCenter UI/I3
production injection, completing the CP3 composition surface; final acceptance
still requires current-target CI and independent review.
B1 delivers P5a/P5b together. ImportTask adds three nullable UTC-second columns
with no historical backfill. TaskManager owns accepted-attempt started/parsed/
failed times and retry resets; repeated running does not refresh started time.
Current-attempt transitions compare the previous durable snapshot inside one
transaction and UPDATE only; stale callbacks do not recreate a missing task or
overwrite committed review/completion. JSON formatting is not an identity change.
QuestionRepository remains the formal completedAt transaction owner.
TaskCenterFacade is an infrastructure implementation of the immutable Application
query/command/file-selection contracts, keeping mutable tasks, diagnostics and
source locations private. Commands revalidate exact nullable attempt/trace/review
identity and current eligibility. Completed cleanup uses an immutable issued
snapshot, the existing cleanup reservation/write tails/commit leases, and a
transaction-bound exact target check. It deletes only still-eligible completed
snapshot members, preserves new/changed/busy records and all learning/source data,
and removes memory projections only after durable success. The legacy UI cleanup
API remains a compatibility path, not the new completed-only command authority.
Retry emits a picker request without mutation; selected input stays ephemeral in
the ingestion adapter and revalidates again at accepted retry. Review emits only
an exact navigation target; the composition bridge retains existing review CAS.
B0 retains package v2, migrates staged schema to v31 and continues to scrub all
ImportTask rows including event times. P5a/P5b and CP2-I implementation are complete;
B1 / CP2-I has been independently accepted and merged. B5 activates TaskCenter
UI and I3 through one TaskCenterFacade shared by query, command and selected-source
retry. Home's parse entry/badge uses the same injected safe query; the screen and
controller consume immutable Application DTOs only. The controller serializes
bounded visible-route refreshes, rejects stale/disposed publication, preserves
captured command/cleanup targets and never auto-replays stale actions. Event
times use the exact event kind and system local conversion, with no legacy
timestamp substitution. Legacy `文档解析任务:` titles are corrected only in the
safe read projection, without rewriting stored titles. FilePicker input stays
ephemeral inside the picker/ingestion compatibility boundaries. TaskCenter V2
uses the Today gray palette and a separate read-only detail sheet. Its narrow
detail query whitelists a bounded current-attempt opaque Trace ID and recorded
start-to-publication duration; it never returns a command target, attempt token
or raw diagnostics. Missing/untrusted facts stay null, and only an explicit copy
tap writes the safe ID to the clipboard. Duration uses validated current-attempt
startedAt/parsedAt wall-clock events, without lifecycle/schema changes or legacy
elapsed inference; the UI labels its recorded-event basis. The review
bridge validates the exact nullable attempt/trace/review identity and eligibility
again immediately before constructing existing ImportStaging inputs and pushing
the route. The historical task_center_projection helper remains for compatibility
tests only. Schema remains v31; PlanConfigScreen retirement and CP4 remain for B6.

B2 implements injectable Training Config list, shared selector/editor and
Presentation controller through Application ports. A single read transaction
returns the complete configuration snapshot, retaining empty custom Categories
and unavailable configurations after their banks disappear. Category Visual
presets are Category-wide preference values, separate from content revisions.
Draft weights and ideal quotas reuse Domain TrainingAllocation. Cancellation
writes nothing; a separately confirmed rebind commits immediately and is clearly
identified as independent of unsaved edits. Content and visual saves use separate
CAS and report partial success without retry or fictitious rollback. Category
reorder validates the complete captured ordered content/revision set and applies
dense ranks atomically; only changed rows advance revisions, with no member or
preference writes. Stale or failed moves leave no partial ordering changes.
Controller generation/dispose guards reject late loads, and busy state prevents
overlapping UI mutations. Configuration CRUD never changes learning facts.
Home/config production composition is now wired by B4/I2; the legacy
PlanConfigScreen remains for compatibility pending B6 retirement. B2 implementation was merged by PR #230 with standing
PR CI success. PR #230 is merged, so B2 is historical accepted delivery under the current
merged-PR recovery rule. Runtime schema remains v31.
TodayTrainingQueryAdapter captures one clock observation and injected local-day
boundaries, then TrainingConfigurationRepository reads catalog, configuration,
selection and counts in one read transaction. It reuses the shared eligibility,
visibility/order and Application fallback projection without preference writes,
sampling, materialization or ReviewState creation. NEW counts include only
positive-weight members; Category due review counts are independent and uncapped;
relation summaries include 0% members and distinct local-day ReviewLog Questions.
TodayController rejects old generations, separates week and training failures,
and uses exact preference CAS for settled Category selection and ordered usable
content cycling. Stale commands reload without replay. Home consumes Application
facts through Category pages and a folded corner; the 2026-10-06 Home UI
amendment retires its seven-day Activity view without removing the query or
durable recording capability.
Only ready launches open the prepared normal Practice route with explicit
ordinaryPractice/categoryReview context; the shared guard spans preparation and
the route lifetime. Home opens the existing B2 configuration page, refreshes on
return/reactivation/resume. Parse/configuration/create-import actions live in
the header; the user deferred the production Home member-bank detail entry
to a later configuration-page redesign, retaining its underlying capability.
Other secondary entries and the real singleton StudyPlan remain.
Production Home no longer consumes bank-scoped TodayContextQuery or
PlanConfigScreen; their compatibility callers are retained.
StudyPlan and TaskCenter boundaries above remain current truth. StudyPlan remains the single global ActiveStudyPlan and stays
independent of TrainingContent. Delivery order, prerequisites and durable current
state live in `docs/product/home-training-v3.md`; bounded execution packages are
temporary PR/context artifacts, and Git/PR/CI/Reviewer owns exact execution history.
