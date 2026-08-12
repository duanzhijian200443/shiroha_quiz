# F1 Parsed Artifact Lifecycle — Focused Canonical Contract

Status: **Canonical F1 authority**.

This document is the authoritative contract for the parsed-artifact lifecycle:
identity, revision, lifecycle states, cache identity, payload boundary,
storage/atomic publish, the approved additive v20 schema expectation, the
Application seam, supported routes, and F1 stage governance. It freezes design
only; F1-P0 implements no production code, tests, or schema migration.

## 1. Identity

- `fileId`: the long-lived stable identity of the original `LibraryFile`.
- `artifactId`: the identity of one successfully published ParsedArtifact
  generation. It must not be derived from file name, path, timestamp, or
  task/attempt ID.
- `revision`: a monotonically increasing sequence number of successful
  publications under the same `fileId`.
  - First successful publication is revision 1.
  - A cache hit creates no artifact and no revision.
  - Explicit reparse bypasses the cache; on success it creates a new
    `artifactId` and increments the revision.
  - Failed, interrupted, or CAS-conflicted generation does not increment the
    revision.
  - Removal deletes the current pointer but preserves the revision head; a
    later successful publication continues incrementing from that head.
- `SourceDocument.sourceId = artifactId`, never `fileId`. Page, block, asset,
  and issue provenance must bind to one specific artifact generation.

## 2. Lifecycle states and behavior

Frozen states:

- `none`: no current artifact.
- `available`: metadata, sidecar, digest, size, and codec validation all pass.
- `generating`: transient Application operation only; never persisted as a
  current artifact.
- `corrupt`: metadata exists but the payload is missing, damaged, unsupported
  version, or identity-mismatched; must be a typed hard failure.
- `removed`: current metadata removed; revision head retained.

Frozen behavior:

- First parse publishes revision 1 on success.
- `ensureParsedArtifact` returns a cache hit when the cache fingerprint matches
  and the current artifact is complete.
- Explicit reparse always generates a new candidate; only a successful CAS
  publish replaces the current artifact.
- Failed or interrupted reparse must preserve the original current artifact.
- Corruption must never silently return an empty `SourceDocument`, legacy
  provider content, or uncontrolled raw fallback.
- F1 v0 keeps at most one current artifact per file and does not implement full
  artifact history.

## 3. Confirmed learning-data independence

- Replacement, removal, or corruption of an artifact must never delete or
  rewrite a confirmed `QuestionDraftV2`, persisted questions, or review/FSRS
  state.
- The existing `SourceRef` values inside a confirmed `QuestionDraftV2` remain
  unchanged after reparse or removal.
- F1 v0 does not guarantee that replaced or deleted historical artifacts can be
  re-dereferenced from those unchanged `SourceRef` values.
- F1 v0 does not implement an artifact history or tombstone registry. An
  unchanged `SourceRef` is a provenance record, not a re-resolution promise.

## 4. Cache identity

Semantic cache-fingerprint inputs:

- `LibraryFile.sha256`
- artifact payload schema version
- resolved parser route
- parser/adapter semantic version
- normalized typed parse options
- parse-options schema version

Excluded from cache identity:

- display name
- external, managed, or resolved absolute path
- storage absolute path
- temporary file/image name
- task/attempt ID
- timestamp

The concrete hash algorithm is not canonical; what is persisted is a versioned
opaque fingerprint.

For OCR/AI non-deterministic results:

- the fingerprint denotes only a semantically identical parse request;
- external result reproducibility is not promised;
- a specific generation is identified by `artifactId + revision + payload
  digest`;
- explicit reparse produces a new generation even when the fingerprint is
  identical.

## 5. Safe payload boundary

Strict versioned `ParsedArtifactPayload`:

```text
schemaVersion
artifactId
fileId
sourceDocument
```

Persisted payloads may contain only:

- `SourceDocument`
- `SourcePart`
- `SourceRef`
- `RichContent`
- `ImportIssue`
- safe `AssetRef` metadata

Forbidden from persistence:

- provider DTOs or raw provider/OCR responses
- `ParsedDocument` diagnostics
- raw exceptions/provider bodies
- Base64, full raw responses, or debug bodies
- absolute/resolved/extracted filesystem paths
- temporary image paths
- parser task/attempt state

v0 does not persist binary image bytes. DOCX/Markdown/OCR images keep only safe
metadata, alternative text, or a typed unsupported/unavailable issue.

Decode must strictly reject:

- missing or unknown schema version
- unknown top-level fields
- wrong field types
- artifact/file identity mismatch
- privacy admission failure
- malformed `SourceDocument`

Unsafe/corrupt payloads must never be downgraded to provider/raw content.

## 6. Storage and atomic publish

Decision: **SQLite current metadata + managed immutable artifact sidecar**.
Rejected: large JSON/BLOB inside SQLite; pure filesystem manifest.

Rationale:

- avoids SQLite/WAL growth and long write locks;
- payloads can be streamed;
- SQLite retains FK, CAS, current pointer, and query authority;
- relative `storage_key` supports Windows/mobile portability;
- suits later P6, Agent, and RAG consumers;
- derived sidecars follow explicit backup/GC rules.

