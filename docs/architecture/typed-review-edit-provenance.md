# Typed Review Edit Provenance Contract

Status: **Current runtime contract**.

This document is the focused canonical authority for how Review decides whether
the original typed explanation structure may still be used. It governs the
Review draft state, the Review preview and the typed commit. It does not change
any question, snapshot, content or database schema.

## 1. The representation premise

A typed explanation and its legacy review text are intentionally **not**
isomorphic:

- the typed form carries `TextNode`, `InlineMathNode`, `BlockMathNode`,
  `ImageNode` and `TableNode`;
- the legacy form carries `$latex$`, pipe-separated table text and `[图片]`.

Both render the same user-visible content and both come from one OCR source, yet
neither is a round trip of the other. A measured real payload showed a typed
projection of 517 characters against a legacy review text of 523 characters,
differing both in math delimiters (the legacy text keeps eight `$`) and in where
table row and cell boundaries fall.

Consequences that are frozen:

- `RichContentTextProjection` remains a **bounded compatibility projection**. It
  is not a round-trip representation, not an edit-provenance record and not a
  typed reconstruction format.
- Structure must never be rebuilt from projected text. No `ImageNode`,
  `TableNode` or math node is ever reparsed out of a legacy string, and image
  asset identity is never re-invented.
- No string rule may be added to decide equivalence between the two
  representations: not delimiter stripping, not table-cell or whitespace
  collapsing, not HTML plus LaTeX canonicalization, not fuzzy or regex equality.
  Such a rule cannot separate a real user edit from a representation difference,
  and admitting one re-opens silent structure loss.

## 2. Authority order

1. `TypedReviewSnapshot.draft` is the original typed structural authority.
2. The legacy `QuestionDraft` string fields are legacy compatibility and
   editable presentation only. They are never the structural authority.
3. Whether the original structure may still be used is decided **only** by the
   explicit explanation edit provenance plus the resolved retention decision.

## 3. Explanation edit provenance

```dart
enum ExplanationEditProvenance { legacyUnknown, untouched, manualEdited }
```

- `untouched` — no user edit of the explanation content has happened since the
  typed snapshot was established.
- `manualEdited` — the user explicitly modified the explanation content.
- `legacyUnknown` — no provenance marker exists. An older draft may have been
  edited before provenance was recorded.

**Absence is not `untouched`.** A missing or unrecognized marker always reads as
`legacyUnknown` and is never upgraded. `legacyUnknown` has no persisted token,
so it is never written back.

Retention intent and edit provenance are orthogonal states and are never merged:

- `QuestionExplanationOverride` (`inherit` / `keep` / `discard`) answers "does
  the user want the explanation kept?".
- `ExplanationEditProvenance` answers "did the user edit the explanation
  content?".

`override = keep` with `untouched` therefore means "keep the original typed
explanation", while `override = keep` with `manualEdited` means "keep the user's
edited text".

## 4. Storage boundary

The provenance marker is transient review state. It lives only in the persisted
ReviewDraft question map under the stable key `_explanation_edit_provenance`
with the stable values `untouched` and `manualEdited`.

It never enters `QuestionDraftV2`, the typed snapshot payload, the question
schema or SQLite. This contract adds no schema and requires no migration.

## 5. Lifecycle

### 5.1 Initialization

The marker is initialized to `untouched` at the one boundary where a typed review
item is created: the OCR typed candidate builder, while it attaches the snapshot
envelope to the review question map. Only a brand-new typed item passes through
there, so a legacy `legacyV1` item and a draft already in storage never receive
an invented `untouched`. The review UI never initializes the marker.

### 5.2 Manual edit

Only a direct user edit of the explanation content moves the state to
`manualEdited`, through `markExplanationManuallyEdited()`. The transition takes no
text and performs no comparison, and it is sticky: an edit that deletes the
original text and types it back is still an edit, and edit history can never be
recovered from the final string.

The Review explanation editor is that user edit event: it seeds its field with
the text currently rendered, keeps the saved value as exact literal text, and
records the manual edit. Dismissing the editor or saving it without changing the
text is not an edit, so the typed structure and its provenance both survive.

The following never set `manualEdited`: initial load, persisted or restart
reload, the explanation retention toggle, deterministic finalization, safe HTML
cleanup, OCR normalization, snapshot registration, typed restore, a policy
discard or keep, AI repair proposal creation and acceptance.

### 5.3 AI repair

An accepted AI repair keeps the existing `ReviewRepairEdit` authority, its
fragment markers and its digest checks. It is not encoded as `manualEdited` and
is not redesigned here. A later manual edit still wins: a stale repair marker
never overwrites subsequent user text.

## 6. Preview and commit matrix

Preview and commit consume the **same** resolved retention decision and the same
provenance. A structure shown in Review can never be flattened at commit time.

| retained | provenance | Preview | Commit |
|---|---|---|---|
| `false` | any | no typed explanation | `clear()` when a typed explanation exists, otherwise `unchanged` |
| `true` | `untouched` | the snapshot's typed explanation, with no text comparison | `unchanged` |
| `true` | `manualEdited` | the literal/manual path | `replace(current text)`; no old structure, no reparse |
| `true` | `legacyUnknown` | the frozen strict fallback | the frozen strict fallback |

The `legacyUnknown` fallback admits only an exact baseline match or an exact
text-projection match. It adds no normalization, so the observed 517-versus-523
payload keeps falling back to the literal path. That is the intended
backward-safe behavior for drafts written before provenance existed; new typed
items carry `untouched` and no longer depend on that comparison.

## 7. Structural identity

An `untouched` restore reuses the snapshot's own `RichContent` node identity. It
never reparses text into a new `TableNode`, never re-downloads an image and never
re-establishes asset identity: `ImageNode.sourceId`, `ImageNode.localAssetId`
and `TableNode.structure` are preserved exactly.

## 8. Unchanged contracts

This contract changes none of the following:

- the typed/legacy parity comparator of `applyOcrTypedCandidateGate`, including
  `typed_candidate_projection_mismatch`,
  `typed_candidate_raw_explanation_diverged`, provenance parity and its
  all-or-nothing behavior;
- the P2-B1T2 parity normalizer (see
  `p2-b1t2-phase2b-typed-legacy-parity.md`);
- `RichContentTextProjection` semantics;
- `TableNode`, `ImageNode`, `RichContent` and `QuestionDraftV2` schemas;
- the SQLite schema;
- OCR providers, the OCR table parser and the renderer's table implementation.
