# Durable Generated Question Proposals

Status: **FROZEN contract; AR-R5A IMPLEMENTATION CANDIDATE.**

AR-R5A implements Domain/Application/Data lifecycle at schema v32, B0 package v2
and a source-level internal READ contribution. Final-head standing CI and
independent semantic review remain acceptance authorities. AR-R5B UI and
AR-R6A external trusted origin/Host authority are not implemented.

Authority/activation: [index](README.md). This owns generated candidate admission,
durable Review, lifecycle, stage idempotency, dedicated commit and retention.
It is independent of existing W0 fill-only proposals and SPL transient drafts.

## 1. Domain and admission

GeneratedQuestionProposal contains App identity/schema/time/local ownership,
trusted origin metadata (internal local/synthetic in R5A; external authority
requires R6A), target scope/bank snapshot, immutable original
candidate batch, durable item identities/provenance, review working copy,
per-item decisions/revision, pending/rejected/committed lifecycle, semantic
submission fingerprint and durable commit receipt.

External input supports single choice, fill blank and short answer with Text,
InlineMath and BlockMath, typed answers/options and optional explanations.
MVP excludes images, tables, raw fallback, arbitrary binary and remote URLs.
Client uses local item/option keys; App mints internal Proposal/item/question/
option identities. Client cannot supply storage id, local ownership, approval,
trusted scope, lifecycle outcome or arbitrary source identity.

Evidence references must be minted for the current authorized generation context
and resolved by Application. Preserve source-qualified provenance, never invent
a source to satisfy admission. Uncited candidates can enter Review visibly
marked without source evidence. No full raw Provider response is retained.

Admission rejects malformed/partial JSON, unknown fields/nodes, type mismatch,
invalid option/answer references or unsafe content as a whole batch with zero
stage. No partial salvage, schema guessing, automatic model repair or legacy
fallback. Empty batch rejects. A complete valid batch with fewer items than the
requested count may stage with explicit actual count/count-mismatch warning;
never fabricate missing items or claim the requested total was delivered.

Design defaults are 1-50 items and at most 1 MiB UTF-8 per submission, subject
to stricter existing typed/content limits. Exact serialization/field schemas and
the enforced resource matrix are frozen before AR-R5 activation. Semantically
incorrect answers require quality gates and human Review; structural validity
does not prove correctness.

## 2. Durable Review and lifecycle

Originals are immutable. User edits/decisions change a durable working copy
under expectedReviewRevision CAS. Use typed content/ReviewDecision/ReviewEdit,
existing strict admission and renderer; do not rebuild structure from strings.

Existing import ReviewSession/adapter has ImportTask-producing-attempt origin.
Generated Review has genuine Proposal origin and cannot fabricate ImportTask,
attempt metadata or import route to reuse that builder. Share safe typed review
primitives/transaction writer, not the import-specific lifecycle authority.

Minimal UI shows origin/target/source status, typed preview, supported Text/math
content edits, answer/explanation and accept/reject/defer. Preserve unedited node
identity/explicit-empty semantics. No first-release kind or option-structure
editing; rejected items replace delete-from-preview tricks. Final flush must
return the revision actually passed to the approve command. No stale save may
resurrect terminal state.

One Proposal has one terminal decision: pending_review -> committed or rejected.
Commit accepted subset only when all remaining items are explicitly rejected.
Unreviewed/deferred items keep it pending and block commit. No multi-commit or
automatic child-Proposal split. Passive dismissal is not rejection or approval.
Restart reloads pending work; it does not authorize commit or repeat execution.

## 3. Stage idempotency and duplicates

Durable uniqueness is (clientProfileId, submissionKey). Fingerprint binds trusted
target, canonical semantic candidate content and the canonical source/evidence
provenance references resolved for staging; omit temporary handle, trace and
external request id. The provenance set may be empty for an explicitly uncited
candidate, but provenance identity is semantic for idempotency: the same key with
changed evidence/provenance returns idempotency_conflict even when question,
answer and explanation content are unchanged. Same key/same semantics returns
the original Proposal; same key/different semantics returns idempotency_conflict
without new stage. Current authorization still applies. Response loss is
reconciled by key; expired handles require new authorization for new staging,
not a duplicate submission.

