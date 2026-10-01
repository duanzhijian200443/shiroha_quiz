# ANSWER-COMP-P0 Answer Completion / Imported Question Sets — Focused Canonical Contract

Status: **Answer Completion v0 — CLOSED / FROZEN. P0 is COMPLETE / FROZEN; ANSWER-ENTRY-GUARD and D0/D1/B0/I0a/I0b/I0c/Q0/U0/P6/P7/V0/CL are COMPLETE.**

Historical P0 freeze: `master@4a154c12766b0cb30e8f869f08b1e52747e4a8de`, `2026-09-27`.

P0 froze the design only and added no production Dart, schema, migration, provider call, OCR behavior or runtime write. The closure amendment below records the implemented contract; historical planning wording describes the original freeze rather than current stage status.

## Closure amendment — implemented v0 authority

The frozen grouping, import, query and activation contracts in §§2–13 are now implemented. Runtime schema is v28, including strict set/member constraints, lifecycle triggers and B0 validation. `QuestionRepository` owns the task-bound typed/legacy atomic commit and calls `ImportedQuestionSetPersistenceKernel` within that same transaction. `document_v4` captures authoritative seed metadata; compatible v3 remains ungrouped.

The Application queue/detail projection uses one read transaction. The original v0 delivery exposed “补充答案” → “待补答案”, full-set P6 activation and single-question P7 review/commit through existing authorities. Current Presentation availability is amended below. Cleanup of source files, artifacts or tasks never owns a committed set; member deletion/bank movement and final-member cleanup remain schema-owned. Answer/content edits preserve membership and query counts remain dynamic.

V0 closes focused deterministic acceptance and standing CI coverage; CL synchronizes the canonical contracts. The executable evidence map is maintained in `test/answer_completion_v0_acceptance.md`, with tests in the unconditional contract list in `.github/workflows/pr-contract-checks.yml`. This closure adds no schema, provider or persistence path and preserves every non-goal in §16. Live-provider/device performance acceptance and future work require their own scope.

## Current availability amendment — P6 shelved, P7 retained

Ordinary Answer Completion exposes the queue, set detail and single-question
AI generation/review/commit only. The set-level “从答案文件补充” entry and its
file-matching launch path are removed even when P6 dependencies are supplied.
File Library and normal document import remain available; existing questions,
answers, imported sets and membership are preserved. P6 services, dependency
wiring, diagnostic UI and offline tests remain retained, with no changes to
shared Candidate/Review, typed persistence, source verification or stale/CAS
semantics. Historical COMPLETE/CLOSED statuses remain delivery history.
Reactivation requires separately authorized work and renewed P6 acceptance.

## 1. Purpose and scope

Answer Completion needs a durable way to identify the exact questions created by one successful source-document import so supplemental-answer matching does not fall back to an entire bank when multiple papers contain the same locators.

```text
QuestionBank(bankName)
  -> ImportedQuestionSet(setId)
       -> ordered PersistedQuestion.storageIds
```

User-facing flow:

```text
题库详情
  -> 补充答案
  -> 待补答案
  -> 导入题组详情
       -> 单题 AI补答案
```

This is an Answer Completion work queue, not a second bank browser and not a second answer persistence system.

## 2. Identity and ownership

`ImportedQuestionSet` represents one successful top-level source-document commit.

Frozen fields:

- `setId`: opaque UUID; never derived from filename, date, artifact, task, or locator.
- `bankName`: current compatibility bank identity; immutable after set creation.
- `displayName`: bounded display snapshot only; never identity or matching evidence.
- `createdAt`: display metadata.
- `sourceFileId`: nullable soft provenance reference; it does not own the source file.

`ImportedQuestionSetItem` contains `setId`, `questionStorageId`, and non-negative `position`.

Invariants:

- one set belongs to one bank;
- one Question belongs to at most one ImportedQuestionSet;
- persisted Question identity remains `PersistedQuestion.storageId`;
- item order records commit order and is not matching evidence;
- no manual grouping, set merge/copy, `PaperQuestionId`, `QuestionSetScope`, or new bank hierarchy is introduced.

`LibraryFile`, `ParsedArtifact`, and `ImportTask` are not set identity. Source-file deletion, artifact replacement, or task cleanup does not delete a committed set.

## 3. Additive persistence contract

P0 planned an additive migration from then-current v27 to v28 without changing runtime schema itself. D1 implemented that migration; current runtime is v28.

Implemented tables:

```text
imported_question_sets
  set_id PRIMARY KEY
  bank_name NOT NULL
  display_name NOT NULL
  created_at NOT NULL
  source_file_id NULL

imported_question_set_items
  set_id NOT NULL
  question_storage_id NOT NULL
  position NOT NULL
```

Required constraints:

- primary key `(set_id, question_storage_id)`;
- `UNIQUE(question_storage_id)`;
- `UNIQUE(set_id, position)`;
- `position >= 0`;
- item -> set `ON DELETE CASCADE`;
- item -> `questions.id` `ON DELETE CASCADE`;
- indexed set lookup by `bank_name`;
- `source_file_id` has no lifecycle foreign key.

Schema-owned invariants:

1. membership INSERT/UPDATE rejects cross-bank Question/set pairs;
2. changing `questions.bank_name` removes that Question from its old set;
3. deleting the last membership deletes the empty set in the same transaction;
4. `imported_question_sets.bank_name` is immutable: changed-value `UPDATE OF bank_name` aborts with a fixed safe failure; same-value update remains legal;
5. empty sets may exist only as uncommitted intermediate state; successful commit and B0 validation reject durable empty sets.

No bank rename or set move is added. A future stable-bank-identity migration must explicitly migrate this relation.

## 4. DocumentQuestionSetSeed protocol

New set-aware document tasks use strict commit-correctness metadata:

```text
import_tasks.diagnostics['_questionSetCaptureV1']
```

Exact envelope:

```json
{
  "schemaVersion": 1,
  "capture": true,
  "displayName": "2021数学一真题.pdf",
  "sourceFileId": null
}
```

Rules:

- exactly four keys; no extras;
- `schemaVersion == 1`;
- `capture == true`;
- `displayName` is 1–256 Unicode scalars, contains no control characters or path separators, and is sanitized only at seed creation;
- decoder never trims, repairs, or fills fields;
- `sourceFileId` is null or a non-empty opaque ID, never a path;
- envelope is nested JSON, not a JSON string;
- compact UTF-8 representation is at most 4096 bytes;
- null, wrong type, unknown version, missing/extra field, or oversize payload fails closed.

Entry provenance:

```text
document_v3 = compatibility document task
document_v4 = new QuestionSet-capture document task
```

Compatibility:

- v3 without seed commits through the old compatible path and creates no set;
- v4 with valid seed atomically creates exactly one set for a non-empty successful commit;
- v4 with missing/invalid seed performs zero learning-data writes;
- any task carrying an invalid seed fails closed;
- incompatible entry/seed combinations fail closed.

The old `document_v3` value remains intact. New dispatch writes v4 + seed together.

Task metadata preservation uses key presence, not `value != null`, so invalid null cannot disappear and be mistaken for an old task. Parser/provider diagnostics cannot overwrite or synthesize the reserved field. Restart, ReviewDraft persistence, diagnostics replacement, and OCR retry preserve the authoritative value.

## 5. Unique transaction owner

The existing task-bound import transaction in `QuestionRepository` is the only transaction owner.

```text
validate persisted task / attempt / ReviewDraft / target / seed
-> write Question rows and obtain actual storageIds
-> write typed sidecars for typed route
-> write existing review/folder relations
-> write ImportedQuestionSet + ordered membership
-> CAS task completion
-> COMMIT
```

`ImportedQuestionSetPersistenceKernel` writes set/member rows only with a caller-owned SQLite `Transaction`. It must not obtain `DatabaseHelper`, open/commit/rollback another transaction, register a post-commit relation writer, or ignore/replace conflicts.

`ImportedQuestionSetRepository` is a query adapter in v0 and is not a second import writer. `ImportCommitService` must not append QuestionSet writes after `QuestionRepository` reports success.

Any set/member/task-completion failure rolls back Questions, sidecars, review state, membership, and task completion together.

## 6. Per-document import boundary

```text
1 selected source document
-> 1 logical ImportTask
-> 1 independent successful commit boundary
-> 0 or 1 ImportedQuestionSet
```

PDF, DOCX, TXT, and Markdown multi-select dispatches one task per top-level file. One failure does not cancel sibling tasks.

A multi-file batch may target only a bank that already exists at dispatch time. Multi-file + proposed-new bank is rejected before task creation/parser work. Do not rewrite targetKind after the first success, depend on task order, create empty-bank reservation, or treat the first task as an implicit batch owner. Single-file proposed-new-bank behavior remains compatible.

ZIP remains one top-level document/task/set boundary. Photo/image collections, clipboard, and other non-document routes do not invent a document seed.

OCR retains current same-task/new-attempt retry semantics. Non-OCR document failures are re-imported as new tasks; universal same-task retry is out of scope.

