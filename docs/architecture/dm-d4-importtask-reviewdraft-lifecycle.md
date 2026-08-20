# DM-D4 ImportTask / ReviewDraft Lifecycle Contract

Status: **CLOSED / FROZEN**
Frozen against: `master@f463fc2e8d242b2c23cbaf97a1ed23a3bf433882`
Date: `2026-08-19`

This document is the canonical lifecycle contract for `ImportTask` and its
`ReviewDraft`. It defines authority, state transitions, attempt identity,
cancel/retry behavior, review-draft concurrency, commit ordering, cleanup, and
retention. D4-D1, D4-D2, D4-D3, and D4-V0/CL must conform to this contract.

This is a contract freeze, not an implementation report. The implementation
comparison in Section 11 records known gaps so later work can close them
without silently changing the contract.

## 1. Scope and non-goals

DM-D4 covers the lifecycle of an import workflow before and around Question
commit:

```text
ImportTask durable workflow row
        -> current OCR ImportAttempt
        -> ReviewDraft (parsed_data + revision)
        -> Question / typed sidecar commit
        -> ephemeral workflow cleanup and retention
```

This freeze does **not** authorize:

- production Dart changes in DM-D4-P0;
- a database schema or migration change;
- UI redesign or a new confirmation surface;
- Agent or MCP behavior;
- OBS expansion;
- Rich Image or managed-asset lifecycle changes;
- garbage collection, reference counting, tombstones, or automatic orphan
  deletion;
- a new B0 portable-history format;
- starting D4-D1 implementation.

The existing Application mutation/backup gate remains the entry boundary for
durable workflow mutations. UI, Agent, and MCP adapters do not issue SQLite
operations directly.

## 2. Authority and ownership

### 2.1 ImportTask

`ImportTask` is durable, restart-readable **ephemeral workflow state**. Its
SQLite row is a checkpoint for an import attempt and its review handoff; it is
not confirmed learning data and is not B0 portable history.

The in-memory `TaskManager` collection is a projection/cache. It may be
reloaded, normalized after restart, or reconciled with SQLite, but it is never
allowed to overrule a successful durable commit or to claim a durable delete
that failed.

ImportTask may contain parsed question candidates, warnings, bounded diagnostics,
attempt identity, and review metadata. Those values remain workflow inputs until
the commit authority accepts them.

### 2.2 ReviewDraft

`ReviewDraft` is the temporary correction state inside an `ImportTask`:

```text
ReviewDraft = import_tasks.parsed_data
            + diagnostics._reviewDraftRevision
```

It is not the authority for a Question. A draft may be discarded, superseded,
or rejected without deleting or rewriting any already committed Question.
Question content becomes formal authority only after the Question commit
boundary succeeds.

### 2.3 Confirmed Question authority

After a successful commit:

- `Question` is confirmed learning data;
- for the typed route, the typed sidecar (`question_v2_payloads`) is the
  authoritative typed-content representation, with the required compatibility
  projection retained by the existing writer;
- Review/FSRS scheduling state remains separate mutable state;
- subsequent ImportTask or ReviewDraft cleanup is independent of the committed
  Question.

An ImportTask/ReviewDraft cleanup failure must never roll back, delete, or make
the committed Question unavailable. A post-commit workflow cleanup failure is a
retryable workflow/orphan condition, not a Question commit failure.

## 3. Frozen state vocabulary

### 3.1 TaskStatus

The persisted `TaskStatus` set is exactly:

```text
processing / pendingReview / completed / error
```

The current persistence mapping remains frozen as `processing = 0`,
`pendingReview = 1`, `completed = 2`, and `error = 3`. No new status is added by
DM-D4-P0.

| TaskStatus | Contract meaning | Cleanup/retention meaning |
| --- | --- | --- |
| `processing` | The task has an active or not-yet-settled attempt. | Active; no cleanup or housekeeping deletion. |
| `pendingReview` | The current attempt produced a ReviewDraft that is available for review. | Review-protected; no automatic cleanup while the draft is available. |
| `completed` | The Question commit has durably succeeded. | Final workflow state; eligible for explicit ephemeral cleanup and age-based housekeeping under Section 9. |
| `error` | The attempt failed, was cancelled, or was normalized to interrupted. | Final workflow state only after the attempt is settled; eligible for retry or final-state cleanup under Section 9. |

