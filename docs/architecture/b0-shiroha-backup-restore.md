# B0 `.shiroha` Backup / Restore — Focused Canonical Contract v0

Status: **Canonical B0 authority — B0 v0 CLOSED / FROZEN**.

This document freezes the B0 v0 package, export, restore, rollback, version
compatibility, exclusion/scrub, observability, and acceptance contract for the
`.shiroha` backup/restore capability.

Implementation status amendment: B0-P0 froze this contract as docs-only. The
serial implementation stages B0-D0 (package/manifest core), B0-E0 (export),
B0-I0 (whole restore + durable journal + crash recovery + rollback), B0-U0
(minimal backup/restore UI), B0-V0 (focused acceptance), and B0-CL (canonical
closure) are COMPLETE. Runtime schema remains v22; B0 adds no migration and no
dependency changes.

The frozen implementation order was:

```text
B0-D0 -> B0-E0 -> B0-I0 -> B0-U0 -> B0-V0 -> B0-CL
```

## 1. Package identity and versioning

- `.shiroha` is a **ZIP-compatible archive with a custom extension name**.
- The project already has the `archive` dependency. B0 v0 must use that
  dependency and must not add or upgrade dependencies.
- Two independent version numbers are frozen and must never be merged:

```text
packageVersion = 1
schemaVersion  = SQLite PRAGMA user_version
```

- `packageVersion` versions the container/manifest protocol.
- `schemaVersion` versions the SQLite schema carried inside the snapshot.
- The manifest carries both; compatibility checks for each are separate
  (§8).
- Current runtime schema at B0-P0 is **v22**.

## 2. Frozen package structure

A `.shiroha` package contains exactly the v1 entry layout below:

```text
<backup>.shiroha

manifest.json

database/
  shiroha.db

files/
  library/
    <fileId>
```

Rules:

- Archive entry paths never use user `displayName`; managed original files are
  addressed by `files/library/<fileId>`.
- `database/shiroha.db` is the sanitized SQLite snapshot.
- Each packaged original must be the immutable managed bytes for one
  `library_files` row and must match its snapshot DB `fileId`, `storageKey`,
  `sizeBytes`, and `sha256` exactly (§3, §5).
- The package carries no file outside this layout unless a later package
  version explicitly adds it to the version contract.

Archive/path safety is fail-closed:

- no absolute path;
- no `..` path segment;
- no drive path (for example `C:` / `C|`);
- no symlink/junction/link entry, and extraction must never follow or create
  links;
- no duplicate entry path, including duplicates that survive normalization
  (`a//b`, `a/../b`, `.`-segment cleanup); case-insensitive collision must
  also fail on Windows/Android extraction;
- no unknown executable payload. v1 accepts only the regular-file entries
  named by this contract; no package payload is interpreted or executed.
- `manifest.json` is a regular JSON file entry, not a directory or link.

Resource admission for entry count, manifest bytes, declared sizes,
compression methods, streaming output, and free-space preflight is frozen in
§12 and is enforced before and during extraction.

The manifest must not copy Conversation text, Question text, typed sidecar
payloads, or user file bytes. Those bytes remain only inside
`database/shiroha.db` or `files/library/<fileId>` as applicable.

## 3. Portable snapshot — INCLUDE

The sanitized SQLite snapshot must preserve all authoritative durable user
state. For current runtime schema v22, the frozen INCLUDE set is:

| Durable state | Current schema rows |
|---|---|
| Questions | `questions` compatibility rows and all question columns |
| Question V2 typed persistence | `question_v2_payloads` (typed sidecar remains authority) |
| Question-bank compatibility data | `questions.bank_name`, `bank_folders`, `custom_folders` |
| Review / FSRS | `review_states` |
| Review logs / learning history | `review_logs` |
| Durable study statistics/history | `pomodoro_sessions`, `exam_papers`, `paper_questions` |
| LibraryFile metadata | `library_files` |
| Library Folder relations | `library_folders`, `library_file_folders` |
| Projects and relations | `projects`, `project_files`, `project_banks` |
| Conversations | `conversations` |
| Conversation Messages | `conversation_messages` |
| Conversation-file relations | `conversation_files` |
| Active StudyPlan | `study_plans` |
| Non-secret AI engine metadata | `ai_engines` metadata columns only; credential columns scrubbed (§4) |
| Legacy AI metadata compatibility | `ai_profiles` metadata columns only, if retained; credential columns scrubbed (§4) |
| Non-secret durable app/Agent configuration | audited `app_settings` rows such as `agent_config_v0`, active engine ids, current-bank and daily-quota settings; purely UI-local keys (currently `app_theme`) are excluded |

