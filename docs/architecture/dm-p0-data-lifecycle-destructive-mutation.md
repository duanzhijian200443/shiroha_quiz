# DM-P0 Data Lifecycle & Destructive Mutation Contract

Status: CLOSED / FROZEN
Frozen against: master@3e10c644324f8b49966f8fb2b6c4e3e634cf3cf0
Date: 2026-08-18

This document is the canonical lifecycle boundary for destructive data work
after DM-P0. It records durable ownership, deletion, reset, invalidation,
confirmation, backup, and follow-up rules. It is a contract, not a development
log or a record of the investigation that produced it.

DM-P0 changes no production Dart code, database schema, migration, UI, B0
runtime, Agent runtime, MCP runtime, or managed-file implementation.

## 1. Authority and ownership classification

| Entity | Classification and authority | Ownership rule |
| --- | --- | --- |
| `LibraryFile` and its original managed bytes | Primary user asset; SQLite metadata plus an app-managed storage identity | The app owns the managed copy. An external source file is never deleted by the app. Project, Folder, and Conversation relations do not own the bytes. |
| `ParsedArtifact` and its immutable sidecar | Rebuildable, generation-scoped derived state | It is derived from one `LibraryFile` generation. It is never the authority for confirmed learning data. |
| RAG chunks, builds, heads, FTS rows, and retrieval caches | Rebuildable derived state | RAG reads only a verified current ParsedArtifact/SourceDocument. RAG deletion or invalidation never deletes primary content. |
| `Question` and `question_v2_payloads` | Confirmed primary learning data; the typed sidecar is authoritative for typed content | A question is independent of its source artifact, Project, Conversation, and LibraryFile after confirmation. |
| `QuestionBank` | Compatibility aggregate derived from `questions.bank_name`, not an independent entity | Bank deletion operates on its questions and relations. It does not create a second bank owner. |
| `AnswerAttempt` | Append-only historical answer fact | It is durable history, separate from ReviewState and ReviewLog. `question_id` is a historical reference, not a lifecycle FK. |
| `ReviewState` | Mutable FSRS scheduling state | It is independent of typed question content and AnswerAttempt history. |
| `ReviewLog` | FSRS review-history data | It is separate from AnswerAttempt and must not be used to justify implicit AnswerAttempt deletion. |
| `Project` | Container and organization relation | A Project references files and bank names; it does not own files, bytes, banks, questions, or StudyPlans. |
| `Conversation`, Messages, and Conversation/File relations | Durable conversation history and context relations | A Conversation owns its messages and relation rows, not the underlying LibraryFiles or committed business writes. |
| `StudyPlanDraft` / `ActiveStudyPlan` | Transient draft / durable global singleton | The draft disappears with the process. The adopted plan is not Project-owned or Conversation-owned. |
| `ExamPaper` / `paper_questions` | Exam history, relation, and submitted answer/result state | The paper owns its relation rows and results, not the referenced Question rows. |
| `ImportTask` / `ReviewDraft` | Ephemeral workflow and recovery state | They are not confirmed learning data and are not portable B0 user history. Successful commit makes the Question authoritative; task cleanup is separate. |

## 2. Lifecycle operations

- **DELETE** removes a primary entity and only the explicitly permitted child
  rows. It is not a synonym for purge, detach, or reset.
- **RESET** changes mutable state back to its defined baseline. Review reset
  must not delete AnswerAttempt history.
- **PURGE** irreversibly removes historical facts, user bytes, or a complete
  data set. It requires a separately named and confirmed operation.
- **INVALIDATE** makes derived data unusable and schedules or permits rebuild;
  it does not delete its source or any confirmed Question.
- **DETACH** removes a relation while preserving both related primary objects.
- **ARCHIVE** hides or retires an object without physical deletion. It is
  reversible unless a later explicit delete is performed.

Primary database mutations use one transaction for the authoritative rows and
relations. Managed-file deletion must never occur before that transaction
commits. Post-commit physical-file and derived-cache cleanup is best effort;
safe orphans are allowed, must be observable, and must not cause a successful
primary deletion to be reported as rolled back.

All destructive operations enter through an Application command/service and the
existing mutation/backup gate. UI, Built-in Agent, and MCP adapters never issue
SQL or bypass the application boundary.

## 3. Lifecycle matrix

