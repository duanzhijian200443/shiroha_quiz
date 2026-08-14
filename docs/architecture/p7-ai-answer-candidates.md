# P7 AI Answer Candidates — Focused Canonical Contract

Status: **Canonical P7 authority. P7-P0 (docs-only), P7-D0a, P7-D0b, and P7-D1 are COMPLETE; P7-I0 and later are NOT STARTED.**

This document is the authoritative contract for P7 v0 AI answer candidates:
the producer boundary, content admission, provider boundary, typed
validation, the unified producer-neutral `AnswerCandidate`, shared
fill/noOp/replace review semantics, confirmation through the existing typed
answer mutation authority, stale/CAS semantics, failure taxonomy, bounds,
stage graph, and the future acceptance matrix. P7-P0 froze design only and
implemented no production code, tests, schema, or migration.

## 1. Purpose (P7 v0 goal)

P7 v0 adds exactly one capability:

```text
AI -> typed AnswerCandidate producer
```

The formal chain:

```text
explicit action on one typed question
  -> safe-content admission
  -> bounded provider request
  -> strict normalization / typed validation
  -> unified transient AnswerCandidate
  -> shared fill/noOp/replace review semantics
  -> explicit confirmation
  -> existing TypedAnswerPersistenceKernel
  -> formal answer
```

AI never owns direct formal answer write authority. Every formal mutation
flows through the existing typed answer mutation authority after explicit
user confirmation.

## 2. Candidate — producer-neutral

P7 and P6 share one producer-neutral `AnswerCandidate` concept. P7 must not
introduce:

- `AiAnswerCandidate`;
- `AiAnswerDraft`;
- an AI-specific review entity;
- an AI candidate table;
- an AI job table;
- a second review/confirmation system.

The shared Candidate must carry a typed/sealed producer origin (or a
structure with equivalent type safety) so that Supplemental and AI origins
are discriminated at the type level, not by nullable ad-hoc fields.

### Supplemental origin (unchanged P6 invariants)

The Supplemental origin must preserve every frozen P6 invariant:

- `supplementalFileId`;
- `artifactId`;
- positive `artifactRevision`;
- non-empty ordered `SourceRefs`;
- every `SourceRef` belongs to the bound artifact;
- match evidence.

These must not be turned into mutually independent nullable fields.

### AI origin

The AI origin carries only safe, bounded, transient provenance:

- producer kind (`ai`);
- bounded generation metadata (for example a generation id and the bounded
  provider/output identifiers needed for review display);
- no provider raw response, no reasoning, no raw thought, no trace.

## 3. P6 compatibility

P6 frozen semantics remain unchanged and are reused verbatim:

- missing answer -> `fill` -> explicit confirm;
- equivalent answer -> `noOp` -> zero transaction;
- different answer -> `replace` -> explicit per-question replacement
  reconfirmation.

P7 must not weaken:

- P6 F1 artifact stale checking (where applicable to the Supplemental
  origin);
- complete target snapshot binding;
- review/session semantics;
- transactional CAS;
- `TypedAnswerPersistenceKernel` authority.

## 4. Content admission — text/math only

Provider input admission happens **before any network request**.

The only RichContent nodes allowed to leave the app:

- `TextNode`;
- `InlineMathNode`;
- `BlockMathNode`.

Never sent outbound:

- `RawFallbackNode`;
- raw JSON;
- `SourceRef`;
- `AssetRef`;
- diagnostics/issues;
- paths;
- storage keys;
- Base64;
- binary/image data;
- unrelated question content;
- the current formal answer;
- explanation;
- RAG / File Library / Conversation content.

A question that:

- contains a `RawFallbackNode`;
- has non-empty `assetRefs`;
- depends on images/assets that P7 v0 cannot provide; or
- would require silently deleting content before generation

must produce:

```text
unsupportedQuestionContent
  -> zero provider calls
  -> zero Candidate
  -> zero mutation
```

Silently dropping images/unsafe content and letting the model guess is
forbidden.

## 5. singleChoice

`QuestionKind.singleChoice` P7 candidates must contain **exactly ONE existing
option ID**.

The provider schema is frozen in singular form:

```json
{
  "schema_version": 1,
  "answer": {
    "kind": "choice",
    "option_id": "opt_a"
  }
}
```

Each of the following is `validationFailed`:

- zero options;
- more than one option;
- duplicate option;
- unknown option ID.

P7 must not create multi-ID singleChoice Candidates, and must not add a
`multipleChoice` kind.

Historical multi-ID `ChoiceAnswer` values:

- remain readable;
- are not migrated;
- are not auto-corrected;
- if the AI one-ID Candidate differs from them, the flow is the normal
  explicit `replace` flow.

## 6. fillBlank / shortAnswer

`fillBlank` / `shortAnswer` use `ContentAnswer`.

Allowed content nodes only:

- `TextNode`;
- `InlineMathNode`;
- `BlockMathNode`.

Requirements:

- structurally non-empty;
- within the bounded ContentAnswer complexity limit.

Forbidden:

- `RawFallbackNode`;
- image content;
- unsupported nodes;
- empty visible content;
- over-limit content.

P7 v0 does not invent a per-blank answer schema. Markdown never becomes the
formal authority; math content uses structural math nodes.

## 7. explanation — answer-only

P7 v0 is answer-only:

- AI explanation generation is deferred;
- AI explanation persistence is deferred;
- `reviewOnlyExplanation` remains `null`.

It is forbidden to save:

- hidden reasoning;
- chain-of-thought;
- reasoning tokens;
- provider raw thought;
- debug trace.

## 8. Provider boundary

Layering:

- Presentation never calls the provider SDK directly;
- Domain never imports provider DTOs;
- Repository never calls the provider.

Target responsibility chain:

```text
Presentation
  -> Application use case
  -> bounded AI Answer provider port
  -> provider adapter
```

The provider raw response is:

- transient only;
- strictly bounded;
- never logged;
- never persisted;
- never placed into a Candidate;
- never returned raw to Presentation.

## 9. Failure taxonomy

Frozen safe typed categories (future enum names may differ; the semantics
are canonical):

Target/content:

```text
questionMissing
questionNotTyped
unsupportedQuestionKind
unsupportedQuestionContent
invalidQuestionState
staleTarget
```

Provider:

```text
providerUnconfigured
providerAuthenticationFailed
providerRateLimited
providerTimeout
providerUnavailable
providerRejected
```

Output:

```text
malformedProviderOutput
validationFailed
```

Lifecycle/persistence:

```text
cancelled
candidateNotCommittable
candidateAlreadyDecided
persistenceFailed
internalError
```

`replace` / `noOp` are normal Candidate outcomes, not failures.

Never exposed to Presentation:

- provider body;
- SQL;
- raw exception;
- filesystem path;
- credential.

`internalError` exposes only a safe category / trace ID.

## 10. Stale / concurrency

Generation start captures:

```text
storageId
+ bankName
+ complete QuestionDraftV2
```

After the provider returns and **before** the Candidate is created, the
captured target must be revalidated. If during generation any of the
following happened:

- question edit;
- answer edit;
- question deletion;
- bank change;

then `staleTarget` and the Candidate is not shown.

Confirmation revalidates again inside the transactional boundary:

- bank check;
- complete draft check;
- write-intent/precondition check;
- existing `TypedAnswerPersistenceKernel` mutation.

Competing Candidates: the first incompatible commit wins; every other
Candidate subsequently becomes stale.

Late results of cancelled / superseded generations must be discarded.

## 11. Persistence

Everything is transient:

- Candidate;
- generation state;
- provenance;
- provider request/result;
- review state.

Never written to SQLite. Never placed into Conversation messages. No
recovery after restart is required.

Only:

```text
candidate.answer
```

may, after explicit user confirmation, enter the existing typed answer
persistence authority. Schema stays **v21**.

## 12. RAG / MCP / W0

P7 v0:

- does not call RAG;
- does not read File Library;
- does not read Conversation attachments;
- does not read Learning Space files;
- does not reuse `RetrievalEgressGrant`;
- does not call `retrieve_file_content`.

Future source-assisted AI answer generation requires a separate additive
contract.

- MCP v0: exactly six `READ_ONLY` tools, unchanged.
- A0: exactly six tools, unchanged.
- W0: not a P7 workflow. P7 and W0 share only the existing typed answer
  value/persistence semantics.

## 13. Bounds

### DURABLE CONTRACT

- finite/bounded timeout;
- bounded provider output;
- bounded raw-response bytes;
- bounded ContentAnswer complexity;
- limit exceeded -> fail closed.

