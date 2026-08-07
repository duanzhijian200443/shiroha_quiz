# R7C.1 Attempt-aware Typed Commit Finalization

Status: IMPLEMENTED CONTRACT
Base: master@3c2fd3bfb220c429b372d2c07241c816a55d4cc7
Database version: 15
Scope: typedV2 commit lifecycle only

## 1. Status

Implemented and covered by permanent acceptance
(`test/r7c1_attempt_aware_typed_commit_acceptance_test.dart`). R7C.1 closes
the two P2 lifecycle gaps left by R7C: typed commits now verify current
attempt ownership in memory **and** in the persisted `import_tasks` row, and
question persistence plus `ImportTask` completion now commit in one SQLite
transaction.

## 2. Scope

typedV2 + `typed_candidate_ready` production commits only. Legacy
(`commit` / `commitLegacy`) behavior is unchanged. No database schema,
migration, version, QuestionDraftV2 codec, R7A snapshot schema, ReviewSession
public contract or R7D read UI is modified.

## 3. R7C lifecycle gaps

1. `commitTyped` only checked that `taskId`/`attemptToken`/`attemptNumber`
   were non-empty; it never verified the task still exists, is
   `pendingReview`/`readyForReview`, matches the attempt exactly, carries the
   typedV2 route/reason, has a matching review draft revision or non-empty
   parsed data.
2. `saveQuestionDraftsV2ToBank` succeeded in one transaction, then
   `TaskManager.completeTask()` fire-and-forget persisted `ImportTask`
   completion outside that transaction, so a restart could re-offer a task
   whose questions were already written.

## 4. Same-database evidence

`DatabaseHelper` is a singleton over one file (`shiroha_core_v1.db`, version
15). `questions`, `question_v2_payloads`, `review_states`, `bank_folders` and
`import_tasks` are all created in the same `_onCreate`/`_onUpgrade` of that
single database. `TaskManager` persists through
`ImportTaskRepository.instance -> DatabaseHelper.instance` and
`QuestionRepository` defaults to the same `DatabaseHelper.instance`, so one
SQLite transaction can cover questions + task completion without a cross-db
compensation protocol.

## 5. Typed commit lease

`TaskManager` owns `TypedCommitAttemptLease{leaseId, taskId, attemptToken,
attemptNumber, reviewDraftRevision, storageRoute, storageReason}`.
`beginTypedCommitAttempt` is serialized with the review-draft queue (every
queued save drains first; every later save observes the lease and is
rejected), validates the in-memory current-attempt gate, and registers one
exclusive lease per task. A second lease for the same task is rejected with
`commitInProgress`. Failed commits release the lease in `finally`; successful
commits clear it only after the queue drains, so an old pendingReview
snapshot can never be written back after completion.

## 6. Review draft flush

`ImportStagingScreen._confirmAndSaveTyped` waits for the queued
`_reviewDraftOperationTail`, executes one final `_persistReviewDraft()`, and
requires `saved == true` before calling `commitTyped`. A
`stale`/`taskMissing`/`itemMissing`/`failed`/`commitInProgress` flush result
blocks the commit with the fixed prompt
`校对结果尚未安全保存，无法入库，请重试`. `_isSaving` stays true through flush
and commit to block double submission.

## 7. Review revision contract

`commitTyped` requires `expectedReviewDraftRevision > 0` and passes the
flush-returned revision. Missing, zero, negative, in-memory mismatched and
persisted-mismatched revisions all block with `staleReviewDraft`; the value is
never accepted without verification.

## 8. In-memory ownership validation

`beginTypedCommitAttempt` requires: task exists, `status == pendingReview`,
attemptState `readyForReview`, attemptToken and attemptNumber exact matches,
route `typedV2`, reason `typed_candidate_ready`, non-empty `parsedData`, and
revision equal to the expected revision. Any failure returns a fixed lease
status without touching the repository.

## 9. Persisted ownership validation

`QuestionRepository.commitQuestionDraftsV2ForImport` runs the strict
persisted gate inside the transaction: exactly one `import_tasks` row,
`status` equal to the frozen pendingReview code, non-null `parsed_data`,
diagnostics that decode to a JSON object, and exact typed matches for
`_attemptToken`, positive `_attemptNumber`, `_attemptState == readyForReview`,
`_importStorageRoute == typedV2`, `_importStorageReason ==
typed_candidate_ready` and positive `_reviewDraftRevision`. No
`toString()` repairs, trimming, missing-revision defaults or status guessing.

## 10. Atomic transaction boundary

