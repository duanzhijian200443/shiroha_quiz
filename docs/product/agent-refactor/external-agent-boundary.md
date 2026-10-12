# External Agent Capability Boundary

Status: **FROZEN target contract; not implemented by AR-R0.**

Authority/activation: [index](README.md). This owns client-neutral external
identity, grants, context, egress and local Application Host. MCP wire schemas
belong to [MCP](mcp-vnext-contract.md); Proposal business lifecycle belongs to
[GeneratedQuestion](generated-question-proposals.md).

## 1. Trust and process boundary

```text
External Agent -> protocol adapter / stdio bridge
               -> authenticated local IPC -> App LocalCapabilityHost
               -> Application CapabilityExecutor -> business services
Built-in Agent ---------------------------> Application directly
```

App is the sole business writer. Bridge never opens SQLite, holds repositories,
executes migrations or starts an alternate writer when App is absent. Composition
roots wire implementations; adapters do not bypass Application ports.

Any authorized client can use this boundary. No brand-specific Proposal/origin
types or business `if client == ...` branches. A different protocol may add an
adapter without changing Question or Proposal Domain. Local compiled modules
are trusted source; external requests and metadata remain untrusted.

## 2. Profile, principal and grants

ExternalClientProfile has App-generated identity, display name, adapter/protocol,
explicit permissions, allowed Learning Spaces/banks/files, category/recipient
egress policy, grant revision, createdAt and revokedAt. Credential material is
separate from durable non-secret metadata; not in SQLite, backups, manifest,
CLI arguments, Proposal, query DTO or log.

Shiroha UI owns pairing and scope/egress approval. One-time pairing information
is not a reusable credential. Trusted authentication maps App-registered client
credentials to ExternalPrincipal; PID, executable name and request parameters
cannot establish that identity. `clientInfo`, brand/model names and claimed
external conversation/session ids are display metadata, never identity or
permission. Missing/corrupt credential access fails closed; never consult a
plaintext fallback.

Valid mTLS proves use of the corresponding credential, not that the upstream
program is Codex. Windows P0 accepts the residual risk that another program
under the same user SID may call a paired Bridge and proxy its credential;
same-SID process identity isolation is not promised. An unpaired direct client
must still be rejected. This accepted Bridge-proxy risk is distinct from an
attacker controlling the entire user account or an administrator/kernel
attacker; no containment of those stronger attackers is claimed here. None of
these limitations bypasses current Application authorization, Scope, Egress or
explicit local COMMIT approval.

Every App runtime generation defaults to external business access disabled.
The user must actively enable one selected, paired Profile through trusted
Shiroha UI and choose a finite validity period. Enablement binds only that
Profile and current generation; it adds no Grant, Scope or Egress. Legitimate
reconnections authenticate again and recheck current authorization, but need
no repeated prompt within the same valid enablement period. Disable, expiry,
revoke, restart or Restore invalidates the applicable runtime enablement; old
connections, Contexts and sessions cannot automatically regain business access.
Duration limits, resource counts and concrete UX remain implementation and
validation choices; no numerical runtime-enable limit is frozen here. Section 3
and per-call/final-release authorization remain independently required.

Host publishes an external capability allowlist limited to READ + STAGE.
Internal local-user approval commands are not Host routes even if registered
elsewhere. No autonomous external COMMIT or DESTRUCTIVE. Client tool approval
and chat agreement do not authorize Shiroha formal writes.

ExternalProposalOrigin records clientProfileId, optional externalRequestId,
submissionKey, adapterProtocol and trusted target/scope/authorization snapshot.
Origin is historical fact, not a live authorization credential. Local owner and
all internal identities are App-generated. External request ids are untrusted,
bounded input and never used as diagnostic identity.

