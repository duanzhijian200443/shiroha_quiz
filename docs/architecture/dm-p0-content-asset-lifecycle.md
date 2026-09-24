# DM-P0-D0 ContentAsset lifecycle successor

Status: **CLOSED — I0, B0G, I1A, I1B, I2, I4, I3 and U0 are activated and closed together on one branch; V0 is independently verified offline and deterministically on `df0559d`; this amendment records that closure.**

This successor defines the ContentAsset lifecycle for managed reclamation. It
supplements the historical DM-P0 destructive-mutation contract. §7 records which
stages are activated, and §8 records the acceptance evidence together with the
rows that remain unproven or deferred. Destructive collection runs only through
the gated maintenance path in §5, requires an explicit user confirmation, and
stays scoped to the single-application-process managed-storage authority
declared there.

## 1. Authorities and current state

| Object or path | Current role | ContentAsset consequence |
| --- | --- | --- |
| `Question` plus its valid `QuestionDraftV2` typed sidecar | Confirmed learning-data authority | Structurally reachable `ImageNode` identities are authoritative durable roots. `assetRefs` is declared metadata/inventory, not a mark set. |
| Current `ParsedArtifact` plus verified `SourceDocument` | Rebuildable derived generation | Its `SourceAssetPart` identities are **runtime retention roots** while that current generation exists. They do not become confirmed Question authority. |
| Pending-review `ImportTask` candidate and active writer operation | Workflow and transient ownership | Exact identities are protected until commit, discard, or proven rollback; §4 records the closed invariant and its evidence. |
| B0 restore commit | Journaled recovery writer | Copies validated staged ContentAssets into the live managed root under B0 exclusive authority and mutation quiescence; it does not use I1A candidate ownership tokens. |
| `LibraryFile` original managed bytes | Primary source file | Its file identity and bytes are separate from source-qualified ContentAsset identity. |
| `AnswerAttempt.image.source_file_id` | Soft `LibraryFile` evidence | Neither ContentAsset root nor required FK nor file-deletion blocker. Missing evidence does not corrupt history. |
| Retrieval/RAG data | Rebuildable derivative of current artifact | No independent ContentAsset root is established by retrieval rows. |
| `parsed_artifact_heads` | CAS/revision continuity | Never a ContentAsset retention root by itself. |

Ordinary runtime ContentAsset byte writes use
`OcrSourceDocumentAdapter -> ManagedContentAssetStore`, with two composed
callers: Import typed-candidate conversion and OCR ParsedArtifact generation.
Separately, B0 restore is a production **recovery writer**:
`BackupRestoreRuntime._swapLiveState` copies staged manifest ContentAssets into
the live managed root. Its authority is B0 staged validation, exclusive restore
commit with mutation quiescence, durable journal/rollback/recovery, and post-swap
verification. It is not subject to the I1A candidate/pre-write-token protocol.
Ordinary writers join I1A by predeclaring the exact identity before the first
byte. A new recovery writer needs an equally explicit recovery authority before
it may publish bytes, and no Application authority may make a writer invisible
to the maintenance gate in §6. Test and tool writers are not additional
production routes, but test-created physical entities are still subject to safe
inventory classification.

Question reachability uses the canonical recursive `reachableImageNodes` walk
through stem, options, `ContentAnswer`, explanation, image alternative content,
and table-cell content. A structurally unused `assetRefs` entry does not make a
Question root. A valid `SourceDocument` may carry `SourceAssetPart` identities
without any Question; these are covered by the ParsedArtifact rule below.

## 2. ADR PA-A: current ParsedArtifact retains referenced assets

**Decision: PA-A.** A current, verifiable ParsedArtifact is a runtime
ContentAsset retention root for every `(sourceId, localAssetId)` in its
`SourceAssetPart` set. This is conservative: a still-current payload must not
point to bytes that GC deleted merely because the artifact is rebuildable.
ParsedArtifact removal/replacement first changes current metadata under its
existing CAS authority. Only after that visibility point may a later complete
reconciliation consider identities from the old generation unreachable. Shared
Question or other roots continue to protect the same bytes. Removing an artifact
does not rewrite a confirmed Question or its `SourceRef`.

“Current ParsedArtifact” has a precise identity for retention: a valid
`parsed_artifacts` **current metadata row** exists, and the row's sidecar/payload
can be safely read and passes all of these checks:

- `fileId` binding and `artifactId` binding;
- payload schema/version support;
- sidecar digest and size;
- strict `SourceDocument` decode.

