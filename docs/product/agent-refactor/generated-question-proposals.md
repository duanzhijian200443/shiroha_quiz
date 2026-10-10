# Durable Generated Question Proposals

Status: **FROZEN contract; AR-R5A COMPLETE / CLOSED;
AR-R5B generated Review UI COMPLETE / CLOSED;
AR-R6A P2 external historical Origin accepted in merged PR #249;
P3 durable external STAGE / reconciliation IMPLEMENTATION CANDIDATE.**

AR-R5A implements Domain/Application/Data lifecycle at schema v32, B0 package v2
and a source-level internal READ contribution, accepted in merged
[PR #244](https://github.com/duanzhijian200443/shiroha_quiz/pull/244).
AR-R5B connects that lifecycle to first-party typed Review UI using the local
authority seam below and is accepted through merged PR #245. P2 adds the strict
historical format and v34 compatibility described in section 10, accepted through
merged PR #249. Section 11 owns the unpublished P3 Application/Data candidate.
Formal Host/transport publication remains blocked. Candidate mechanical evidence
does not close independent review.

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
AR-R5A runtime is accepted through merged PR #244; AR-R5B through merged PR #245.**

This section freezes the exact v0 input and persistence contract before formal
writer implementation. AR-R5A acceptance is recorded by merged PR #244. The authorized
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

The existing R5A STAGE entry retains internal local/synthetic contexts only.
P1 persists non-secret Profile/Grant policy; P2's history codec creates no external
context, pairing or Host. A trusted Application authority supplies
`localOwner`, `originKind`, `clientProfileId`, an explicitly confirmed existing
target, and current evidence. Candidate JSON can supply none of these fields.
Historical origin values are soft metadata, never authorization.

### AR-R5B-P0 local first-party authority

The existing `app_settings` entry `generated_proposal_local_owner` retains one
App-minted canonical lowercase UUIDv4 as local **data ownership**, not a password,
account, Provider identity or external authentication credential. The Data
authority repository loads/initializes it in one SQLite transaction under the
existing B0 mutation lease. Concurrent initializers return the durable winner;
reopen never rotates a valid identity. First initialization occurs on entry to a
first-party generated-review session, outside B0 maintenance, not on each
composition rebuild.

A missing setting with any retained Proposal fails `local_identity_missing`;
a present null/malformed value fails `local_identity_corrupt`; any retained
Proposal owner different from the valid setting fails `local_identity_mismatch`.
No path derives identity from Proposal metadata, replaces damaged settings or
claims historical data. Such states stop generated-review access and require a
separately authorized compatibility plan. Storage failures expose only
`local_identity_persistence_failed`, never raw SQLite errors.

`GeneratedLocalAuthorityFactory` is constructed only by first-party App
composition. Its session exposes owner-scoped read-only `pending`/`read` through
a narrow Application port; read authority has no confirmed target and cannot be
passed to R5A mutation commands. Neither opening the Inbox nor reading a Proposal
creates approval authority. Only the UI action confirming the target actually
displayed calls `confirmDisplayedTarget`, which pins a separate
`GeneratedLocalContext` to that target and session. Reading historical target
metadata is not user confirmation. R5A still owns revision/selection/target/
evidence/duplicate validation and every formal transaction.

Session close or composition invalidation permanently disables its read
authority and all previously confirmed Contexts. In-flight identity/query
results are rechecked before release. During B0 maintenance all sessions and
Contexts are unavailable; production restore reload invalidates the old factory
before replacing composition, and the first-party dependency scope has a new
composition key. A new factory/session must reload the restored identity; old
Context/session objects cannot regain authority after maintenance ends. No
session, confirmation, automatic approval or active grant is backed up.

B0's existing `app_settings` retention preserves this non-secret identity with
the Proposal data. Missing/corrupt/inconsistent restored settings remain unchanged
and fail first-party session entry; portable schema/codec validators and
credential SCRUB rules are unchanged. P0 added no schema, Proposal codec, Receipt,
package-format/version, Agent/MCP grant, external profile/pairing/IPC or Review UI;
the subsequent R5B UI behavior is described in section 9.

Target snapshot fields are exactly `bankName`, `folderName` (nullable),
`projectId` (nullable), `projectBankNames` (sorted unique array). Local scope has
null project and an empty array. Project scope records the exact authorized
Project-bank relationship. Rebinding changes the snapshot under a fresh revision
and clears all accepted decisions; silent target substitution is prohibited.

Resolved evidence fields are exactly `evidenceKey`, `sourceRef` (existing strict
QuestionDraftV2 SourceRef encoding), `fileId`, `artifactRevision` (positive int),
`artifactDigest` (lowercase SHA-256). Only current authorized context evidence
can be staged. Current resolution binds the claimed `sourceRef.sourceId` to the
file's current parsed artifact identity and, under a Project target, requires
current `project_files` membership; identity or scope drift resolves as
unavailable, never authorized. A current-source resolver reports `authorized`,
`stale`, or `unavailable`; missing historical sources do not prevent reading
originals. Each item stores its resolved evidence, or an empty array explicitly
meaning uncited. Source claims which cannot resolve or authorize reject staging.
Stale/unavailable evidence needs an explicit local acknowledgement saved against
the exact evidence status and revision; any subsequent status change invalidates
that acknowledgement. Acknowledgement grants no external access.

### Durable state and review commands

Local/synthetic v1 Proposal fields: `schemaVersion` (1), `proposalId`, `createdAtUtcMs`,
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
never a decoded field. Read/query also require current local owner authority, and
report a foreign-owned proposal ID exactly like an absent one.
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

## 9. AR-R5B first-party Review UI

The optional GeneratedQuestion module contributes exactly the finite
`workspaceAction` descriptor `generated_proposal_review`. Presentation explicitly
maps it to the existing Assistant AppBar action on desktop and mobile. Removing
the contribution hides the action without deleting Proposal data, changing the
three main tabs or rewriting GlobalSidebar. No Widget plugin or route registry
is introduced. Inbox defaults to durable pending work; its separate completed
view reopens retained rejected batches and committed Receipts.

Owner-scoped Application read sessions expose pending/completed/read, current
target choices and evidence states. Target choices preserve exact nullable
Folder and Project-bank snapshots; the existing R5A resolver supplies source
states without granting command authority. Origin, target, requested/actual
counts, mismatch warning, per-item decisions and source references remain
visible. Text/InlineMath/BlockMath preview uses RichContentRenderer directly.

The node editor preserves existing node order/types and literal values. It may
append admitted text/math nodes; it does not project/reparse fields, edit kind,
change option identity/label/order/count or replace original provenance.
Single-choice answer selection retains Option IDs; content answers remain typed.
Unchanged fields and null versus explicit-empty explanation remain distinct.
Applying edits changes only the local working preview and resets that item's
decision. Accept/reject/defer are review operations, never formal writes.

Controller queues finite ordered operations and saves one R5A Review Flush after
explicit confirmation of the displayed target. Its loaded revision is replaced
only by the returned durable revision. Stale CAS preserves local operations and
blocks automatic resubmission; reload with local work requires explicit discard.
Source refresh preserves originals; acknowledging the displayed stale/unavailable
state queues the exact R5A acknowledgement. Rebind requires explicit target
confirmation, clears decisions/acknowledgements, and must be saved and reviewed.
Normal return prompts save/discard with local work and executes no terminal
command. Busy operations block duplicate actions/return. Closing during async
identity load releases the late session instead of retaining it.

Formal approval is enabled only for at least one accepted item, every other item
rejected, no deferred/unreviewed/local pending work, and no busy/conflict/unknown
result. Before the final dialog the UI rereads the Proposal. A newer pending
review revision blocks confirmation without replacing the displayed working copy;
explicit reload and review are required. An already-terminal result may be shown
but cannot be resubmitted. Confirmation shows target, Learning Space,
accepted/rejected counts and the actual revision. Only that explicit action
sends ApproveGeneratedProposalCommand. All rejected uses
the separate RejectGeneratedProposalCommand, with no zero-item approval.

Success shows the durable Receipt and returns the viewport to it. Lost responses
reconcile the same Proposal ID, revision and ordered accepted selection against
the retained Receipt. An unconfirmed pending result stays locked with a dedicated
verification action; it creates no replacement Proposal or second write. Completed
history and restart reload the original Receipt. Fixed safe Chinese failures
distinguish CAS, target/source drift, duplicates, incomplete/blocked Review,
terminal/ownership/unavailable state and persistence; there is no force-duplicate
override or raw exception/SQL display. R5A remains the final admission authority.

Focused standing tests include real Widget/Application/SQLite edit/subset commit,
Question/sidecar/initial-review relationships, close/reopen, matching Receipt
recovery, confirmation double click, typed/null-empty fidelity, CAS, source
acknowledgement, module removal and 360x720/1024x768 interaction. Synthetic fixtures
remain test-only. No new generator/model/Provider/Agent/MCP tool, external grant,
schema/codec/Receipt/B0 format, GC or R6A/R6B capability is activated.

## 10. P2 external historical Origin and v34 compatibility

P2 adds a historical format, not an external execution entrypoint.
`GeneratedOriginContext.validate()` still permits only local/synthetic. Candidate
submission JSON remains the exact v1 key set and accepts no Origin, Profile,
Grant, Scope, target or `trusted` assertion. The legacy STAGE path also refuses
an existing external historical key instead of treating it as an internally
authorized stage result. Parsing Origin never mints a current Principal.

Local/synthetic Proposal JSON retains its exact schemaVersion 1 fields/meaning.
External Proposal JSON uses schemaVersion 2, the same header/item/review/receipt
fields, originKind `external`, and one required `externalOrigin` payload.
Version 1 cannot express external; version 2 cannot express local/synthetic.
No default/coercion/fallback changes the tag. Receipt remains v1.

Payload is at most 32 KiB UTF-8, duplicate-key checked before Map decoding with
the existing nesting ceiling 16. Its exact fields are:

| Field | Historical representation |
|---|---|
| `schemaVersion` | Integer 1 |
| `externalRequestId` | Required nullable value; non-null matches `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`. Untrusted correlation only, never authorization, diagnostic identity or idempotency. |
| `adapterProtocol` | Exact `{adapter, protocol}`; each matches `[a-z][a-z0-9._-]{0,31}`. Future Application publication captures the trusted Profile/Adapter binding. |
| `authorizationSnapshot` | Exact `{grantRevision, permission, authorizedFileIds, egressCategories}`. Revision is integer 1..2147483647, permission exactly `stage`; files are at most 128 sorted unique local-key-format ids; categories are a sorted unique subset of `fileContent`, `proposalMetadata`, `questionContent`, including explicit empty. |

`ExternalProposalOrigin` binds Profile (canonical UUIDv4), original key and Target
to the immutable Proposal Header, without repeating them in the payload.
Snapshot target scope uses the original Target's exact Learning Space/bank
relationship, not Review's later rebind. Its recipient is that Profile; every
original item's evidence file must occur in historical file scope. Typed
construction rejects contradictory Header bindings. These are admission facts,
never a current Grant, credential or Context. No key/token/credential/runtime
handle field is stored. Future P3 captures this through trusted Application
authority at owning STAGE/revoke publication; P2 has no authenticated factory.

SQLite v34 retains the five v32 tables and `(client_profile_id, submission_key)`
uniqueness. Header gains nullable `external_origin_json` and a mutually exclusive
CHECK: local/synthetic requires schema_version=1 and NULL payload; external
requires schema_version=2, UUID-length Profile and nonempty bounded text payload.
Typed decode additionally validates UUID, exact keys, enums and existing
Proposal/fingerprint/Receipt relationships. Header immutability includes payload;
child and terminal triggers retain their rules. No FK targets current Profiles.

Historical v32 physical schema authority is retained separately. Pre-v32 upgrades
create/check that format before v33 authorization and v34 Origin migration.
Exact empty current objects remain idempotent for controlled reset-version
fixtures; older versions cannot adopt published current-format data.
For genuine v32/v33 Headers, DatabaseHelper's upgrade transaction saves old Header
columns in a migration-only SQL snapshot, keeps foreign_keys ON, defers checks
to commit, drops/recreates only Header, recreates its index/guards, and reinserts
under the original parent name. Both-direction EXCEPT comparison proves all old
Header values unchanged; new payloads are NULL. Child rows/triggers are never
dropped or rewritten. Exact schema/data and foreign_key_check must pass; the
migration-only table disappears and commit still enforces FKs. Failure rolls back
DDL, rows, guards and user_version together. No foreign_keys OFF/writable_schema.

B0 package stays v2: Proposal/Origin INCLUDE, all Profile/Grant rows SCRUB,
credentials/runtime contexts EXCLUDED. Missing/revoked Profiles do not invalidate
history. Restore grants no authentication, Grant, pairing or runtime Enablement;
raw rollback retains original live policy/history. Corrupt Origin rejects live
open/export/staged admission. Local Inbox, typed edit/Flush CAS, explicit local
COMMIT, current target/evidence/duplicate checks and Receipt/Question mappings
retain their owning services and semantics.

At P2, R1-P3-1, R1-DESIGN-1 and the shared durable STAGE/revoke transaction/CAS
boundary remained open. Section 11 supersedes that Application/Data gap with a
bounded P3 implementation candidate; formal external Host publication stays blocked.

## 11. P3 durable external STAGE candidate

`ExternalGeneratedStageService` is a transport-independent Application entry;
it is not registered in a Host, capability projection, MCP, module or UI route.
It accepts only this service's opaque Context and its authenticated Session.
Trusted App composition binds an opaque `ExternalProfileReference`, validated
by its owning management service, to the exact Principal minted by this
TrustCore. Their Profile ids must match. A second TrustCore with the same display
id cannot enter. Credential possession proof, pairing and current-runtime
enablement remain mandatory. The bounded synthetic CredentialPort tests exercise
that process; no saved credentials, real pairing UI or production identity adapter
are wired. App composition must close/invalidate these services before Restore
or runtime replacement. Persisted Origin cannot recreate a binding.

App approval mints `ExternalStageContext` with the original Target/evidence,
current Grant revision and a finite 15-minute lifetime (default and upper bound
for this unpublished candidate, not a measured Host product limit). Candidate
JSON retains the strict v1 content-only keys. The shared admission parser is
content validation, not authentication. Neither a public legacy Context,
`isCurrent`, `trusted`, Profile string nor `mcpStudyV0` proves external authority.

STAGE invocation checks runtime admission and current durable policy before
publication. `GeneratedProposalRepository` owns one B0 mutation lease and one
SQLite transaction for current Profile/Grant/revision, exact bank/Project and
approved file scopes, current source identity/revision/digest, retained local
owner, fingerprint/key lookup and Header/Origin/Item/Review publication. Revoke
and policy replacement use the same DatabaseHelper SQLite transaction authority.
Independent public authorization transactions are never publication authority.
Revocation/revision first commits no new Proposal; publication first retains the
complete immutable history even when later revoke suppresses result release.
The transaction-local row publisher is shared with the unchanged local/synthetic
entry. Existing Target/evidence/quality/duplicate checks remain in effect.

Origin v1 is assembled from the authenticated binding and the current transaction's
Profile adapter/protocol, revision, sorted approved files and Egress categories.
Only bounded `externalRequestId` is caller correlation metadata. External Header
remains Proposal JSON v2 at SQLite v34. No second Stage Receipt table or schema
upgrade exists. `generated_question_commit_receipts` still means local formal
COMMIT only. Pending/terminal Review and Question writer semantics are unchanged.

Durable STAGE authority is the complete, strictly decoded Proposal under
`(authenticated clientProfileId, original submissionKey)`, with its recomputed
semantic fingerprint and immutable original Target/content/provenance. Same
semantics reuse its identity; changed semantics conflict. A fresh authenticated
and App-bound Session can `reconcile` after closing/reopening the database without
an old Context or journal. Lookup corruption fails closed. Missing rows return
`outcome_unknown`, never proof that a queued/uncertain operation had no effect;
there is no automatic restage. No retention/deletion/tombstone policy is added.

The external result is only `ExternalStageSummary(proposalId, submissionKey)`.
Publication requires STAGE, exact current target/file scopes, `questionContent`
and `proposalMetadata`, plus `fileContent` for approved source files. Reconciliation
and final release require current STAGE, `proposalMetadata` and the original
bank/Project scope; they require no general READ and release no candidate,
Question, source, Review state or COMMIT Receipt. Historical file absence does not
invalidate a narrow status query. Invalid/revoked/mismatched authorization yields
bounded non-enumerating denial. Every response rechecks runtime and current
SQLite authorization; release failure preserves effect evidence but no output.
Lookup admits the current scope using only the immutable routing Header before
decoding any candidate/Review content. Out-of-scope and absent keys both return
unknown without disclosing content validation or record existence.

This branch uses the existing typed `CapabilityEvidence`, execution statuses and
effects directly, without inventing an external `CapabilityPrincipal` or adapting
to `mcpStudyV0`. General `ExecutionReceipt`/Host projection integration remains
unimplemented. Only a committed/strictly validated Proposal confirms
`proposal_staged`. A thrown transaction checks SQLite absence before confirming
rollback; uncertainty is not `failed_without_effect`. Cancellation before handler
entry proves none. After handler entry, interruption remains unknown until
settlement; committed history can then be reconciled even after response loss.

The durable branch has only bounded pending operation slots (16 globally, 4 per
Session), retained until actual handler settlement even after caller cancellation
or deadline. Completed/failed keys are not kept in a Map. It bypasses the old
`ExternalInvocationCore._stages` journal for both execution and reconciliation.
That pure-memory candidate and W0/SPL transient semantics are unchanged; their
general journal finding is not claimed globally closed. This closes the durable
branch's journal/restart gap only as an implementation candidate, pending CI and
independent semantic review. B0 remains Proposal/Origin INCLUDE, Profile/Grant
SCRUB, credential/Context EXCLUDED; restore never restores external access.

Deterministic acceptance uses synthetic credential proof and real temporary
SQLite: both revoke/revision ordering directions, same-key concurrent calls,
Header/Items/pre-commit rollback and ignored-row rejection, commit-then-response
loss, cancel/deadline with pending capacity retention, actual file close/reopen,
source/Project drift, Profile isolation, corrupt history, and actual B0 restore
and raw rollback. Host/IPC/real-provider acceptance is outside this candidate.