Across different keys, exact typed-content duplicates are detected and surfaced,
including duplicates within a batch and in pending/current target content.
Ignore internal storage IDs when computing content signatures; do not use fuzzy
text normalization as typed equality. Default duplicate commit blocks, requires
fresh Review and an explicit local duplicate-retention decision if supported.
Near duplicates remain human/search-assisted; no semantic-dedup guarantee.

## 4. Formal approval and atomic persistence

Shiroha UI explicit confirmation -> dedicated Application approve command with
Proposal identity, expectedReviewRevision and approved selection -> dedicated
Data persistence port. Command is not an external/MCP route. Natural language,
client-side tool approval and artifact reference cannot authorize it.

One SQLite transaction owns:

1. Proposal local ownership, pending status, revision, current working batch and
   exact accepted/rejected set checks.
2. Current target bank/scope relationship, typed privacy/answer/quality admission,
   stale evidence handling and exact duplicate revalidation.
3. Typed Question sidecar authority, V1 compatibility projection, initial review
   state and existing typed writer's required relationship maintenance.
4. Item-to-Question result mapping, durable receipt and terminal Proposal CAS.

Reuse frozen mapper and transaction-local batch writer through Data. Do not call
the public independently transactional saveQuestions API and mark committed
later; no SQL/DatabaseHelper/transaction object leaks into Application/UI/MCP.
No typed failure switches to legacy writer. Every failed write/CAS rolls back
all Question/sidecar/review/relationship/receipt changes, preserving pending work.

Current bank_name is compatibility identity, not stable entity incarnation.
Commit targets an explicitly shown/confirmed existing bank, not an automatic
new bank. Missing/renamed/changed relation requires explicit rebind/re-review and
new revision, never silent substitution. Stable bank identity is deferred.

Source reparse/deletion makes evidence visibly stale/unavailable, not permission
to mutate originals or committed Question provenance. Local Review must explicitly
resolve relevant stale evidence before approval. Imported/generated Questions
remain readable without dereferencing the original artifact or Proposal.

## 5. Races, retries and receipts

Transaction/CAS is durable authority; an in-memory gate is not a substitute.
Concurrent approve/reject has one terminal winner. Duplicate approve with the
same reviewed selection/revision returns the existing receipt; different
selection/revision conflicts. Lost commit response/restart resolves from durable
receipt, never inserts again. Concurrent distinct duplicate batches recheck
inside the write transaction. Source/target/stale-review failures are typed,
non-enumerating where needed, and do not produce partial writes.

External revoke blocks future client access but does not delete received
candidates. Local user can review/approve under current local authority;
historical external grant is not current COMMIT authority. Receipt identities
are results, not permits to write, read out of scope or modify Question state.

## 6. Retention, archive and future deletion

MVP retains pending, rejected and committed Proposal originals, review and
receipts. No background expiry, automatic GC, history deletion or clear-data
feature is introduced. Handle expiry and module disable do not delete proposals.
Archive, if later added, is display organization, not a new terminal outcome or
deletion. No precise retention duration is frozen here.

Committed Question content and necessary provenance are self-contained;
Proposal/profile links are soft evidence. Deleting future Proposal history must
not cascade to, corrupt or invalidate Question/sidecar/review data.

Future explicit content cleanup must preserve a minimal idempotency/terminal
record or tombstone for the promised reconciliation lifetime. Erasing a history
row must not let a previously committed submission key become a fresh stage.
Define retention lifetime, privacy erase semantics, profile lifecycle, duplicate
key behavior and backup/restore/clear-data effects before implementing cleanup.
Hard erasure cannot silently retain the old indefinite-idempotency claim.
Deleting formal Questions remains a separately approved destructive command;
external clients gain no deletion authority.

## 7. Schema, B0 and acceptance

AR-R5A adds Proposal/item/review/receipt persistence with uniqueness/revision/
transaction constraints in one existing database. It does not alter Question
codec, sidecar authority, existing import attempts or W0/SPL durability. Allocate
next actual schema version at implementation, not a pre-reserved number here.

B0 includes durable Proposal originals/items/review/receipts and soft origin
metadata with strict schema/codec/relationship validation. Active external
profiles/grants are scrubbed under the external owner; credentials/handles are
excluded. Missing restored profile/current artifact must not break historical
origin or Question decode. Restored pending work requires current local target
and Review validation. Package version is not automatically changed for new
SQLite tables; B0 classification/validators/staged upgrades ship with schema.