Additional SQLite rows may be included only after an explicit B0-D0/E0 audit
confirms they are authoritative durable user state and are not in the EXCLUDE
sets below. Unclassified authoritative rows must never be silently dropped;
when the audit cannot confirm either way, B0-D0 must classify before E0 ships.

For every `library_files` row in the snapshot, the corresponding managed
original bytes must be packaged. The packaged original and snapshot row must
agree on:

```text
fileId
storageKey
sizeBytes
sha256
```

`sha256` is lowercase hex. A `library_files` row with missing, extra,
unreadable, or digest/size-mismatched packaged bytes makes the export or
restore fail (§5, §9).

## 4. Explicit EXCLUDE / SCRUB

### Credentials

The package must never contain:

- the secure credential store contents;
- API keys;
- Authorization values;
- access tokens;
- secrets.

In the sanitized snapshot, all legacy/current credential columns must be in an
empty/null safe state. For current schema v22 this includes at least:

```text
ai_engines.api_key
ai_profiles.text_api_key
ai_profiles.vision_api_key
```

No credential column may retain a non-empty value. Restore must not modify the
target device secure credential store. Existing credentials remain
device-local. After restore, runtime may rehydrate an engine only when the
target device secure store already contains a credential for the same
`engineId`, through the existing S0 authority. B0 v0 must never infer,
generate, migrate, or copy a credential from package contents.

### ParsedArtifact

B0 v0 chooses the F1-permitted route:

```text
exclude artifact sidecars
+
strip artifact metadata from the backup DB copy
```

In the sanitized snapshot:

```text
parsed_artifacts
parsed_artifact_heads
```

must contain **zero rows** — no current artifact state and no revision head
state. Their schema objects may remain. Artifact sidecars are never packaged.
The live DB is never changed by this scrubbing. After restore, artifacts can
be rebuilt through the F1 Application lifecycle seam; existing `SourceRef`
values remain provenance records with the same F1 no-re-dereference promise.

### Retrieval / derived lexical cache

The following are rebuildable derived cache and package no data rows:

```text
retrieval_index_builds
retrieval_index_heads
retrieval_chunks
retrieval_chunks_fts
```

and any other RAG-1 derived state. Schema objects (tables, FTS5 objects, and
the frozen triggers) may remain in the DB snapshot, but business/cache rows
must be scrubbed to zero so restore can rebuild them. The legacy `questions_fts`
cache, when present in the copied DB, is also rebuildable derived cache: its
schema objects may remain, but its cache rows must be scrubbed.

### Import transient state

ImportTask / pending import Review / attempt diagnostics are not B0 v0
portable state. All `import_tasks` rows are removed from the sanitized
snapshot; the table schema object may remain. The package must not carry:

- `parsedData`;
- pending/failed chunks;
- attempt diagnostics;
- task correlation logs.

### Other exclusions

The package must not carry:

- OBS / application logs;
- temporary files or partial export/import artifacts;
- provider raw responses;
- OCR raw payload;
- reasoning / chain-of-thought content;
- Replay private/cache payload;
- SharedPreferences / purely UI-local state (except where an audited SQLite
  setting is explicitly INCLUDE above);
- any other rebuildable derived cache.

## 5. Export consistency

Copying the live `shiroha_core_v1.db` directly while WAL/runtime is active is
forbidden. B0-E0 must obtain a consistent SQLite snapshot using a
SQLite/runtime-recognized snapshot strategy, for example an engine-level
consistent snapshot API or a quiesced/checkpointed copy.

The exact technical choice is frozen in D0/E0 only after feasibility is
verified on current Windows + Android runtimes. If the existing `sqflite` seam
cannot reliably produce a consistent snapshot:

```text
STOP
SNAPSHOT_PRIMITIVE_UNAVAILABLE
```

No silent fallback to a bare file copy is permitted.

Export order is frozen:

```text
T0
consistent DB snapshot

| sanitize snapshot copy

| enumerate LibraryFiles FROM SNAPSHOT

| copy immutable managed originals

| verify digest + size

| build manifest

| build temporary archive

| verify completed archive

| atomic publish/rename to final .shiroha
```

