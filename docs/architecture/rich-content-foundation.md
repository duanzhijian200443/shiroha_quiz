# RichContent Foundation Phase 0 Contract

Status: **FINAL / FROZEN architecture target; implementation and production
activation are deferred.**

Durable architecture truth changed by this contract: **YES**.

This document is the focused canonical authority for the RichContent
Foundation target. It freezes the contracts that future `ImageNode`,
`TableNode`, codec, admission, asset-resolution, structural-import, renderer,
and AI-repair work must preserve. It does not claim that those nodes are
already implemented.

The current runtime remains authoritative for existing text/math/fallback
behavior. In particular, current `master` has `RichContent` with `TextNode`,
`InlineMathNode`, `BlockMathNode`, and `RawFallbackNode`; `QuestionDraftV2` is
the typed question authority and already owns a source-qualified asset
inventory; `SourceAssetPart` and `SourceTablePart` already preserve typed
source structure; and the current assembler still rejects Asset/Table source
parts. This contract freezes the additive target that closes those gaps.

Canonical documentation placement:

- this file is the focused authority;
- `ARCHITECTURE.md` carries only the repository-wide pointer and summary;
- implementation status, review findings, PR history, test logs, and rollout
  evidence do not belong in either canonical contract.

## A. Frozen RichContent Foundation

### A.1 FINAL node set

RichContent Foundation v0 contains exactly this sealed node set:

```text
sealed ContentNode
├── TextNode
├── InlineMathNode
├── BlockMathNode
├── ImageNode
├── TableNode
└── RawFallbackNode
```

`InlineMathNode` and `BlockMathNode` remain separate. Inline and block math
have different structural and presentation semantics; renderers must not infer
that distinction again from delimiters or layout heuristics.

No other foundation node is approved in v0. In particular, input or
presentation formats such as HTML, Markdown, provider blocks, files, generic
widgets, and layout containers are not Domain `ContentNode` types.

### A.2 Durable truth and extension rules

`QuestionDraftV2 -> RichContent -> ContentNode` is the typed content authority.
Legacy strings are compatibility representations only. Node order in
`RichContent.nodes` is canonical encounter/reading order.

Every formal node extension must satisfy all of the following before
production activation:

- immutable value semantics and bounded canonical payload;
- no Flutter, SQLite, HTTP, file-system, provider DTO, credential, provider
  response, raw OCR body, or storage-locator dependency in Domain;
- deterministic encode and strict decode;
- fail-closed handling for malformed payloads of a schema the reader claims to
  understand;
- lossless preservation of future nodes the reader does not understand;
- complete structural equality and hash participation wherever
  `RichContent` participates in `QuestionDraftV2` equality, stale detection,
  revision/CAS checks, or collection keys;
- recursive privacy/resource admission;
- deterministic rendering with explicit unsupported and missing-resource
  states;
- a bounded, safe, deterministic legacy projection that is never promoted
  back to typed authority.

Adding codec support without updating equality/hash, admission, legacy
projection, and every exhaustive node switch is incomplete and non-conforming.

### A.3 Renderer and AI boundaries

The final `RichContentRenderer` must handle every node in the frozen set. It
may obtain image bytes only through a safe Application/Presentation asset-read
seam. It must not interpret Domain identity as a path, parse provider URLs or
HTML, or synchronously perform heavy file I/O. Missing, corrupt, unsupported,
or still-loading resources require bounded fallback UI and must not change the
typed authority.

Future AI Repair proposes a validated `RichContent`/`ContentNode` tree against
an exact base snapshot and ReviewDraft revision/CAS boundary, followed by
strict admission. It does not reconstruct or overwrite typed authority from an
AI-generated legacy string. Provider schema remains deferred.

## B. ImageNode v0 FINAL Contract

### B.1 Minimal canonical fields

`ImageNode` v0 contains only:

```text
ImageNode
- source-qualified asset identity: (sourceId, localAssetId)
- alternativeText: RichContent?
```

The source-qualified pair is exactly the identity already represented by
`SourcedAssetRef.sourceId` plus `SourcedAssetRef.localAssetId`; it is not a new
global ID namespace. The canonical v0 JSON payload uses the existing asset key
convention and contains only:

```text
type = image
sourceId
assetId
alternativeText
```

