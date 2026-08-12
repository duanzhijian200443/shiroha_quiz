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
- Identity is generation-scoped: `artifactId` identifies one successfully
  published generation, `revision` is the monotonic per-file publication
  counter, and `SourceDocument.sourceId = artifactId` (never `fileId`).
- F1-P0 freezes the full lifecycle contract in
  `docs/architecture/f1-parsed-artifact-lifecycle.md`; it implements no
  production code, tests, or schema migration.

#### Lifecycle states

- `none` — no current artifact.
- `available` — metadata, sidecar, digest, size, and codec validation all pass.
- `generating` — transient Application operation, never persisted as a current
  artifact.
- `corrupt` — metadata exists but the payload is missing, damaged, unsupported,
  or identity-mismatched; typed hard-fail.
- `removed` — current metadata removed; the revision head is retained.

A cache hit creates no artifact and no revision. Explicit reparse bypasses the
cache and, on a successful CAS publish, creates a new `artifactId` and
increments the revision. Failed, interrupted, or CAS-conflicted generation
preserves the current artifact; corruption never silently falls back to empty,
legacy provider, or uncontrolled raw content.

#### Storage decision

SQLite current metadata + managed immutable artifact sidecar.

Rejected alternatives:

- SQLite large JSON/BLOB — WAL growth and long write locks;
- pure filesystem manifest — loses FK, CAS, current-pointer, and query
  authority.

Publish sequence: unique-nonce temporary sidecar -> close/flush and compute
size/digest -> rename to the immutable sidecar -> one SQLite transaction with
expected-revision CAS -> commit as the only visibility point. A CAS failure
leaves the candidate invisible and schedules cleanup; a commit-time old-sidecar
cleanup failure leaves only an orphan and never rolls back the published
artifact. DB metadata without a matching sidecar, or with mismatched
size/hash, is a typed corruption failure.

GC, publish, and remove share a per-file Application lock; SQLite CAS is the
final concurrency correctness boundary. F1 v0 promises a single application
process and no cross-process writer.

#### Backup and concurrency consequences

B0 backup must choose one of:

- include and validate all current sidecars; or
- remove artifact metadata from the backup database copy and exclude derived
  sidecars.

Backups with dangling artifact metadata are forbidden.

#### Cache identity

Semantic fingerprint inputs: `LibraryFile.sha256`, artifact payload schema
version, resolved parser route, parser/adapter semantic version, normalized
typed parse options, and parse-options schema version. Excluded: display name,
external/managed/resolved absolute paths, storage absolute path, temporary
file/image names, task/attempt ID, and timestamp. The persisted fingerprint is
versioned and opaque; the concrete hash algorithm is not canonical. For
OCR/AI, a fingerprint denotes only a semantically identical parse request —
external reproducibility is not promised, and explicit reparse always produces
a new generation.

#### Confirmed learning-data independence

- Replacement, removal, or corruption never deletes or rewrites a confirmed
  `QuestionDraftV2`, persisted questions, or review/FSRS state.
- Existing `SourceRef` values in a confirmed draft remain unchanged after
  reparse or removal.
- F1 v0 does not guarantee that replaced or deleted historical artifacts can
  be re-dereferenced from those unchanged `SourceRef` values, and it implements
  no artifact history or tombstone registry.

#### Application seam

Consumers use only `getCurrentArtifact`, `ensureParsedArtifact`,
`reparseArtifact`, and `removeCurrentArtifact`, with safe outcomes
(`cacheHit`/`published`/`removed`) and the typed failure taxonomy. Adapters
never receive SQLite rows, absolute paths, `ParsedDocument`, or provider DTOs.
F1 does not expand the MCP v0 exactly-six read-only tools.

#### Deferred

Full artifact history, binary asset persistence, ZIP/vision routes,
P6/P7/RAG, Agent File tools, MCP v0 expansion, and UI entry/redesign remain
deferred. F1 v0 keeps one current artifact per file.

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

- managed storage needs explicit orphan/cleanup and backup rules, frozen in
  F1-P0 and enforced in F1-D1/B0;
- immutable sidecar cleanup may leave bounded orphans after commit; these never
  roll back a published artifact;
- Project relations require a bounded bank-identity decision before persistence.
