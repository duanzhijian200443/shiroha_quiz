# P2-B1T2 Phase 2B Typed / Legacy Parity Contract

Status: **FINAL / FROZEN V0 CONTRACT TARGET; NOT YET IMPLEMENTED.**

Durable architecture truth changed by this contract: **YES**.

This document is the focused canonical authority for the conservative P2-B1T2
Phase 2B v0 typed/legacy eligibility comparison. It freezes the minimum safe
representation-only differences that may be admitted to `typedV2` and the
differences that must continue to fail closed to `legacyV1`.

P2B-C0 freezes this v0 contract only. The current exact gate remains runtime
truth until a separately reviewed and merged P2B-I1 implementation conforms to
this document. P2B-I1 is an implementation slice, not Phase 2B closure. The
broader Issue #116 parity acceptance, including formatting-only OCR line-wrap
handling, remains open until a separately frozen producer-backed amendment is
implemented. This contract does not activate image/table OCR sources, change a
persisted schema, or begin Phase 3.

## 1. Authority and safety invariant

The authoritative path remains:

```text
final user-visible legacy question
    -> finalizeAndAuditImportQuestions
    -> strict baseline decode
    -> raw_explanation admission
    -> typed/legacy field parity
    -> exact ordered provenance parity
    -> TypedReviewSnapshot
    -> typedV2 or whole-batch legacyV1
```

The Phase 2B safety property is:

> Normalization MAY make formatting-equivalent representations compare equal.

> Normalization MUST NOT manufacture equality across semantic changes.

Normalized text is a comparison-only representation. It is never typed
authority, legacy authority, review-baseline authority, or replacement text
for persistence. `QuestionDraftV2 -> RichContent` remains typed authority. The
final legacy map remains the user-visible compatibility baseline.

`TypedReviewSnapshot.baselineLegacy` MUST continue to contain the actual final
user-visible legacy values exactly as decoded by the strict baseline decoder.
It MUST NOT contain normalized values. `LegacyReviewBaseline` equality and its
persisted codec remain exact; Phase 2B uses a dedicated admission comparison
and does not redefine value-object equality.

Issue #116 remains the umbrella acceptance for P2-B1T2. In particular, its
requirement that formatting-only OCR differences, including line wrapping, do
not force an otherwise valid typed batch to `legacyV1` is not deleted or
rewritten by this v0 contract. V0 deliberately freezes only the subset that is
currently provable without semantic guessing.

## 2. Current strict runtime contract

Before P2B-I1, `applyOcrTypedCandidateGate()` performs these checks directly:

- `_strictDecodeBaseline()` strictly decodes the six legacy fields;
- `_rawExplanationAllowed()` admits only `null`, the empty string, or exact
  equality with final `explanation`;
- `LegacyReviewBaseline == candidate.projectedLegacy` requires exact equality
  for all six fields, including ordered option elements and answer case;
- `_provenanceParity()` requires exact ordered equality for
  `source_page_indices` and `source_block_ids`;
- any failed question removes every typed envelope and routes the whole batch
  to `legacyV1`.

Consequently, a representation-only difference currently fails as
`typed_candidate_raw_explanation_diverged` when it is first observed between
`raw_explanation` and final `explanation`, or as
`typed_candidate_projection_mismatch` when it is first observed between the
strict final baseline and the candidate compatibility projection.

## 3. Frozen field-level v0 contract

| Field | Phase 2B v0 comparison | Permitted normalization |
|---|---|---|
| `type` | exact | none |
| `questionNumber` | exact | none |
| `content` | exact | none |
| `options` | exact ordered list and exact elements | none |
| `standardAnswer` | exact and case-sensitive | none |
| `explanation` | exact, or bounded normalized equality only for the TextNode-only path defined below | section 4 only |
| `source_page_indices` | exact ordered equality | none |
| `source_block_ids` | exact ordered equality | none |

The comparator MUST NOT lowercase answers, sort answers or options, remove
punctuation, normalize digits numerically, rewrite LaTeX, normalize
mathematical symbols, remove math delimiters, strip HTML, apply Unicode NFKC,
perform semantic sentence rewriting, collapse internal whitespace, collapse
structural nodes to arbitrary text, or reconstruct typed authority from a
legacy string.

## 4. Bounded TextNode-only v0 normalization

