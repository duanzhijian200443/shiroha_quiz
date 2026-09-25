# IMPORT-RD0: Initial durable ReviewDraft materialization

## Scope and authority

For a new `documentImportEntry` task whose persisted storage route is `typedV2` with reason `typed_candidate_ready`, successful parsing first persists `pendingReview`, the deduplicated `parsedData`, and `readyForReview` for the current attempt. A separate TaskManager operation then submits that same payload and the task's review explanation retention to the existing ReviewDraft CAS writer with `expectedRevision = 0`. A successful CAS makes revision 1 durable before notification or opening Review. Revision 1 is a real persisted review snapshot, not a synthetic commit token.

This is a second, conditional persistence operation after the parse-result task write. A failure in the second operation never rolls back the first: the task stays `pendingReview`, its parsed payload remains available, and the existing Review UI can perform the first `0 → 1` save. No auto commit is introduced here.

## Result and concurrency contract

The operation returns `materialized` for a successful `0 → 1` CAS; `alreadyMaterialized` for a positive revision on the same current attempt, including when a manual save wins first; `ineligible` for an unsupported route, entry, state, empty payload, invalid revision or active commit lease; `staleAttempt` for a changed attempt; and `failed` for a persistence failure. None of these fallback outcomes turns a successful parse into a task error or deletes its Review payload.

RD0 runs in the existing ReviewDraft write queue. Manual Review saves and typed commit lease acquisition share that queue. The existing persisted CAS checks exact attempt identity and expected revision, so only one writer can win `0 → 1`; RD0 does not add a writer or bypass the lease. A restart loads a durable positive revision and does not initialize it again. Review continues normal CAS from the loaded revision.

## Frozen target through the transition

When a document import already has a nonempty `bankName` and parse completion supplies an empty bank, `requireAttemptReview` preserves both `bankName` and `folderName`. A conflicting nonempty target or classification is rejected. Retry preserves a nonempty frozen document target. Historical, photo, and other compatibility callers retain their prior target behavior. The target remains in the existing ImportTask fields; RD0 introduces no bank identity or schema change.

Existing ReviewDraft CAS, positive revision and typed commit guards remain unchanged. This contract does not alter question persistence, OCR/P6 behavior, quality scoring, or legacy writers.