Acceptance uses synthetic admission, original immutability, close/reopen Review,
same/different-key semantics, same-key changed-provenance conflict, lost
stage/commit response, stale save/approval, approve/reject races, partial
acceptance, exact duplicate concurrency and injected transaction rollback.
Widget proof covers typed edit/preview/flush,
explicit approval and double click. B0 proves roundtrip, corrupt payload rejection
and no credential/active grant restoration. Feature rollback hides entrypoints
but retains storage compatibility and existing Questions.

## 8. AR-R5A schema/resource checkpoint

Status: **FROZEN AR-R5A v0 implementation schema/resource checkpoint.
Runtime implementation is a candidate until standing CI and independent review.**

This section freezes the exact v0 input and persistence contract before formal
writer implementation. It does not claim independent approval. The authorized
R5A storage-gate transition retains the R4 hashes through exact additive-source
projection; all other retained-source assertions remain unchanged.
Existing QuestionDraftV2 and RichContent codecs remain unchanged.

All objects below use exact key sets. Every listed key is required; nullable
keys must be present with JSON null. Unknown keys, wrong types, coercion,
unknown enums and legacy fallback reject the entire operation. JSON duplicate
object keys must be rejected before normal Map decoding can discard them.
Integers exclude floating point encodings. Local keys use
`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`; generated internal identities are UUIDv4.

### Candidate submission

Submission keys: `schemaVersion` (integer 1), `submissionKey` (local key),
`requestedCount` (integer 1..50), `items` (ordered array 1..50).
An item has exactly `itemKey`, `kind`, `stem`, `options`, `answer`,
`explanation`, `evidenceKeys`. Kinds are `singleChoice`, `fillBlank`,
`shortAnswer`. Content is an ordered node array. Node objects are exactly
`{type: text, text: string}`, `{type: inline_math, latex: string}` or
`{type: block_math, latex: string}`. No implicit Markdown/HTML parsing occurs.
Stem and content answers must have nonempty visible text/math; explanations
are nullable and preserve explicit empty arrays. Options have exactly
`optionKey`, `label`, `content`. Single choice has 2..26 options with unique
keys and labels and exactly one referenced option; other kinds have no options.
Choice answers have exactly `type: choice`, `optionKeys: [one local key]`;
content answers have exactly `type: content`, `content: node array`.
Evidence keys are unique local keys resolved only against the trusted current
generation context; candidates cannot carry source IDs or raw SourceRef objects.

### Trusted context and evidence

R5A has internal local and synthetic origin contexts only. No external pairing,
profile, grant or Host exists. A trusted Application authority supplies
`localOwner`, `originKind`, `clientProfileId`, an explicitly confirmed existing
target, and current evidence. Candidate JSON can supply none of these fields.
Historical origin values are soft metadata, never authorization.

Target snapshot fields are exactly `bankName`, `folderName` (nullable),
`projectId` (nullable), `projectBankNames` (sorted unique array). Local scope has
null project and an empty array. Project scope records the exact authorized
Project-bank relationship. Rebinding changes the snapshot under a fresh revision
and clears all accepted decisions; silent target substitution is prohibited.

Resolved evidence fields are exactly `evidenceKey`, `sourceRef` (existing strict
QuestionDraftV2 SourceRef encoding), `fileId`, `artifactRevision` (positive int),
`artifactDigest` (lowercase SHA-256). Only current authorized context evidence
can be staged. A current-source resolver reports `authorized`, `stale`, or
`unavailable`; missing historical sources do not prevent reading originals.
Each item stores its resolved evidence, or an empty array explicitly meaning
uncited. Source claims which cannot resolve or authorize reject staging.
Stale/unavailable evidence needs an explicit local acknowledgement saved against
the exact evidence status and revision; any subsequent status change invalidates
that acknowledgement. Acknowledgement grants no external access.

### Durable state and review commands