## 7. Legacy and typed eligibility

Grouping and typed eligibility are separate:

- new typed and new legacy successful document imports both create sets;
- legacy-only sets are visible but unsupported for this Answer Completion flow;
- mixed/ineligible sets do not silently filter legacy members to create a smaller file-matching target;
- corrupt typed payloads fail safely and are not reclassified as legacy;
- historical legacy is not migrated/backfilled;
- historical/manual typed questions with no set remain ungrouped and may enter the single-question missing-answer queue.

`TYPED-ADMISSION-R1` remains separate. This epic does not loosen batch-wide typed admission. Text-direct typed activation is also separate.

## 8. Answer Completion query projection

Each queue/detail response is built from one short SQLite consistent read transaction:

```text
set + membership + Questions + typed sidecars
+ source-file availability + ungrouped membership exclusion
-> eligibility / answer state / counts
-> immutable Application DTO
```

The transaction callback is read-only, reuses the same executor, never waits on UI/provider/filesystem work, and never stitches counts from multiple temporal snapshots.

```text
missing    = valid typed && answer == null
answered   = valid typed && answer != null
ineligible = legacy + invalid
total      = missing + answered + ineligible
```

Typed explicit-empty is answered. Corrupt typed sidecar never falls back to V1. Query failure returns a safe unavailable state instead of fabricated counts.

Completed means only:

```text
total > 0 && missing == 0 && ineligible == 0
```

It does not mean answers are verified correct.

## 9. P6 integration

This retained integration is shelved at the ordinary product-entry boundary;
opening set detail does not start file matching. The following binding
contract remains implemented internally and covered by offline tests.

Selecting a set resolves its complete ordered `storageIds`, then reuses:

```text
ExplicitQuestionScope(ordered storageIds)
-> TargetQuestionSnapshot
-> deterministic matcher
-> SupplementalAnswerReviewSession
-> existing typed answer mutation authority
```

File matching uses the full eligible typed set, not only missing questions. Existing equal answers remain `noOp`; missing answers are `fill`; differing answers remain `conflict` with explicit replacement confirmation. Full-set scoping preserves ambiguity evidence.

No matcher changes are authorized for filename, year, ordering, timestamps, semantic inference, or AI guessing. No `QuestionSetScope` is added.

Supplemental files continue through File Library/F1. Scanned PDFs require existing explicit OCR confirmation; NO SILENT OCR remains frozen.

## 10. P7 and legacy-editor boundary

The queue exposes single-question AI generation only for valid typed targets, reusing `AiAnswerGenerationService.generateForQuestion(storageId)`, producer-neutral Candidate/Review, epoch/cancellation, stale/CAS, and replacement confirmation.

P7 remains answer-only. No batch AI, AI explanation persistence, AI-specific Candidate table, or durable answer-origin is added.

Before Answer Completion implementation depends on this surface, `ANSWER-ENTRY-GUARD` must ensure typed questions cannot enter the legacy `QuestionEditScreen._askAi()` / `answerSingleQuestion` path. Routing uses the real persisted `storageId` through a typed-aware Application read, with a defensive editor check.

Acceptance wording:

- typed questions: legacy `answerSingleQuestion` provider calls = 0;
- valid legacy questions: existing legacy answer+explanation provider path remains usable.

## 11. UI contract

Bank detail exposes secondary action **“补充答案”**, opening **“待补答案”** without immediately opening a source picker.

Queue:

- **待处理**: eligible imported sets with missing typed answers;
- **未分组题目**: eligible typed questions with `answer == null` and no set membership;
- **暂不支持 / 数据异常**: legacy-only, mixed, or corrupt sets shown separately;
- **已完成**: imported sets satisfying the completed predicate.

Set detail defaults to missing members, can show all, and exposes per-question P7 where eligible. It does not expose **“从答案文件补充”** or file-matching eligibility prompts while P6 is shelved.

The product does not expose the old whole-bank matching menu in v0. Existing `QuestionBankScope`, `ProjectScope`, and `ExplicitQuestionScope` Application contracts/tests remain.

Ungrouped questions leave the queue when answered; they do not become synthetic completed sets.

## 12. Lifecycle and B0

- deleting source LibraryFile preserves set/Questions/membership;
- `sourceFileId == null` means no LibraryFile provenance and must not be rendered as deleted;
- artifact/task cleanup does not affect committed sets;
- existing Exam-reference guards run before Question/Bank deletion;
- successful Question deletion cascades membership; final-member deletion removes the empty set;
- moving a Question to another bank detaches it from the old set and does not auto-attach elsewhere;
- folder moves do not change set identity;
- ordinary content/answer edits preserve membership while counts update dynamically;
- duplicate successful import creates a new set/new Questions; filename/fileId does not deduplicate.

