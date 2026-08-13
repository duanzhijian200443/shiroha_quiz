# P6 Supplemental Answer Matching — Focused Canonical Contract

Status: **Canonical P6 authority. P6-P0 is COMPLETE (canonical docs only).**

P6-D0 and later stages are NOT STARTED.

This document is the authoritative contract for P6 supplemental-answer
matching: input boundary, supplemental document projection, deterministic
matching, transient `AnswerCandidate` lifecycle, Preview/Review and explicit
confirmation, the write boundary that reuses the existing typed answer
mutation authority, stale/CAS semantics, failure taxonomy, stage graph, and
the future acceptance matrix. P6-P0 freezes design only; it implements no
production code, tests, or schema migration.

## 1. Purpose

The only P6 goal:

```text
explicit supplemental LibraryFile
        +
resolved typed target scope
        ->
deterministic supplemental answer matching
        ->
transient AnswerCandidate
        ->
Preview / Review
        ->
explicit confirmation
        ->
existing typed answer mutation kernel
```

P6 does not create a second answer persistence protocol. Multiple PDFs always
remain multiple independent `LibraryFile` / `ParsedArtifact` objects; nothing
in P6 pairs or merges documents.

## 2. Input boundary and target scope

Frozen request shape:

```text
SupplementalAnswerMatchRequest
  targetScope:
    QuestionBankScope(bankName)
    | ProjectScope(projectId)
    | ExplicitQuestionScope(ordered storageIds)
  supplementalFileId: exactly one explicitly selected LibraryFile
```

Rules:

- one session = one target scope + one supplemental file;
- Project is resolved at session start into a complete typed-question
  snapshot; later Project relation drift does not change the session;
- the supplemental file need not belong to the Project;
- no automatic discovery of adjacent, same-name, or historical paired files;
- an explicit subset preserves caller order and must explicitly report
  missing, duplicate, and legacy targets;
- legacy targets are visible-but-ineligible;
- no eligible typed target -> `targetUnavailable`.

Formal target identity is `TypedPersistedQuestion.storageId`.
`QuestionDraftV2.questionId` is a draft content identity and must never be
used as a persistence identity.

## 3. Supplemental document projection

Frozen transient shape:

```text
SupplementalAnswerFragment
  fragmentId
  normalized main-number feature
  optional transient subquestion feature
  answerContent: RichContent
  optional explanationContent: RichContent
  heading/context
  ordered SourceRefs
  source sequence/table position
  optional stem context
```

Rules:

- consumes only the current F1 `SourceDocument` through
  `ParsedArtifactLifecyclePort.getCurrentArtifact(fileId)`; never sidecars,
  SQLite rows, or managed paths directly;
- no implicit ensure/reparse/OCR; `auto` never triggers OCR;
- paragraph / heading / formula / table / continuation parts are projectable;
- table parts support explicit "question-number row + answer row" layouts;
- image/asset parts participate only when typed alternative text already
  exists; P6 never runs OCR;
- unsupported / image-only / raw-unsafe nodes never produce a writable answer;
- a multi-part answer combines `RichContent` nodes structurally;
  flatten -> string -> reparse is forbidden;
- explanation may be previewed but is never persisted.

## 4. Matching objects

Three layers:

```text
AnswerMatchRecord
AnswerCandidate
TargetCoverage
```

`AnswerMatchRecord.disposition`: `matched | ambiguous | unmatched | conflict |
invalid`.

- `AnswerCandidate` exists only for a deterministic unique target.
- `unmatched` = a source fragment has no target.
- `uncovered` = a formal target has no supplemental answer.
- The two must never be conflated.

## 5. Matching contract

Permitted deterministic normalization:

- Unicode / full-width digits;
- common explicit question-number punctuation;
- explicit "第1题" markers;
- contextual `(1)/(2)` sub-markers;
- whitespace / equivalent punctuation;
- structural normalized stem fingerprint.

Forbidden:

- LLM / embedding / semantic-model matching;
- edit-distance threshold auto-write;
- UUID / SQLite row order / createdAt as question order;
- filename inference;
- sequence-only matching;
- forcing parenthesized numbers into subquestions without context.

Primary identity proofs (any one, plus hard compatibility):

1. scope-unique exact normalized main number;
2. unique main number + explicit subquestion proof;
3. no number, but scope-unique exact normalized full stem fingerprint;
4. same-locator continuation group that still resolves uniquely.

Question type / answer shape is a hard compatibility filter. Heading, source,
and neighborhood are corroboration only. Sequence never upgrades a match by
itself.