`completed` and `error` are final **workflow** states, not evidence that the
Question data was deleted or that a failed cleanup succeeded.

### 3.2 OCR ImportAttemptState

The OCR attempt state set is exactly:

```text
queued / running / cancelRequested / cancelled /
failed / interrupted / readyForReview
```

These values are attempt metadata, currently carried in bounded task
diagnostics. They must be interpreted by name, not guessed from an unrelated
TaskStatus value.

The normative transitions are:

```text
queued ------------------------------> running
  |                                      |
  | cancel                              | success
  v                                      v
cancelled                       readyForReview
  ^                                      |
  |                                      | successful commit
  |                                      v
cancelRequested <--------- running   completed task
  |
  | cancellation settles
  v
cancelled

running -----------------------------> failed

persisted active processing on restart -> interrupted
failed / cancelled / interrupted --explicit retry--> queued (new attempt)
```

Additional rules:

- `cancelRequested` is an in-progress cancellation state, not a terminal
  success or a cleanup target.
- A queued cancellation may settle immediately to `cancelled`; a running
  cancellation first records `cancelRequested` and then settles when the
  scheduler/request boundary has stopped the work.
- `readyForReview` corresponds to `TaskStatus.pendingReview` and protects the
  ReviewDraft until an explicit commit, discard, or other contract-approved
  terminal action.
- A persisted active task found after restart is normalized to
  `TaskStatus.error` + `interrupted`. Restart does not automatically start a
  new attempt.
- A stale attempt result, progress update, cancellation completion, or queued
  write must not change the current attempt or resurrect a deleted task.

## 4. Attempt identity and retry

An attempt is identified by:

```text
(taskId, attemptNumber, attemptToken, traceId)
```

Retry is an explicit user action only. It has all of the following properties:

1. preserve the existing `taskId`;
2. set `attemptNumber` to the previous value plus one;
3. generate a fresh `attemptToken`;
4. generate a fresh `traceId`;
5. optionally retain bounded parent/correlation lineage, without reusing the
   old attempt token or trace identity;
6. reset the new attempt to `queued` and start it only through the normal
   Application pipeline boundary.

There is no automatic retry or automatic restart after app restart. A task in
`cancelRequested` remains active until cancellation settles; it cannot be
cleaned up or forked into a concurrent retry. Retry is admitted only after a
terminal `failed`, `cancelled`, or `interrupted` outcome, and is rejected
closed if the current attempt identity no longer matches.

The old attempt must remain causally distinguishable from the new attempt.
An old completion, progress event, or persistence callback cannot overwrite
the new attempt merely because both use the same `taskId`.

## 5. Cancellation

Cancellation is an Application operation under the existing mutation/backup
gate:

- `queued` and `running` may enter cancellation;
- `running -> cancelRequested` is the observable processing intermediate state;
- cancellation must eventually settle to `cancelled` or a fixed failure result;
- a task that is active (`processing`, `queued`, or `running`) or
  `cancelRequested` is not cleanup-eligible;
- cancellation must not delete Question, typed sidecar, ReviewState, ReviewLog,
  AnswerAttempt, LibraryFile, or ParsedArtifact data;
- a cancelled task remains eligible for explicit retry with a new attempt
  identity.

If durable cancellation persistence fails, the failure remains observable and
retryable. Neither the UI nor the in-memory projection may report a durable
cancelled state that SQLite did not accept.

## 6. ReviewDraft concurrency and CAS

The current ReviewDraft revision is a positive monotonically increasing value
stored with the task metadata. A write that supplies `expectedRevision` is
valid only when:

```text
expectedRevision == current persisted revision
```