One SQLite transaction contains: persisted ownership validation → folder
decision → `questions` inserts → `question_v2_payloads` inserts →
`review_states` inserts → `bank_folders` upsert → compare-and-set
`import_tasks` completion update (`WHERE id = ? AND status = pendingReview`,
affected rows must equal 1, otherwise rollback). Any ownership mismatch, CAS
mismatch or `DatabaseException` rolls back everything with zero question rows
and the task still `pendingReview`.

## 11. ImportTask completion mapping

The completion update sets `status = completed code`, `progress_text =
已成功导入题库`, `percent = 1.0`, `error_msg = null`, `parsed_data = null` and
`completed_at = batch transaction timestamp`. `id`, `title`, bank/folder,
`created_at`, `warnings`, `diagnostics` (including attempt metadata,
route/reason and review draft revision) are preserved. `TaskManager`
`applyDurableTypedCommitCompletion` only syncs memory (status, progress text,
transaction `completedAt`, `parsedData = null`, lease cleanup,
`notifyListeners`) and never calls `_saveTask` or any repository. When the
in-memory task was removed, a fixed safe warning is logged and the durable
database state stays authoritative.

## 12. Failure taxonomy

Repository: `TypedImportCommitPersistenceFailure{taskMissing,
taskNotPendingReview, staleAttempt, invalidTaskMetadata, staleReviewDraft,
alreadyCompleted, transactionFailed}`. Service: `TypedReviewCommitAttemptFailure
{taskMissing, taskNotPendingReview, staleAttempt, staleReviewDraft,
commitInProgress, persistenceFailed}` with fixed `toString()` text.
`TypedReviewCommitFailure` keeps its frozen R7C values in
`typed_review_result_builder.dart`; the new attempt taxonomy lives in
`import_commit_service.dart` because the former file is outside the R7C.1
write scope (same frozen semantics). Exceptions carry only the enum: no raw
cause, SQL, diagnostics JSON, question content, path, token, task id, source
id or database message.

## 13. Concurrent duplicate behavior

Two identical concurrent typed commits: the lease allows only one; the second
receives a fixed `commitInProgress` (or the repository gate rejects an
already-completed task after restart). Exactly one batch of questions,
sidecars and review states is written and the task is completed once. No
idempotency/commit-marker table is added.

## 14. Rollback behavior

Task-completion update failure and question/sidecar insert failures both roll
back the whole transaction: zero parent rows, zero sidecars, zero review
states, zero folder mappings, task remains `pendingReview` with `parsed_data`
intact. The acceptance test proves a retry succeeds after the blocker is
removed.

## 15. Legacy compatibility

`commit()` → `commitLegacy()` → `saveQuestionDraftsToBank` → legacy
`TaskManager.completeTask` is unchanged and never enters the atomic typed
API. Historical `legacyV1`/shadow tasks keep the legacy writer. R6/R7C/R7D
existing tests keep passing unchanged in behavior.

## 16. Test matrix

- `test/typed_import_commit_guard_test.dart`: guard/result/taxonomy/fixed
  constants, TaskManager key aliases, frozen pendingReview/completed status
  codes.
- `test/task_manager_typed_commit_lease_test.dart`: lease gates, queue
  serialization, commitInProgress saves, failure release, durable memory-only
  completion, stale-lease safety, idempotent re-application, no resurrection.
- `test/question_repository_v2_test.dart`: atomic repository matrix
  (success, every ownership failure with zero writes, rollback triggers, CAS
  rollback, safe exceptions, concurrent duplicate single-batch).
- `test/import_commit_service_test.dart`: revision requirement, lease order,
  failure mapping, no legacy fallback, no second task persistence, retry.
- `test/import_staging_typed_commit_widget_test.dart`: final flush, revision
  pass-through, fixed errors, double-submit block, legacy unchanged.
- `test/r7c1_attempt_aware_typed_commit_acceptance_test.dart`: seven vertical
  scenarios on real v15 file databases with close/reopen (success, completion
  failure rollback, question failure rollback + retry, stale attempt zero
  writes, stale revision zero writes, duplicate single batch, delayed save
  race).

## 17. Deferred work

- R7E full production V2 activation acceptance.
- PracticePage/WrongBookPage V2-first, typed editor, option structure editing.
- Historical rejected audit and V1 backfill.
- Legacy completion durability (legacy path intentionally unchanged).
- Database version upgrades (kept at 15).

## 18. R7E readiness

The typed writer path is now attempt-owned, revision-checked and atomically
durable: `commitTyped` can be invoked with a flush-produced revision and
either fully commits (questions + completion in one transaction) or fully
rolls back with a fixed safe failure and a retryable `pendingReview` task.
Provider calls remain 0 in all acceptance evidence.