- Export has **ZERO MUTATION** against live user data. Sanitization happens
  only on the snapshot copy.
- Data committed after T0 may legitimately be absent from this snapshot.
- If, after T0, an original referenced by the snapshot is concurrently
  deleted or changed, this export must fail and delete the temporary package.
  It must never publish an incomplete backup.

## 6. Manifest v1

`manifest.json` is a strict versioned DTO. B0 v0 must not leak free-form
`Map<String, dynamic>` manifest data into Application/UI layers.

Frozen v1 fields:

```text
format = "shiroha-backup"
packageVersion
schemaVersion
createdAtUtc
database:
  archivePath
  sizeBytes
  sha256

managedFiles[]:
  fileId
  storageKey
  archivePath
  sizeBytes
  sha256
```

Type/format rules:

- `packageVersion` is the integer `1`.
- `schemaVersion` is the integer SQLite `PRAGMA user_version` of the sanitized
  snapshot.
- `createdAtUtc` is a deterministic UTC timestamp.
- `database.archivePath` is `database/shiroha.db`.
- `database.sizeBytes`/`database.sha256` describe the exact packaged DB entry.
- `managedFiles[].archivePath` is `files/library/<fileId>`.
- `managedFiles[].fileId`/`storageKey` match the snapshot `library_files` row;
  `storageKey` must pass the F0 safe-storage-key validation.
- `sizeBytes` are non-negative integers; `sha256` values are lowercase hex.
- Every declared `sizeBytes` value must pass the v0 entry and package ceilings
  in §12 before extraction.
- v1 emits no extra root fields. Any future bounded format metadata must use a
  separately versioned strict DTO and an unknown metadata version must fail
  closed.

Forbidden in the manifest:

- user text, displayName, question/conversation/StudyPlan bodies;
- absolute paths;
- credentials or secret material.

Validation is fail-closed:

- unknown `format` or unsupported/unknown required version -> fail;
- duplicate `fileId`, `storageKey`, or `archivePath` -> fail;
- unsafe path -> fail;
- invalid digest or size -> fail;
- missing declared entry -> fail;
- unexpected package entry -> fail unless explicitly permitted by this
  package-version contract.

B0 v0 provides corruption/integrity detection. It does not claim cryptographic
authenticity or signatures.

## 7. Restore semantics

B0 v0 is **WHOLE RESTORE ONLY**. The following are explicitly not in v0:

- merge restore;
- selective restore;
- Project-only restore;
- question-only restore;
- conflict merge;
- sync;
- cloud restore.

Frozen restore pipeline:

```text
package
| strict manifest validation
| archive resource admission
| extract to isolated staging root
| digest / size validation
| validate staged DB
| migrate staged DB if supported
| validate staged managed files
| quiesce app
| commit swap
| reopen / validate
| success
```

- Extraction is isolated; no package path is used to access anything outside
  the staging root.
- Resource admission (§12) is fail-closed: limit breaches stop extraction
  immediately and clean staging with the fixed safe failure
  `resourceLimitExceeded`.
- Every pre-commit failure leaves live DB, live managed files, and secure
  credentials unchanged.
- Only after all staged validation succeeds may LIVE be touched.

## 8. Schema compatibility

`packageVersion` and `schemaVersion` are checked independently.

```text
packageVersion > supported package version
-> reject

schemaVersion > current runtime schema
-> reject as newer backup

schemaVersion <= current runtime schema
-> only use the existing DatabaseHelper / schema migration authority
   to migrate the STAGED database
```

- At B0-P0 the supported packageVersion is exactly `1`; any other package
  version is unsupported.
- B0 v0 creates no second migration logic and never runs package migration
  directly against the live DB.
- If the current app cannot legally migrate the candidate through the existing
  authority, restore rejects safely.

## 9. Staged DB validation

Before commit, the staged DB must pass at least:

- SQLite `PRAGMA integrity_check` or `PRAGMA quick_check` -> `ok`;
- `PRAGMA foreign_key_check` -> zero violations;
- supported schema version and the existing schema validation authority;
- current migration authority success (staged only);
- credential scrub invariant (§4);
- excluded derived/transient-state invariant (§4): all named derived/cache/
  transient tables contain zero portable rows;
- `library_files` rows and manifest `managedFiles[]` are exactly 1:1, with
  matching `fileId`, `storageKey`, `sizeBytes`, and `sha256`;
- every staged managed original exists and matches manifest/snapshot size and
  SHA-256.