### IMPLEMENTATION DEFAULT (not canonical)

The following are implementation defaults only, not permanent canonical
semantics:

- 120 sec timeout;
- 2048 output tokens;
- 64 KiB raw response;
- 64 nodes;
- 8192 Unicode scalars.

Defaults may be tuned by later authorized implementation stages; the
durable contract above cannot be weakened.

## 14. Acceptance matrix

Minimum future acceptance matrix for P7 implementation stages:

1. missing answer + valid AI result -> `fill` Candidate -> confirm -> one
   formal mutation.
2. same answer -> `noOp` -> zero transaction.
3. different answer -> `replace` -> explicit replacement reconfirmation.
4. unknown option -> `validationFailed` -> zero mutation.
5. multi-ID singleChoice output -> `validationFailed`.
6. `RawFallback` -> `unsupportedQuestionContent` -> provider call count zero.
7. asset/image-dependent question -> `unsupportedQuestionContent` -> provider
   call count zero.
8. malformed provider output -> typed failure -> zero mutation.
9. provider timeout -> zero mutation.
10. cancel -> late result discarded.
11. question changed during generation -> `staleTarget`.
12. answer changed during generation -> `staleTarget`.
13. retry -> new generation; the old result can never auto-submit.
14. raw provider response -> never persisted/logged.
15. P7 never automatically accesses RAG / File Library.
16. historical multi-ID answer -> readable; AI one-ID proposal follows
    `replace` semantics.
17. Supplemental P6 Candidate invariants remain unchanged.

## 15. Stage graph

```text
P7-P0 -> P7-D0a -> P7-D0b -> P7-D1 -> P7-I0 -> P7-C0 -> P7-U0 -> P7-V0 -> P7-CL
```

Definitions:

- P7-P0 canonical contract — COMPLETE (docs-only);
- P7-D0a producer-neutral Candidate/origin — COMPLETE;
- P7-D0b generic review-decision core — COMPLETE;
- P7-D1 provider port + strict adapter / validation — COMPLETE;
- P7-I0 AI generation Application use case — NOT STARTED;
- P7-C0 confirmation + transactional persistence adapter — NOT STARTED;
- P7-U0 minimal typed-question Presentation integration — NOT STARTED;
- P7-V0 focused validation / privacy / concurrency / acceptance —
  NOT STARTED;
- P7-CL canonical closure — NOT STARTED.

All P7 implementation stages are SERIAL. P7-I0 and later remain NOT
STARTED; this stage graph is the frozen route only, and no later stage may
be executed by an earlier stage.

## 16. Non-goals

P7-P0 and P7 v0 do not include:

- schema migration (runtime schema remains v21);
- persisted Candidate / generation state / provenance / provider request or
  result / review state;
- persisted or generated AI explanation;
- per-blank answer schema;
- a new question kind (`multipleChoice` or others);
- multi-ID singleChoice Candidates;
- AI direct formal answer write authority;
- any automatic RAG / File Library / Conversation / Learning Space access;
- MCP, A0, or W0 changes;
- a second review/confirmation system or second answer writer;
- Candidate answer editing;
- auto-submission of old generation results;
- silent dropping of images/unsafe content before generation;
- source-assisted AI generation (requires a separate additive contract).

## 17. Stop conditions and documentation authority

Stop conditions:

- any requirement for a schema change (v22 or later);
- any requirement to modify P6 durable semantics;
- any requirement to modify `TypedAnswerPersistenceKernel` durable
  semantics;
- any requirement for new Candidate/job persistence;
- any requirement to integrate RAG;
- any requirement to modify MCP / A0 / W0;
- any requirement for a new formal question kind;
- any requirement to modify files outside the allowed scope;
- current master drift that cannot be confirmed safe;
- a targeted revision that clearly conflicts with current code truth.

Documentation authority:

- `ARCHITECTURE.md` — repository-wide dependency and boundary contract;
- this document — focused P7 authority for the producer-neutral
  `AnswerCandidate` generalization and AI-origin semantics;
- `docs/architecture/p6-supplemental-answer-matching.md` — focused P6
  authority for Supplemental producer/review semantics and
  Supplemental-origin invariants;
- `docs/architecture/n0-post-p5-roadmap.md` — stage ordering and current
  status.