| Entity / operation | Allowed mutation | Cascade or preservation rule | Confirmation |
| --- | --- | --- | --- |
| LibraryFile | Future D2/D4 delete only through a formal Application authority | DB metadata and relations are authoritative first; managed bytes are cleaned after commit only when ownership is proven. Project/Conversation detach never deletes bytes. | D4 for physical-byte deletion; backup recommended. |
| ParsedArtifact | D1 remove current / invalidate | Preserve Question, typed sidecar, SourceRef, ReviewState, and FSRS. Invalidate related RAG derived state. | No extra destructive confirmation. |
| RAG derived state | D1 delete/rebuild/invalidate | Never changes LibraryFile, ParsedArtifact authority, Question, or AnswerAttempt. | No extra destructive confirmation. |
| Question | D2 delete | Remove the typed sidecar and question-owned review/FTS rows. Preserve AnswerAttempt. If referenced by any ExamPaper, fail closed with zero mutation. | One explicit confirmation. |
| QuestionBank | D4 delete | Delete its Questions and permitted dependent rows in one transaction; detach bank relations. Preserve AnswerAttempt, LibraryFile, ParsedArtifact, Project, and ExamPaper. Any Exam reference blocks the operation rather than allowing partial deletion. | Entity-scoped confirmation describing the cascade; backup recommended. |
| ReviewState | D3 reset | Reset scheduling state only. AnswerAttempt remains untouched; any ReviewLog behavior must be named by the reset operation. | Explicit reset confirmation. |
| AnswerAttempt | No implicit entity-level delete | Preserve on Question/Bank deletion. Historical orphan references are valid and must be represented as unavailable history, not silently reassigned. | Only a separately authorized D3/D4 purge. |
| Project | D2 delete | Delete Project metadata and `project_files`/`project_banks` relations. Preserve files, bytes, banks, questions, sidecars, review data, and StudyPlan. Conversation scope becomes unavailable via `SET NULL`. | One explicit confirmation. |
| Conversation | D2 delete | Delete Conversation, Messages, and Conversation/File relations. Preserve LibraryFiles and all committed Question/StudyPlan/W0 writes; never roll them back. Active turns or moves block deletion. | One explicit confirmation. |
| ActiveStudyPlan | D3 stop/replace | Stop or replace only the exact durable plan. It remains after Project/Conversation changes and becomes `planUnavailable` if its bank disappears. | Explicit stop/replace confirmation. |
| ExamPaper | D2 delete | Delete the paper and its `paper_questions` rows. Preserve all referenced Questions, including generated hidden questions unless a future ownership contract says otherwise. | One explicit confirmation, with active grading guard. |
| ImportTask / ReviewDraft | D1 cleanup or cancel | Never delete confirmed Question data. Durable cleanup failure is observable and retryable; in-memory projection must not silently claim durable deletion. | Normal task action; no D2 data-delete confirmation. |

## 4. Cascade matrix

| Source operation | May remove | Must preserve / must not cascade |
| --- | --- | --- |
| Project delete | Project row, `project_files`, `project_banks` | LibraryFile rows/bytes, folders, banks, Questions, sidecars, review data, Conversations, StudyPlans |
| Conversation delete | Conversation row, Messages, `conversation_files` | LibraryFile rows/bytes, Projects, Questions, committed W0 writes, committed StudyPlans |
| ParsedArtifact removal | Current artifact pointer and its derived sidecar after publish rules | LibraryFile, QuestionDraftV2, Questions, SourceRefs, ReviewState/FSRS |
| RAG invalidation | Builds, heads, chunks, FTS/cache rows | LibraryFile, ParsedArtifact, SourceDocument authority, Questions, AnswerAttempts |
| Question delete | Question, typed sidecar, question-owned ReviewState/ReviewLog/FTS rows | AnswerAttempt, LibraryFile, ParsedArtifact, Project, ExamPaper; operation is blocked if an exam reference exists |
| QuestionBank delete | Bank Questions and their permitted dependent rows; bank relation rows | AnswerAttempt, LibraryFile, ParsedArtifact, Project, ExamPaper; no partial success when a reference guard fails |
| ExamPaper delete | ExamPaper and `paper_questions` | Referenced Question rows and their Question lifecycle |
| StudyPlan stop | Exact ActiveStudyPlan row after CAS | Questions, ReviewState, AnswerAttempt, Conversations, Projects |

## 5. D0-D4 destructive classification

| Level | Meaning | Confirmation rule |
| --- | --- | --- |
| D0 | Detach, archive, or reversible relation change | No additional destructive confirmation; operation remains observable and reversible where applicable. |
| D1 | Derived-state cleanup, invalidation, or ephemeral-task cleanup | System-owned operation; no user purge confirmation. Failure is retryable and cannot alter primary authority. |
| D2 | Single primary user-entity deletion | One explicit confirmation naming the entity and effect. |
| D3 | Historical reset or targeted purge | Explicit entity/name confirmation plus backup recommendation. No implicit AnswerAttempt purge. |
| D4 | Multi-entity cascade, physical-byte deletion, whole-library clear, or irreversible bulk purge | Explicit entity-scoped confirmation describing cascade and irreversibility; backup recommendation; execution only through an Application commit boundary. No autonomous Agent/MCP execution. |

## 6. Fail-closed and history invariants

1. A Question referenced by `paper_questions` cannot be physically deleted until
   an explicit exam-history ownership/snapshot contract exists.
2. If the reference check cannot be completed, Question or QuestionBank delete
   fails closed with zero primary mutation.
3. AnswerAttempt is append-only historical fact. Deleting a Question or Bank
   does not delete its attempts, and an unresolved historical `question_id` is
   not a reason to rewrite or discard the attempt.