On success the write stores the new `parsed_data` and increments the revision
as one logical durable update. A stale draft fails closed with a fixed typed
stale result and performs no draft mutation. It must not silently merge over a
newer revision.

Commit uses a task-scoped commit lease:

- review-draft writes already queued before lease acquisition drain in order;
- once the lease is active, new ReviewDraft mutation is rejected as
  `commitInProgress`;
- the commit observes the exact revision bound to the lease;
- a failed commit releases the lease and leaves the reviewable task/draft
  available for a controlled retry;
- a successful durable commit clears the workflow draft only after the
  Question commit transaction has succeeded.

The same serialization rule applies to every future commit route. A legacy
route may not bypass the ReviewDraft CAS or commit lease merely because it
uses a compatibility writer.

## 7. Commit contract

### 7.1 Typed V2 authority

The existing typed V2 commit remains the authoritative commit path for eligible
typed tasks. Its durable order is:

```text
validate task / attempt / ReviewDraft revision / route
  -> acquire commit lease
  -> one SQLite transaction:
       validate the persisted pending-review task
       write Question compatibility rows
       write typed sidecars
       write initial review/folder relations
       mark import_tasks completed and clear parsed_data
     COMMIT
  -> update the in-memory TaskManager projection only
```

The transaction is the authority. If it fails, all of its Question, sidecar,
relation, and task-completion writes roll back together; the task remains
reviewable or returns a typed failure. In-memory completion synchronization
must not issue a second durable task write that can recreate an old draft.

### 7.2 Legacy compatibility commit

The legacy route remains supported for compatibility, but its durable contract
is frozen as follows:

> A legacy commit must ultimately guarantee that Question write and ImportTask
> completion cannot produce an ambiguous partial workflow state.

It must not report an unqualified final success while one durable effect has
succeeded and the other is unknown or failed. D4-D3 must close this boundary by
using one authoritative transaction or a typed reconciliation-needed outcome;
it must not silently rely on two independent durable writes.

This requirement does not authorize a production change in D4-P0. The current
legacy implementation is recorded as a known follow-up gap in Section 11.

### 7.3 Post-commit cleanup

Once the Question commit transaction has committed, ImportTask/ReviewDraft
cleanup is a separate D1 operation. A cleanup error cannot change the commit
result to “Question commit failed,” cannot delete the Question, and cannot roll
back the already committed typed sidecar.

## 8. Cleanup contract

ImportTask cleanup is D1 ephemeral cleanup. It has no destructive data-purge
confirmation and must never be treated as Question/AnswerAttempt deletion.

### 8.1 Eligibility

- active `processing` tasks, `queued`/`running` attempts,
  `cancelRequested`, and any task with unsettled work are protected;
- `pendingReview` / `readyForReview` tasks are protected while a ReviewDraft is
  available, unless a separately named discard operation is introduced by a
  later contract;
- only settled final `completed` or `error` workflow rows may enter explicit
  ephemeral cleanup or age-based housekeeping;
- cleanup cannot be used to force completion, cancellation, or commit.

### 8.2 Durable-first truth

Durable cleanup is authoritative:

```text
check current durable task/attempt identity
  -> execute the durable cleanup/delete under the Application gate
  -> observe successful DB commit
  -> invalidate/remove the in-memory projection
```

If the DB operation fails:

- the failure remains observable and retryable;
- the durable row remains the source of truth;
- memory must not claim that durable deletion succeeded;
- any stale UI/projection is reconciled by a later reload, not treated as
  proof of deletion.

No cleanup path may delete Question, typed sidecar, ReviewState, ReviewLog,
AnswerAttempt, LibraryFile, or ParsedArtifact as an implicit side effect.

### 8.3 Stale queued writes

Every queued or delayed task write must be bound to the task/attempt/revision it
was accepted for and re-check durable eligibility before writing. After a task
has been durably deleted, a stale callback must become a safe no-op or typed
stale/missing result. It must not use an unconditional replace/upsert to
resurrect the deleted task.

This invariant must be implemented with the smallest existing serialization,
identity, and database checks available. DM-D4 does not introduce a tombstone,
GC, or reference-count framework.