Relaxed comparison is eligible only when the corresponding typed explanation
contains no node other than `TextNode`. Node eligibility comes from the typed
draft, never from guessing whether a legacy string "looks structural". If an
explanation contains `InlineMathNode`, `BlockMathNode`, `ImageNode`,
`TableNode`, or `RawFallbackNode`, section 6 applies instead.

`TextNode` does NOT prove that the source was ordinary prose. Current OCR
production maps `formula` / `equation` blocks to
`SourceContentPart(role: formula, content: [TextNode(...)])`, and the parity
candidate does not retain `SourceContentRole` as an eligibility signal. Code,
aligned text, formula source, or other preformatted material may therefore
also arrive through TextNode-only content. For that reason, v0 MUST NOT mutate
internal spacing or internal LF structure.

For an eligible operand `x`, `N0(x)` is defined in this exact order:

1. replace every CRLF pair with LF and every remaining CR with LF;
2. remove only `U+0020 SPACE`, TAB, LF, and `U+3000 IDEOGRAPHIC SPACE` from
   the two boundaries of the whole string;
3. perform no other transformation.

In particular, v0 does NOT:

- collapse repeated internal ASCII spaces, TABs, or `U+3000`;
- join or delete internal LFs;
- change blank-line count;
- rewrite text merely because it contains `\\`, `$`, LaTeX-like syntax,
  source code, alignment spacing, or preformatted content.

The normalizer MUST be deterministic, pure, locale-independent, and
idempotent:

```text
N0(N0(x)) == N0(x)
```

It MUST use a bounded left-to-right Unicode-scalar scan with no I/O, DB,
Provider, Flutter, AI, parser, or backtracking-dependent regex behavior. For
an exact-unequal pair, relaxed comparison is attempted only when each original
operand contains at most `RichContentLimits.maxProjectionScalars` Unicode
scalar values. An over-limit pair is not equivalent and fails through the
existing reason for the active comparison seam. The symbolic limit is the
existing compatibility-projection bound already enforced by
`RichContentTextProjection`; Phase 2B defines no new number and no UTF-16-only
limit. Normalization is `O(n)` time, uses at most `O(n)` comparison storage,
and never increases scalar count.

Although `RichContentLimits.maxProjectionScalars` is a runtime safety limit
rather than a persisted schema value, changing it changes the set of pairs
eligible for normalized parity. Any future change that widens or narrows this
admission surface MUST be reviewed as a Phase 2B parity-contract change; it is
not an unrelated tuning-only change.

Exact equality remains the first comparison path. The resource bound above
governs the additional normalized representation, not persisted payload
shape.

## 5. `raw_explanation` v0 admission

The following order is frozen:

```text
raw == null
    -> allowed

raw == ''
    -> allowed

raw == final explanation
    -> allowed

raw != '' AND final explanation == ''
    -> reject typed_candidate_raw_explanation_diverged

both strings non-empty, typed explanation TextNode-only, and N0(raw) == N0(final)
    -> allowed

otherwise
    -> reject typed_candidate_raw_explanation_diverged
```

The non-empty-raw/empty-final guard runs before normalization. In particular,
whitespace-only non-empty raw text is not allowed to normalize into a literal
empty final explanation. This preserves fail-closed retention/quality-policy
semantics.

V0 does not treat deterministic safe-HTML cleanup, deterministic LaTeX repair,
or general OCR line reflow as equivalent merely because they may be produced
by finalization. Those transformations require their own evidence-backed
contract if they remain a real first-loss boundary.

## 6. Internal line wrapping, formula-role TextNodes, math, and structural content

### Internal OCR line wrapping

Internal line-wrap normalization is **NOT IMPLEMENTED BY V0**. Internal LF
count and position remain semantically significant after section 4's
line-ending encoding conversion and whole-string boundary trim. Blank-line
count differences therefore also remain unequal in P2B-I1.

This is a conservative implementation boundary, not a deletion of the parent
requirement. Issue #116 explicitly requires formatting-only line wrapping not
to force an otherwise valid batch to `legacyV1`. Therefore:

- P2B-I1 MUST NOT be described as Phase 2B complete;
- Issue #116 MUST remain open after P2B-I1;
- before Phase 2B / Issue #116 parity closure, a separately reviewed canonical
  amendment MUST either freeze a narrow producer-backed line-wrap
  normalization with sanitized regression evidence, or explicitly amend the
  parent acceptance;