Proposal fields: `schemaVersion` (1), `proposalId`, `createdAtUtcMs`,
`updatedAtUtcMs`, `localOwner`, `originKind`, `clientProfileId`, `submissionKey`,
`semanticFingerprint`, `requestedCount`, `actualCount`, `countMismatchWarning`,
`originalTarget` (immutable submission snapshot), `target` (review target),
`reviewRevision` (initially 0), `lifecycleStatus`, `items`,
`commitReceipt` (nullable). Lifecycle values are exactly `pending_review`,
`committed`, `rejected`. Count mismatch is derived from actual vs requested.
Each item has `itemId`, `itemKey`, `position`, `original`, `working`, `evidence`,
`decision`, `evidenceAcknowledgement` (nullable). Original/working use the
unchanged strict QuestionDraftV2 codec and share App-minted question/option IDs.
Decisions are `unreviewed`, `accepted`, `rejected`, `deferred`.

ReviewEdit is a tagged exact-key union: `field` (`stem`, `answer`,
`explanation`, `optionContent`), `itemId`, `value`; `optionContent` additionally
requires `optionId`. Content/answer values use the admitted generated subset;
reviewed choice answers use `type: choice`, `optionIds` with exactly one existing internal ID;
only explanation permits null. Original content, kind, option identities,
labels/order/count and source metadata cannot change. A changed item resets
its decision to unreviewed. ReviewDecision fields are `itemId`, `decision`.
Atomic final flush applies an ordered finite batch of edits/decisions plus
evidence acknowledgements under one expected revision CAS and returns the
durably stored new revision. No last-write-wins or terminal resurrection.

Approval requires proposal ID, expected revision, exact ordered accepted item
IDs and current trusted local confirmation for the saved owner/scope/target.
All other items must be rejected. All-rejected uses the separate reject command.
Receipt fields: `schemaVersion` (1), `proposalId`, `committedAtUtcMs`,
`reviewRevision`, `approvedItemIds`, `itemMappings` (ordered
`{itemId, persistedQuestionId}`), `finalStatus: committed`.
Receipt selection/revision must match the terminal proposal exactly.

Stage fingerprint is SHA-256 over canonical UTF-8 JSON containing the trusted
target, ordered typed semantics with question/option IDs replaced by positions,
and ordered resolved provenance. It excludes temporary handles/transport IDs
and context-local evidence-key aliases; changing real source identity, revision
or digest still conflicts.
Exact duplicate signatures contain typed semantics only, including ordered
node type/content, option labels/order, answer references by option position and
null vs explicit-empty explanation. They exclude all storage IDs and provenance.
Duplicates are surfaced for batch/pending/current-bank content and block commit;
v0 offers no duplicate-retention override. Corrupt typed sidecars fail closed.
A collision with an existing legacy V1 projection is a conservative quality
block, not proof of structural typed equality.

### Resource matrix

| Surface | Enforced ceiling |
|---|---|
| Raw submission | 1 MiB UTF-8; 1..50 items; maximum JSON nesting 16 |
| Candidate item | 128 KiB canonical UTF-8 |
| Stem / answer / explanation / each option content | 32 KiB UTF-8; 256 nodes; 8,192 Unicode scalars |
| Individual text/math node | 4,096 Unicode scalars; 16 KiB UTF-8 |
| Math | Same node ceiling; aggregate included in content ceiling |
| Options | 26; labels use existing 32-scalar safe typed label bound |
| Evidence | 8 per item; 256 per context; 2 KiB per resolved reference |
| Original batch / review working batch | 4 MiB each, including typed IDs and evidence |
| Final flush / individual edit | 128 KiB UTF-8; at most 50 operations |
| Receipt | 32 KiB UTF-8; at most 50 mappings |
| Bank/scope metadata | 256 scalars per bank/folder; at most 256 Project banks |

These ceilings supplement, never relax, existing RichContentLimits and privacy
admission. Generated input additionally rejects URLs, locators, HTML, encoded
binary and forbidden provider side channels even in ordinary text/math nodes.
No full provider response or active authorization is retained or backed up.

### Physical storage boundary

AR-R5A allocates actual schema v32 from the accepted v31 baseline.
Use proposal headers with durable `(clientProfileId, submissionKey)` uniqueness,
separate immutable ordered originals/evidence, revision-owned working rows,
one receipt per proposal and one result mapping per accepted item. Database
constraints enforce lifecycle/revision/type/identity/relationship consistency;
strict cross-row codecs validate remaining consistency on startup and B0.
Question references are soft history so deletion cannot cascade formal content
from proposal history or make a receipt unreadable. Receipt-to-proposal and
item-to-proposal relationships remain constrained. No module-owned migration.
Questions, typed sidecars, initial review state, required target relationships,
receipt/mappings and pending-to-committed CAS share one transaction. Reuse the
existing mapper and extract only the transaction-local batch write primitive;
import attempt gates and lifecycle remain unchanged. B0 package stays v2.