`parsed_artifact_heads` provides CAS/revision history authority only. A head
without a `parsed_artifacts` current row creates **no current Artifact retention
root**. If a current metadata row exists but its sidecar is missing, corrupt,
unsupported, unreadable, or cannot be stably observed across a replacement
race, the root scan is **incomplete**. The entire destructive pass performs
**zero deletes**; it must not interpret the row as having no references. The
same fail-closed rule applies to an undecodable current row or unavailable
repository read. A safe bounded retry may resolve a legal replacement race,
but cannot turn uncertainty into an empty root set.

PA-B (artifact never retains assets) would require atomic or crash-recoverable
artifact invalidation before any referenced byte disappears. No such combined
contract exists in the current repository. PA-A is selected for v0 because it
protects the visible current payload without a new schema.

## 3. Two distinct asset sets

Define, for one complete and consistent runtime observation:

```text
questionRoots = reachable ImageNode identities in valid current QuestionDraftV2 payloads
artifactRoots = SourceAssetPart identities in verified current ParsedArtifacts
candidateRoots = durable pending-review identities plus active writer/operation ownership
futureRoots = identities from any later explicitly registered durable ContentAsset root

runtimeContentAssetLiveSet =
  questionRoots ∪ artifactRoots ∪ candidateRoots ∪ futureRoots
```

Question roots are authoritative learning data. Artifact roots retain bytes
while a rebuildable current generation exists; they are released by current
metadata invalidation/removal, then a later full scan and grace period.
Candidate roots bridge writes into either published authority or exact rollback.
An unenumerable root category, invalid sidecar, undecodable payload, unresolved
writer, or inconsistent scan makes liveness **unknown** and forbids the whole
destructive pass. Absence is meaningful only after a complete scan under the
required mutation authority.

B0 uses a different set:

```text
backupRequiredContentAssetSet =
  structurally reachable ImageNode identities in authoritative QuestionDraftV2
  payloads retained in the sanitized B0 package
```

The existing B0 snapshot scrubs `parsed_artifacts`, `parsed_artifact_heads`,
retrieval rows, and `import_tasks`; it exports source-qualified ContentAssets
required by packaged Questions. Consequently, an asset protected only by a
current ParsedArtifact is retained at runtime but need not enter B0. Restore
must validate and restore every package-required Question asset and may rebuild
derived artifacts later. Runtime GC roots must never be inferred from the B0
manifest, and the B0 export set must never be inflated by artifact-only roots.
An unsupported/corrupt Question payload must fail backup or GC completeness,
not silently contribute an empty set.

**B0G implementation.** `BackupSnapshotRepository`
`_readReferencedContentAssetIdentities` fails package asset-set construction
when an admitted `question_v2_payloads` row has an unsupported schema or
uninterpretable content. Export does not publish a package in that case.

## 4. Writer ownership: present gap and target invariant

**Closed by I1A and I1B.** Import conversion predeclares the exact identity
before `storeBytesSync` and registers the candidate lease, so a write that
becomes physically visible while verification or the ownership callback fails
still leaves an exact identity for rollback or conservative grace. OCR
ParsedArtifact generation runs the same adapter under a reset authority and
becomes a durable root only when its current generation publishes; a prepublish
failure leaves reconcilable residue rather than an unowned identity. Both
composed callers therefore satisfy “protected before first byte”, which is what
destructive classification depends on. §8 records the acceptance evidence.

**Target invariant for ordinary writers.** Before a durable byte can become
visible, each ordinary runtime writer obtains explicit operation ownership for
a bounded set of exact `(sourceId, localAssetId)` identities. The preferred
minimal v0 mechanism is predeclaring the exact identity before
`storeBytesSync`, under the shared
Application mutation lease; the Import candidate owner and ParsedArtifact
generation owner each record it before write. A writer-scoped token may carry
that declaration within the operation, without a persisted refcount. The write
then verifies bytes and publishes the identity into a durable pending-review,
Question, or current ParsedArtifact owner, or performs exact rollback. On a
failure after physical visibility, the operation retains enough exact identity
to retry cleanup or conservatively classify residue. It must never silently
discard identity because a callback, verification, CAS, or cleanup failed.

I1A proves this for both composed callers, synchronous failure, cancellation,
and idempotent retry; §8 records the evidence. A process crash can erase a
transient lease; it cannot erase the requirement to account for any visible
residue. I2/I4 conservatively rediscover it through complete physical inventory,
full root scans, startup reconciliation, and grace before I3 can classify it
for deletion, and I1B closes artifact invalidation/removal and derived cleanup
ordering. A staging identity, durable registry, or refcount is not selected for
v0; if predeclaration, leases, and conservative recovery cannot close the crash
gap, stop and re-plan before destructive activation.