## 9. Retention and restart policy

### 9.1 Current retention policy frozen for D4

The current housekeeping window is **three days** based on `completedAt` for
settled final workflow rows. The state-aware rules are:

| Task class | Retention rule | Housekeeping behavior |
| --- | --- | --- |
| Active (`processing`, queued/running, `cancelRequested`) | Retain regardless of age until settled. | Never auto-delete. |
| Review (`pendingReview`, `readyForReview`) | Retain while a ReviewDraft is available, regardless of age. | Never auto-delete merely because `completedAt` is old. |
| Final (`completed`, `error`, including failed/cancelled/interrupted) | Retain for at least three days from a valid `completedAt`. | Eligible for D1 housekeeping after the cutoff. |
| Final with missing/invalid `completedAt` | Fail closed and retain. | No automatic deletion. |

Explicit cleanup may remove only a settled final workflow row and must obey the
durable-first rules in Section 8. It does not remove confirmed Question data.
No restart automatically resumes a retained active row; a normalized
`interrupted` task needs explicit retry.

### 9.2 Housekeeping isolation

Housekeeping is maintenance, not the authority for loading tasks. A
housekeeping failure must be observable but must not prevent the normal task
load from proceeding. The load path must still read and project durable task
rows, then expose the maintenance failure as retryable diagnostics/status.

This rule also applies when an old-row delete succeeds but a later projection
step fails: durable rows are re-read as the authority and memory is not used to
invent a deletion result.

## 10. Invariants that later D4 work must preserve

1. ImportTask/ReviewDraft are ephemeral workflow state, never confirmed
   Question authority and never B0 portable answer history.
2. `taskId` survives retry; `attemptNumber`, `attemptToken`, and `traceId` do
   not get reused.
3. Restart does not automatically resume or retry an OCR attempt.
4. A stale attempt, stale ReviewDraft revision, stale commit lease, or stale
   queued write fails closed and cannot overwrite newer durable state.
5. Active and review-protected tasks cannot be cleaned up.
6. DB failure is observable/retryable; memory never claims a durable deletion
   that did not commit.
7. Typed V2 Question/sidecar commit is one authoritative transaction.
8. After Question commit, workflow cleanup cannot roll back or delete the
   committed Question.
9. Legacy commit cannot report an ambiguous partial workflow success.
10. Housekeeping failure cannot block normal task load.

## 11. Current implementation self-check

The following matrix is a read-only comparison against
`master@f463fc2e8d242b2c23cbaf97a1ed23a3bf433882`. “Follow-up gap” means the
contract is frozen now and must be implemented in the named later stage; it is
not permission to change production code in DM-D4-P0.