The node carries identity and placement, not a second copy of `AssetRef`
metadata. Full safe metadata is resolved from the owning draft inventory under
section C.

`alternativeText` remains `RichContent?`, matching the existing typed
`SourceAssetPart.alternativeText`. Converting it to `String?` would be a
structural downgrade.

### B.2 Alternative-text admission

Image alternative text may contain only:

- `TextNode`;
- `InlineMathNode`;
- `BlockMathNode`.

It may not contain `ImageNode`, `TableNode`, or `RawFallbackNode`. Admission
must enforce bounded node count, bounded text/scalar size, and the global
RichContent depth/resource budget. The concrete default numbers are an
implementation decision, but enforcement is mandatory.

### B.3 Excluded fields and semantics

`ImageNode` v0 has no caption. Current source Domain has no stable caption
authority. Caption may be considered only after an input contract can
reliably distinguish image body from image caption.

Image position is the node's position in `RichContent.nodes`; no `position`,
`index`, or `order` field is permitted. v0 also introduces no persisted
`nodeId`.

The Domain node must not contain:

- an absolute, local, temporary, cache, extracted, or managed-storage path;
- a URI, provider URL, HTTP URL, DataURL, Base64 payload, raw bytes, provider
  block ID, provider/OCR response body, credential, or diagnostic payload;
- Flutter fit, rounded-corner, loading, cache, display-width, or
  display-height policy;
- duplicate MIME type or pixel dimensions.

Safe MIME type and canonical pixel dimensions remain `AssetRef` metadata in
the draft inventory. They are not repeated on `ImageNode`.

## C. Asset Authority Contract

### C.1 Inventory and placement authority

`QuestionDraftV2.assetRefs` remains the draft-level canonical declared asset
inventory. Each inventory member is a `SourcedAssetRef` whose identity is the
pair `(sourceId, localAssetId)` and whose `AssetRef` carries the canonical safe
metadata.

`ImageNode` is content placement and reference only. Every image identity in
the stem, option content, content answer, explanation, image alternative text,
or table cell must resolve to exactly one member of the owning
`QuestionDraftV2.assetRefs` inventory.

Formally:

```text
for every ImageNode image:
  (image.sourceId, image.localAssetId)
    belongs to QuestionDraftV2.assetRefs identities
```

The existing draft rule also remains: every inventory asset source belongs to
the draft's declared `sourceRefs`.

### C.2 Consistency and failure behavior

For one `(sourceId, localAssetId)` identity there is exactly one canonical
`AssetRef` metadata value. Duplicate declarations with equal metadata may be
deduplicated deterministically; conflicting kind, MIME type, pixel width, or
pixel height must fail closed.

Draft construction, decode, admission, and any mutation/review boundary must
reject:

- an image identity absent from the draft inventory;
- an inventory asset absent from the declared source set;
- conflicting metadata for one source-qualified identity;
- stale replacement that changes identity metadata without satisfying the
  owning revision/CAS contract.

Rendering failure or a physically missing/corrupt asset is an explicit
resource state. It does not authorize legacy-string fallback, metadata repair
inside the node, silent node deletion, or semantic mutation.

### C.3 Durable lifetime and backup invariants

The durable lifetime of an image referenced by a confirmed Question must be
independent of provider responses, temporary files, OCR caches, and
replaceable `ParsedArtifact` generations. None of those may be the confirmed
Question's only byte authority.

Before production activation of `ImageNode`, all durable image assets required
by confirmed Questions must participate in the formal Backup/Restore contract.
Restoring a typed question while permanently omitting its required image bytes
is not an acceptable successful restore. Registry, storage layout, archive
format, manifest, and validation mechanics remain deferred.

## D. TableNode v0 FINAL Contract

### D.1 Shared canonical structure

Table v0 uses one shared Domain value model:

```text
TableNode
└── structure: TableStructure
    └── rows: List<TableRow>
        └── cells: List<TableCell>
            ├── content: RichContent
            ├── rowSpan: int
            └── columnSpan: int
```

`SourceTablePart` and `TableNode` must converge on this same
`TableStructure`; they must not become independent, field-for-field duplicate
table authorities. The current `SourceTablePart.rows:
List<List<RichContent>>` is the pre-span source representation and can be
adapted into the shared value during implementation. That transitional shape
does not authorize a third `ParsedTable`/`TableNode` Domain authority.