- P2B-I1 MUST NOT invent a Unicode-script, natural-language, regex, or
  punctuation heuristic to satisfy that future requirement.

The repository evidence currently does not justify a broader join rule:

- `OcrQuestionRegion` trims individual owned text parts and joins them with a
  single LF as an explicit producer boundary;
- `OcrQuestionAssembler` and `QuestionDraftV2LegacyProjector` do not establish
  a second general plain-text line-reflow authority;
- `finalizeAndAuditImportQuestions` applies retention, safe HTML cleanup, and
  deterministic LaTeX audit/repair, but no general OCR line-wrap removal;
- the permanent typed-candidate unit and R7B acceptance fixtures do not isolate
  a producer-backed internal-LF transformation that can safely be generalized.

Therefore no Han/Hiragana/Katakana/Hangul or other Unicode-script heuristic is
authorized by v0.

### Formula-role TextNodes

Current OCR `formula` / `equation` blocks are represented as
`SourceContentPart(role: formula)` whose `RichContent` contains `TextNode`.
Because that source role is not retained as a parity-gate eligibility signal,
TextNode-only MUST NOT be interpreted as "ordinary prose". V0's no-internal-
mutation rule is the safety guard. A future relaxed comparator that wants to
collapse internal spacing or line structure MUST first add a durable way to
prove producer/role eligibility and regression-test formula-role content as
ineligible for that relaxation.

### Math and structural content

An explanation containing `InlineMathNode`, `BlockMathNode`, `ImageNode`,
`TableNode`, or `RawFallbackNode` is ineligible for relaxed TextNode-only
comparison. Its supported bounded compatibility representation must compare
exactly. Current projection-unsupported content, including raw fallback at the
question projection boundary, continues to fail closed before parity.

At minimum, all of these remain unequal:

- `\\(x\\)` versus `\\( x \\)`;
- `x+1` versus `x-1`;
- a line-layout change around block math;
- an image or table structural/projection mutation;
- TextNode formula-like/preformatted content whose only difference is internal
  horizontal spacing.

Phase 2B v0 introduces no LaTeX, MathML, Markdown, or HTML parser; no symbolic
algebra, CAS, equation equivalence, or regex equation rewriting.

## 7. Failure taxonomy and batch behavior

Phase 2B v0 adds no failure reason:

- raw semantic/non-admitted representation mismatch remains
  `typed_candidate_raw_explanation_diverged`;
- candidate projection mismatch remains
  `typed_candidate_projection_mismatch`;
- count, identity, baseline, snapshot, provenance, and earlier candidate
  failures retain their existing fixed classifications.

Gate order and first-failure classification remain stable. Normalization does
not hide count, identity, baseline-shape, snapshot, or provenance failures.

Batch behavior remains all-or-nothing. Any mismatch in any question routes
the whole batch to `legacyV1` and removes every typed review envelope. Mixed
per-question typed/legacy routing is not authorized.

## 8. Frozen v0 decision matrix

Every ACCEPT below assumes all other gate checks pass and yields `typedV2` +
`typed_candidate_ready`. Explanation mutation rows refer to candidate
projection versus final baseline unless explicitly marked raw; the same
substantive mutation confined to `raw_explanation` fails earlier as
`typed_candidate_raw_explanation_diverged`.