| Contract area | Current implementation evidence | D4 status |
| --- | --- | --- |
| Task authority and four TaskStatus values | `lib/services/task_manager.dart` defines the four enum values and serializes the existing index; `lib/data/repositories/import_task_repository.dart` / `lib/core/database/database_helper.dart` persist `import_tasks`. | Aligned; in-memory projection must remain subordinate to durable state. |
| OCR attempt state vocabulary | `lib/services/import_pipeline/import_attempt_context.dart` defines `queued`, `running`, `cancelRequested`, `cancelled`, `readyForReview`, `failed`, and `interrupted`; `TaskManager` reads the named diagnostic state. | Aligned vocabulary; durable ordering/failure behavior is D4-D2. |
| Restart behavior | `TaskManager._loadTasksFromDb()` normalizes persisted `processing` tasks to `error` + `interrupted` and clears partial payload/chunks; `test/task_manager_import_diagnostics_test.dart` covers this. | Aligned; no automatic restart. |
| Retry identity and stale attempt isolation | `ImportTaskCoordinator.retryOcrTask()` and `TaskManager.restartAttempt()` preserve task ID, require the next attempt number, and accept a fresh token/trace; coordinator checks current attempt before applying results. | Partial. Identity semantics are aligned, but `TaskManager.restartAttempt()` currently also admits `cancelRequested`. D4-D2 must reject retry until cancellation has settled and must close persistence/stale-attempt races. |
| Cancel transition | `ImportTaskCoordinator.cancelOcrTask()` uses the mutation gate; `TaskManager.requestAttemptCancellation()` distinguishes queued, running, and `cancelRequested`. | Mostly aligned; persistence-failure semantics remain D4-D2. |
| ReviewDraft storage and CAS | `TaskManager.saveReviewDraft()` stores `parsedData` plus `_reviewDraftRevision`; `_saveReviewDraftNow()` rejects an expected-revision mismatch without mutating the newer draft. | Partial. `TaskManager` serializes review writes and checks the in-memory revision, then persists before publishing the new projection. The database write is currently unconditional replace/upsert rather than a persisted conditional revision CAS. D4-D3 owns closure of the persisted CAS boundary. |
| Commit lease | `TaskManager.beginTypedCommitAttempt()` serializes with the review-write tail and rejects concurrent draft writes; `ImportCommitService.commitTyped()` releases the lease on failure. | Aligned for typed V2; D4-D3 must make the legacy route obey the same boundary. |
| Typed V2 atomic commit | `QuestionRepository.commitQuestionDraftsV2ForImport()` validates the persisted guard and writes Question rows, typed sidecars, relations, and ImportTask completion in one transaction. `test/import_commit_service_test.dart` and typed guard tests cover stale/lease/failure paths. | Existing authority; preserve unchanged in D4-P0. |
| Post-commit workflow cleanup | Typed completion updates the in-memory projection only after the durable transaction; cleanup is conceptually separate. | Contract frozen; D4-D1 owns durable cleanup semantics. |
| Legacy Question + task completion | `ImportCommitService._commitLegacyUnchecked()` calls `saveQuestionDraftsToBank()` and then `TaskManager.completeTask()` as separate effects. | Follow-up gap: D4-D3 must eliminate ambiguous partial success. |
| Cleanup failure truth | `TaskManager.deleteTask()` and `clearCompletedTasks()` currently remove from memory before DB cleanup and log persistence failure without surfacing a durable failure. | Follow-up gap: D4-D1 must make DB-first success authoritative and retryable. |
| Active/review cleanup guard | Current implementation evidence: `TaskCenterProjection` blocks delete for detailed OCR `queued`/`running`/`cancelRequested` states, but the coarse/non-OCR presentation currently exposes delete without enforcing `processing`/`pendingReview` eligibility. Persistence methods are also broader than the frozen cleanup contract. | Follow-up gap: D4-D1 must enforce eligibility at the Application/persistence authority, and Presentation must mirror that authority for both detailed OCR and coarse/non-OCR tasks. |
| Stale queued writes after delete | Per-attempt write tails and current-attempt checks exist in `TaskManager`; database task persistence still uses replace semantics and delete does not yet establish a durable stale-write barrier. | Follow-up gap: D4-D1/D2 must prevent resurrection without tombstones/GC. |
| Three-day retention | `TaskManager._loadTasksFromDb()` invokes `deleteOldImportTasks()` before load; `DatabaseHelper.deleteOldImportTasks()` filters `completed_at` older than three days. | Partial: D4-D1 must make it state-aware so old ReviewDrafts are protected and housekeeping failure cannot block load. |
| Housekeeping isolation | `_loadTasksFromDb()` currently wraps housekeeping and task loading in one catch boundary. | Follow-up gap: D4-D1 must isolate maintenance failure from normal load. |

## 12. Follow-up stages

### D4-D1 — durable cleanup / retention

Implement durable-first ImportTask cleanup, active/review/final eligibility,
retryable DB failure reporting, stale-write deletion barriers using existing
identity/serialization seams, and housekeeping isolation. Do not delete
confirmed Question data and do not introduce GC/ref-count/tombstone machinery.

### D4-D2 — cancel / retry durability