The canonical v0 node payload is logically:

```text
type = table
rows = [
  { cells = [
      { content, rowSpan, columnSpan }, ...
  ]}, ...
]
```

Rows and cells preserve encounter order. A table must contain at least one row
and have a non-zero expanded width.

### D.2 Cell content and nesting

`TableCell.content` is always a non-null `RichContent`. It may contain only:

- `TextNode`;
- `InlineMathNode`;
- `BlockMathNode`;
- `ImageNode`.

It may not contain `TableNode` or `RawFallbackNode`. Therefore tables cannot
nest, while text, math, images, and intentionally blank cells remain
representable.

An empty cell is an existing `TableCell` with
`RichContent(nodes: [])`. `null`, an omitted anchor cell, or a missing row
index does not represent an ordinary blank cell.

### D.3 Spans and canonical geometry

`rowSpan` and `columnSpan` are part of v0 and are integers greater than or
equal to one. Each row lists anchor cells in reading order. During geometry
expansion, each anchor occupies the first unoccupied column at or after the
previous anchor; positions covered by an earlier row span or column span are
covered coordinates, not implicit cells. Any uncovered coordinate requires an
explicit empty cell.

Validation must fail closed unless all of the following hold:

- every span is positive;
- expanded rows form one rectangular table geometry;
- no anchor or span overlaps another anchor/span;
- no span extends beyond the validated row or column geometry;
- expansion creates no unknown or implicit content cell;
- row, column, logical-cell, expanded-cell, nested-node, text/scalar, and asset
  budgets are satisfied;
- every cell image belongs to the owning draft asset inventory;
- no cell recursively contains a table.

Concrete maximum numbers are implementation defaults, not durable schema
values. The durable rule is that tables are bounded before provider/OCR input
can enter Domain or persistence.

### D.4 Excluded fields

Table caption, `headerScope`, background, border, alignment, width,
column-width, row-height, CSS, HTML attributes, and style are not in v0.
Caption and header semantics remain deferred until a reliable source contract
exists; presentation styling remains outside Domain.

## E. Codec Evolution Policy

### E.1 RichContent schema version

`RichContentCodec.schemaVersion` remains `1`. Adding the previously unknown
node discriminators `image` and `table` is a compatible minor extension of the
v1 envelope because an older v1 reader already preserves unknown node objects
as `RawFallbackNode` and losslessly re-encodes them.

Adding a node discriminator is not the same as changing an established node
schema. The v0 image and table payloads above are intentionally minimal.

### E.2 Unknown, extended, and malformed payloads

An unknown future node discriminator must become `RawFallbackNode`, render as
a safe unsupported placeholder, pass recursive privacy/resource admission,
and losslessly re-encode without semantic mutation. It must not be dropped,
converted to empty text, or projected into a legacy string and written back as
typed authority.

The current v1 codec also treats a recognized text/math discriminator with its
required canonical string field plus additional unknown fields as a lossless
raw fallback. This is a future extension of a known discriminator, not license
to recover malformed known data. This contract preserves that existing
forward-compatibility behavior.

Once the active reader claims the exact v0 `image` or `table` schema, a payload
with a missing/wrong required field, invalid identity, invalid alternative-text
subset, invalid span/geometry, forbidden nesting, conflicting inventory
metadata, or exceeded bound is malformed known data and must fail closed. It
must not be hidden inside `RawFallbackNode`.

Encoding is deterministic, decoding is strict, and no known-node path may
silently discard fields. Any compatible future extension of an established
discriminator must define how old readers preserve it before activation.

### E.3 When a schema bump is required

A RichContent schema-version bump is required when a change cannot be safely
preserved and re-encoded by the existing v1 envelope, including:

- removing, renaming, or incompatibly reinterpreting an established field or
  discriminator;
- changing image identity or table geometry semantics incompatibly;
- making previously valid v1 payloads invalid without a compatible read path;
- changing the root envelope or unknown-node preservation contract;
- requiring a migration that an old v1 reader cannot losslessly carry.

A new, self-contained discriminator that satisfies the existing unknown-node
contract does not mechanically require a bump.

## F. Privacy / Admission Contract

`RichContentPrivacyAdmission` becomes recursive across every formal nesting
edge:

```text
RichContent
├── ImageNode -> alternativeText -> RichContent
└── TableNode -> TableCell -> RichContent -> ImageNode -> alternativeText
```

