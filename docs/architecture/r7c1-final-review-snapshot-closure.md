# R7C.1 Final Review Snapshot Closure

Status: IMPLEMENTED CLOSURE
Database version: 15 (unchanged)
Scope: typed commit orchestration and acceptance evidence for `ImportStagingScreen`

## Current invariant

A successful typed commit must bind one persisted review revision to the exact payload that is committed:

```text
block payload mutation
-> final review-draft flush
-> obtain revision N
-> rebuild TypedReviewCommitInput from the stable current staging state
-> commitTyped(post-flush items, N)
```

Building commit inputs before the final flush and pairing them with a later revision is forbidden.

## Commit-time mutation gate

While `_isSaving` is true, every staging action that can change the typed commit payload must be unavailable in the UI and a no-op if invoked programmatically. This includes:

- single/batch answer distillation;
- document/per-question explanation retention;
- swipe deletion;
- selection-mode entry;
- selection-mode type change/delete;
- batch-result application.

This keeps the state used for the final flush stable until the repository commit observes the rebuilt inputs.

## Distillation gate

A typed commit cannot begin while answer distillation is active.

The confirm UI is disabled while `_isDistillingAnswers`, and the typed save path independently rejects a programmatic bypass with the fixed safe message:

```text
答案仍在生成中，请等待完成后再入库
```

The disabled button is not the only protection.

## Final flush and payload rebuild

`_confirmAndSaveTyped`:

1. validates task/attempt metadata;
2. enters `_isSaving`;
3. performs the final `_persistReviewDraft()`;
4. requires a saved result and revision N;
5. calls `_buildCurrentTypedCommitInputs()` only after that successful flush;
6. reads derived explanation-retention inputs from the same stable post-flush state;
7. calls `commitTyped(... expectedReviewDraftRevision: N ...)`.

`_buildCurrentTypedCommitInputs()` preserves `originalIndex` binding to review markers/snapshot provenance and rejects missing typed envelopes with a fixed safe blocked result rather than exposing raw state.

## Failure behavior

- final review draft not safely saved -> zero typed repository writes;
- missing/invalid post-flush typed provenance -> zero typed repository writes;
- distillation active -> zero typed repository writes;
- stale attempt/revision/lease/repository failures retain the R7C.1 fixed-safe-error and no-legacy-fallback behavior;
- legacy writer behavior remains unchanged by this closure.

## Acceptance evidence

The focused R7C.1 acceptance covers the contract dimensions rather than implementation history:

- post-flush payload/revision binding;
- distillation UI and programmatic gates;
- commit-time payload-mutation gates, including selection-mode controls;
- final-flush failure and invalid provenance with zero writes;
- normal typedV2 commit with the final review revision;
- unchanged legacy path;
- vertical answer-distillation race ending in the distilled answer;
- strict ordering from final flush completion to commit input observation to repository commit.

## R7E readiness

R7C.1 closes the typed finalization race required before full production V2 activation acceptance. R7E may treat the final-review snapshot, attempt/revision guard, atomic typed persistence, and V2-first question-list work as frozen prerequisites rather than reopening their implementation history.