## 6. Ambiguity semantics

Must be `ambiguous` when:

- the strongest evidence vector maps to multiple targets;
- rank tie;
- duplicate number without a unique sub/stem proof;
- sequence/neighborhood only;
- a sub-marker exists but the target lacks sufficient transient features;
- a plausible target lacks a primary identity proof;
- Project/explicit subset duplicates a locator across banks.

`ambiguous` never produces a committable Candidate, never auto-selects by
score, and P6 v0 allows no arbitrary target override. The user may narrow the
scope or fix the source, then rematch.

## 7. Multi-fragment semantics

- one fragment -> multiple questions: `ambiguous`; copying is forbidden;
- multiple identical answer fragments -> one question: structurally equal
  fragments merge provenance into one Candidate;
- answer + explanation/continuation: compose in source sequence;
- mutually conflicting answers: `invalid(sourceConflict)`;
- multiple subquestions -> parent: only when the expected transient
  subquestion set is uniquely and completely covered and the target supports
  `ContentAnswer`, composed in sub-order; otherwise `ambiguous`;
- never compose a multi-select answer for a `singleChoice` target.

## 8. Confidence semantics

P6 defines no probability confidence and freezes no 0-1 score. An internal
lexicographic evidence rank is allowed for sorting review alternatives only:

```text
locator identity
> exact stem
> type compatibility
> heading/source corroboration
> neighborhood
```

The rank is never persisted, never exposed as probability, never bypasses the
identity-proof gate, and a tie is always `ambiguous`.

Canonical outputs:

```text
MatchCertainty: deterministic | ambiguous | none
MatchEvidence:  typed codes
Disposition:    matched | ambiguous | unmatched | conflict | invalid
```

## 9. Candidate lifecycle

```text
session -> snapshot -> project fragments -> match -> review
```

- missing current answer: matched/fill -> select -> explicit confirm ->
  commit;
- equivalent: noOp -> terminal -> zero transaction;
- different: conflict -> per-question replace review -> per-question explicit
  reconfirm -> commit;
- ambiguous/unmatched/invalid: review-only terminal -> never committable.

Rules:

- Candidate is immutable;
- Candidate/session are transient and lost on process exit;
- `sessionRevision` increments on every review decision;
- confirm carries exactly `candidateId + sessionRevision`;
- stale never auto-rematches or retries;
- P6 v0 has no Candidate answer editor.

## 10. Existing-answer contract

- missing: fill;
- typed structural equivalent: noOp;
- different: conflict.

Equivalence:

- `ChoiceAnswer`: compare formal option IDs;
- `ContentAnswer`: compare `RichContent` structure;
- rendered-text similarity is never equivalence;
- typed explicit-empty is not missing.

A supplemental single-choice label must map uniquely to a current option
label -> option ID; otherwise `invalidCandidate`.

## 11. Confirmation and write boundary

```text
AnswerCandidate
  -> Review
  -> explicit confirmation
  -> P6 Application command
  -> existing typed answer mutation authority
```

The existing authority is currently `TypedAnswerCommand` /
`TypedAnswerPersistencePort` / `TypedAnswerPersistenceKernel` (or any
equivalent application command that reuses that kernel). P6 adds no second
answer writer.

- fill candidates may be explicitly batch-selected, but each question commits
  independently with independent stale/failure;
- conflict never enters a fill batch; each conflict requires per-question
  replace reconfirmation;
- Domain/Application never read SQLite directly.

## 12. Atomic stale protection

Confirm performs two layers inside one linearized boundary.

Layer 1 — through the F1 seam, re-read the current artifact and confirm
`fileId`, `artifactId`, `revision`, and readable payload exactly match the
Candidate.

Layer 2 — inside one caller-owned persistence transaction, recheck:

- current parsed-artifact metadata generation;
- target `storageId` exists;
- current `bankName` == snapshot;
- current `QuestionDraftV2` == expectedDraft;
- current answer state still satisfies the fill/replace precondition;

then reuse `TypedAnswerPersistenceKernel` in the same transaction.

Purpose: give reparse publish and answer mutation a definite ordering and
eliminate artifact-check -> later-write TOCTOU.

If the existing transaction abstraction cannot carry both the artifact
metadata generation check and the typed answer kernel, P6-C0 must STOP and
re-plan; degrading to a non-atomic double check is forbidden.

## 13. Stale semantics

Any of the following -> `staleTarget` -> zero mutation:

- artifactId/revision change;
- target draft change;
- target answer change;
- target bank change;
- target deleted.