Construction/codec validation prohibits `TableNode -> TableCell -> TableNode`
before recursion can continue. Admission must use explicit depth and resource
budgets even where v0 nesting rules already make recursion finite.

Admission must validate:

- total/node-local node counts and text/scalar sizes;
- image alternative-text subset and bounds;
- table row, column, logical-cell, expanded-cell, nested-node, and text/scalar
  bounds;
- every image identity against the current draft inventory;
- all `RawFallbackNode` maps/lists/strings recursively under the existing
  side-channel and locator defenses.

Opaque, bounded `sourceId` and `localAssetId` values plus safe `AssetRef`
metadata are identities/metadata and are allowed. Identity is never a storage
locator and must never be passed to file/HTTP APIs as though it were one.

The following are prohibited anywhere in canonical node payloads or fallback
side channels: `file://` locators, Windows or POSIX paths, UNC paths, provider
or HTTP URLs, DataURLs, Base64, raw bytes, provider requests/responses, raw OCR
bodies, cache/temp/managed-storage locations, diagnostics that disclose source
content, credentials, tokens, and secrets.

## G. Compatibility Contract

Legacy-only Questions continue to use their String representation. This
contract does not rewrite the legacy Question model or delete legacy data.

For a typed Question:

- `QuestionDraftV2 -> RichContent` remains formal authority;
- the V1 String row remains a compatibility projection, never a second truth;
- typed explicit-empty content is authoritative and does not trigger legacy
  fallback;
- a corrupt or unsafe typed sidecar hard-fails explicitly and does not silently
  load the legacy row;
- asset/render failure does not switch authority to legacy content.

Image legacy projection is the safe deterministic projection of admitted
alternative text when that projection is non-empty; otherwise it is `[图片]`.
It never contains paths, managed storage keys, URLs, DataURLs, Base64, raw
bytes, provider references, or inventory metadata.

Table legacy projection expands the validated rectangular geometry, places an
anchor cell's projected content at its top-left coordinate, leaves covered
span coordinates empty, joins columns with ` | `, and joins rows with a single
newline. Cell projection recursively uses safe text/math/image projection.
It is bounded, deterministic, text-only, and never contains raw HTML, JSON,
provider HTML, or storage metadata.

Legacy projections are display/persistence compatibility outputs only. They
are not round-trip formats and must never reconstruct or overwrite typed
authority.

## H. Structural Ownership Contract

The typed structural path is:

```text
SourcePart identity plus block provenance and reading order
    -> ordered QuestionRegion ownership
    -> TypedQuestionAssembler
    -> ContentNode sequence
```

Structural field ownership and order must be derived from source-qualified
block identity/provenance, the actual `SourcePart` occurrence, and canonical
reading/encounter order. An optional `SourceSlice` may select a text interval
inside a `SourceContentPart`; it does not recover non-text ownership.

The concrete OCR/DOCX claim type is deferred, but it must be able to carry at
least the target `QuestionRegionField`, source/block identity or equivalent
`SourcePart` identity, canonical reading order, and an optional text-only
source slice.

`String.indexOf()`, string equality, `[图片]` placeholders, raw HTML, or an
"exactly one unmatched typed part" heuristic may not be structural ownership
authority for images, tables, formulas, or mixed non-text sequences. Text
slicing and deterministic text-field parsing may remain inside text content.

The conforming target maps `SourceAssetPart` directly to `ImageNode` and
`SourceTablePart` directly to `TableNode` in `TypedQuestionAssembler`,
preserving ordered mixed sequences. OCR/DOCX adapters produce Domain source
structure; they do not generate Flutter widgets. Presentation does not parse
HTML to recover Domain content.

## I. Deferred Decisions

The following are explicitly not frozen by Phase 0:

- concrete asset registry or asset-resolution implementation;
- SQLite tables, migration, or database version;
- managed-storage directory/key layout, reference counting, or garbage
  collection;
- Backup package version, archive layout, manifest, and restore mechanics;
- concrete Renderer/Application asset-read API, caching, lazy-loading, and
  asynchronous loading implementation;
- concrete OCR block-claim/region-fragment class;
- DOCX parser/adapter implementation;
- concrete numeric admission/resource defaults;
- image caption schema and extraction semantics;
- table caption and header-scope semantics;
- AI Repair provider schema and prompt;
- provider-specific OCR/DOCX payload schemas;
- Rich Image production activation.