No absolute path from the package may be used for file access. On mismatch,
restore fails before commit and LIVE remains untouched.

## 10. Restore commit / rollback

This is the hard B0-I0 invariant. Commit may begin only after the app has
reached a maintenance/quiescent state where:

- no new user mutation may start;
- no active Agent turn exists;
- no active Import/OCR/ParsedArtifact mutation exists;
- no Conversation move/delete/write exists;
- no concurrent second backup/restore exists.

If quiescent state cannot be reached, restore does not enter commit.

Commit must use staging + rollback copy/swap:

```text
LIVE
DB + managed files

STAGED
validated DB + managed files

ROLLBACK
pre-restore DB + managed files
```

- LIVE may be touched only after the staged package has been fully validated.
- Complete rollback copies of the pre-restore DB and managed files must be
  prepared and verified before the first live mutation.
- The durable restore journal (§11) must be in `SWAPPING` state before the
  first live mutation. Live mutation without a durable `SWAPPING` journal is
  forbidden.
- If DB replacement fails, managed-file replacement fails, reopen fails, or
  post-swap validation fails, the implementation must transition the journal
  to `ROLLING_BACK` and attempt to restore the complete ROLLBACK state.
- Rollback success transitions the journal to `ROLLED_BACK`; rollback failure
  transitions it to the terminal `ROLLBACK_FAILED` state. In either case,
  restore is not reported as success.

Restore success may be reported only when all are true:

```text
new DB valid
+
new managed originals valid
+
application reopened/reinitialized successfully
+
journal durably COMMITTED
```

After `COMMITTED`, old rollback state cleanup is best-effort. A cleanup
failure leaves the journal in `COMMITTED` for startup retry and does not
invalidate the already-committed durable state.

## 11. Durable restore journal and startup recovery

B0-I0 must persist a **durable restore journal** for every whole-restore
commit. Crash recovery is frozen by this contract, not left as an I0
implementation choice.

### Journal placement and integrity

- The journal lives outside all swapped roots: not inside the live DB
  directory, not inside the live managed-files root, and not inside package
  staging. A DB or managed-files swap must never delete or replace it.
- The journal is local device state and is never packaged inside `.shiroha`.
- It is a strict versioned DTO with `restoreJournalVersion = 1`; an unknown
  required version, unknown state, or malformed journal fails closed.
- Every state transition is flushed/fsynced durably before the corresponding
  filesystem action may begin.
- Journal content is bounded metadata only: journal version, operationId,
  package format/`packageVersion`/`schemaVersion`, package or manifest digest,
  state, `updatedAt`, counts, byte counts, and safe relative rollback/staging
  identities. It must never contain displayName, absolute paths, user content,
  credential material, or a manifest body.

### Frozen state machine

```text
PREPARED -> SWAPPING -> COMMITTED
                |
                v
          ROLLING_BACK -> ROLLED_BACK
                |
                v
          ROLLBACK_FAILED
```

- `PREPARED`: staged package validated; complete pre-restore DB + managed-file
  rollback state copied and verified; no live mutation has begun. Startup
  recovery in `PREPARED` is equivalent to pre-commit cancellation and is a
  ZERO LIVE MUTATION path.
- `SWAPPING`: journal durably `SWAPPING` before the first live mutation;
  replacement, reopen, and post-swap validation are in progress.
- `COMMITTED`: new DB and managed originals valid and the application has
  reopened/reinitialized successfully. Only then may restore report success.
- `ROLLING_BACK`: failure or crash after `SWAPPING`; restoration of the old
  state is in progress.
- `ROLLED_BACK`: the complete old state is restored and verified; restore has
  failed safely and is never reported as success.
- `ROLLBACK_FAILED`: rollback itself could not restore the complete old state.
  This is a terminal failure; the journal is retained.

Commit-success ordering:

```text
staged package fully validated
-> rollback copies complete + verified
-> journal durably PREPARED
-> journal durably SWAPPING
-> live swap + reopen + post-swap validation
-> journal durably COMMITTED
-> report success
-> best-effort cleanup
```

No live DB or managed-file mutation may begin before `PREPARED` exists and
`SWAPPING` is durably recorded.

### Startup recovery

The journal check must run **before production database initialization** and
before normal Application composition enters service. It is forbidden to open
the live DB and enter normal operation while an unfinished restore journal
exists.

No journal -> normal startup.

Valid journal:

- `PREPARED`: verify the journal is valid, then recover with **ZERO LIVE
  MUTATION**:

```text
PREPARED
-> verify journal is valid
-> DO NOT modify LIVE DB
-> DO NOT modify LIVE managed files
-> delete staging
-> delete temporary rollback copies
-> clear journal
-> normal startup using untouched LIVE state
```

  Hard invariant: `PREPARED startup recovery = ZERO LIVE MUTATION`.
  `PREPARED` is equivalent to pre-commit cancellation because `SWAPPING` has
  not been durably entered, therefore the contract guarantees no LIVE
  mutation was permitted. Startup must not overwrite LIVE with the rollback
  copy merely "for safety".

- `SWAPPING`: LIVE may be partially replaced. Startup must transition/recover
  through `ROLLING_BACK` and restore the complete pre-restore durable state
  before normal startup.

- `ROLLING_BACK`: startup resumes rollback, verifies the old DB and old
  managed originals, transitions to `ROLLED_BACK`, and only then may normal
  startup proceed with the old state.

- `ROLLED_BACK`: startup verifies the restored old state, cleans staging and
  rollback temporary state, clears the journal, and enters normal startup with
  the old state.

- `COMMITTED`: startup verifies the new state can be reopened/validated,
  completes best-effort cleanup, clears the journal, and enters normal
  operation. If new-state verification fails while complete rollback state
  still exists, startup transitions to `ROLLING_BACK`; if complete rollback
  state no longer exists, startup transitions to `ROLLBACK_FAILED`. Cleanup
  failure does not change the already-committed success state; a retained
  `COMMITTED` journal is retried at next startup.

- `ROLLBACK_FAILED`: startup must not enter normal operation. The app enters a
  maintenance/blocked state, exposes the OBS `diagnosticId` / safe diagnostic
  summary, and retains the journal. No automatic destructive recovery is
  attempted.

A malformed or unknown-version journal is fail-closed: normal startup is
blocked, the journal evidence is retained, and only a safe diagnostic summary
may be surfaced.

During journal recovery the app remains quiescent: no user mutation, Agent
turn, Import/OCR/ParsedArtifact mutation, Conversation mutation, or second
backup/restore may start.

## 12. Archive resource admission and disk-exhaustion defense

ZIP path safety alone is insufficient. B0 v0 enforces fail-closed resource
admission before and during extraction.

Frozen v0 limits:

```text
maxArchiveEntries                     = 65,536
manifestEntryMaxBytes                 = 16 MiB (16,777,216 bytes)
databaseMaxDeclaredSizeBytes          = 4 GiB  (4,294,967,296 bytes)
singleManagedFileMaxDeclaredSizeBytes = 8 GiB  (8,589,934,592 bytes)
packageMaxDeclaredUncompressedBytes   = 16 GiB (17,179,869,184 bytes)
```

- `maxArchiveEntries` counts every archive entry: manifest, database, and all
  managed originals.
- The manifest entry's compressed and uncompressed bytes are each limited to
  `manifestEntryMaxBytes`; the parser never buffers more.
- `database.sizeBytes` and each `managedFiles[].sizeBytes` must respect their
  entry ceilings and their sum must respect the package ceiling.
- These limits are `packageVersion = 1` contract values. A later version may
  raise them only through a new package-version contract.

Enforcement before extraction:

- validate the archive entry count and reject `resourceLimitExceeded` when the
  bound is exceeded;
- reject encrypted entries and any compression method not explicitly allowed.
  v0 accepts only ZIP stored and deflate methods; anything else is a fixed
  `unsupportedCompression` safe failure;
- `manifest.json` has no `sizeBytes` field for itself. For this entry only,
  require ZIP declared uncompressed size `<= manifestEntryMaxBytes`; it must
  not be compared against a nonexistent manifest field;
- for `database/shiroha.db` and every `files/library/<fileId>` entry, require
  ZIP declared uncompressed size `==` the corresponding manifest `sizeBytes`;
  mismatch fails closed;
- enforce all declared-size ceilings before writing any staged bytes.

Streaming extraction:

- decompression/output is streamed while counting bytes per entry and total;
  actual output is the authority, never the ZIP header alone;
- `manifest.json`: actual streamed bytes must be
  `<= manifestEntryMaxBytes`. Exceeding it terminates extraction immediately,
  deletes staging, and returns `resourceLimitExceeded`;