## 5. Inventory, classification, and deletion authority

`ManagedContentAssetStore.listAssets()` is a healthy-asset listing: it reads
full bytes and hashes accepted files, filtering only by entity kind, identity
shape, size and image magic bytes. It therefore skips empty, oversized,
temporary, unknown-MIME and non-file entities, but it does **not** validate
image content — a file with an intact modern signature and corrupt body is
still listed. Its one production consumer is B0 package construction, which
reports a loud integrity mismatch instead of deciding deletion. It is **not** a
complete physical inventory for destructive classification. I2 provides a
bounded inventory of raw physical entities and an explicit outcome for every
encountered file, directory, link/reparse point, malformed name, unreadable
entry, and transient write. Skipped or unclassified entities cannot be treated
as absent. Inventory failure makes the scan incomplete and the destructive pass
delete nothing.

The classifier distinguishes live authoritative Question assets, live derived
Artifact assets, owned candidates/in-flight writes, shared assets, proven
unreachable regular assets, corrupt/unknown physical entities, and incomplete
scans. An asset becomes a deletion candidate only after complete root and
physical scans, no owner, an elapsed grace interval across scans, and a fresh
exclusive revalidation immediately before exact physical deletion. A failed
delete is observable and retryable; it does not roll back a committed primary
mutation. No deletion follows a symlink, junction, or reparse point. Lexical
`normalize`/`isWithin` checks currently used by managed paths are insufficient
proof of resolved filesystem containment; I2/I3 prove target and parent
containment on supported platforms or fail closed, rejecting any link/reparse
entity during classification and re-proving the selected target immediately
before unlink.

The destructive path's check-to-delete guarantee is scoped to the existing
single-application-process managed-storage authority: every production
ContentAsset writer and root acquisition must participate in the same
maintenance gate. An independent process concurrently replacing managed-root
entries is outside that contract. A static link, junction, or reparse point is
still rejected, and every selected target is rechecked immediately before
deletion. If a deployment permits concurrent external mutation of the managed
root, path-based deletion cannot meet this contract and I3 must remain off in
that deployment. This scope does not shorten grace or make ledger rows a
live-set authority.

Report-only classification remains available and deletes nothing; destructive
collection is activated on this branch and additionally requires an explicit
user confirmation. The original D0 v0
selection assumed Application ownership, full scans, conservative retention,
and existing identities could avoid a registry, refcount, and schema migration
**if** I1A/I1B/I2/I4 proved all required invariants. G0 repository verification
invalidated only the no-schema part of that conditional assumption: there is no
existing durable evidence of when an identity first became unreachable. File
creation and modification times prove file age, not continuous orphan age.
The focused amendment below permits one derived observation table while still
forbidding an ownership registry, refcount, and persisted live-set cache.

### G0 amendment: durable reclamation observation

Schema v27 adds `content_asset_reclamation_observations`, a narrow **derived
maintenance-state** ledger keyed by `(source_id, local_asset_id)`. Each row has
`first_unreachable_at` and `last_verified_unreachable_at`, both UTC Unix
seconds. It stores no path, storage key, owner identity, payload, provider
data, reference count, or live-set cache. A row is grace evidence only:
presence never proves an asset orphan, and absence never proves it live.
Current liveness always comes from the complete Question, current
ParsedArtifact, durable candidate, and active-owner scans plus physical
inventory. An unavailable, corrupt, invalid-schema, or unreadable ledger makes
the entire destructive pass incomplete and permits zero deletes; a missing
row for one asset merely means that asset is not grace eligible.

Only a complete maintenance root scan and raw physical inventory may create a
new observation for a canonical, safely classified, currently unreachable
asset. A complete later observation of the same unreachable asset updates
`last_verified_unreachable_at` without changing `first_unreachable_at`.
Incomplete roots or inventory, bound hits, corrupt current Artifacts,
malformed pending-review owners, maintenance conflicts, and ambiguous paths
create no new grace evidence. Root release never starts a timer directly: the
next complete observation does. Report-only I2 may internally classify an
unreachable asset as `unobserved`, `gracePending`, or `graceEligible`, but
durable, log, and UI results expose only fixed states and counts.

