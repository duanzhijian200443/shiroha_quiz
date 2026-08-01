# Content Model V2 Architecture Baseline

Status: R0A documentation baseline. This document defines migration intent only.
No V2 model named below exists in production code as part of R0A.

## Current factual data flow

The repository currently has two input paths that converge late:

```text
TXT / Markdown / DOCX / ZIP
  -> adapters in lib/services/import_pipeline/adapters/
  -> ParsedDocument
  -> DocumentPart (TextPart / TablePart / ImagePart)
  -> ParsedDocument.toPlainTextForParsing()
  -> DocumentParseRouter / LocalQuestionAssembler
  -> Question Map

PDF / image / GLM-OCR response
  -> OcrDocumentClient and provider DTO parsing
  -> OcrDocument / OcrPage / OcrBlock
  -> OcrQuestionRegionizer
  -> OcrQuestionRegion
  -> OcrQuestionAssembler
  -> Question Map

Question Maps
  -> ImportQuestionFusionCoordinator / MultiFileQuestionMergeService
  -> final field policy, safe HTML cleanup and final LaTeX audit
  -> QuestionDraft + ImportReviewItem / ImportReviewIssue
  -> TaskManager parsedData review snapshot
  -> ImportCommitService
  -> QuestionRepository
  -> DatabaseHelper questions row
  -> Question.fromMap
  -> StructuredContentRenderer
```

The important current loss boundary is
`ParsedDocument.toPlainTextForParsing()`: tables become Markdown-like strings
and images become textual placeholders. The OCR path retains block and page
identity longer, but its assembled business result also becomes a question
`Map<String, dynamic>`.

## Duplicate model matrix

| Current concepts | Overlap | V2 disposition |
|---|---|---|
| `ParsedDocument` and `OcrDocument` | Source document identity, ordered content and diagnostics | Extend the general source model; keep OCR classes as infrastructure DTOs during compatibility, then remove their business-model role |
| `DocumentPart` and `OcrBlock` | Text, table/image-like content and source order | Extend `DocumentPart` semantics into source parts; adapt OCR blocks at the boundary |
| `OcrQuestionRegion` and assembled question maps | Question boundaries plus provenance | Preserve the stable numbering algorithm; migrate its output to a typed `QuestionRegion` before typed assembly |
| `QuestionDraft`, question maps and database rows | Editable/final question fields | Keep `QuestionDraft` as a V1 bridge; introduce one domain draft and delete map-shaped business exchange only after all callers migrate |
| diagnostics maps and `ImportReviewIssue` | Issue code, severity and affected question | Make typed issues canonical; keep diagnostic maps as compatibility/reporting projections |
| `ImportTask.parsedData` and staging widget state | Review draft, overrides and revision | Move ownership to an application `ReviewSession`; keep snapshot maps as a versioned serializer |
| Markdown strings and renderer tokens | Text, formulas, images and fallback content | Parse into `RichContent`; keep legacy Markdown conversion at the compatibility edge |

## Target responsibilities

These names describe responsibilities, not R0A implementations.

| Target concept | Layer | Responsibility |
|---|---|---|
| `SourceDocument` | domain | Stable source identity, ordered source parts and document-level provenance |
| `SourcePart` | domain | One ordered source unit without provider, file-system or widget types |
| `SourceRef` | domain | Safe page/block/range reference; never stores absolute path or full preview text in diagnostics |
| `QuestionRegion` | application/domain boundary | A numbered source span prepared for assembly while preserving provenance |
| `RichContent` | domain | Ordered content nodes with lossless fallback |
| `ContentNode` | domain | Text, inline math, block math, table, image reference or raw fallback node |
| `AssetRef` | domain | Stable asset identity and metadata, not a local absolute path |
| `QuestionOption` | domain | Stable label, ordered rich content and optional source reference |
| `QuestionDraftV2` | domain | Editable typed question fields plus provenance references |
| `ImportIssue` | domain | Stable code, severity, safe field name and source reference without content body |
| `ReviewSession` / `ReviewDraft` | application | Revisioned edits, deletions, retention overrides and answer-distillation state |
| `PersistedQuestion` | infrastructure boundary | Explicit database representation used by a repository mapper |

`RichContent` must always have a raw fallback node for unsupported structures.
No converter may silently discard text, tables, images, formulas, diagnostics or
source references.

## Asset identity scope before R3

`AssetRef.assetId` is local to one `SourceDocument`. Reusing a deterministic
local token such as `asset_000001` in another source document is valid and does
not imply that the assets are equal.

Any aggregate that can contain assets from multiple source documents must use
the composite identity `(sourceId, localAssetId)`. `QuestionDraftV2` represents
that association with `SourcedAssetRef`; identical composite references are
deduplicated in first-encounter order, while conflicting metadata for one
composite identity is invalid. Different source IDs must never be merged solely
because their local asset IDs match.

Source IDs are assigned by the future source registry before adapter conversion
and must be independent of file names, paths, provider identifiers, timestamps,
random values, and asynchronous completion order. Local asset IDs may be
assigned after parsing in deterministic asset encounter order. Neither local nor
composite asset identity is a database-global key; future persistence must keep
the owning aggregate identity alongside the composite source/asset identity.

## Dependency rules

The target direction is:

```text
presentation -> application -> domain
infrastructure -> domain/application ports
```

The domain must not import Flutter, SQLite, HTTP clients, provider DTOs, file
system APIs or UI types. Presentation must not import SQLite or
`DatabaseHelper`. Services must use repositories or application ports.
Infrastructure may implement ports and map DTOs, rows and files into domain
objects.

Executable architecture checks should be added before production V2 types:

- domain paths do not import `package:flutter`, `sqflite`, `dart:io` or provider
  packages;
- presentation and application paths do not import `DatabaseHelper`;
- `DatabaseHelper` does not import repositories, services or UI;
- infrastructure DTOs are not exposed in public domain/application signatures.

## Compatibility bridges and deletion conditions

The migration requires temporary, named bridges:

- OCR provider DTO / `OcrDocument` -> `SourceDocument`;
- `ParsedDocument` -> `SourceDocument`;
- `QuestionDraftV2` <-> legacy question map;
- `RichContent` <-> legacy Markdown/string;
- typed issue -> current `_import_review` and diagnostics maps;
- `ReviewSession` <-> versioned `ImportTask.parsedData` snapshot;
- `PersistedQuestion` <-> V1 questions row.

A bridge can be deleted only when all production callers, persisted readers and
characterization tests have moved to the typed side, a rollback reader remains
available for the previous released schema, and read-only Replay acceptance
shows no loss of counts, ordering, assets, diagnostics or content fallback.

## Privacy boundary required before R2

Before any source-model production migration, path and preview handling needs an
explicit policy:

- source references expose stable IDs and relative/sanitized labels, never
  absolute paths;
- diagnostics expose counts, stages, statuses and safe field names only;
- text previews are opt-in, bounded and excluded from logs, snapshots and
  acceptance reports by default;
- raw OCR text, answers, provider bodies, credentials and Base64 assets never
  enter diagnostics;
- fixture content remains synthetic and cannot be derived from private PDFs or
  Replay payloads.