Publish sequence:

1. Write a temporary sidecar under a unique nonce.
2. Close/flush and compute size/digest.
3. Rename to the immutable artifact sidecar.
4. Publish metadata in one SQLite transaction via expected-revision CAS.
5. The SQLite commit is the only externally visible point.
6. On CAS failure the candidate payload is invisible and enters cleanup.
7. After commit, old sidecars are cleaned; a failed cleanup leaves only an
   orphan and never rolls back the published artifact.

DB metadata with a missing sidecar or mismatched size/hash returns a typed
corruption failure.

GC, publish, and remove share a per-file Application lock; SQLite CAS is the
final concurrency correctness boundary. F1 v0 promises a single application
process and no cross-process writer.

B0 backup must choose one of:

- include and validate all current sidecars; or
- remove artifact metadata from the backup database copy and exclude derived
  sidecars.

Backups with dangling artifact metadata are forbidden.

## 7. Additive v20 schema expectation

Current runtime/schema is v20. F1-P0 froze the additive v20 design without
modifying the database; F1-D1 implemented the two new tables. F1-P0-era
statements that v20 was "approved but not implemented" describe that stage's
history and no longer describe current state.

v20 adds two new tables and modifies no existing table.

`parsed_artifact_heads`:

```sql
CREATE TABLE parsed_artifact_heads (
  file_id TEXT PRIMARY KEY NOT NULL,
  last_revision INTEGER NOT NULL CHECK(last_revision >= 0),
  FOREIGN KEY(file_id)
    REFERENCES library_files(file_id) ON DELETE CASCADE
);
```

`parsed_artifacts`:

```sql
CREATE TABLE parsed_artifacts (
  file_id TEXT PRIMARY KEY NOT NULL,
  artifact_id TEXT NOT NULL UNIQUE,
  revision INTEGER NOT NULL CHECK(revision > 0),
  source_sha256 TEXT NOT NULL CHECK(length(source_sha256) = 64),
  cache_key_version INTEGER NOT NULL CHECK(cache_key_version > 0),
  cache_fingerprint TEXT NOT NULL
    CHECK(length(cache_fingerprint) BETWEEN 1 AND 128),
  parser_route TEXT NOT NULL
    CHECK(length(parser_route) BETWEEN 1 AND 64),
  parser_version TEXT NOT NULL
    CHECK(length(parser_version) BETWEEN 1 AND 64),
  options_schema_version INTEGER NOT NULL
    CHECK(options_schema_version > 0),
  payload_schema_version INTEGER NOT NULL
    CHECK(payload_schema_version > 0),
  storage_key TEXT NOT NULL UNIQUE CHECK(length(storage_key) > 0),
  payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256) = 64),
  size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
  published_at INTEGER NOT NULL CHECK(published_at >= 0),
  FOREIGN KEY(file_id)
    REFERENCES parsed_artifact_heads(file_id) ON DELETE CASCADE
);
```

Semantics:

- the head retains revision continuity after current removal;
- at most one current record per file;
- the publish transaction guarantees current `revision == last_revision`;
- no speculative secondary indexes beyond PK/UNIQUE automatic indexes;
- no status/history/chunk/vector/provider/options JSON, question, bank,
  Project, or Conversation fields.

## 8. Application seam

Presentation, Agent, MCP, P6, and RAG consume artifacts only through the stable
Application lifecycle seam:

- `getCurrentArtifact(fileId)`
- `ensureParsedArtifact(fileId, options)`
- `reparseArtifact(fileId, options, expectedRevision)`
- `removeCurrentArtifact(fileId, expectedRevision)`

Safe outcomes:

- `cacheHit`
- `published`
- `removed`

Safe failure taxonomy:

- `invalidRequest`
- `fileNotFound`
- `unsupportedRoute`
- `sourceUnavailable`
- `parseFailed`
- `publishConflict`
- `artifactMissing`
- `artifactCorrupt`
- `payloadUnsupported`
- `temporarilyUnavailable`
- `internalError`

The Application never exposes SQLite rows, absolute paths, `ParsedDocument`,
or OCR/provider DTOs to adapters. F1 does not expand the MCP v0 exactly-six
read-only tools.

## 9. F1 v0 routes

Supported:

- `pdf_text`
- `docx_text`
- `txt`
- `markdown`
- `ocr_pdf`
- `ocr_image`: PNG/JPG/JPEG

Rules:

- auto route selects deterministic routes only;
- a PDF without usable text returns a typed unavailable, never an implicit
  OCR/provider call;
- OCR must be explicitly selected;
- multiple files always have independent `fileId`/`artifactId` lifecycles;
- the old paired/combined two-PDF merge is not restored.

## 10. Stage graph, ownership, and governance

Frozen stage graph:

```text
F1-P0 -> F1-D0 -> F1-D1 -> F1-A1 -> F1-I1 -> F1-I2 -> F1-CL
```

Ownership:

- `F1-P0`: canonical docs — COMPLETE.
- `F1-D0`: ParsedArtifact domain, SourceDocument codec, payload codec —
  COMPLETE.
- `F1-D1`: v20 migration, repository, managed sidecar storage — COMPLETE.
- `F1-A1`: Application lifecycle seam and orchestration — COMPLETE.
- `F1-I1`: deterministic production generation adapter on existing parser
  truth — COMPLETE.
- `F1-I2`: explicit OCR ParsedArtifact generation integration — COMPLETE.
- `F1-CL`: focused verification, final full semantic review, canonical
  closure — COMPLETE.

Current state: F1-P0 through F1-CL are COMPLETE; F1 v0 is closed. The v20 tables, the D1
persistence/storage primitives, and the A1 lifecycle seam (get/ensure/reparse/
remove, cache fingerprint v1, per-file mutation gate, publish and best-effort
cleanup orchestration, and the 11-item Application failure taxonomy) exist in
production. F1-I1 wires deterministic artifact generation through the A1
generation port for `pdf_text`/`docx_text`/`txt`/`markdown`, reusing the
existing parser truth (shared Syncfusion PDF text extraction,
`DocxDocumentAdapter`, `TxtDocumentAdapter`, `MarkdownDocumentAdapter`) and
projecting every result through `ParsedSourceDocumentAdapter`. Under the F1-I1
Class C amendment, `ParsedSourceDocumentAdapter` is activated for exactly one
production consumer (the deterministic generation adapter); the R2D
acceptance allowlist keeps rejecting every other caller. F1-I2 explicit OCR
generation is COMPLETE for explicit `ocr_pdf`/`ocr_image` routes; `auto`
remains deterministic-only and never triggers OCR. OCR artifact source truth
is `OcrDocumentClient -> OcrDocument -> OcrSourceDocumentAdapter ->
SourceDocument`; the question OCR pipeline (`OcrImportService`, regionizer,
assembler, typed candidates, reference answers) is not part of ParsedArtifact
generation. Under the F1-I2 Class C amendment, `OcrSourceDocumentAdapter`
has exactly two production callers: the frozen R7B typed-candidate seam and
the F1-I2 OCR artifact generation seam. OCR testing/acceptance is offline and
mocked; no live provider proof is claimed. F1-CL is COMPLETE: focused
verification PASS, final full semantic review APPROVE, closure repair merged
via PR #65, and no open P0/P1/P2/P3 findings. There is no UI, Agent, or MCP
activation.

Governance:

- all F1 stages are `SERIAL`;
- a checkpoint must complete and freeze before the next stage starts, and later
  stages never auto-activate;
- F1-CL is the single fixed high-risk closure point: focused verification
  followed by the final full semantic review;
- mid-stage review escalation is allowed only for a truly unresolved Class C
  decision or still-unfrozen schema/CAS semantics;
- there is no F1-U; UI entry/redesign is deferred.

## 11. Validation matrix

| Concern | Validated invariant |
|---|---|
| Identity | `artifactId` uniqueness per generation; revision monotonicity; `SourceDocument.sourceId == artifactId` |
| Lifecycle | state transitions; cache-hit creates nothing; failed reparse preserves current artifact |
| Learning data | confirmed drafts/questions/review state and existing `SourceRef` values unchanged after reparse/removal |
| Payload | strict codec admission; privacy admission; corruption is a typed hard-fail |
| Publish | CAS conflict preserves current; commit is the only visibility point; cleanup failure leaves only an orphan |
| Storage | sidecar presence/size/hash validated; no dangling artifact metadata in backups |
| Seam | adapters receive only safe outcomes/typed failures, never rows, paths, or provider DTOs |

## 12. Rollback and stop conditions

Rollback:

- F1-P0: revert the four canonical documents to the pre-freeze tree; no code or
  schema exists to roll back.
- Later stages: any stage that cannot satisfy its frozen contract stops at its
  checkpoint; prior frozen stages remain authoritative, and identity, revision,
  CAS visibility, and confirmed learning-data independence are never silently
  redefined.

Stop conditions:

- any change requiring actual schema, production, or test modification without
  separate authorization;
- any requirement that conflicts with identity, revision, `sourceId`, CAS
  visibility, or confirmed learning-data independence;
- any expansion into deferred capabilities (ZIP, vision, binary assets, full
  history, P6/P7/RAG, MCP, or UI).

## 13. Deferred capabilities

- ZIP
- vision/AI question parsing
- binary asset persistence
- full artifact history
- P6 supplemental matching
- P7 AI candidates
- embeddings/chunk/vector/RAG
- Agent File tools
- MCP v0 expansion
- UI entry/redesign
- bank identity, Project, Conversation schema changes

## 14. Documentation authority

- `ARCHITECTURE.md` — repository-wide dependency and boundary contract.
- This document — focused F1 authority.
- `docs/architecture/adr-002-learning-asset-lifecycle.md` — accepted lifecycle
  decision.
- `docs/architecture/n0-post-p5-roadmap.md` — stage ordering and current
  status.