Every production transition that can make an exact identity a Question root,
current ParsedArtifact root, durable pending-review owner, or active ordinary
writer owner must delete/reset its observation **before** the owner becomes
visible or the first byte can become visible. I1A writer predeclaration resets
even for an idempotent write to pre-existing bytes; that write never acquires
physical-delete ownership of the pre-existing file. Question root acquisition
should reset in the same SQLite transaction as typed persistence, covering all
production write routes. ParsedArtifact CAS publish should reset within its
metadata transaction; if that cannot be composed, reset first and then CAS,
leaving a conservative restarted timer on CAS failure. Pending-review publish
resets idempotently after writer predeclaration. Question deletion, Artifact
replacement/removal, and candidate discard do not create observations.
Startup reconciliation invalidates stale observations for any currently live
identity before considering grace; an old row alone never authorizes deletion.

Grace is satisfied only when an observation remains valid across all
intervening root/ownership acquisitions, at least 72 hours have elapsed since
`first_unreachable_at`, a new complete scan still finds the identity
unreachable, raw physical classification is safe, and fresh exact path,
inventory, and root revalidation passes under exclusive maintenance. Neither
`ctime` nor `mtime` substitutes for `first_unreachable_at`. If current UTC
Unix seconds precede either stored timestamp, the observation is invalidated
and restarted only through a complete observation; that pass deletes nothing.
No network time authority is introduced.

The observation ledger is not authoritative user backup state. B0 export
scrubs every row from its sanitized snapshot and includes no observation in
the manifest. Restore, including migration of an older supported package to
v27, leaves the ledger empty and restarts all grace timers. This can delay
reclamation but cannot shorten grace. The v26-to-v27 migration is additive and
must preserve Questions, typed sidecars, Review state/log, AnswerAttempts,
Exams, LibraryFiles, current ParsedArtifacts, and ImportTasks.

## 6. Concurrency and operation ordering

B0 gates export, inspect, and prepare with exclusive authority. Export also
uses atomic fail-fast maintenance admission: an active mutation yields a fixed
busy failure before snapshot work, while an admitted export blocks new
mutations. Restore commit uses exclusive authority,
mutation quiescence, and the journaled recovery path described in §1;
startup recovery runs from the journal before production database open and
normal composition. `enterQuiescence` still waits for active leases; export
uses the separate `tryEnterQuiescence` primitive. GC must use the same
exclusive authority and refuse deletion when an
active writer, restore, backup snapshot, or unresolved lease prevents a
complete observation.
It cannot reuse waiting quiescence as proof of safe admission. No Application
authority may make a new ContentAsset writer invisible to that gate.

Primary Question/Bank/clear-all deletion must preserve Exam guards before
deleting referenced Questions, including `paper_questions` under clear-all.
Database commit precedes byte cleanup. LibraryFile deletion remains the
Application authority for original managed bytes and relations; Project,
Conversation, and Folder detach do not delete those bytes. `AnswerAttempt`
soft evidence does not enter the file-deletion guard. Derived
`LibraryFile -> ParsedArtifact -> Retrieval` invalidation remains distinct from
ContentAsset primary learning-data lifetime. I1B/I4 establish idempotent,
crash-safe startup reconciliation and derived cleanup without promoting
retrieval rows to roots: startup reconciliation removes stale artifact sidecars
and stale retrieval builds, and leaves ContentAsset bytes to the grace
lifecycle below rather than deleting them directly.

Explicit user `LibraryFile` deletion and future bulk answer-photo cleanup are
different authorities. An `AnswerAttempt` having once referenced a file does
not make it eligible for bulk deletion. Bulk cleanup remains deferred pending
an atomic eligibility/deletion contract that preserves Project, Conversation,
Folder, and any future required uses without detaching unrelated relations;
AnswerAttempt history remains intact in either operation.

## 7. Implementation dependencies and review units

```text
D0 contract (this document)
  -> I0 clear-all Exam guard
  -> B0G fail-fast export admission + Question asset-set validation
  -> D0-G0 derived observation ledger amendment (this section)
  -> I1A ContentAsset writer ownership closure
  -> I1B ParsedArtifact invalidation and derived reconciliation
  -> I2 complete physical inventory + report-only classifier
  -> I4 crash/startup reconciliation and grace proof
  -> I3 destructive sweep
  -> U0 bounded presentation
  -> V0 independent destructive/concurrency verification
  -> CL canonical closure
```