P2's persisted historical representation is owned by
[GeneratedQuestion section 10](generated-question-proposals.md#10-p2-external-historical-origin-and-v34-compatibility).
It binds Profile/key/original Target once in the immutable Header, with bounded
adapter/protocol and historical authorization metadata. Decoding grants no
authentication or current Grant/Context. P2 has no external STAGE factory;
the local/synthetic entry remains closed to external contexts/historical keys.

Scope admission precedes content lookup; unauthorized/nonexistent targets share
safe non-enumerating errors. Aggregates operate inside authorized scope, not
global query followed by filtering. Revalidate current grants on every call and
egress release. Recipient is the authenticated external principal unless a
stronger verified recipient contract exists; a model name supplied by the client
does not establish its actual downstream recipient.

UI must explain which content will leave Shiroha to the external client. App
cannot revoke already released data or promise control over client retention.

## 3. Opaque context handle

open_generation_context mints a transient opaque handle binding principal,
grant revision, READ/STAGE permission, one authorized target bank/scope,
approved file snapshot, category/recipient egress, source/target generations,
App runtime generation and expiration. Client chooses safe references minted
by App, not trusted raw database identities, permissions or authority fields.

Handle is not persisted and not MCP-session-scoped. Copying it to a different
principal fails. Restart, revoke, restore and expiry invalidate it. Scope/source
changes yield a fixed stale failure; never silently expand files or substitute
targets. Relevant bindings are revalidated at invocation and stage/egress gates.

TTL must be finite and bounded. **15 minutes is an implementation candidate,
not a frozen product constant.** AR-R6A must choose/document the default and
upper bound after measuring realistic read/generate/stage duration; safety does
not depend on TTL replacing per-call authorization.

Expired clients may open a new context after current authorization. A new handle
does not renew old authority or silently accept old source generations. It does
not change a submission key or create a second Proposal. Already staged data
does not expire with its handle; outcome query uses current principal and
Proposal authorization, not a live generation handle.

### P4 Application READ foundation (accepted scope)

P3 durable STAGE/reconciliation is accepted through merged PR #250. P4 is
accepted through merged PR #251 within its unpublished Application/Data scope, without a Host, wire
decoder, MCP tool, general CapabilityPrincipal or external formal-write route.
`ExternalRuntimeAdmission` extracts P3's exact Principal-to-management-reference
binding and Session/runtime checks. StageService delegates to that same instance;
READ receives it from trusted App composition. There is one binding authority,
with the existing TrustCore still owning credential proof, pairing, enablement,
generation and disable epoch. Current durable policy remains Data-owned.

Target metadata is a minimal projection of `questionContent`, never
`proposalMetadata`. Each access requires current authenticated Principal,
App-bound Session, active runtime enablement, unrevoked Profile/Grant, READ,
`questionContent`, exact `bank + bankName + projectId` Scope, owning-Profile
recipient and current Bank/Folder/Project relationships. Permissions and Egress
categories never imply each other. STAGE-only reconciliation remains available
under P3's separate narrow policy and cannot list READ targets.

The output record has exactly `targetRef`, `bankName`, nullable `projectId`, and
nullable `folderName`. Page envelopes have only `items` and nullable `nextCursor`.
No full Project bank list, global counts, file identity, content, paths, storage
keys or internal authority objects leave this entry. Data first loads this
Profile's bounded explicit bank scopes, then resolves only those targets; it
never loads global Learning Spaces/banks/files for Application-side filtering.
Missing scoped targets are omitted; client-supplied missing or unauthorized
selection references have the same safe denial.

App mints separate opaque target-selection, cursor and READ Context references
using 32 cryptographically random bytes (43 unpadded base64url characters) in a
process-local registry. References also bind the registry/admission instance,
exact Principal, runtime generation, current Grant revision and finite lifetime.
Copying a string cannot authenticate; wrong reference kinds are denied. A cursor
binds its offset and the ordered authorized target snapshot; revision or target
relationship changes invalidate continuation, including deletion elsewhere in
that snapshot. A target reference is selection only: Context creation reloads
policy and current target relationships. Context stores creation/expiry time,
READ/STAGE and category/recipient policy snapshot, exact selected Bank/Folder/
Project, and explicitly empty approved File/Evidence snapshots. This candidate
does not admit source files or retrieve any Question/File body. Snapshot STAGE
permission is never a STAGE authorization path; READ references cannot enter P3.

The preceding body-read exclusion describes P4's accepted scope. P5 below adds
only Context-scoped Question READ; File/Evidence snapshots stay explicitly empty.

Every call reloads current durable Profile/Grant and rechecks revision, scope,
target and Egress. Listing repeats the current-policy/relationship query at its
final release gate. Context validity reports only `authorized`, `invalid`, or
`unavailable`; it exposes no other Profile policy or existence information.
Regrant, expansion and a fresh Context never renew old handles. Bank compatibility
names retain P1's identity limitation; no bank-incarnation guarantee is added.

| Unpublished candidate resource | Bound |
|---|---|
| Context/reference lifetime | Default and upper bound 15 minutes; not a measured Host product constant |
| All active references, including selections/cursors | 256 total, 160 per Profile; enough for all 128 granted targets plus cursors and 16 Contexts |
| READ Context subset | 64 total, 16 per Profile |
| Target page size | Default 20, maximum 50; no global total |
| Target candidates | Existing Grant ceiling of 128 exact scopes |
| Encoded metadata page | 32 KiB UTF-8 including references and cursor |
| Pending READ operations | 16 total, 4 per Profile |
| Single READ operation | At most 2 seconds, checked by trusted clock, Stopwatch and timer |
| Registry cleanup | Before admission/mint and every 30 seconds; close clears immediately |

Cancellation/deadline suppress output; SQLite work is cooperatively checked
between awaits/statements and at release, rather than claimed OS-level query
preemption. An interrupted caller retains its pending slot until actual work
settles. Failed/unreleased allocations are removed. Invalid runtime/expired
references are swept; durable revocation/revision cannot authorize access and
retained entries remain bounded by TTL/capacity. App composition must close the
shared admission and drain work before B0 swap/runtime replacement. This closes
READ registries and invalidates Sessions; success or raw rollback restores no
runtime authorization. References/Contexts are never stored in SQLite, B0,
manifest, Origin or logs. Schema stays v34 and B0 package stays v2.

P3's StageContext, current-policy publication/revoke transaction, original
key/fingerprint, lost-response semantics and durable reconciliation remain
owned by GeneratedQuestion §11. The old generic transient journal remains
separate debt. General ExternalPrincipal integration must be a separately
scoped trusted admission interface with explicit current-authorization and
receipt/projection impact review; `mcpStudyV0` is never an external identity.

### P5 Context-scoped Question READ (accepted scope)

P5 is accepted through merged PR #253 within its unpublished Application/Data
scope. The existing
`ExternalReadContextService` adds `searchQuestions` and `getQuestionDetail`;
both require an authenticated Session and this Registry's READ Context. There
is no new identity map, pairing state machine, Grant manager or Registry. Current
READ + questionContent + exact bank/Project Scope and target/Folder relationships
are mandatory in every owning Data read transaction and final Release transaction.
P4 File/Evidence snapshots remain empty; this adds no file-content authority,
STAGE entry, general CapabilityPrincipal, Host, transport or MCP tool.

`ExternalQuestionReadAccess` is a private-constructor, Context-minted proof for
the narrow Data port. It rechecks the live Registry/Context, Principal/runtime,
expiry and service lifecycle across awaits. It is not a current durable Grant.
Data reuses `requireExternalGrant`, checks the exact target and then selects
identities only with `q.bank_name = context.bankName`. Exact detail additionally
requires the selected id inside that same bank predicate. The existing
`materializeExactQuestions` runs only on those bounded selected identities within
the same transaction, checks membership again, and decodes through
`QuestionV2PersistenceMapper`. No global content query or unscoped StudyQuery
operation is used. No Review/history query or business mutation is performed.

Search query is nonblank and at most 200 UTF-16 code units before trimming;
matching uses a trimmed, lowercase literal substring of safe stem/explanation
text/math. Keyset order is created_at DESC, id DESC. At most 128 candidates plus
one metadata sentinel are selected per call; raw content is materialized only
for scanned candidates. Matching uses the typed authority projection, never V1
decoy text or RawFallback payload. A bounded scan can return zero hits with a
continuation cursor; clients must not infer exhaustion until nextCursor is null.
MCP v0's frozen compatibility-projection search semantics remain unchanged.

Search items have exactly questionRef, kind, stemPreview, hasAnswer,
hasExplanation, sourceKind; the envelope has only items and nullable nextCursor.
Detail has exactly kind, stem, options, nullable answer, nullable explanation,
sourceKind. Kind/option-label/choice-answer projection is shared with StudyQuery
through the stateless `StudyQuestionProjection`; projection supplies no authority.
Detail nodes admit only text, inline_math, block_math and an unsupported marker.
Image/Table/RawFallback have no path, asset identity, raw payload or guessed
replacement content. Typed null and explicit empty values remain distinct.
Legacy compatibility uses the existing mapper/projection only for a genuinely
absent sidecar; malformed legacy options fail safely. A present corrupt, partial,
unsafe or unsupported sidecar fails the whole search/detail without V1 fallback.

QuestionRefs and search cursors use P4's 32-byte random minting and the same
256-global/160-per-Profile Registry. Both bind the exact parent Context, Principal,
generation, revision and target, and expire no later than that Context. Cursor
state additionally binds the bounded query and last scanned keyset identity.
References hold only internal selection metadata: storage id, created_at,
SQLite row identity and a SHA-256 fingerprint of the fully decoded content
identity; none of those fields is emitted. Detail and final Release revalidate
that identity, so deletion, movement, changed content or replacement rejects the
old selection. A corrupt replacement still fails closed. No separate persistent
incarnation ledger is added; a byte-identical reconstruction of the same content
identity is not distinguished as a new semantic question. Restore always
invalidates the runtime independently of identical restored bytes.

Final Release is a separate current-authority Data transaction after safe
projection: reload Grant/revision/scope/target and verify every selected identity,
then Application rechecks Context/cancellation/deadline and emits only the
size-checked whitelist. Revocation queued during a read cannot commit inside that
read transaction; once it wins before Release, no held preview/detail is emitted.
No automatic retry or fallback scope exists. Unknown references and references
from another identity/Context share safe denial; a previously selected deleted or
changed question reports fixed stale, never other content.

All P4 maximums remain in force for Question READ composition, including 16/4
pending calls, 2-second cooperative deadline, 32 KiB UTF-8 response, 64/16
Contexts and 256/160 references. Search pages default to 20, maximum 50; candidate
stored content is bounded to 256 KiB before decoding, and internal storage
identity to 256 UTF-8 bytes (oversized identities are not selected into memory).
Detail allows at most 26
options and 512 projected nodes in total. Oversized results fail completely,
without truncated formulas or partial output. Cancelled/timed-out work retains
its pending slot until settlement; unreleased allocations are removed. SQLite
kernel preemption is not claimed. P4's maximum 128 target selections plus cursors
and Contexts leave limited QuestionRef capacity: a page that exceeds remaining
capacity fails safely rather than expanding budgets or evicting live references.

Expired/removed Contexts invalidate all dependent references. Close, runtime
replacement and B0 Restore/raw rollback clear them under the existing composition
close/drain obligation. QuestionRefs, cursor/query state and Contexts are never
persisted or logged. SQLite remains v34, B0 remains v2; Profile/Grant SCRUB and
Proposal/Origin INCLUDE are unchanged. P3 StageContext, atomic publication/revoke,
key/fingerprint, narrow STAGE-only reconciliation and local Review/COMMIT are
unchanged. P6 below adds only bounded file/passages; external principal/kernel
integration and real Host/transport remain separate work.

### P6 explicit File Snapshot, lexical retrieval and passages (accepted scope)

P6 is accepted through merged PR #255 within its unpublished Application/Data scope, with no Host,
transport, MCP registration, UI, credential implementation or general external
CapabilityPrincipal. It reuses P4 runtime admission and the same Registry.
Existing P4/P5 Contexts keep empty file snapshots. `listFileSelections` constructs
App-owned choices from the authenticated Profile's current explicit File scopes
whose nullable Project equals the selected Context's exact Learning Space.
READ + fileContent, current Grant revision/recipient, file existence and current
Project/file relations are required independently of the parent bank authority.
Bank/questionContent and Project membership never grant file access.

Choices contain only random `fileRef` and `selectionOrdinal`; they disclose no
File/Artifact/storage identity. A selection is not a body-read credential.
`createFileContext` accepts only these Registry-minted references bound to the
exact Principal and parent Context. It verifies current F1 payloads and creates
a separate Context with an immutable selected-file snapshot. It does not modify
or renew the original Context. Each internal tuple records File ID, Artifact ID,
revision and payload digest, bound through its owning Context to exact Project,
Principal, Grant revision, creation time and expiry. Both new Context and all
descendants expire at the original Context's deadline. Choices are bounded to
64; missing/unready eligible Artifacts return fixed `sourceNotReady`, with no
whole-Project fallback or automatic parse. A new selection can only narrow the
current exact Grant; no second file authorization store is introduced.

Data reuses `requireExternalGrant` and the existing SQLite authority. It checks
the parent bank/Folder/Project relation, then only selected exact File scopes,
current file/source digests and Artifact tuples. The private-constructor
Context proof (`ExternalQuestionReadAccess`, reused as runtime/Context proof)
does not prove file permission; that independent Data transaction is mandatory.
`ExternalVerifiedArtifactSource` calls only F1 `getCurrentArtifact`, checks
metadata before/after verified load, and never calls ensure/reparse, reads raw
originals or accepts request paths. No Built-in Provider per-turn grant is used
as an external recipient grant.

`retrieveFileContent` internally constructs `RetrievalFilesScope` exclusively
from the approved snapshot. It calls the existing `RetrievalService` with
lexicalV1, the same Chunker/SQLite Index/FTS5, deterministic English/CJK token
rules, quoted parameterized MATCH and BM25/tie-breaks. Optional consumer checks
run across source/index awaits without changing Built-in retrieval behavior.
Every hit is matched back to the exact current verified Chunk projection; cache
content or provenance alone is never egress authority. Snapshot/source/Grant are
checked before retrieval, after results, and again at final release. Corrupt or
changed sources fail the complete external call rather than returning an older
Index or another generation. Query scalars/tokens/files/hits remain 200/32/64/20;
RAG's 6,000-byte hit and 24,000-byte result limits remain in force.

Search hit keys are exactly `passageRef`, `content`, `contentKind`, `locator`,
`chunkOrdinal`, `partOrdinal`, `windowOrdinal`, nullable `pageNumber`. Locator
is recomputed from verified part/window ordinals; no raw SourceRef JSON, block
id, File/Artifact/Chunk ID, title, heading, path, image bytes or storage key is
serialized. File pages have exactly `items`, nullable `nextCursor`, `hasMore`,
`unsupportedExcluded`, `startsAtDocumentBeginning`. Search pages have no search
continuation and do not assert document coverage. A finite ranked hit set never
means the complete document was read.

`getFilePassage` requires Session, original file Context and a search-minted
`passageRef`. Its optional cursor additionally binds the exact anchor reference,
parent Context, file generation and next safe Chunk ordinal. It returns at most
eight complete existing RAG Chunks in actual SourcePart/window order, starting
at the hit (or continuation). The response shrinks at complete Chunk boundaries
to at most 24,000 UTF-8 bytes including JSON/cursor, also honoring a lower P4
response budget. Math-bearing parts that require multiple Chunk windows fail
safely rather than releasing a split formula. Unsupported/RawFallback content
is excluded by the existing projection and reported explicitly. `hasMore` means
remaining safe Chunks after this page; `startsAtDocumentBeginning` distinguishes
a first-Chunk read from a middle-document hit. Excluded structure never becomes
readable via continuation, and exhaustion does not claim unsupported content
or earlier Chunks were read.

Selections, file Contexts, PassageRefs and cursors all count against P4's
unchanged 256/160 references and 64/16 Contexts. Failed/unreleased allocations
are removed. P4's 16/4 pending calls and two-second timeout remain shared with
Question/Target reads. Cancellation/deadline suppresses output and retains the
slot until real settlement. RAG index ensureBuild may write only the existing
derived cache under B0 mutation lease and Index transaction authority. Successful
pages carry internal `RetrievalExecutionEvidence` (not a wire field); fixed
`ExternalFileReadException` failures carry the same evidence. Before build entry
none is known; confirmed commits report derivedCache; unconfirmed/lost build
responses remain unknown. An interrupted in-flight build can settle later, so
the evidence remains live until `whenIdle`. No fake ExecutionReceipt, business
writer, second cache table, schema upgrade or mcpStudyV0 identity exists.

Final release re-verifies F1 integrity and then current SQLite policy/tuples,
followed by synchronous Context/runtime/control checks before output. Revoke,
revision narrowing, Project detach, digest/generation drift, delete/replacement,
expiry and corruption deny stale output. Shared close/drain before real B0
Restore or raw rollback clears every dependent Registry entry; restart requires
fresh authentication/selection. All references/snapshots/cursors remain
EXCLUDED; Profile/Grant SCRUB, Proposal/Origin INCLUDE, schema v34 and B0 v2
remain unchanged. P3 STAGE-only reconciliation, P4 target whitelist, P5 exact
typed Question authority and MCP v0's six tools retain their own semantics.

Deterministic candidate tests use synthetic credential proof, injectable clock,
real temporary SQLite, real F1 sidecars/lifecycle and the production Chunker/
Index. Checkpoints exercise policy/source drift after actual FTS results,
unknown versus confirmed cache effects, interruption/slot retention and actual
database restart plus B0 Restore/raw rollback. Candidate mechanical success is
not independent semantic approval; HOST_STABILITY_HALT remains ACTIVE.

### P7 trusted Capability execution (accepted unpublished scope)

The Kernel integration amendment in
[Application capabilities section 7](application-capabilities.md#7-p7-trusted-external-kernel-integration-accepted-unpublished-scope)
owns P7's typed allowlist, private execution-context construction and Receipt
projection. This is trusted Application composition only; no Host, IPC, transport
or MCP tool registration is added. It uses the existing TrustCore, management
binding and shared RuntimeAdmission, not a second identity or Grant authority.

The new P7 execution Context binds the exact Session at creation. Its trusted
Principal, generation, revision, scope, categories and recipient cannot be
supplied by request JSON, Profile strings, callbacks or a public CapabilityContext
constructor. Existing P4-P6 references remain Principal/generation scoped and
may be used by another currently valid Session for that same Principal after
all existing reference, policy, scope and Egress checks. Such a Session must mint
its own P7 execution Context; it cannot copy/rebind another Session's execution
Context. P3's existing precise STAGE Session binding is not relaxed.

P7's READ admission/release borrows the existing Registry-minted Data access
proofs and owning current-authority ports. READ Context creation remains separate
from STAGE target approval. File contexts remain explicit separate snapshots;
the original empty P4/P5 Context is not expanded. Final Kernel output checks
revalidate selected Question identities or verified File tuples and current
Data authorization; metadata-only selections never reload document bodies, and
full F1 payload re-verification stays with references that release passage
content. Cancelled/deadline/lost output is withheld, with newly minted
unreleased references discarded. Existing scopes, counts, bytes and capacities
are not increased; the complete P7 READ invocation shares one two-second bound.

STAGE still uses the original owning SQLite publication/revoke/CAS transaction.
Confirmed effects are observed from owning evidence, not reconstructed from
output, success flags or JSON. P7 receipts are local transient execution evidence;
Proposal/original key remains the only durable reconciliation authority. An
unknown result never automatically restages or releases candidate/Review/COMMIT
content. Narrow STAGE-only reconciliation still requires no READ Context.

Deterministic P7 acceptance uses synthetic identities, real temporary SQLite,
verified F1/FTS, both publication/revoke orderings, cancellation/deadline/result
loss and B0 Restore/raw rollback. Built-in Agent and MCP v0 remain unchanged.
HOST_STABILITY_HALT remains active; P7 acceptance does not constitute AR-R6A,
Transport, Host or MCP vNext acceptance.

### P8 offline Local Host dispatch foundation (accepted unpublished scope)

The internal Application seam has this direction:

```text
Future protocol adapter -> trusted authenticated Session
-> LocalHostDispatchCore -> ExternalCapabilityGateway (P7)
-> P3-P6 owning services -> original CapabilityResult / ExecutionReceipt
```

P8 is accepted through merged PR #258 within its offline scope. It is callable
only by trusted compiled composition in offline
fixtures. It has no production composition, public transport, listener, JSON
decoder, credential adapter or MCP projection. HOST_STABILITY_HALT remains
ACTIVE; passing offline tests proves neither transport nor OS identity security.

Construction defaults to disabled. Explicit `startOffline` checks database
readiness, completed B0 recovery and module/route readiness in order, then
validates the exact ten P7 typed bindings and their READ/STAGE-only permissions.
The readiness port belongs to trusted composition, never request parameters;
its synchronous current-generation check remains mandatory at admission and
release. No default application path constructs or starts this core. Startup
failure is closed, cannot be retried on the same instance, and exposes only a
fixed failure. Shutdown racing startup cannot publish a ready instance.

`bindSession` accepts only an existing credential-proven, management-bound
ExternalSession with current finite Enablement and current unrevoked Grant.
It mints a private-constructor LocalHostSessionEntry bound to this core,
exact Session, runtime generation and Grant revision. Request fields cannot
construct an entry, identity, scope, permission or recipient. Every context
opening repeats current runtime/Grant admission; changed revision cannot renew
an old entry. Disable, expiry, revoke, restart and Restore reject old entries
and Contexts. A new entry requires current authentication and authorization;
it never renews an old P7 execution Context or P3 StageContext.

Dispatch accepts `CapabilityId<I,O>` with its typed input, the minted entry and
the original P7 execution Context. Its only routes are P7's ten definitions:
target list/READ Context, Question search/detail, File choices/File Context/
retrieval/passage, generated STAGE and original SubmissionKey reconciliation.
Unknown identities and mismatched type bindings fail before handler entry.
Built-in capabilities, COMMIT and DESTRUCTIVE are not routes. There is no
`execute(String, Map)` or request-supplied authority. The Host has no SQLite,
Repository, file path or Provider dependency and does not implement business
authorization, content parsing, STAGE publication or output serialization.

Host-level pre-admission denial reuses Kernel rejection with `notStarted/none`
and a denied Principal without Profile/scope/authorization details. Unknown or
mismatched route names are represented only by the fixed `local_host_rejected`
receipt identity, never an echoed arbitrary request string. Accepted
calls return the original P7 result and Receipt unchanged. P7 owns current
authorization, limits, admission, final category/recipient/scope release and
fixed failures. Host readiness/entry validity is included in the synchronous
final response-availability gate. Loss/timeout does not infer rollback, erase
known effects, release unreleased content or automatically repeat STAGE.
The original SubmissionKey and Proposal authority remain the reconciliation
path; the Host stores no completed-call journal or second Receipt.

Shutdown first blocks new Host calls, closes Gateway, then closes Registry and
STAGE/runtime admission. It drains Gateway, Registry, STAGE and pending Host
startup/binding/context-opening work before completion. Caller cancellation or
deadline may return sooner, but cannot shorten shutdown's wait for the real
owning work. Trusted composition must await shutdown before B0 swap, raw rollback
or runtime replacement, then invalidate the remaining local authorities and
restart/restore TrustCore using the existing sequence. A stopped core cannot
restart; replacement uses fresh composition with disabled external access.

Offline acceptance uses synthetic CredentialPort, deterministic clock,
temporary real SQLite/F1/FTS and owning-service barriers: pre-admission and
cross-Principal/exact-Session denial, all ten routes, both Grant/revoke orderings,
final release changes, cancellation/deadline, committed-but-lost STAGE/key
reconciliation, shutdown during real work/startup/admission and B0 Restore/raw
rollback. Built-in and MCP v0 regressions remain required. Real credentials,
mTLS, Discovery, Windows SID/protected objects, transport limits and abnormal
OS recovery belong to a separately authorized safety stage.

## 4. Stage reconciliation, cancellation and revoke

Use [typed execution receipts](application-capabilities.md). A timeout or lost
connection after handler entry is not evidence of zero effect. STAGE's durable
reconciliation key survives request ids and handle replacement. Query receipt
before restaging an uncertain request; if context is stale, reconcile first and
open a newly validated context only for a new stage attempt.

Before transaction start, cancellation can stop with known zero effect. Past
durable stage commit, cancellation cannot remove the Proposal or report that
stage was undone. Unknown bridge outcome is reconciled by submission key.
Revoke blocks new invocations and unreleased egress. For STAGE, validation of the
current client profile/grant revision and durable Proposal/receipt publication
must share one transaction/CAS publication boundary; a preflight grant check
followed by an independently committing stage is insufficient. If revoke or
grant-revision change wins before publication, STAGE commits zero durable effect
and returns the bounded stale/unauthorized result. If durable stage publication
wins first, later revoke cannot retroactively erase that local Review data.
Local user's current approval authority decides future formal commit, not the
revoked external grant.

P3's unpublished Application/Data implementation candidate is owned by
[GeneratedQuestion section 11](generated-question-proposals.md#11-p3-durable-external-stage-candidate).
It binds a management-validated opaque Profile reference to this App TrustCore's
Principal, requires a credential-proven Session and current runtime enablement,
and mints the approved original Target/evidence Context inside Application.
Profile strings and historical Origin never establish this binding. Real
credential adapters, pairing UI and Host are still unwired.

The existing Proposal repository owns the publication transaction and reuses
transaction-local policy checks against the same SQLite authority as revoke.
Status reconciliation uses the authenticated Profile/original key and retained
validated Proposal, independent of old Context/Session/journal instances. The
minimal acknowledgement contains only Proposal id and original key: current
STAGE + `proposalMetadata` + original bank/Project scope suffice, without READ.
Publication also requires `questionContent` and approved-file `fileContent`.
No content or formal COMMIT Receipt is exposed. Absence stays unknown, with no
automatic restage. Final output release rechecks current policy and Session.
The new pending-only guard is bounded and retains slots until actual settlement;
the pure-memory invocation core/transient journal is not production integration.
This adds no transport, Host route or external COMMIT authority.

App unavailable/not ready/recovering returns safe unavailable/busy; it does not
trigger alternate database access. Host starts only after B0 recovery, database
validation and complete module/route validation.

## 5. Local IPC decision checkpoint

Architecture freezes authenticated local-only transport, protected endpoint
discovery, App/bridge peer validation, bounded framing/payload/concurrency,
deadline/cancellation, versioning, reconciliation, restart/revoke behavior and
safe logs. Windows P0 selects IPv4 Loopback TCP + mTLS as the preferred
implementation and verification candidate, with Named Pipe retained as a
fallback. Its listener may bind only explicit `127.0.0.1`, never `0.0.0.0`, a
LAN address or an IPv6 wildcard. There is no unauthenticated business fallback.

Windows P0 uses **B-class isolation**: other local SIDs may attempt TCP
connections; OS rejection by SID at TCP `connect()` is not promised. Before
protected business handling or READ/STAGE output release, trusted authentication
and current Application ExternalPrincipal/Profile/Grant/Scope/Revision/Context
checks must pass. A client under a different SID with valid credentials and
current authorization may receive business access in this model. Cross-SID
credential secrecy, trust-anchor integrity, tamper-resistant Discovery,
protected runtime objects, resource limits and rejection of unauthorized
business access remain hard requirements. Loopback is not authentication;
mTLS is not equivalent to OS ACL isolation.

TCP/TLS should use Dart standard capabilities. A minimal Windows Native Adapter
is permitted only for demonstrated platform security gaps in necessary key and
certificate generation, secure storage, or creation/checking of protected
Discovery objects. It gains no business authorization authority and cannot
access or bypass formal business database write paths. User-level DPAPI does
not isolate different processes under the same SID; no guarantee keeps TLS
leaf private keys permanently out of process memory. This decision selects no
FFI package or certificate algorithm and authorizes no Native implementation.

Only the pure-memory trust/protocol core is implemented and accepted within its
memory scope. Real TCP/mTLS and Windows protection remain **UNVERIFIED**;
Transport remains **BLOCKED** until actual Windows acceptance is complete.

AR-R6A is NEEDS IMPLEMENTATION-SPIKE. First screen candidates against Dart/AOT,
supported Windows environments and packaging. Record why any candidate fails;
implement minimal comparable proof only for viable candidates and within
section 6's explicit runtime authorization. Evaluate protected-object ACLs,
the chosen isolation model, authenticated endpoint discovery and impersonation,
cancellation, orphan cleanup, restart/races, multi-client calls and bridge launch.
Named-pipe ACL alone is not all application authorization.

AF_UNIX-specific ROOT-ACL OS-connect rejection, Socket-file movement, endpoint
lease and unlink races are not TCP candidate pass conditions. Historical
ROOT-ACL results remain **INCONCLUSIVE**, never rewritten as PASS. TCP must
separately prove mTLS identity, Principal/Grant isolation, protected Discovery,
real resource limits, lifecycle safety, revoke and abnormal recovery; removing
AF_UNIX-only tests does not remove other credential, object or input protections.

Choose the least complex candidate passing every hard property. Spike must be
allowed to overturn the TCP preference, fall back to Named Pipe or reject all
candidates if evidence requires it. If none passes, keep
Host unpublished; no unauthenticated fallback. HTTP is not preferred without a
specific benefit. No shell, generic arbitrary RPC dispatch or remote listener.
Wire envelope belongs to infrastructure; Application remains typed/protocol-free.

## 6. Persistence, backup and acceptance

Profile/grant non-secret metadata uses additive v33 storage accepted in PR #248
below, with its constraints and compatibility validators owned here.
No existing schema is changed at AR-R0. Credentials use a dedicated secure seam,
not the Provider credential namespace.

### Non-secret authorization storage (P1)

The additive v33 schema uses the existing DatabaseHelper migration/open authority:

| Table | Persisted authority and constraints |
|---|---|
| `external_client_profiles` | App-generated UUID v4 identity; display name (1–80 characters), adapter/protocol tokens (1–32), creation/revocation UTC milliseconds and grant revision (0–2147483647). Identity metadata is immutable; updates advance revision by exactly one; revoked Profiles cannot be updated. |
| `external_grants` | One current policy per Profile, explicit READ/STAGE booleans (at least one), revision, update/revocation time. Composite FK binds Profile/revision and cascades the revision update inside the transaction. No COMMIT/DESTRUCTIVE column or generic permission string exists. |
| `external_grant_scopes` | At most 128 distinct named bank/file targets per Grant, each bound to one Learning Space (`project_id`) or the explicit local context (empty stored project id). Target ids are bounded to 256 characters, project ids to 128. Empty rows deny all targets; there is no wildcard or missing-target global fallback. |
| `external_grant_egress` | Whitelisted `questionContent`, `fileContent`, `proposalMetadata`; recipient is the owning Profile, not a client-supplied provider/name. Scope/egress rows have Grant FKs and composite primary keys. |

Application's trusted first-party management entry mints Profile ids and opaque
local references. Profile creation grants no permissions, pairing, authenticated
Principal or runtime enablement. References belong to the current management
composition and cannot be constructed from RPC/JSON ids. Trusted local selection
by id is management only; it is not credential authentication. The existing
memory trust state machine is unchanged and is not durable identity authority.

Grant replacement (including expansion or narrowing), Grant revoke and Profile
revoke use the existing B0 mutation gate and a SQLite transaction with expected
Profile revision CAS. A stale revision cannot overwrite the current winner;
revoke advances revision. Regrant requires an explicit current management action,
and a revoked Profile cannot be reactivated. Current policy queries reload durable
state, compare revision, permission, exact scope, category and recipient, and
recheck target existence and Learning Space membership. Missing/unauthorized
targets share a fixed denial; deleting a target never expands scope. Persisted
bank names retain the existing compatibility identity, not a new incarnation
guarantee. Grant lookup is policy inspection and supplies neither authentication
nor runtime admission, handler execution or output release authority.

Fresh creation, normal open, staged validation and upgrade check exact owned
schema objects, relationships and typed row data; unknown permissions, malformed
metadata, inconsistent revisions and extra owned triggers/indexes fail closed.
Older versions may acquire only exact empty additive objects, never adopt
pre-existing authorization rows. No credential, pairing secret, certificate,
runtime generation, Enablement or Context is persisted in these tables. No Host,
external Origin codec or CapabilityExecutor integration is added by P1.

Portable B0 validates this authority before deleting all four tables' rows in the
snapshot copy, including revoked metadata. Incoming portable packages must have
empty authorization tables; Restore does not silently sanitize active grants.
Raw rollback baselines keep the original local authorization metadata. Existing
Proposal Profile references remain soft and have no FK to these tables. Package
v2 is unchanged. Durable STAGE/revoke publication still requires the owning
service's future shared transaction/CAS boundary; this storage does not close
the process-local journal or restart Receipt findings.

Portable B0 snapshot scrubs active external profiles/grants, excludes credentials
and has no handles/sessions. Restore keeps historical Proposal origin as a soft
profile reference, invalidates running contexts and requires fresh pairing.
Restore never reads/writes secure credentials or reactivates a restored grant.
Rollback baselines retain original live metadata under existing B0 authority.

Tests require principal isolation, forged clientInfo, direct-call rejection,
handle copy/expiry/reopen, stale scope/source, non-enumeration, egress revoke,
stage-vs-revoke/grant-revision races, stage response loss/restart and
restore-no-reauthorization. Windows proof covers
chosen transport authentication/protected-object ACLs under section 5's isolation
model, process/endpoint races, cancellation/orphans, Unicode
and spaced paths, multiple clients and clean bridge launch. Linux proof alone
does not establish Windows safety. Disable Host/routes while retaining data
compatibility; do not delete Proposal state to roll back an external feature.

**HOST_STABILITY_HALT is active for the primary Windows host.** Transport
security acceptance and system stability acceptance must complete separately.
Experiment-associated blue screens, hard hangs or kernel-driver anomalies
immediately trigger HOST_STABILITY_HALT and stop the related dynamic experiments.
The reported AF_UNIX-associated instability on 2026-10-10 is sufficient risk
basis to stop further experiments; it does not prove a complete kernel-failure
causal chain, and acceptance must not require reproducing a blue screen.

Old AF_UNIX ROOT-ACL, endpoint-lease and close/unlink dynamic experiments are
permanently halted on the primary host and must not rerun automatically. Windows
updates, replacement scripts or account changes do not lift this halt. Future
real TCP/mTLS, Windows SID, Discovery and credential-security verification needs
new explicit authorization and should prioritize a separately approved isolated
environment. An ordinary VM on the primary host is not automatically independent
of host-kernel stability risk. If any required security or stability acceptance
is missing, the formal Host remains **unpublished**. This contract amendment
authorizes no dynamic experiment or Host activation and does not unlock AR-R6B.

## 7. P9 offline IPC Envelope foundation (accepted unpublished scope)

This freezes an internal offline framing candidate, not a published client
protocol or MCP Tools Schema. Infrastructure owns bytes; Application stays
typed and protocol-free. The existing memory-only P0 protocol remains a separate
historical candidate; P9 neither changes nor silently interoperates with it.

```text
Untrusted bytes -> bounded frame admission -> version/length/encoding checks
-> strict fixed envelope -> untrusted validated envelope
Future authentication + App Authority -> Session -> P8 -> P7 -> owning services
```

Successful decoding proves only framing/encoding validity. There is no Principal,
Session, Host entry, execution Context, capability dispatch, authentication
callback, persistence or SubmissionKey factory in the codec. Claimed identity,
Profile, Session, recipient, Scope, Grant, `trusted`, request ID or credentials
inside a payload remain opaque untrusted text. Future adapters must separately
authenticate and obtain App-owned authority before parsing typed business input
and invoking P8. Correlation never establishes durable STAGE identity.

### Exact internal frame v1

`IPC envelope version 1 != MCP protocol version != Submission schema version`.
No negotiation, automatic downgrade, compression, binary payload, JSON-RPC,
extension fields or MCP projection is supported. Integers are unsigned
big-endian; the fixed header is exactly 16 bytes, followed by the ID bytes and
then exactly the declared payload bytes:

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 4 | Magic ASCII `SHIP` |
| 4 | 1 | IPC envelope version, exactly 1 |
| 5 | 1 | Kind: 1 request, 2 response, 3 protocolError |
| 6 | 1 | Encoding: 1 strict UTF-8 text |
| 7 | 1 | Feature flags, exactly zero |
| 8 | 1 | ID byte length |
| 9 | 3 | Reserved, all zero; unknown fields/features reject |
| 12 | 4 | Payload byte length, excluding header and ID |

Request/response IDs are 1..64 ASCII bytes from `[A-Za-z0-9_-]`; no Unicode,
whitespace, path, numeric coercion or implicit conversion. Responses are distinct
messages, never converted to requests. Protocol errors have zero ID bytes and
only one fixed failure-code token as payload; they never echo an untrusted ID,
body, exception, stack trace or local path. Payloads of request/response are
nonempty opaque UTF-8 text, preserving literal BOM and NUL exactly; framing does
not interpret JSON. Strict UTF-8 rejects malformed bytes; encoding rejects
unpaired UTF-16 surrogates instead of replacing them. Business JSON syntax,
duplicate/unknown business fields and Tool Schema validation belong to a future
separately frozen adapter; payload text grants nothing.

### Budgets and allocation

| Resource | Fixed P9 ceiling and basis |
|---|---|
| Request payload | 6,324,224 bytes = 6 × 1 MiB + 32 KiB |
| Response payload | 229,376 bytes = 6 × 32 KiB + 32 KiB |
| Protocol-error payload | 32 ASCII bytes, exactly a supported failure code |
| Single frame | 6,324,304 bytes = request + 16-byte header + 64-byte ID |
| Retained decoder byte storage | One header, one ID scratch area and at most one admitted payload: 6,324,304 bytes |
| Output per consume operation | At most one envelope; at most 6,324,224 UTF-16 code units; no accumulated output queue |

GeneratedQuestion's existing `GeneratedLimits.submissionBytes` / resource matrix
allows 1 MiB raw UTF-8 submissions. A future wrapper may embed the original
`ExternalStageSubmission.submissionJson` as a JSON string: worst-case JSON
escaping needs at most six ASCII bytes per original UTF-8 byte. The additional
32 KiB reserves the existing complete P4/P5 metadata/output budget for bounded
wrapper metadata; it does not freeze that future projection or authorize
arbitrary metadata. P4/P5 enforce 32 KiB output; P6 enforces 24,000 bytes,
including passage/page metadata, which fits the response base. The response
ceiling similarly accommodates worst-case string embedding plus 32 KiB headroom.
P3 returns only Proposal ID/original key, never its 4 MiB original/review batch
or formal COMMIT receipt. P9 does not enlarge any business budget or encode
ExecutionReceipt/authorization objects. Future projection exceeding these bounds
requires contract review; no silent truncation or weakening P3-P8 is permitted.

The decoder validates the complete header before body allocation, validates ID
bytes before allocating the payload, and retains no caller-owned input view.
Zero length, high-bit/signed-negative representation and over-limit declarations
fail without allocating that body. Encoder scans Unicode and computes UTF-8
length before creating encoded bytes, using these same fixed ceilings, then
writes directly into its single final frame. Encoder byte allocation is at most
6,324,304 bytes, with no second encoded payload or SDK encoder scratch; decoder
explicit byte storage is bounded as above.
Decoded string storage is bounded by twice the payload bytes for UTF-16 (at most
12,648,448 bytes). SDK conversion scratch and object headers remain proportional
to one bounded frame; these data bounds are not a measured OS resident-heap or
production transport memory guarantee. Caller input/output ownership, connection
count and backpressure require separate transport budgets; callers must not
retain an unlimited list of decoded envelopes.

### Incremental API, failure and lifecycle

`consume(bytes, offset)` consumes at most through one complete frame and returns
the consumed byte count plus either one untrusted envelope or no envelope.
Callers repeat at the next offset for coalesced/continuous frames, or feed the
next chunk for an incomplete frame. There is no hidden multi-frame queue and
no publication before all declared bytes and strict validation complete.
`finish` checks end-of-input: partial header/ID/payload or trailing garbage is
truncated/invalid, never silently discarded. EOF on a frame boundary closes
cleanly. Explicit close clears unfinished data; replacement uses a new decoder.

Every failure closes and clears the decoder; it cannot resynchronize, skip
garbage, downgrade or reuse stale state. Prior returned envelopes remain only
untrusted values. Fixed classifications are `invalidFrame`, `unsupportedVersion`,
`unsupportedMessage`, `unsupportedEncoding`, `unsupportedFeature`,
`invalidLength`, `resourceLimit`, `invalidId`, `invalidUtf8`, `invalidPayload`,
`truncated`, `closed`. A protocolError can carry only one such token; no business
failure, execution status, effect or rollback conclusion is invented. Error
objects retain only the classification. Encoder failures do not alter decoder
state. No listeners, actual transport, credentials, MCP/stdio, default production
composition or client protocol publication are installed.

Deterministic acceptance covers all message kinds, exact length/Unicode boundaries,
fragmentation/coalescing, allocation-before-body refusal, malformed/truncated
headers and bytes, reserved/unknown features, safe errors, bounded seeded fuzz,
forged authority text and absence of production wiring. P7/P8 and Built-in/MCP v0
regressions remain required; green local tests are not independent approval.
HOST_STABILITY_HALT stays ACTIVE, Transport BLOCKED, AR-R6A NOT_ACCEPTED.

## 8. P10 offline typed IPC command projection (accepted unpublished scope)

P9 is accepted within its offline scope through merged PR #260. P10 is accepted
within its offline scope through merged PR #261. P10 freezes
only the following internal business schema and offline composition. It adds
no production Host, transport, authentication implementation, MCP registration
or public Tool Schema. Business schema v1, P9 envelope v1, MCP protocol version
and GeneratedQuestion Submission v1 are independent; mismatches reject without
negotiation or coercion.

### Authentication and trusted composition

The infrastructure adapter receives a P9 envelope, a trusted authentication port
and an existing P8-minted execution Context supplied by compiled composition.
The port receives no payload/claimed identity and returns only a credential-proven
Session (or denies). Before business parsing the adapter calls P8 `bindSession`
to obtain a currently admitted LocalHostSessionEntry. P8/P7 still verify the
exact Session, Grant revision, Context, lifecycle and final egress. No JSON can
mint/rebind a Principal, Session, entry, execution Context, Grant, permission,
recipient, target bank, file path or execution Scope. Offline fixtures provide
READ/STAGE/reconciliation Contexts through existing P8 openings; P10 does not
add a wire Context registry or a STAGE target-approval route. Original key
selection for reconciliation is trusted P8 composition, not Envelope Request ID.

### Exact request schema v1

Root keys are exactly `schemaVersion` (integer 1), `type` (string `command`),
`capability` (one of the ten names below), `input` (exact object below).
Every listed field is required, including nullable fields. Missing and null
are distinct; neither triggers defaults. Unknown keys at any parsed level,
duplicate JSON keys (including escaped aliases), wrong types/nesting, floating
point/exponent numbers in integer fields, malformed JSON, invalid Unicode
scalars and unsupported versions reject. No dynamic CapabilityId is constructed.

| Fixed capability | Exact input keys and shape |
|---|---|
| `external_list_targets` | `pageSize`: integer 1..50; `cursor`: null or opaque ref |
| `external_create_read_context` | `targetRef`: opaque ref |
| `external_search_questions` | `query`: nonblank string, <=200 UTF-16 units before trimming; `pageSize`: integer 1..50; `cursor`: null or opaque ref |
| `external_get_question_detail` | `questionRef`: opaque ref |
| `external_list_file_selections` | Empty object |
| `external_create_file_context` | `fileRefs`: 1..64 distinct opaque refs |
| `external_retrieve_file_content` | `query`: nonblank string, <=200 Unicode scalars before trimming; `limit`: integer 1..20 |
| `external_get_file_passage` | `passageRef`: opaque ref; `cursor`: null or opaque ref |
| `external_stage_generated_questions` | `submissionJson`: nonempty original JSON string <=1 MiB UTF-8; `externalRequestId`: null or `[A-Za-z0-9][A-Za-z0-9._-]{0,127}` |
| `external_reconcile_generated_stage` | Empty object |

Opaque refs are exactly 43 ASCII base64url characters, preserving the existing
P4-P6 mint/lookup semantics. Syntax supplies no authorization. P10 reuses the
bounded duplicate-aware JSON lexical decoder (maximum nesting 16) for the
wrapper, with P9's unchanged request ceiling. Embedded Submission is unchanged
text; P3 alone parses its schema, keys, content, provenance and idempotency.
P9 Request ID is copied only to the response frame and is never automatically
used as externalRequestId, SubmissionKey or a credential. Fixed rejection of
every other capability includes Built-in/MCP v0, COMMIT, DESTRUCTIVE and SQL.

### Exact response schema v1 and whitelist

Root keys are exactly `schemaVersion` (integer 1), `type` (`result`),
`capability` (fixed accepted name or null before valid projection), `data`
(operation-specific object or null), `error` (fixed code or null). Success has
non-null data and null error; failure has null data and one fixed code.
Adapter codes are `unauthenticated`, `unavailable`, `invalidRequest`,
`unsupportedVersion`, `unsupportedCapability`, `invalidResult`,
`responseEncodingFailed`; owning failures use only the fixed
`capability.<CapabilityFailure enum name>` vocabulary. No arbitrary input,
exception, body, credential, authorization metadata or path enters an error.

| Capability result | Exact allowed data |
|---|---|
| Target list | `items`, nullable `nextCursor`; each item exactly `targetRef`, `bankName`, nullable `projectId`, nullable `folderName` |
| READ/File Context creation | `contextRef` only |
| Question search | `items`, nullable `nextCursor`; each hit exactly `questionRef`, `kind`, `stemPreview`, `hasAnswer`, `hasExplanation`, `sourceKind` |
| Question detail | `kind`, `stem`, `options`, nullable `answer`, nullable `explanation`, `sourceKind`; options exactly `label`, `content`; nodes exactly text/text, inline_math/latex, block_math/latex or unsupported/type |
| File choices | `items`, nullable `nextCursor`, `hasMore`, `unsupportedExcluded`, `startsAtDocumentBeginning`; item exactly `fileRef`, `selectionOrdinal` |
| Retrieval/passage | Same five page keys; each passage exactly `content`, `contentKind`, `locator`, `chunkOrdinal`, `partOrdinal`, `windowOrdinal`, nullable `pageNumber`; retrieval hits additionally require `passageRef` |
| STAGE/reconciliation | `proposalId`, original `submissionKey`, `publication` (`STAGED`), `formalCommit` (`NOT_REPORTED`) |

Question kind is exactly `single_choice`, `fill_blank`, `short_answer`, `unknown`;
sourceKind is `typed` or `legacy`; contentKind is `paragraph`, `heading`,
`formula`, `answerLike`, `table`, `imageAlt`. Flags/hasAnswer/hasExplanation are
strict booleans. Ordinals are integers 0..2147483647 (selectionOrdinal 0..63);
pageNumber is null or integer 1..2147483647. Item arrays are bounded to 50 targets/
question hits, 64 file selections, 20 retrieval hits or eight passage chunks.
Detail has at most 26 options and 512 nodes total; content strings fit 32 KiB,
individual passage content fits 6,000 UTF-8 bytes, locator 256 UTF-16 units,
bank/folder names 512 UTF-16 units and projectId 256. Proposal IDs are UUIDv4;
SubmissionKey preserves the existing 1..64 local-key grammar. Nullable fields
must be present. Selection/retrieval pages have null cursor, false hasMore and
false startsAtDocumentBeginning; selections also have false unsupportedExcluded,
while retrieval retains its verified unsupportedExcluded flag. Passage hasMore
iff its nextCursor is non-null. Structural node types
remain the existing safe P5 vocabulary. READ results come only from the P8/P7 final egress
gate; nested whitelist validation never supplies authority. File references
remain opaque. Coverage flags describe only the allowed safe page; ranked hits,
middle-document passage or exhaustion never assert complete-document coverage.
Reconciliation confirms durable historical STAGE publication, never pending
Review, formal COMMITTED status or a COMMIT Receipt (P7's summary has none).

The adapter validates projected data against its operation whitelist, preserves
typed null versus explicit empty content, and checks the unchanged owning output
ceilings (32 KiB metadata/questions, 24,000 bytes file pages) and P9's 229,376-byte
response budget before frame encoding. No truncation or ceiling enlargement.
A trusted frame-encoder port permits deterministic encoding failure injection;
default encoding is P9 and budget validation always precedes that port.

### Effects, interruption and settlement

The returned local call result retains the original P8 CapabilityResult/Receipt
object separately from any wire bytes. It is never serialized or logged.
Projection/encoding failure changes only response availability, never the
original execution status, confirmed effect or durable reconciliation evidence.
Unknown STAGE is not retried. Persisted Proposal/original key remains P3's sole
durable reconciliation authority, including across real database reopen.
Cancellation/deadline/response loss delegates to P8/P7 control and release;
READ emits no withheld data. No second transaction, Receipt table or completed
call log is added. Adapter shutdown rejects new work, starts P8 shutdown and
waits both its pending authentication/admission calls and P8 owning settlement.
Restore/restart require that drain and fresh composition/authentication.

Offline deterministic acceptance covers all ten routes, every other name,
authentication-before-parsing, stale/cross-Profile/cross-generation/exact-Session
denial, strict malformed/duplicate/unknown/type/version/numeric boundaries,
P9 roundtrips, unchanged Question/File scopes, final egress revocation, lost
durable STAGE and original-key reconciliation, encoder failure with preserved
Proposal/derived-cache effects, cancellation/deadline/drain and replacement.
P3-P9, architecture and Built-in/MCP v0 regressions remain required. Real Host
security/stability stays UNVERIFIED: HOST_STABILITY_HALT ACTIVE, Transport
BLOCKED, AR-R6A NOT_ACCEPTED; production Host and MCP vNext remain inactive.

## 9. P11 trusted local authorization management (accepted local scope)

This freezes a first-party settings flow for non-secret Profile/Grant policy
configuration only, accepted through merged PR #262. P10 is
accepted through merged PR #261; this stage does not reopen P0-P10 semantics.
The page always states: “当前仅配置访问规则。外部客户端尚未配对，真实连接功能未启用。”
Saving policy proves neither pairing, credential identity, authentication nor
runtime enablement. No Principal, Session, Host or external management route is
created. HOST_STABILITY_HALT stays ACTIVE, TRANSPORT BLOCKED, AR-R6A NOT_ACCEPTED.

Trusted composition mints UUIDv4 Profile IDs. Each page owns an independently
closable management view and existing opaque Profile references. Creation starts
at revision zero without a Grant. A bounded read-only keyset query lists at most
50 Profiles per page, including revoked metadata; it validates P1 records and
adds no Capability or RPC. Local display names and fixed adapter/protocol
metadata (`local-policy` / `unconfigured`) are not identity evidence.

Permissions are exactly READ and STAGE, independently selected; Egress is a
separate explicit set of questionContent/fileContent/proposalMetadata. At least
one permission is required by P1; empty Egress denies content release. Scopes are
at most 128 distinct exact Bank/File and nullable Project tuples. Empty Scope
authorizes no targets. The local context is explicit, never a wildcard. Choices
come from trusted Application Bank/File/Project queries, carry no
absolute path, and cannot be minted by UI text input. Project relations are
preserved exactly. Deleted/detached choices cannot be silently remapped; stale
saved scopes are displayed as unavailable and require explicit removal. P1's
existing transaction rechecks target existence/membership before publication.
Bank names retain P1's compatibility identity, without an incarnation guarantee.
The existing import selector omits empty banks. The internal management query
therefore reuses P1's bank_folders/ questions union for existing Bank names,
while File/Project metadata uses existing Application services. This read-only
query changes neither import selection nor external READ/MCP semantics.

Replace/revoke operations reuse the P1 repository, revision CAS, transaction and
B0 Mutation Gate, with no new tables, migration or B0 v2 change. CAS conflict
discards the stale editor and reloads current policy; it never automatically
retries a write. Grant replacement and both revocations require local confirmation.
Profile revoke is irreversible under P1. The UI blocks duplicate actions and
publishes async results only while its page/view/composition remain current.
Composition replacement and closure of the captured database invalidate old views,
including successful Restore and raw rollback; old objects cannot resume writes.
Errors expose fixed categories only, and corrupt state refuses editing.

Offline acceptance uses synthetic data, real temporary SQLite and Widget tests
for exact multi-target roundtrip, empty scope, permission/egress separation,
revision races, reference isolation, revoke, stale targets, B0 portable scrub,
Restore/raw rollback, disposed pages and absent Host wiring. Existing External,
architecture, Built-in and MCP v0 regressions remain required. No credentials,
pairing proof, runtime switch, transport, discovery, bridge or real client test is
part of P11. Mechanical checks do not constitute independent acceptance.

## 10. P12 offline trust binding (accepted offline scope)

P11 is accepted within its local policy scope through merged
[PR #262](https://github.com/duanzhijian200443/shiroha_quiz/pull/262).
Its final-head contract checks succeeded (7/7), fixed-target Verifier reported
PASS and independent semantic review found zero confirmed P0/P1/P2. The review
record remained INCONCLUSIVE pending that verification; no later APPROVAL marker
is asserted. Historical acceptance follows AGENTS.md's merged-PR rule.
Exact head/base/merge and run identities remain in Git/PR evidence.

P12 is accepted through merged
[PR #263](https://github.com/duanzhijian200443/shiroha_quiz/pull/263), only within
its unpublished offline Application scope. Final-head CI succeeded 7/7 and the
final Reviewer recorded REVIEW APPROVAL with zero P0/P1/P2. By explicit user
instruction, that same review session performed the fixed-target offline
verification closing the regression gap; it was not a separate independent
Verifier session and no VERIFICATION APPROVAL marker is invented. The
[final closure](https://github.com/duanzhijian200443/shiroha_quiz/pull/263#issuecomment-6122245804)
owns the precise evidence and disclosed exception.

P12 freezes only an unpublished offline Application composition. The existing
P0 TrustCore is the sole Principal/Peer/Session and PairingState authority;
P1/P11 remains the sole durable non-secret Profile/Grant authority. The minimal
P0 registration amendment accepts an opaque management reference and its owning
management service, never an arbitrary Profile string. It reloads the Profile,
requires matching identity, no Profile revocation, an owning-Profile Grant when
present, and an unchanged generation before minting. Repeated selection in one
TrustCore returns the identical Principal; the original bounded Profile map
prevents duplicate Principals. Missing Grant/Scope/Egress is never repaired or
inferred. Registration does not authenticate, pair, enable or grant access.

`ExternalTrustCoordinator.offline` owns local selection handles and one P8
Host over the existing P7 Gateway/P4 Admission. Each local pairing/enablement
action reloads its own current management reference; handles from another
coordinator, closed/replaced compositions and generation changes fail closed.
P4 binding requires equal Profile/Principal/Grant identity and is scoped to its
binding generation. Old bindings cannot admit new-generation Sessions without
fresh trusted binding. Profile ids, decoded JSON and historical Proposal Origin
cannot mint or reactivate these authorities.

The coordinator delegates the unchanged sequence to P0: unpaired ->
requestPending -> approvedPendingProof -> pairedDisabled ->
enabledForCurrentRuntime. Local approval still requires separate credential
possession proof. Invalid proof stays approvedPendingProof. Enablement selects
one Profile and a finite positive duration within P0's existing thirty-minute
candidate ceiling. Authentication requires that selected Profile's Principal;
it adds no READ/STAGE. Saving P11 policy never enables a Profile. Grantless
credential-proven Sessions release no business content and cannot bind P8.

P8/P7 and their owning services still reload current Profile/Grant, revision,
exact Scope and independent Egress on every admission/publication/release.
READ references retain same-Principal/current-generation cross-Session semantics;
P7/P8 execution Contexts and P3 STAGE Contexts retain exact-Session binding.
Disable/expiry/revoke, restart, Restore and composition replacement invalidate
applicable old authority; reauthentication never restores an old Context.
There is no second pairing machine, Session table, writer, journal or Receipt
store. P3's original SubmissionKey/Proposal remains the durable reconciliation
authority, including committed-but-lost STAGE across real SQLite reopen.

Shutdown rejects new work immediately, delegates P8 close/drain and also awaits
pending local management operations. Only after actual owning settlement does
it advance P0 generation. Await it before database close, B0 swap/raw rollback or
runtime replacement; replacement starts disabled and requires fresh selection,
proof and explicit enablement. Revocation or invalid enablement before STAGE
publication yields no durable effect; after publication it withholds unreleased
output while preserving the original owning effect and reconciliation key.

Acceptance is deterministic and fully offline: P11 policy-created Profiles,
synthetic test-only CredentialPort, existing temporary SQLite/B0 fixtures,
identity/reference conflicts, invalid proof, missing authority, stale revisions,
cross-Profile/generation/Session attempts, READ compatibility, disable/expiry,
restart/Restore/raw rollback, lost STAGE and shutdown/owning-work barriers.
P0-P11 and Capability/Architecture/Built-in/MCP v0 regressions remain required.
Green synthetic proof is not credential, OS or transport security acceptance.

Production `main.dart` constructs neither this coordinator nor TrustCore/P8 Host,
and injects no authenticating synthetic CredentialPort. P11's unpaired-client
statement remains exact; P9/P10 syntax cannot activate identity. No listener,
real key/storage/rotation, transport, discovery, client pairing or MCP vNext
tool is added. SQLite v34, B0 v2, formal COMMIT/DESTRUCTIVE and Built-in/MCP v0
are unchanged. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED. Real Windows credential/TCP/mTLS and stability work
requires separate authorization and independent safety-environment assessment.

## 11. P13 Windows security readiness (static candidate)

[Windows Host security readiness](windows-host-security-readiness.md) owns the
production gap/dependency matrix, static TCP/mTLS versus Named Pipe screening,
CredentialPort mapping proposal, isolated experiment authorization checklist and
real PASS/FAIL/fallback criteria. It distinguishes existing offline proof,
official API support, real Windows evidence still missing and unsupported
promises. It supplies no credential implementation, listener or production wiring.

An approved environment independent of the primary host's kernel, exact bounded
scope/resources and new explicit user experiment authority are not established
by this checkpoint; dynamic admission is BLOCKED. Ordinary primary-host VMs,
synthetic tests and design approval cannot clear the security/stability gates.
Sections 2/5/6 retain B-class isolation, same-SID proxy risk, protected credentials/
Discovery and the permanent halt on primary-host AF_UNIX experiments. If a hard
property cannot be proved, keep Host closed; no authentication fallback or silent
change to P0/P4/Grant semantics. HOST_STABILITY_HALT = ACTIVE;
TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED; AR-R6B remains inactive.
