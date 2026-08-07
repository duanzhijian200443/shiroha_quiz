# R7C.1 Final Review Snapshot Closure

Status: IMPLEMENTED CLOSURE
Base: master@f515fb82911d255096a80d8ce089b9df4ba2daa3
Database version: 15 (unchanged)
Scope: `ImportStagingScreen` typed commit orchestration only

## 1. Original P1

`_confirmAndSaveTyped` constructed `TypedReviewCommitInput` items from
`_allItems` **before** the final review-draft flush, then committed those
entry-time items with the post-flush revision. Answer distillation
(`_isDistillingAnswers`) can rewrite the persisted review draft and
`_allItems`, and neither `_validateBeforeSave` nor the confirm button treated
distillation as a commit gate. The result: revision N could describe draft B
while the payload was draft A, so the R7C.1 revision gate could not prove
revision N <-> payload N.

## 2. Race sequence

1. User confirms while a review-draft mutation (distillation) is pending or
   lands mid-commit.
2. Old code: payload = entry-time `_allItems` (A); flush persists the current
   draft (B) and returns revision N.
3. Old code: `commitTyped(items: A, expectedReviewDraftRevision: N)`.
4. The revision gate proves the persisted draft is B at revision N, but the
   payload is A: revision N and payload N are decoupled.

## 3. Frozen invariant

A successful typed commit must guarantee:

final review flush -> revision N -> rebuild `TypedReviewCommitInput` from the
post-flush `_allItems` -> `commitTyped(post-flush items, N)`.

Building inputs before the flush and committing them with a newer revision is
forbidden.

## 4. Final flush ordering

`_confirmAndSaveTyped` now validates task/attempt metadata first, sets
`_isSaving = true`, runs one final `_persistReviewDraft()`, requires
`saved == true`, and only then rebuilds the payload. `_isSaving` is set before
the flush so the button and the internal path cannot double-submit.

## 5. Post-flush payload construction

The pure helper `_buildCurrentTypedCommitInputs()` reads the current
`_allItems`, `_reviewItemIds` and `_snapshotProvenance`, preserves the
`originalIndex` association, and strictly requires the persisted marker and
the `_typed_review_v1` envelope for every item. It returns null on any
invalid binding so the caller shows the fixed `_typedCommitBlockedText`
without exposing raw state. Derived inputs (`explanationOverrides`,
`explanationRetentionMode`) are also read from the post-flush state.

## 6. Distillation gate

The confirm button's `onPressed` is null when `_isSaving`,
`_isBlockedByQualityGate` or `_isDistillingAnswers` is true. While answers are
being generated, the save flow cannot be started from the button at all.

## 7. Programmatic gate

`_confirmAndSaveTyped` starts with
`if (_isDistillingAnswers) { _showFixedError('答案仍在生成中，请等待完成后再入库'); return; }`.
The disabled button is not the only protection: any bypassed save flow that
reaches the typed commit path while distillation is active is blocked with
the fixed prompt and zero repository writes.

## 8. Failure behavior

- Final flush not saved (`null`/`failed`/`stale`/`itemMissing`/`commitInProgress`):
  `校对结果尚未安全保存，无法入库，请重试`, zero `commitTyped` calls.
- Post-flush provenance invalid (marker/envelope missing): the flush still
  runs, then `结构化题目缺少必要的审核信息，无法入库，请检查后重试`, zero commits.
- Distillation active at typed entry: fixed in-progress prompt, zero commits.
- All downstream lease/revision/repository failures keep the frozen R7C.1
  behavior: fixed safe exceptions, `pendingReview` task, zero fallback.

## 9. Regression matrix

`test/r7c1_final_review_snapshot_closure_test.dart` (synthetic widget
harness, Fake TaskManager/Repository recording event sequences):

- 18.1 post-flush inputs: a real review-draft mutation lands while the final
  flush is in-flight; the commit payload is rebuilt from the post-flush
  state, `expectedReviewDraftRevision` equals the flush-returned revision.
- 18.2 distillation active: confirm disabled, no final flush, zero
  `commitTyped`, zero repository calls.
- 18.3 programmatic bypass: invoking the captured save handler while answers
  generate still blocks with the fixed prompt.
- 18.4 final flush failure: fixed unsafe-save prompt, zero commits.
- 18.5 post-flush provenance invalid: flush completes, then the fixed blocked
  text, zero commits. (The reviewItemId-missing branch is defensive: markers
  always have the task-local fallback for restart tasks.)
- 18.6 normal typed path: flush -> rebuild -> typed commit, guard carries
  `typedV2` + `typed_candidate_ready` and the flush revision.
- 18.7 legacy path: unchanged; no review revision requirement and no
  distillation typed gate is added to `commitLegacy`.
- 19 vertical race: delayed distillation completes first, confirm is blocked
  until then, the final commit binds answer B to the flush revision N; A is
  never committed.
- 20 order probe: `final_flush_started < final_flush_saved_revision_N <
  commit_input_observed:B < repository_commit` asserted strictly, not just by
  call counts.