Each arrow is an activation dependency. The closure work kept B0G, this
amendment, I1A, I1B, I2, I4, I3, U0, and V0/CL on one branch for one final PR.
That branch activates all of them: I0 and B0G are closed, I1A and I1B are
closed with writer and derived ownership, I2 and I4 are closed with complete
inventory, durable grace and startup reconciliation, I3 is closed behind the
gated maintenance path with an explicit user confirmation, and V0/CL are closed
by the independent verification recorded in §8. I2 classification is never
final proof for I3 unless I1A and I1B have closed writer and derived ownership
and the v27 ledger proves grace. No stage activates its successor merely because
its PR was created.

## 8. Acceptance contract and closure status

The table below is the deterministic, synthetic/offline acceptance contract. The
closure status after it records, per ID, the evidence that exists today: rows
marked `PARTIAL` or `DEFERRED` state what is still unproven, and verification
ruled them non-blocking for destructive activation, which rests on the gated
path in §5, the single mutation authority in §6, and the V0 record at the end of
this section.

| ID | Required behavior |
| --- | --- |
| L1 | A uniquely Question-rooted asset remains live; after Question deletion, complete scan and grace may classify it orphan. |
| L2 | Two Questions sharing one asset retain it until both roots disappear. |
| L3 | Pending-review candidate asset remains protected through restart, commit, discard, and retryable cleanup. |
| L4 | Unknown physical file, directory, link, or unreadable entry never becomes a deletion candidate by omission. |
| L5 | LibraryFile deletion cannot delete a ContentAsset still required by a Question. |
| L6 | Derived ParsedArtifact/Retrieval invalidation preserves Question assets and leaves retryable derived cleanup. |
| L7 | Post-commit physical deletion failure preserves committed DB truth and is observable/retryable. |
| L8 | B0 export/restore and GC exclude each other under one mutation authority. |
| L9 | Restored Question plus required image bytes pass structural and digest validation. |
| L10 | Question/Bank/clear-all Exam guard or DB failure produces zero premature asset cleanup and no dangling `paper_questions`. |
| L11 | Removing LibraryFile photo evidence preserves AnswerAttempt history and unavailable-evidence display. |
| L12 | An answer-photo `LibraryFile` with Project, Conversation, Folder, or future required use is ineligible for bulk evidence cleanup. Bulk cleanup never detaches unrelated relations merely because AnswerAttempt holds soft evidence; AnswerAttempt history is preserved regardless. |
| L13 | An invalid/empty/oversized physical asset skipped by healthy listing is still accounted for by destructive inventory. |
| L14 | B0 export encountering an active long-running mutation fails fast; it does not wait into an inconsistent snapshot. |
| L15 | ParsedArtifact-only asset remains protected while a verified current metadata row and payload exist. |
| L16 | After current ParsedArtifact invalidation/removal, with no other root, complete scan and grace may classify its asset orphan; a head-only row is not a root. |
| L17 | Import byte write followed by verification/callback failure retains exact ownership or reconcilable residue; no silent unclassified asset. |
| L18 | ParsedArtifact byte write followed by prepublish failure has the same safety property. |
| L19 | An asset shared by Question and ParsedArtifact survives removal of either one alone. |
| L20 | B0 excludes derived ParsedArtifact but restores all authoritative package-required Question assets consistently. |

L15/L16 also cover the corrupt-current-row boundary: missing, corrupt, or
unsupported sidecar/payload makes the root scan incomplete and yields zero
destructive deletes, rather than an empty Artifact root set.

B0G also requires a focused export regression: an unsupported QuestionDraftV2
sidecar schema fails package asset-set construction before publication, rather
than silently omitting its ContentAssets.

The G0 amendment additionally requires synthetic migration and B0
compatibility checks, complete-observation grace tests before and after 72
hours, reset tests for Question, ParsedArtifact, candidate and writer
acquisition, root-release and restart tests, backward-clock and unavailable
ledger failures, and proof that a restored ledger is empty. These are
implementation acceptance requirements, not claims of current coverage.

### Closure status

`PASS` means a deterministic test proves the invariant. `PARTIAL` names the gap
that is still unproven. `DEFERRED` means the behaviour a row guards does not
exist yet, so the row cannot be exercised.