These deferred implementation choices may not weaken the FINAL identity,
inventory, privacy, boundedness, compatibility, structural-ownership,
durable-lifetime, backup-before-activation, or renderer-boundary invariants.

## J. Phase 0 FINAL Decision Matrix

| Decision | Status | Reason |
|---|---|---|
| `ImageNode` in the foundation set | FINAL | Images require first-class typed placement rather than string/renderer reconstruction. |
| `TableNode` in the foundation set | FINAL | Tables require first-class typed structure rather than lossy text/HTML projection. |
| `InlineMathNode` / `BlockMathNode` split | FINAL | Inline/block semantics are structural and must not be re-inferred. |
| Additional v0 nodes | REJECTED | No current foundation evidence requires HTML, widget, layout, provider, file, or Markdown nodes. |
| String asset reference or storage locator | REJECTED | Identity is the existing source-qualified asset identity; locators are infrastructure details. |
| `QuestionDraftV2.assetRefs` inventory authority | FINAL | It is the single draft-level source of canonical safe asset metadata. |
| Image `(sourceId, localAssetId)` placement reference | FINAL | It references inventory identity without duplicating metadata. |
| `alternativeText: RichContent?` | FINAL | It preserves the existing typed Source asset contract. |
| Alternative-text text/math-only subset | FINAL | It prevents recursive images/tables and bounds semantics. |
| Image caption | DEFERRED | No stable source caption authority exists. |
| Image position/order fields | REJECTED | `RichContent.nodes` already carries canonical order. |
| Persisted ContentNode ID in v0 | REJECTED | No current Foundation invariant requires stable node identity. |
| Shared `TableStructure` for Source/Table node | FINAL | It prevents duplicate table authorities. |
| RichContent cells | FINAL | Cells must preserve text, math, images, and explicit empty content. |
| `rowSpan` / `columnSpan` | FINAL | Merged cells are source structure, not presentation decoration. |
| Empty cell as `RichContent(nodes: [])` | FINAL | Cell existence and geometry remain explicit. |
| Nested `TableNode` in cells | REJECTED | v0 is not a recursive layout engine. |
| `RawFallbackNode` in cells/alternative text | REJECTED | These constrained subtrees require known, bounded semantics. |
| Table caption / `headerScope` / style | DEFERRED | No reliable source semantics justify v0 fields; style is Presentation-owned. |
| Bounded table and nested content admission | FINAL | Unbounded OCR/provider payloads may not enter Domain/persistence. |
| Recursive privacy admission | FINAL | Every nested RichContent edge must preserve side-channel defenses. |
| Asset identity distinct from locator | FINAL | Domain identity never authorizes path/URL interpretation. |
| RichContent schema version 1 | FINAL | New self-contained node discriminators fit current unknown-node preservation. |
| Unknown future node -> lossless fallback | FINAL | Old readers preserve data without semantic mutation. |
| Malformed known node -> fallback | REJECTED | Claimed known schemas fail closed on invalid canonical payloads. |
| Legacy Question rewrite/deletion | REJECTED | Existing banks and String compatibility remain supported. |
| Typed explicit-empty -> legacy fallback | REJECTED | Explicit typed emptiness is authoritative. |
| Corrupt typed sidecar -> legacy fallback | REJECTED | Corrupt/unsafe typed authority remains a hard failure. |
| Structural ownership by reverse string matching | REJECTED | It cannot preserve mixed or repeated non-text structure. |
| Block-native ownership principle | FINAL | Source/block provenance and reading order carry structural truth. |
| Durable confirmed-image lifetime invariant | FINAL | Provider temp/cache/artifact generations cannot be sole byte authority. |
| Backup/Restore before ImageNode production activation | FINAL | A successful restore cannot permanently orphan required images. |
| Concrete SQLite asset registry | DEFERRED | Phase 0 freezes invariants, not persistence implementation. |
| Concrete Backup package implementation | DEFERRED | Archive mechanics require a separate asset-lifecycle contract. |
| Ambient/global asset resolver | REJECTED | Renderer access requires an explicit safe Application/Presentation seam. |
| AI Repair String overwrite authority | REJECTED | Future repair proposes admitted node trees against exact revision/CAS state. |