| ID | Difference | Frozen v0 result |
|---|---|---|
| A | TextNode-only explanation CRLF versus LF | ACCEPT |
| B | TextNode-only explanation whole-string outer whitespace only | ACCEPT |
| C | internal horizontal-space run difference, e.g. `a  b` versus `a b` | REJECT at the active seam |
| D | non-empty raw and final explanation equal under section 4 `N0` | ACCEPT |
| E | internal OCR line-wrap-only or blank-line-count difference | REJECT in v0 at the active seam; parent Issue #116 requirement remains OPEN |
| F | explanation `x=1` -> `x=2` | REJECT `typed_candidate_projection_mismatch` |
| G | explanation `+` -> `-` | REJECT `typed_candidate_projection_mismatch` |
| H | sentence added | REJECT `typed_candidate_projection_mismatch` |
| I | sentence removed | REJECT `typed_candidate_projection_mismatch` |
| J | negation changed | REJECT `typed_candidate_projection_mismatch` |
| K | answer conclusion changed | REJECT `typed_candidate_projection_mismatch` |
| L | `standardAnswer` case mutation | REJECT `typed_candidate_projection_mismatch` |
| M | option reorder | REJECT `typed_candidate_projection_mismatch` |
| N | option text mutation | REJECT `typed_candidate_projection_mismatch` |
| O | content mutation | REJECT `typed_candidate_projection_mismatch` |
| P | substantive explanation mutation | REJECT `typed_candidate_projection_mismatch` |
| Q | source page changed | REJECT `typed_candidate_projection_mismatch` |
| R | source block changed | REJECT `typed_candidate_projection_mismatch` |
| S | source block order changed | REJECT `typed_candidate_projection_mismatch` |
| T | candidate/final count mismatch | REJECT `typed_candidate_count_mismatch` |
| U | question-number set/uniqueness or UUID identity mismatch | REJECT `typed_candidate_identity_mismatch` |
| V | non-empty `raw_explanation` with literal empty final explanation | REJECT `typed_candidate_raw_explanation_diverged` |
| W | `\\(x\\)` versus `\\( x \\)` or block-math layout mutation | REJECT `typed_candidate_projection_mismatch` |
| X | substantive text added to, removed from, or changed only in `raw_explanation` | REJECT `typed_candidate_raw_explanation_diverged` |
| Y | formula-like/preformatted TextNode internal spacing only, e.g. `\\text{a  b}` versus `\\text{a b}` | REJECT at the active seam |

For rows C, E, and Y, "active seam" means a raw/final mismatch fails as
`typed_candidate_raw_explanation_diverged`, while a strict final-baseline /
candidate-projection mismatch fails as `typed_candidate_projection_mismatch`.

## 9. Compatibility projection boundary

`QuestionDraftV2LegacyProjector` and `RichContentTextProjection` produce a
bounded compatibility representation:

- `TextNode` appends text;
- `InlineMathNode` and `BlockMathNode` append their LaTeX payload;
- `ImageNode` projects admitted alternative text or `[图片]`;
- `TableNode` expands deterministic cells, joins columns with ` | `, and rows
  with LF;
- `RawFallbackNode` is not admitted by the question legacy-projection
  boundary.

This string is not typed authority and is not a round-trip format. Neither the
parity comparator nor any later consumer may normalize, parse, or reconstruct
it into `ImageNode`, `TableNode`, math nodes, or other typed content.

The v0 comparison policy frozen here is a permanent minimum safety floor. It
has no planned deletion, but it is intentionally not the complete Issue #116
parity acceptance. Any future widening, including internal line-wrap handling,
requires a separately reviewed durable contract amendment and focused
regression evidence.

## 10. Checkpoint and deferred boundaries

P2B-I1 MUST wait for P2B-C0 independent architecture review, merge, and a new
frozen master SHA. P2B-I1 may implement only the v0 comparator/gate behavior
frozen here; it may not redesign or silently widen this contract on its
implementation branch.

P2B-I1 completion MUST be reported as:

```text
Phase 2B v0 comparator/gate implemented.
Issue #116 parity closure remains open.
Internal producer-backed line-wrap equivalence remains unresolved/deferred.
```

Before Phase 2B is declared closed, the remaining parent acceptance must be
resolved by a separate canonical amendment and implementation, followed by the
required final live acceptance. This preserves #116 as the umbrella target
rather than rewriting its historical acceptance to match an implementation
shortcut.

This contract changes no `RichContent`, `QuestionDraftV2`, or
`TypedReviewSnapshot` schema/version; no database or payload migration is
required.

The following remain deferred and are not activated by this contract:

- producer-backed internal OCR line-wrap equivalence required for final Phase
  2B / Issue #116 parity closure;
- evidence-backed handling, if required, for finalizer safe-HTML cleanup or
  deterministic LaTeX repair differences;
- Phase 3 durable asset lifecycle and B0 asset integration;
- real image/table `OcrSourceDocumentAdapter` source activation;
- provider materialization, durable image bytes, renderer/resolver work, and
  live PDF acceptance;
- AI Repair, P2-B2, AnswerAttempt, RAG, MCP, and option-extraction redesign;
- P3 mixed-structural stem option extraction.