| ID | status | evidence or remaining gap |
| --- | --- | --- |
| L1 | PASS | Production repository acquisition, release through the production deletion authority, grace starting at the first complete unreachable observation, and byte deletion after the window |
| L2 | PASS | A shared asset is retained until both roots release |
| L3 | PASS | Candidate restart/commit/discard coverage plus cleanup-residue owner protection and malformed-residue abort |
| L4 | PASS, with two recorded non-constructible classes | Stray file, invalid source directory and invalid asset name are each classified, and the whole pass refuses while any of them exists. `externalOrEscape` and `unreadableEntity` are fail-closed branches that a deterministic single-process fixture cannot reach: any static link on the path is classified `junctionOrReparse` first, and Windows enumeration cannot produce a pipe or socket entity |
| L5 | PASS | LibraryFile deletion cannot remove a Question-required ContentAsset |
| L6 | PARTIAL | Derived idempotence and RAG-cleanup failure are proven; a real invalidation with a live Question-rooted asset is not driven end to end |
| L7 | PARTIAL | Observable failure and preserved committed truth are proven; no consumer demonstrates reclaiming the same residue afterwards |
| L8 | PASS | Export/restore and the destroy window exclude each other, proven from both sides |
| L9 | DEFERRED | Restore-side digest validation belongs to the B0 contract |
| L10 | PARTIAL | Guard rollback is proven on three routes; asset-side zero-cleanup evidence and a clear-all case over a non-empty `paper_questions` set are still missing |
| L11 | PASS | Soft evidence is preserved and unavailable-evidence rendering is proven |
| L12 | DEFERRED | Bulk answer-photo cleanup does not exist, so its eligibility predicate cannot be exercised |
| L13 | PASS | One tree, two views: the healthy listing and destructive inventory disagree by design and the sweep refuses |
| L14 | PASS | Export fails fast against an active mutation |
| L15 | PASS | Current-artifact acquisition keeps the asset live, and a malformed current row blocks the scan |
| L16 | PARTIAL | Head-only rows are proven not to be roots; the transition from verified current to orphan is not driven |
| L17 | PASS | A post-visibility write failure keeps the exact identity in the lease and rolls it back exactly |
| L18 | PASS | Real adapter bytes with a failing publish leave reconcilable residue that is never live and never deleted |
| L19 | PARTIAL | The artifact-removed direction is proven; Question removal with a live artifact root is not |
| L20 | PARTIAL | Derived exclusion and nested closure are proven; only a single-asset package is restored and the staged/live digest cross-check is untested |
| B0G | PASS | Unsupported, corrupt and codec-rejected sidecars each fail before package publication |
| G0 cluster | PASS | Migration, B0 compatibility, scrubbed grace evidence, empty restored ledger, grace before and after the window, resets for Question, artifact, candidate and writer acquisition, root release, restart continuity, backward clock, unavailable ledger, renamed-column ledger and negative clock |
| §9 traps | discharged where implemented | Unclassified writers, reset-before-visibility, artifact verification, scan completeness and the B0 sidecar refusal each carry evidence above; the containment trap is discharged by classification rejection plus the pre-unlink re-proof |

### V0 verification record

V0 is signed on `df0559d` by an independent verification session. It re-ran the
changed deterministic files (105 tests), the surrounding gate files (67 tests)
and the maintenance file alone (33 tests) on the product platform, all passing
with no failures and no skips, with `dart format`, `flutter analyze`,
`git diff --check` and the CI contract checks clean, and it confirmed that the
delta from the previously verified head touched only test files. It recorded
that CI cannot observe Windows-only filesystem behaviour — those cases now
report an explicit skip instead of a silent pass — and that L18 pins byte
survival rather than the sweep outcome. V0 being signed means I3 may run on that
head; it is not a merge approval, which stays a separate decision.

## 9. HARD STOP for destructive activation

Stop before any physical ContentAsset sweep if a production writer is
unclassified; an identity can become visible before ownership; current
ParsedArtifact verification is incomplete; a durable or candidate root cannot
be scanned; B0 can silently omit an uninterpretable Question sidecar;
B0/GC/writer mutation admission is ambiguous; raw physical
inventory skips an entity; resolved path containment is unproven; Exam guards
are bypassed; startup recovery/grace cannot distinguish residues from live
assets; or a proposed fix requires schema beyond the focused v27 observation
table, an ownership registry, refcount, or public contract beyond this amended
design. Also stop if any production root-acquisition path cannot reset its
observation before visibility, if v27/B0 compatibility cannot be preserved, or
if ParsedArtifact CAS cannot provide safe reset-before-publish ordering.
Preserve bytes and return an
observable blocked/incomplete result. Re-plan the precise failed invariant
before changing that boundary.

These conditions remain standing. Their discharge for the current activation is
recorded in §8: classified writers and reset-before-visibility (§4), complete
inventory and containment (§5), the mutation authority (§6), artifact
verification and the B0 sidecar refusal (§8 L15/L16/B0G), and v27/B0
compatibility (the G0 cluster).