Make cancellation settlement, retry identity, restart normalization, scheduler
interactions, and durable stale-attempt rejection linearizable across restart,
in-flight work, and persistence failure. Preserve the no-automatic-restart
rule.

### D4-D3 — ReviewDraft / commit authority

Carry the revision CAS and commit lease across every commit route, preserve the
existing typed V2 transaction, and close the legacy Question-write/task-
completion ambiguity with one authoritative transaction or a typed
reconciliation-needed outcome.

### D4-V0 / CL — acceptance and closure

Add focused acceptance for restart normalization, explicit retry identity,
cancel settlement, stale attempt/draft writes, commit lease ordering, typed
atomic commit, legacy partial-failure handling, cleanup failure truth,
resurrection prevention, retention boundaries, and housekeeping-failure task
load. Closure requires contract, implementation, and test scope to agree.

## 13. Frozen boundary

DM-D4-P0 freezes the lifecycle semantics above. It changes no production Dart,
schema, migration, UI, Agent/MCP, OBS, Rich Image, GC/ref-count, or B0
runtime. Any later proposal that changes authority, state vocabulary, retry
identity, commit ordering, cleanup classification, or retention policy must
amend this canonical contract before implementation.

## 14. D4-V0 / CL Closure Addendum

This addendum records implementation provenance after the historical,
read-only P0 comparison in Section 11. It does not rewrite that comparison or
imply that the later implementation was already present at the P0 freeze.

### 14.1 Implementation provenance

- D4-D1 durable cleanup / retention:
  `758cb33` and `00406d1` (merged by PR #129).
- D4-D2 cancel / retry durability:
  `45765de`, `ce1a69c`, `fd17904`, and `0a4a8dc` (merged by PR #130).
- D4-D3 ReviewDraft / commit authority:
  `687802d` (persisted ReviewDraft compare-and-set) and `c5131db`
  (task-bound legacy atomic commit, shared lease arbitration, and legacy
  same-attempt resume entry closure).
- D4 final implementation / acceptance head: `c5131db`.

No schema or migration change was required; runtime schema remains v23.

### 14.2 Final fault-matrix authority

The final D4 acceptance matrix is owned by the following focused regressions:

| Fault class | Regression authority |
| --- | --- |
| restart / explicit retry identity | `test/task_center_restart_recovery_test.dart`, `test/import_task_coordinator_test.dart` |
| cancellation settlement / persistence failure | `test/task_manager_import_diagnostics_test.dart`, `test/import_task_coordinator_test.dart` |
| persisted ReviewDraft revision / stale attempt / stale resurrection | `test/data/repositories/import_task_review_draft_cas_test.dart`, `test/task_manager_typed_review_snapshot_test.dart` |
| typed commit lease / atomic commit / rollback | `test/task_manager_typed_commit_lease_test.dart`, `test/import_commit_service_test.dart`, `test/question_repository_v2_test.dart` |
| legacy exact nullable identity / lease / atomic rollback | `test/task_manager_typed_commit_lease_test.dart`, `test/import_commit_service_test.dart`, `test/question_repository_v2_test.dart`, `test/import_staging_typed_commit_widget_test.dart` |
| cleanup / retention / housekeeping failure | `test/task_manager_cleanup_test.dart` |
| staging draft / commit / batch-action races | `test/import_staging_typed_commit_widget_test.dart`, `test/import_staging_batch_actions_widget_test.dart` |

The persisted ReviewDraft authority returns the actual durable revision to a
stale caller. Ordinary saves capture the current projection revision and use
it as the persisted expected revision; there is no production unconditional
ReviewDraft save. Task-bound legacy commits bind exact nullable attempt
identity (null is not a wildcard), use the same task-scoped lease arbitration
as typed commits, and commit Question rows plus ImportTask completion in one
SQLite transaction. Task-less compatibility writes retain their historical
behavior.

### 14.3 Closure status

At the D4 final implementation / acceptance head, the Executor closure target
has no known open P0, P1, or P2 defect. Independent verification and review of
the Draft FINAL PR remain required before any merge; this addendum is not a
self-approval or merge authorization.
