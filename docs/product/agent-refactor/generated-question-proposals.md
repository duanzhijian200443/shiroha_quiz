# Durable Generated Question Proposals

Status: **FROZEN target contract; not implemented by AR-R0.**

Authority/activation: [index](README.md). This owns generated candidate admission,
durable Review, lifecycle, stage idempotency, dedicated commit and retention.
It is independent of existing W0 fill-only proposals and SPL transient drafts.

## 1. Domain and admission

GeneratedQuestionProposal contains App identity/schema/time/local ownership,
trusted ExternalProposalOrigin, target scope/bank snapshot, immutable original
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
target plus canonical semantic candidate content; omit temporary handle, trace
and external request id. Same key/same semantics returns the original Proposal;
same key/different semantics returns idempotency_conflict without new stage.
Current authorization still applies. Response loss is reconciled by key; expired
handles require new authorization for new staging, not a duplicate submission.

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
same/different-key semantics, lost stage/commit response, stale save/approval,
approve/reject races, partial acceptance, exact duplicate concurrency and
injected transaction rollback. Widget proof covers typed edit/preview/flush,
explicit approval and double click. B0 proves roundtrip, corrupt payload rejection
and no credential/active grant restoration. Feature rollback hides entrypoints
but retains storage compatibility and existing Questions.