- `database/shiroha.db` and `files/library/<fileId>`: actual streamed bytes
  must equal the corresponding manifest `sizeBytes`. If the stream would
  exceed `sizeBytes`, the entry ceiling, or the package ceiling, extraction
  terminates immediately and returns `resourceLimitExceeded`; an actual byte
  count below `sizeBytes` also fails closed before commit;
- SHA-256 and package total ceiling checks remain mandatory after streaming;
- a disk-write failure such as out-of-space is normalized to
  `resourceLimitExceeded`, never a raw OS error/path.

Export must apply the same entry-count, manifest-byte, entry-size, and package
ceiling checks before building the temporary archive. A library whose snapshot
or manifest would exceed a v0 limit fails `resourceLimitExceeded` with zero
live mutation.

Free-space preflight:

- Export: before building the temporary archive, verify available space covers
  the snapshot DB size + packaged original bytes + final/temporary package
  coexistence + working reserve. Failure -> `resourceLimitExceeded`, zero live
  mutation.
- Restore extraction: before extraction, verify available space covers the
  declared package uncompressed total + working reserve.
- Restore commit: before creating rollback copies and touching LIVE, verify
  available space covers the current live DB + current live managed originals
  + working reserve.
- The working reserve is `max(512 MiB, 10% of the operation's durable byte
  requirement)` and is a contract floor, not a suggestion.

`resourceLimitExceeded` is a fixed safe failureCode. It must flow through the
existing OBS diagnostic summary without logging entry names, manifest body,
absolute paths, or user content.

## 13. Cancellation

Before commit (journal absent or `PREPARED`, and before any live mutation):

```text
cancel
-> delete staging
-> clear any PREPARED journal
-> ZERO LIVE MUTATION
```

After the journal durably enters `SWAPPING`, cancellation is disabled. The
operation must either complete successfully or execute rollback through
`ROLLING_BACK`; it may not stop half-way and leave a mixed state.

## 14. In-memory state

Restore success freezes the following behavior:

- all pre-restore Controller/projection caches are stale;
- pending Import tasks, transient Agent proposals, and transient StudyPlan
  drafts are cleared;
- Application composition is reinitialized or performs an equivalent reload;
- pre-restore activeThread/file/project projections must not be reused.

The implementation mechanism is chosen in B0-I0, but this behavior is frozen.

## 15. Idempotency

Restoring the same `.shiroha` twice must produce the same durable state:

```text
restore -> restore again
=> identical durable state
```

Restore must not duplicate Questions, Conversations, LibraryFiles, or
StudyPlans.

## 16. OBS-1 observability

B0 Export and Restore must enter the unified operation trace. The bounded
operation kinds are:

```text
backupExport
backupRestore
```

Only these fields may be recorded:

- package stage;
- counts;
- byte counts;
- duration;
- status;
- fixed failureCode.

Fixed safe failureCodes include the restore journal terminal states
(`ROLLBACK_FAILED`) and resource admission (`resourceLimitExceeded`,
`unsupportedCompression`); failureCode values must remain fixed enum-like
tokens, never derived from an exception message or path.

OBS must never log:

- file displayName;
- absolute path;
- question/conversation content;
- manifest body;
- restore journal body;
- API key.

Failures must be able to return the existing OBS `diagnosticId` and safe
diagnostic summary. OBS-1 remains schema v22; B0-P0 adds no telemetry or log
schema.

## 17. Non-goals

B0 v0 explicitly excludes:

- Sync;
- Device Transfer;
- LAN transfer;
- cloud backup;
- automatic scheduled backup;
- backup history manager;
- encryption/password-protected archive;
- package signing;
- merge restore;
- selective restore;
- credential backup;
- ParsedArtifact backup;
- RAG cache backup;
- schema v23;
- DATA-MGMT destructive features;
- UI redesign.

The ordering `Package -> Transfer -> Sync` remains unchanged.

## 18. Stage graph and risk

Frozen stage graph:

```text
B0-P0 Contract Freeze
|
B0-D0 Package / Manifest Core
|
B0-E0 Export
|
B0-I0 Whole Restore + Rollback
|
B0-U0 Minimal UI
|
B0-V0 Round-trip / corruption acceptance
|
B0-CL Closure
```

Risk:

```text
P0/D0 = T2
E0    = T2
I0    = T3 / HIGH RISK
U0    = T1
V0/CL = T2
```