4. ReviewState/FSRS scheduling is not an answer-history authority and cannot be
   used as a substitute for AnswerAttempt correctness or retention.
5. A Conversation delete never rolls back a previously committed Question,
   StudyPlan, Project, or W0 write.
6. A Project delete never becomes an implicit file, bank, Question, or byte
   delete.

## 7. LibraryFile, ParsedArtifact, and RAG lifecycle

```text
LibraryFile (primary bytes and metadata)
  -> current ParsedArtifact / SourceDocument (derived generation)
  -> deterministic RAG chunks / index / cache (derived retrieval state)
  -> confirmed QuestionDraftV2 / Question (independent primary learning data)
```

- ParsedArtifact replacement, removal, or corruption never deletes or rewrites
  confirmed Questions, typed sidecars, SourceRefs, or ReviewState/FSRS.
- RAG consumes only the verified current artifact and treats its rows as
  rebuildable derived state. Source mutation invalidates derived retrieval;
  derived cleanup never mutates the source.
- Removing a Project, Folder, or Conversation relation is DETACH, not a
  LibraryFile delete.
- No DM-P0 implementation introduces reference counting, garbage collection,
  automatic orphan deletion, or physical asset cascade behavior.

## 8. B0 interaction

Durable whole-backup state includes Questions, typed sidecars, ReviewState and
ReviewLog, AnswerAttempt, exam records, LibraryFile metadata and originals,
Projects/relations, Conversations/Messages/relations, and ActiveStudyPlan.

ParsedArtifact metadata/sidecars, RAG builds/heads/chunks/FTS, ImportTasks,
credentials, logs, provider raw responses, and other rebuildable or secret
state remain excluded or scrubbed according to B0 rules.

### B0 v23 alignment

**CURRENT**

- Runtime schema = v23.
- AnswerAttempt backup/restore already has acceptance coverage. The acceptance
  test inserts `answer_attempts.attempt_id = att-1`, performs export, mutates
  the live database, restores, and asserts that `att-1` is present after
  restore.
- AnswerAttempt is already part of whole-backup durable state.

**GAP**

- The B0 canonical contract still describes runtime schema v22 in several
  places and its INCLUDE table is v22-based.
- v23 documentation, current-runtime fixtures, and staged-validation alignment
  are the bounded DM-D3A follow-up.
- DM-D3A must not reimplement AnswerAttempt export/restore acceptance or
  describe it as unverified. It must distinguish intentional v22 compatibility
  fixtures from stale current-runtime expectations and explicitly align staged
  validation with v23.

D3/D4 operations should recommend a B0 export before irreversible work. DM-P0
does not modify B0 runtime, restore code, or backup schema.

## 9. Rich Image asset lifecycle

**DEFERRED.**

Rich Image / `AssetRef` / `SourceAssetPart` / `SourceTablePart` physical
ownership, reference counting, orphan collection, and cascade deletion are
not frozen by DM-P0. Until a dedicated contract exists:

- no ref-count or GC implementation may be introduced incidentally;
- no Question, ParsedArtifact, Project, or LibraryFile delete may assume unique
  image ownership;
- safe orphan preservation is preferred to destructive cleanup;
- binary bytes and raw OCR/image payloads do not become B0 or RAG authority.

## 10. Follow-up graph

- **DM-D1 — Primary destructive lifecycle**
  - D1A: `clearAllData` atomicity.
  - D1B: Question delete plus Exam reference guard.
  - D1C: QuestionBank cascade semantics.
  - D1D: Review reset and history preservation.
  - D1E: destructive confirmation and zero-mutation tests.
- **DM-D2 — LibraryFile / ParsedArtifact / RAG cleanup**
  - Formal file-delete authority, DB-first managed-file cleanup, explicit RAG
    invalidation, and safe orphan handling.
- **DM-D3 — B0 v23 contract alignment**
  - Canonical wording, INCLUDE table, current-runtime fixtures, compatibility
    labeling, and staged validation; reuse existing AnswerAttempt acceptance.
- **DM-D4 — ImportTask / ReviewDraft lifecycle**
  - Cancel, restart, commit, retention, durable cleanup failure, and retry
    semantics.
- **DM-D5 — Destructive presentation and tool boundary**
  - UI confirmation, OBS-1 operation traces, and future Agent/MCP
    `DRAFT/STAGE -> explicit confirm -> COMMIT` behavior.

Rich Image asset lifecycle, P2-B1T2 / issue #116, automatic asset GC, Agent/MCP
destructive runtime, B0 implementation changes, and unrelated schema or UI
redesign remain DEFERRED or out of scope for DM-P0.

## 11. ATTEMPT-2 readiness

**ATTEMPT-2 = READY_WITH_BOUNDED_EXCEPTIONS.**

Subjective Answer work may proceed only when it does not introduce a new
destructive lifecycle operation, physical-file deletion, bank/question purge,
AnswerAttempt purge, asset GC, or Agent/MCP destructive tool.

Any such expansion must first use the applicable DM-D1 through DM-D5 contract
and review path. DM-P0 closure does not close P2-B1T2 / issue #116.