Fixed failures for v0: `invalid_submission`, `unsupported_content`,
`unsafe_payload`, `resource_limit`, `invalid_evidence`, `unauthorized`,
`target_changed`, `proposal_unavailable`, `stale_revision`, `terminal_conflict`,
`idempotency_conflict`, `duplicate_content`, `review_incomplete`,
`quality_blocked`, `stale_evidence`, `invalid_edit`, `corrupt_state`,
`persistence_failed`. Errors carry only their fixed code, never raw exceptions.

### Command envelopes and relational layout

Final flush JSON has exactly `proposalId`, `expectedReviewRevision`, `operations`.
Operations are ordered and have a `type` discriminator: `edit` additionally has
`edit` (the union above), `decide` has `itemId` and `decision`, `acknowledge`
has `itemId` and `evidenceState` (ordered array of exact objects with
`evidenceKey`, `status`, `currentRevision` nullable integer, `currentDigest`
nullable SHA-256). Current evidence is compared inside the transaction.
`rebind` has `target` and requires separate trusted local confirmation for the
new existing target; all decisions and evidence acknowledgements reset.
Approval envelope keys are exactly `proposalId`, `expectedReviewRevision`,
`approvedItemIds`; rejection keys are exactly `proposalId`,
`expectedReviewRevision`. Trusted context is a separate typed constructor input,
never a decoded field. Read/query also require current local owner authority.
All-rejected rejection is a terminal CAS; repeated same-revision rejection is
idempotent, and conflicting terminal/revision commands fail.

Physical v32 uses five tables in the existing database:

- `generated_question_proposals`: `proposal_id` PK, `schema_version` (=1),
  `created_at_utc_ms`, `updated_at_utc_ms`, `local_owner`, `origin_kind`
  (`local`/`synthetic`), `client_profile_id`, `submission_key`,
  `semantic_fingerprint`, `requested_count`, `actual_count`, `target_json`,
  `review_revision` (>=0), `lifecycle_status` and nullable `terminal_revision`.
  Unique `(client_profile_id,submission_key)`; pending requires null terminal
  revision, terminal requires terminal_revision = review_revision. Original
  submission target is separately stored as immutable `original_target_json`
  so rebind cannot alter submission idempotency.
- `generated_question_proposal_items`: `(proposal_id,item_id)` PK, `item_key`,
  `position`, `original_json`, `evidence_json`; unique proposal/key and
  proposal/position. FK proposal, ordered positions 0..actualCount-1.
- `generated_question_review_state`: `(proposal_id,item_id)` PK/FK item,
  `working_json`, `decision`, nullable `evidence_ack_json`.
- `generated_question_commit_receipts`: `proposal_id` PK/FK proposal,
  `receipt_json`, `review_revision`, `committed_at_utc_ms`.
- `generated_question_commit_items`: `(proposal_id,item_id)` PK/FK item and
  FK receipt, `persisted_question_id` unique historical identity. This ID is
  deliberately not a Question FK: later authorized Question deletion must not
  corrupt the retained terminal receipt.

All required strings/JSON are nonempty; timestamps/counts/revisions use integer
typeof/range checks. Original header/target/items are guarded against UPDATE;
terminal proposals/working rows and receipts/mappings against mutation.
No DELETE/GC API is introduced. Strict shape validation compares all owned
tables, indexes, triggers, FKs and constraints; strict data validation decodes
every payload, recomputes the original fingerprint, validates ordered identities,
per-item original/working structure, and terminal receipt/mapping/decision
consistency. Historical source/target/Question existence is not a B0 read gate.
The runtime approve path revalidates current target, sources and duplicates.
The single schema owner serves fresh create, older upgrade, normal open, staged
B0 migration and portable validation. An older database may already contain
only the exact empty additive objects; idempotent migration validates their
complete shape and rejects unknown objects or any preexisting Proposal data.
Generated admission checks its own foreign keys and cross-row relationships;
B0 retains its existing global foreign-key validation and all earlier validators.
The writer also verifies actual Question/sidecar/initial-review rows and affected
working-copy updates, so SQLite RAISE(IGNORE) cannot fabricate successful writes.