All B0 implementation stages are `SERIAL`. A later stage never auto-activates
before the previous checkpoint closes. B0-P0 is docs-only and already satisfies
that boundary.

Stage closure status:

```text
B0-P0 Contract Freeze — COMPLETE
B0-D0 Package / Manifest Core — COMPLETE
B0-E0 Export — COMPLETE
B0-I0 Whole Restore + Rollback — COMPLETE
B0-U0 Minimal UI — COMPLETE
B0-V0 Round-trip / corruption acceptance — COMPLETE
B0-CL Closure — COMPLETE

B0 .shiroha Backup / Restore — CLOSED / FROZEN
```

## 19. Required B0-V0 acceptance matrix

The B0-V0 acceptance suite must cover:

1. empty/fresh app export + restore;
2. realistic populated v22 round trip;
3. Questions + typed sidecars preserved;
4. FSRS/review history preserved;
5. Library files + bytes/digests preserved;
6. Folder/Project relations preserved;
7. Conversations/messages/file relations preserved;
8. Active StudyPlan preserved;
9. credentials absent from package;
10. target device secure credential store not mutated;
11. ParsedArtifact excluded and rebuildable;
12. RAG cache excluded and rebuildable;
13. ImportTask transient state excluded;
14. same package restored twice remains identical;
15. corrupt manifest rejected;
16. corrupt DB rejected;
17. missing original rejected;
18. tampered original rejected;
19. unsafe/Zip-Slip archive path rejected;
20. duplicate manifest/archive entry rejected;
21. newer packageVersion rejected;
22. newer schemaVersion rejected;
23. supported older-schema candidate migrates in staging;
24. pre-commit cancellation = zero live mutation;
25. DB swap failure restores original live state;
26. managed-file swap failure restores original live state;
27. post-swap reopen failure restores original live state;
28. restore success invalidates/reloads stale in-memory state;
29. crash after DB swap but before managed-file swap recovers the complete
    pre-restore durable state at next startup;
30. startup detects an unfinished restore journal before production DB
    initialization and never opens a mixed LIVE state;
31. `ROLLING_BACK` interrupted by another crash resumes rollback at next
    startup and ends in `ROLLED_BACK`;
32. rollback failure leaves `ROLLBACK_FAILED` terminal state and blocks normal
    startup without deleting the journal;
33. a small archive declaring oversized total/manifest/entry sizes is rejected
    as `resourceLimitExceeded` before staged bytes are written;
34. entry-count overflow, encrypted entry, or unsupported compression method
    is rejected before extraction;
35. actual streamed decompressed bytes exceeding declared size or package
    ceiling terminate immediately and delete staging;
36. export/restore free-space preflight failure returns
    `resourceLimitExceeded` with zero live mutation;
37. crash after durable `PREPARED` but before `SWAPPING`: startup performs
    zero live DB writes and zero live managed-file writes, deletes transient
    staging/rollback state, clears the journal, and boots the untouched
    pre-restore LIVE state;
38. archive size admission distinguishes `manifest.json` (bounded only by
    `manifestEntryMaxBytes`, declared and streamed) from
    `database/shiroha.db` / `files/library/<fileId>` (ZIP declared size and
    streamed actual size must each equal manifest `sizeBytes`).

## 20. Contract authorities

- `ARCHITECTURE.md` — repository-wide architecture boundary and current v22
  schema statement.
- This document — focused B0 `.shiroha` contract authority.
- `docs/architecture/n0-post-p5-roadmap.md` — stage ordering and current B0
  status.
- `docs/architecture/f1-parsed-artifact-lifecycle.md` — ParsedArtifact
  lifecycle authority; B0 v0 uses the allowed
  `exclude sidecars + strip backup DB metadata` route.
- `docs/architecture/rag1-project-retrieval.md` — derived lexical-cache
  authority; B0 v0 scrubs and rebuilds that cache.
- `docs/architecture/s0-secure-credential-storage.md` — credential authority;
  B0 v0 never packages or restores credentials.
- `docs/architecture/obs-1-unified-operation-trace-v0.md` — privacy-safe
  operation trace authority extended with bounded B0 kinds.
- F0 managed-storage contract (`ARCHITECTURE.md`, `adr-002`, `LibraryFile`):
  safe relative `fileId + storageKey` identity; B0 v0 never uses absolute
  paths.

B0-P0 changes only the canonical B0 contract and the roadmap. Production code,
tests, UI, migrations, schema, CI, and dependencies are intentionally
untouched.