Set/member tables are B0 portable durable data. ImportTask and ParsedArtifact remain scrubbed/transient. B0 preserves setId/position/membership and validates tables/indexes/FKs/required triggers and no empty/cross-bank/duplicate/dangling membership, while allowing missing soft source-file provenance.

P0 itself does not change current B0 package/runtime schema.

## 13. Failure / observability

Answer Completion uses Application projection states rather than extending P6/P7 enums:

`setUnavailable`, `emptySet`, `legacyOnly`, `partiallyIneligible`, `memberDataCorrupt`, `targetDrifted`, `noMissingAnswers`, `supplementalFileUnavailable`, `seedInvalid`, `seedVersionUnsupported`, `queryUnavailable`.

Logs contain only bounded safe codes, stages, statuses, and counts. No question text, answers, displayName, paths, document content, provider bodies, or raw exceptions.

## 14. Stage order

```text
0  ANSWER-COMP-P0       docs-only canonical freeze (this document)
1  ANSWER-ENTRY-GUARD   typed/legacy old-editor boundary repair
2  ANSWER-COMP-D0       domain/Application contracts + strict seed codec
3  ANSWER-COMP-D1       additive schema + constraints/triggers
4  ANSWER-COMP-B0       backup/restore inclusion and validation
5  ANSWER-COMP-I0a      v3/v4 metadata preservation/recovery
6  ANSWER-COMP-I0b      QuestionRepository-owned atomic writer/kernel
7  ANSWER-COMP-I0c      per-document dispatch + batch target guard
8  ANSWER-COMP-Q0       consistent read query projection
9  ANSWER-COMP-U0       queue/detail Presentation
10 ANSWER-COMP-P6       set -> full ExplicitQuestionScope wiring
11 ANSWER-COMP-P7       shared single-question P7 Presentation
12 ANSWER-COMP-V0       focused migration/lifecycle/race acceptance
13 ANSWER-COMP-CL       canonical closure
```

P0 must be merged before production implementation begins. D1/B0/I0b require independent deterministic verification before independent semantic review.

`TYPED-ADMISSION-R1`, text typed activation, universal import retry, batch-new-bank reservation, historical grouping recovery, batch AI, and stable bank ID remain outside this chain.

## 15. Required acceptance

Implementation must prove:

- all-missing typed set;
- 21 answered + 1 missing;
- full answer file over partial set yields noOp/fill/conflict without silent overwrite;
- same bank with multiple Q1 locators remains isolated by selected set;
- legacy-only and mixed sets are truthful and non-mutating;
- typed explicit-empty counts as answered;
- source-file deletion does not delete set;
- Question delete/move cleans membership and leaves no committed empty set;
- retry/duplicate confirm creates no duplicate set;
- typed/legacy writer failure rolls back Questions, sidecars/review, set/items, and task completion together;
- historical/manual typed missing stays ungrouped and can use P7;
- B0 round-trip preserves setId/order/membership;
- changed `set.bank_name` is rejected; same-value update is allowed;
- required trigger/schema corruption is rejected by restore validation;
- v3 without seed remains compatible;
- v4 missing/null/wrong-type/unknown-version/extra-field/oversize seed fails closed with zero learning-data commit;
- metadata replacement/restart/Review/OCR retry preserves authoritative seed;
- parser/provider diagnostics cannot overwrite reserved seed;
- kernel member-write failure rolls back outer transaction;
- concurrent query vs delete/answer update returns complete before/after snapshot or safe failure, never mixed counts;
- UI action is “补充答案” -> “待补答案”, with no ordinary whole-bank matching menu;
- typed old-editor AI path performs zero legacy provider calls, while valid legacy AI remains usable.

## 16. Non-goals and STOP conditions

This epic does not authorize legacy -> typed migration/backfill, relaxing typed admission, bank identity/rename, batch AI or explanation, automatic pairing, matcher heuristics, silent OCR, second import transaction/writer, persistent count caches, or general retry redesign.

Implementation stops and re-plans if current master/canonical contract changes incompatibly, committed storageIds cannot be obtained inside the existing task-bound transaction, set/member writes require another transaction, v4 seed cannot be strictly preserved, bank rename authority appears, deletion/FK/trigger semantics conflict with DM-P0, B0 cannot validate the relation, or P6/P7 must be weakened.
