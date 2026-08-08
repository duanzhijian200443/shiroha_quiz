# ADR-002: Learning Asset Lifecycle and Project Ownership

Status: **Accepted**

## Context

Post-P5 features need user files for normal import, supplemental-answer matching, Agent analysis, later retrieval and backup. Treating a selected PDF/image as a temporary import argument would create duplicate file lifecycles for each feature. Treating OCR output as the file itself would also lose the original source needed for reparse, audit and future models.

## Decision

Shiroha distinguishes three lifecycles:

```text
LibraryFile
  original user-owned file + durable managed-storage identity
        |
        v
ParsedArtifact / SourceDocument
  reproducible derived parser/OCR structure
        |
        v
QuestionDraftV2 -> Review -> PersistedQuestion
  confirmed learning data
```

### LibraryFile

- Original bytes live in app-managed storage, not SQLite blobs.
- SQLite stores metadata plus a stable `fileId` and managed storage key/relative identity.
- Durable metadata must not depend on platform absolute paths.
- A file can exist without being parsed or imported into a bank.

### ParsedArtifact

- Derived/cache-like data associated with a LibraryFile.
- May be regenerated/replaced without changing the original file identity.
- F0 is not required to implement full artifact history/versioning.

### Persisted learning data

- Confirmed questions/review state are independent formal assets.
- Removing/replacing an artifact cache must not delete confirmed questions or FSRS state.
- Source/provenance references remain safe and typed.

### Project

- Optional long-lived organization/context layer.
- Projects reference files and banks; they do not own/duplicate original file bytes.
- One LibraryFile may be referenced by multiple Projects.
- Unassigned files/banks remain valid.
- Existing subject/folder structures are retained until separately migrated.

## Deferred decision

Stable bank identity for `project_banks` must be resolved at J0-P0. N0 intentionally does not create `bank_registry` or migrate current `bank_name` persistence.

## Consequences

Positive:

- import, P6, Agent, RAG and backup share one original-file lifecycle;
- reparse can improve derived artifacts without destroying user assets;
- Projects remain flexible and non-destructive.

Costs:

- managed storage needs explicit orphan/cleanup and backup rules in F0/B0;
- Project relations require a bounded bank-identity decision before persistence.