Even content that "looks equivalent" is stale. Project membership affects
only the session-start snapshot; commit never reinterprets Project
membership.

## 14. Provenance

P6 v0 updates only the persisted question answer. Never persisted:

- supplemental explanation;
- supplemental SourceRefs;
- Candidate;
- review session;
- match evidence.

These exist only in transient Preview/Review. Therefore: no schema change.

## 15. Failure taxonomy

Frozen semantic categories (future enum names may differ; the semantics are
canonical):

```text
sourceUnavailable
artifactCorrupt
unsupportedArtifact
noUsableAnswers
targetUnavailable
ambiguousMatch
unmatched
conflict
staleTarget
invalidCandidate
temporarilyUnavailable
internalError
```

Requirements:

- missing / corrupt / unavailable are never conflated;
- corrupt artifact fails closed;
- no raw exceptions;
- no managed paths leaked;
- no OCR/raw source text leaked into errors;
- `internalError` exposes only a safe category / trace ID.

## 16. Permanent prohibition of legacy merge

The following are never P6 seams:

- `reference_answer_merger`;
- `multi_file_question_merge_service`;
- paired PDF;
- combined merge;
- automatic two-PDF pairing.

P6 means explicit supplemental file + explicit target scope, no automatic
pairing, no implicit merge, no neighboring-file inference. The legacy
services may at most inform pure normalization fixtures; their merge
authority is never reused.

## 17. Non-goals

P6-P0 and P6 v0 do not include:

- schema migration;
- persisted Candidate;
- persisted supplemental provenance;
- persisted explanation;
- formal subquestion schema;
- arbitrary ambiguous remapping;
- Candidate answer editing;
- bulk conflict overwrite;
- OCR/provider invocation;
- AI matching;
- P7;
- RAG;
- Agent/MCP expansion;
- UI redesign;
- multi-supplemental durable relation;
- restoration of old paired/combined merge.

## 18. Stage graph

```text
P6-P0 -> P6-D0 -> P6-X0 -> P6-Q0 -> P6-M0 -> P6-R0 -> P6-C0 -> P6-U0 -> P6-V0
```

Definitions:

- P6-P0 canonical contract (this stage);
- P6-D0 transient domain;
- P6-X0 SourceDocument projector;
- P6-Q0 typed target snapshot;
- P6-M0 deterministic matcher;
- P6-R0 review lifecycle;
- P6-C0 confirm/CAS/typed commit;
- P6-U0 bounded Preview/Review activation;
- P6-V0 offline acceptance/closure.

All P6 stages are SERIAL. This change completes P6-P0 only; no P6-D0+ stage
is COMPLETE, and later stages never auto-activate.

## 19. Acceptance matrix and fixture policy

Minimum future acceptance matrix:

- exact question number;
- number + subquestion;
- duplicate numbers;
- cross-bank duplicate;
- supplemental missing target;
- sequence mismatch;
- answer across multiple parts;
- table number/answer layout;
- existing answer fill/noOp/conflict;
- artifact reparse stale;
- target draft/answer/bank stale;
- ambiguous zero write;
- unmatched zero write;
- reject zero write;
- user confirm typed write;
- explicit subset order/missing IDs;
- Project snapshot relation drift;
- legacy target ineligible;
- corrupt artifact fail closed;
- choice label -> option ID;
- fragment source conflict;
- stale session revision;
- fill batch per-item stale;
- no OCR/provider invocation;
- no paired-directory scanning;
- no old merge service use.

Fixture policy:

- checked-in `SourceDocument` fixtures = real layout patterns + fictional
  content;
- real graduate-exam PDF text/answers never enter CI fixtures;
- private PDFs are limited to future local smoke runs and never enter the
  repository or CI.

## 20. Stop conditions and documentation authority

Stop conditions:

- any requirement for schema, production, or test modification without
  separate authorization;
- any requirement that conflicts with transient candidates, the single typed
  write authority, or the atomic stale boundary;
- any expansion into deferred capabilities (P7, RAG, OCR/AI matching,
  persistence of candidates/provenance/explanation, formal subquestion
  schema, UI redesign, Agent/MCP expansion).

Documentation authority:

- `ARCHITECTURE.md` — repository-wide dependency and boundary contract;
- this document — focused P6 authority;
- `docs/architecture/f1-parsed-artifact-lifecycle.md` — current artifact
  identity/revision and the Application seam P6 consumes;
- `docs/product/W0 Safe Agent Write.md` — the shared typed-answer write
  authority P6 reuses;
- `docs/architecture/n0-post-p5-roadmap.md` — stage ordering and current
  status.
