# Shiroha Quiz Architecture Contract

Status: **Canonical architecture contract after R1–R8 and P5**.

This file describes the current dependency direction and the boundaries that all new post-P5 work must preserve. Historical R0/R1 migration documents remain useful as design provenance, but they are not current-state authority.

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
9. Current database schema is **v21**: the frozen v15 typed sidecar remains
   authoritative, with the additive v16 File Library, v17 Project, v18 flat
   File Library Folder, v19 Conversation, and v20 parsed-artifact tables, plus
   the additive RAG-1 derived lexical-retrieval cache and FTS5 objects.

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
- F1-D1 implemented the additive v20 artifact tables without modifying any
  earlier table. RAG-1 subsequently raises the current runtime schema to v21
  with derived lexical-retrieval cache tables and a dedicated FTS5 index.

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

## 7. Evolution discipline

- Do not start another R0–R8-scale rewrite merely to add File Library, Project, Agent, MCP or RAG.
- Prefer additive, bounded stages around the stable typed core.
- Do not migrate source model, persistence, Project, Agent and UI in one stage.
- New cross-surface business capabilities should be introduced once in the application layer and reused by UI/Agent/MCP.
- RAG is a retrieval implementation behind File/Project/Agent concepts, not a separate user-facing knowledge-base domain.
- Historical compatibility code is removed only when its legitimate responsibility is proven obsolete; code is not retired merely because it is old.

The canonical post-P5 sequence is maintained in `docs/architecture/n0-post-p5-roadmap.md`.

## 8. Architecture document authority

Current-state authority, in order:

1. `ARCHITECTURE.md` — repository-wide dependency and boundary contract;
2. active focused contracts in `docs/architecture/` (for example MCP v0, F1 parsed-artifact lifecycle, and R7/R8 typed-persistence contracts);
3. ADRs for accepted post-P5 architectural decisions;
4. `docs/architecture/n0-post-p5-roadmap.md` for stage ordering and deferred decisions.

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

## 10. Supplemental-answer matching boundary (P6)

P6-P0 froze the focused canonical contract in
`docs/architecture/p6-supplemental-answer-matching.md`; P6-P0 is docs-only
and COMPLETE, and P6-D0 through P6-V0 implemented the frozen contract and are
COMPLETE. The following durable boundary applies to the P6 implementation:

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
output validation), P7-I0 (AI generation Application use case), and P7-C0
(confirmation + transactional answer-only persistence) are COMPLETE, and
P7-U0 and later are NOT STARTED. The following durable
boundary applies to any future P7 implementation:

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
  provenance/provider request/result/review state; runtime schema remains
  v21.