## 10. Deferred CI hygiene

`.github/workflows/pr-contract-checks.yml` only appends the new test to the
existing focused contract matrix. No runner, action, cache, dependency or
workflow structure is changed.

## 11. R7E readiness

The typed commit now receives a payload provably rebuilt after the final
flush, so the R7C.1 revision/lease/transaction gates verify one consistent
snapshot. Legacy remains on the untouched writer; provider calls stay 0 in
all acceptance evidence.

## 12. P3-1 closure repair (2026-08-07)

Status remains IMPLEMENTED CLOSURE.

Finding (class B, closure pass 1/1): during `_isSaving` (final flush through
typed commit) several payload-mutating UI entries remained operable and could
rewrite `_allItems`/`_explanationOverrides` between the final flush and
`_buildCurrentTypedCommitInputs()`: the batch and per-item answer
distillation buttons, the document and per-question explanation retention
controls, the swipe-to-delete gesture, and the selection-mode batch
type/delete handlers. A mutation whose save was rejected by the commit lease
could leave the persisted draft at state A while the commit payload was
rebuilt as post-mutation state B, weakening the revision N <-> payload proof
in the narrow window.

Fix (commit SHA: 0e5bcdc74df850f89fbec10bb0b651c111f9049f): every
payload-mutating entry now carries both a UI disable and a programmatic gate.
UI: `onPressed`/`onSelected`/`onChanged` become null (and Dismissible uses
`DismissDirection.none`) while `_isSaving`; the app-bar batch icon and the
selection toolbar type/delete buttons are disabled too. Programmatic: each
mutation handler (`_applyBatchResult`, `_deleteSelectedWithConfirm`,
`_changeSelectedType`, `_setDocumentExplanationRetention`,
`_setQuestionExplanationRetention`, `_distillSingleAnswer`,
`_distillAllAnswers`, `_enterSelectionMode`, and Dismissible `onDismissed`)
returns immediately when `_isSaving`, so a bypassed caller cannot change the
commit payload or enqueue a review-draft save. The frozen ordering final
flush -> revision N -> rebuild post-flush inputs -> commitTyped(post-flush
items, N) is unchanged; legacy path stays untouched.

Verification: `dart format --output=none --set-exit-if-changed` and
`flutter analyze --no-pub --no-fatal-infos` on the two changed Dart files
pass; the focused contract matrix
(`import_staging_typed_commit_widget_test`,
`r7c1_final_review_snapshot_closure_test`, `import_commit_service_test`,
`task_manager_typed_commit_lease_test`,
`r7c1_attempt_aware_typed_commit_acceptance_test`,
`r7d_v2_first_question_list_acceptance_test`) passes 93/93 serially.
18.1/20 now land state B before confirm and still assert payload B with
revision == final flush revision; the new 18.8 asserts all disabled
controls, programmatic no-ops (`_allItems` unchanged, no enqueued save) and
payload == flush-saved state. Provider calls stay 0.

## 13. P3-2 test-only closure (2026-08-07)

Status remains IMPLEMENTED CLOSURE; production code unchanged.

Finding (class B, closure pass 1/1): the targeted Closure Reviewer reported
that 18.8 did not cover the selection-mode toolbar gating (`改题型` at
`import_staging_screen.dart:1970` and `删除` at :1980 disabled while
`_isSaving`) nor the programmatic no-ops of `_enterSelectionMode` /
`_deleteSelectedWithConfirm` / `_changeSelectedType`. The selection toolbar
replaces the bottom confirm button while active, so the save flow can reach
`_isSaving` with the toolbar still visible only through a bypassed entry;
the frozen invariant requires the toolbar handlers to be no-ops in that
window too.

Closure: test-only. New 18.9 in
`test/r7c1_final_review_snapshot_closure_test.dart` (same synthetic widget
harness and Fakes; no harness-behavior change to the existing 11 cases). The
test enters selection mode, selects both questions, opens the change-type
dialog, then invokes the captured confirm handler so the final flush runs
while the selection toolbar is up. It asserts both toolbar buttons are
disabled (`onPressed == null`) during `_isSaving`, and that programmatic
`_enterSelectionMode` / `_deleteSelectedWithConfirm` / the captured
change-type selection handler are no-ops: selection count unchanged, no
delete dialog, no type change, no enqueued save (`saveCount == 1`) and
`distillCalls == 0`. After the flush, the commit payload must equal the
flushed state (2 items, original types singleChoice/shortAnswer, answer and
explanation unchanged, revision == flush revision, success dialog shown).
`.github/workflows/pr-contract-checks.yml` already lists the test file and
needs no change.

Verification: `dart format --output=none --set-exit-if-changed` and
`flutter analyze --no-pub --no-fatal-infos` on the changed test file pass;
`flutter test --concurrency=1
test/r7c1_final_review_snapshot_closure_test.dart
test/import_staging_typed_commit_widget_test.dart` passes 25/25 serially
(12/12 + 13/13); `git diff --check` passes. Provider calls stay 0. Commit:
this test-only closure commit.
