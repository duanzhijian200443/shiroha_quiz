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
At Kernel final release, each opaque reference is still validated independently.
A search hit and its continuation cursor may share the same complete selection
key; Application checks that key once through the original Data release port.
Equality includes storage id, creation time, row identity and content fingerprint,
so a different content version is never collapsed by storage id alone. Data's
duplicate-key rejection and 50-key ceiling remain unchanged.
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
only by trusted compiled composition. It has no active production composition,
public transport, listener, JSON decoder, credential adapter or MCP projection;
the dormant
[MCP §16](mcp-vnext-contract.md#16-dormant-windows-startup-and-credential-handoff-composition)
startup root is the only non-fixture composition that calls this seam, and
normal startup never activates it. HOST_STABILITY_HALT remains ACTIVE; passing
offline tests proves neither transport nor OS identity security.

Construction defaults to disabled. Explicit `startOffline` checks database
readiness, completed B0 recovery and module/route readiness in order, then
validates the original ten P7 typed bindings plus the independent lifecycle READ
binding, and their READ/STAGE-only permissions.
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
the original P7 execution Context. Its routes are the original ten P7 definitions
(target list/READ Context, Question search/detail, File choices/File Context/
retrieval/passage, generated STAGE and original SubmissionKey reconciliation)
plus the independent lifecycle READ route. Unknown identities and mismatched
type bindings fail before handler entry.
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
cross-Principal/exact-Session denial, all eleven routes (the original ten plus
the lifecycle READ route), both Grant/revoke orderings,
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

The independent lifecycle metadata READ extension is governed by
[GeneratedQuestion §12](generated-question-proposals.md#12-external-proposal-lifecycle-metadata-query).
It requires current READ + proposalMetadata + both original/current bank/Project
Scope and releases only persisted lifecycle and bounded aggregate counts. It
does not enlarge the STAGE-only reconciliation acknowledgement above or grant
external Review/COMMIT. P7/P8 retain authentication, budgets and final egress.

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

**HOST_STABILITY_HALT = ACTIVE for the primary Windows host.** Transport
security acceptance and system stability acceptance must complete separately.
Experiment-associated blue screens, hard hangs or kernel-driver anomalies
immediately trigger HOST_STABILITY_HALT and stop the related dynamic experiments.
The reported AF_UNIX-associated instability on 2026-10-10 is sufficient risk
basis to stop further experiments; it does not prove a complete kernel-failure
causal chain, and acceptance must not require reproducing a blue screen.
This proves neither that TCP/mTLS must reproduce the event nor that it is safe.

Old AF_UNIX ROOT-ACL, endpoint-lease and close/unlink dynamic experiments are
permanently halted on the primary host and must not rerun automatically. Windows
updates, replacement scripts or account changes do not lift this halt. Future
real experiments follow P17's tiered G0 contract in
[Windows readiness §6](windows-host-security-readiness.md#6-future-experiment-authorization-and-environment):
G0-L0 source/compile/static/offline work requires normal scoped task authority
and no real-experiment grant; G0-L1 test-only DPAPI/CNG/NTFS/lock/replace
functions require individual user-approved batches; G0-L2 one bounded
127.0.0.1 TCP/mTLS candidate without business routes requires necessary passing
L1 evidence, independent implementation review and separate batch approval.
Each batch freezes the device/root/objects/operations/counts, source/artifact/
OS/toolchain, budgets, STOP/recovery responsibility and independent
Verifier/Reviewer. No formal data/credentials/personal files, global trust store,
system account/formal ACL changes or elevated ordinary processes are included;
no second SID or aggressive negative cases without separate authority.

L1/L2 are narrowly scoped exceptions while HALT remains ACTIVE, never inherited
authority. High-risk primary-host crash/driver/kernel reproduction remains
forbidden. Blue screen, hard hang, unexpected system mutation, object overreach,
unknown handle ownership, data corruption or resource excess immediately STOP
the batch; no primary-host blue-screen reproduction to establish causality.
Full A0–A12 and corresponding X0–X12 acceptance still requires G0-I: a separately
approved Windows environment with an independent kernel. An ordinary primary-
host VM does not automatically qualify. Local functional evidence does not
automatically pass an A item or clear system-stability acceptance.
If either complete security or stability acceptance is missing, the formal Host
remains **unpublished**. TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED. P17 permits
applications only, grants no dynamic run or Host activation and unlocks no AR-R6B.

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

### Legacy v1/v2 authentication and trusted composition

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

Offline deterministic acceptance covers all ten original P10 v1 routes, every
other name,
authentication-before-parsing, stale/cross-Profile/cross-generation/exact-Session
denial, strict malformed/duplicate/unknown/type/version/numeric boundaries,
P9 roundtrips, unchanged Question/File scopes, final egress revocation, lost
durable STAGE and original-key reconciliation, encoder failure with preserved
Proposal/derived-cache effects, cancellation/deadline/drain and replacement.
P3-P9, architecture and Built-in/MCP v0 regressions remain required. Real Host
security/stability stays UNVERIFIED: HOST_STABILITY_HALT ACTIVE, Transport
BLOCKED, AR-R6A NOT_ACCEPTED; production Host and MCP vNext remain inactive.

### Bounded vNext source composition amendment

Lifecycle version extension: the original ten business schema-v1 commands and
responses above remain unchanged. The single additional command
`external_get_proposal_lifecycle` requires integer `schemaVersion: 2`, type
`command`, and exact empty `input`. The original key is bound only by trusted
P8 `openProposalLifecycle`, never Envelope Request ID. v1 rejects this command;
v2 rejects all original v1 commands. There is no coercion or implicit fallback.
Unknown versions reject explicitly. A successfully parsed lifecycle command's
response uses schemaVersion 2, the same exact result-root keys, and exactly the
six data fields defined in GeneratedQuestion §12. Count/status consistency and
the 32 KiB metadata/P9 response budgets are hard validated. Errors after valid
command parsing also use v2; pre-command parsing/authentication errors retain
the original null-capability v1 error envelope. The legacy response pairing
remains exact; the explicit v3 extension below adds its own pairing.
No v1 STAGE/reconciliation field is extended.
This is a bounded source capability, not production P10/Host activation.

P8's internal route allowlist is consequently eleven routes: the original ten P7
typed bindings plus the independent lifecycle READ binding. P10's original ten
schema-v1 commands remain unchanged. The frozen Windows A10/X10 criterion remains
the original ten-route baseline for the not-yet-activated real-device experiment;
the additional route is a bounded source extension that neither changes that
experiment target nor authorizes it. Any future Windows acceptance that covers the
additional route must explicitly revise X10 under the existing security rules and
must not treat this source amendment as an experiment-scope expansion. P8 offline
acceptance additionally covers the lifecycle READ route; the original ten P10 v1
command acceptance remains unchanged.

The original MCP §7 source composition used these legacy versions. Its current
App/Bridge mapping uses the explicit v3 selection binding below, preserving MCP
profile v2, Submission v1 and all existing operation/result semantics. P10 itself
registers no MCP tool. The separate server remains inactive in production; its
standalone default refuses every business call. Synthetic links are test-only.

### P10 v3 trusted Context selection binding

The minimal extension is business schema v3 on the unchanged P9 `SHIP/v1`
frame. A separate App routing wire contract is unnecessary: it would duplicate
strict decoding, version and correlation rules while still needing the same P8
openings. There is no new Session, approval, permission or Proposal authority.
Only compiled App composition implements `IpcTrustedContextBinding`;
Bridge code passes opaque selections and never creates trusted Contexts.

The root remains exactly `schemaVersion` (integer 3), `type` (`command`),
`capability` and `input`. All listed input keys are required, including explicit
nullable fields. The v1 limits, duplicate/unknown-key rejection, lexical rules,
opaque-ref syntax and deep result whitelists above apply without enlargement.
The complete v3 command matrix is:

| Fixed capability | Exact input | Trusted App opening after admission |
|---|---|---|
| `external_list_targets` | `pageSize`, nullable `cursor` | `openRead(E)` |
| `external_create_read_context` | `targetRef` | `openRead(E)`; original P4 target lookup |
| `external_search_questions` | `contextRef`, `query`, `pageSize`, nullable `cursor` | `openRead(E, contextRef)` |
| `external_get_question_detail` | `contextRef`, `questionRef` | `openRead(E, contextRef)` |
| `external_list_file_selections` | `contextRef` | `openRead(E, contextRef)` |
| `external_create_file_context` | `contextRef`, `fileRefs` | `openRead(E, contextRef)` |
| `external_retrieve_file_content` | `contextRef`, `query`, `limit` | `openRead(E, contextRef)` |
| `external_get_file_passage` | `contextRef`, `passageRef`, nullable `cursor` | `openRead(E, contextRef)` |
| `external_stage_generated_questions` | `contextRef`, `submissionJson`, nullable `externalRequestId` | Conditional existing approval, or explicit first-party wait below; original `openStage(E, approval)` |
| `external_reconcile_generated_stage` | `submissionKey` only | `openReconciliation(E, originalKey)`; internal, STAGE-only |
| `external_get_proposal_lifecycle` | `submissionKey` only | `openProposalLifecycle(E, originalKey)`; independent READ/metadata |

`contextRef` is a non-null 43-character opaque reference. `submissionKey` is a
non-null original key matching `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`. Other fields
retain the exact v1 bounds above. A key is selection input, not authentication,
approval or execution Context. P9 Request ID remains correlation only.

TLS/P15/P0 authenticates Session S. P10 calls original P8 `bindSession(S)` to
create entry E BEFORE strict business parsing. Only then does it pass the decoded
typed selection, S, E and owning control to the compiled App binder. The binder
uses the openings in the table; the resulting fresh execution Context and the
SAME E enter original P8/P7 dispatch. Authentication is revalidated after binding
and may return only identical S or null. A different Session is rejected, even
for the same Principal. P8/P7 retain exact Session/revision/Scope, lifecycle and
final egress checks; a supplied string never becomes an execution Context.

P4 READ handles retain their original Principal, runtime-generation, revision,
expiry and reference-kind checks. A fresh valid Session B of the same Principal
and effective running generation can revalidate a handle made under Session A.
Every call still creates a new execution Context bound to its own Session.
Wrong kind, different Principal, old generation, changed/revoked Grant or expired
handle rejects. QuestionRef, FileRef, PassageRef and cursor ownership, F1 source
verification and current scopes remain the original P4/P5/P6 responsibilities.

STAGE selection first resolves the original READ target, then selects an existing
App approval matching identical S, current authorization revision and exact
bank/nullable Project/Folder. P8/P3 validate the original StageContext and current
STAGE/Scope/Egress. The ordinary binder never calls `approveTarget`; READ and File
selection never become approval or evidence consent. Windows TLS independently
authenticates each connection and permits at most ONE request; another connection
cannot reuse approval. The default Bridge still refuses `propose_generated_questions`
before Submission serialization and sending, even with an App approval. Only the
explicit source-only waiting profile below permits a new same-Session UI approval.
Real Windows transport/security admission remains BLOCKED.

Proposal lifecycle opening needs no old READ handle or STAGE authority. The
original key reaches P8 and the existing GeneratedQuestion §12 Data owner under
fresh READ/proposalMetadata and BOTH original/current target scopes. Internal
reconciliation remains a distinct STAGE-only historical acknowledgement. P3's
original-key idempotency/conflict and durable recovery are unchanged; unknown
STAGE is never automatically repeated.

Version selection is explicit, without negotiation or fallback. The legacy
supplied-Context entry accepts exactly v1's ten commands and v2's lifecycle
command; it rejects v3. `invokeV3` accepts only v3 and rejects v1/v2. The TLS Host
requires exactly one of the legacy Context supplier or the App v3 binder, for
the same Host. Normal startup installs neither new route nor transport. A client
must explicitly choose v3 and rejects any old-version success; it never resends
under v1/v2. Unknown versions reject. Valid v3 command responses, including
binding/dispatch errors, use version 3 and the unchanged exact result root/data.
Pre-command/authentication errors retain the null-capability v1 failure envelope;
that is accepted only as failure. Bridge checks P9 ID, command, exact v3 version,
deep result shape and applicable original key. Mismatches withhold all data.
MCP v0's six tools, vNext's seven schemas/profileVersion 2 and Submission v1 are
unchanged and independently versioned.

READ binding and dispatch share the original at-most-two-second deadline (or a
shorter caller deadline); binding never renews it. Cancellation, timeout,
disconnect or caller withdrawal prevents release. Projection drain includes
pending authentication/binding and then original P8/P7 owning settlement, even
if caller completion came first. TLS keeps its existing single-request, socket,
handshake, pipeline and buffer limits; the explicit STAGE-only timing exception
below does not renew READ deadlines. Uncertain cleanup retains its
resources. App close/Restore invalidates old Session/Context/approval custody and
waits owners before database replacement. Reconnect authenticates independently;
regrant/re-enable never revives old handles/approvals. Restart/Restore requires
fresh composition and original-key query for durable Proposal recovery. Response
or encoding loss never changes committed effects, invents rollback or permits
automatic STAGE retry; missing lifecycle data is not proof that pending work
cannot still publish.

The bounded implementation uses the existing P10 parser/projection, App
composition, TLS Host injection and shared seven-tool mapping. No P0/P15 model,
P9 frame, writer or database schema changes. Standing P10, TLS and MCP tests
cover the strict version matrix, fresh Session READ revalidation, independent
metadata lookup, synthetic same-Session approval/isolation, real F1/FTS/SQLite
through Fake TLS, zero-send/zero-serialization Bridge STAGE, interruption/drain
and original-key recovery. Existing P3/P7/P8/P9, stdio modern/legacy, MCP v0 and
isolated Windows Codex regressions remain required; Fake TLS proves source
integration only. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED. No production Listener/credentials/DPAPI/ACL/App/Bridge,
Trial 1A or G0-L1/L2/I activation follows from this source implementation.

### P10 opt-in first-party STAGE wait

Issue #324's two explicitly user-approved contract exceptions are limited to
(1) an independent bounded human waiting phase in the ORIGINAL authenticated
Session, and (2) one bounded pre-approval Submission encoding/send/retention when
explicitly enabled. `enableStageApprovalWait` defaults false independently in
App composition, TLS Host and Bridge. No normal startup installs or enables it.
The Host requires the same App/P8 owner and its trusted approval binding.
No wire field, tool argument, READ handle or existing approval enables this mode.

After P15/P0 authentication and P8 entry E, P10 strictly parses the bounded v3
envelope and retains the immutable `submissionJson`. It does not parse candidate
content or enter the STAGE handler. One Application-owned request binds identical
Session S, E, effective runtime generation, original current Grant revision R,
exact bank/nullable Project/Folder (including Project bank snapshot), and this
Submission. Preparation revalidates the original READ selection AND independently
checks P3 STAGE/Scope/Egress against an App-minted local Review target. That READ
selection supplies no STAGE permission or evidence consent. The current
FirstPartyExternalAccess UI view displays this target and accepts one explicit
user approve/reject action. A local view object is never a wire approval ticket.
Confirmation revalidates authentication, identical S/E, R, generation, enablement,
current target and caller availability before and after calling original P3
`approveTarget(S, target, [])` and P8 `openStage(E, approved)`. P8/P7/P3 and the
owning publication transaction keep every existing check; no COMMIT is granted.

| Phase | Fixed bound / accounting |
|---|---|
| Request upload/assembly | Existing 2-second no-progress and 10-second total, unchanged. |
| App preparation after complete frame | At most 2 seconds; no human deadline renewal by slow policy queries. |
| Human wait after successful preparation | Default AND maximum 120 seconds, monotonic; no extension/queue. At most one request per App generation across all connections. |
| Confirmation/rejection through completion | At most 10 seconds after the UI claims approval; rejection ends waiting immediately. Expiry requests cancellation/close, not fictitious resource release. |
| Opt-in Bridge final response + EOF | At most 132 seconds from complete upload (2 + 120 + 10); at most 142 seconds for the entire exchange. After the first response byte, 2-second no-progress/10-second response-frame limits also apply within that outer bound. |

P9 remains one `SHIP/v1` request, ONE final response and EOF; there is no approval
frame, heartbeat, second request or version negotiation. Therefore the Bridge
cannot observe the exact App phase boundary: only this explicit STAGE profile
allows bounded response silence beyond ordinary 2/10 seconds. Ordinary READ and
legacy request deadlines remain unchanged. A shorter caller/MCP timeout always
wins; compatible callers need an explicit tool timeout above 142 seconds.

Before encoding, the Bridge checks the existing 1 MiB UTF-8 JSON Submission,
depth 16 and 50-item bounds (including escaping and JSON-only values), then
reserves the existing pipeline/protocol/string budgets before its single lazy
encoding/frame send. P9/P10 sizes and the Host's lexical/container admission
remain unchanged. App retains only bounded raw text before approval, not a
candidate graph, publication or upgraded authorization. Global ceilings remain
8 sockets / 2 handshakes / 2 pipelines / 16 MiB protocol / 32 MiB strings /
512 KiB output. The approval slot and reservations survive caller completion
until actual validation/business/I/O settlement AND acknowledged close. Failed
cleanup poisons admission and keeps uncertain resources; it never admits a new
waiter. Waiting holds no SQLite transaction or B0 mutation lease across user input.

Cancel, reject, expiry, caller withdrawal, disconnect/extra request bytes,
revocation, ANY Grant revision change, target drift, finite-enable expiry,
view replacement/close, App close or Restore invalidate the request. Pending
policy/confirmation work is drained; late input cannot resurrect it. While
waiting, bounded serialized revalidation observes policy/target changes at most
once per second with one in-flight check; confirmation always rechecks directly.
The Host observes EOF/trailing input with one bounded read, writes its final
response without awaiting that read, closes its own channel, THEN joins the
observer. It never waits for peer EOF before sending the response. Before handler
entry these paths execute no STAGE. After entry, existing unknown-effect and
publication/revoke ordering rules apply unchanged: reconcile only the original
submissionKey with fresh authorization; never repeat STAGE or infer rollback.
Close/Restore drains this owner before database replacement. No persistent
approval table, restart recovery, cross-Session inheritance or automatic approval
is introduced. Fake TLS + Widget + SQLite tests in the existing standing TLS suite
cover this source-only profile; production security gates remain unchanged.

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
candidate ceiling.
MCP §17.12's separately authorized normal Windows App-owned development
composition explicitly supplies an eight-hour ceiling and guided default. Its
first-party Enable passes the absolute deployment deadline through the same
coordinator to P0. P0 clamps its expiry at the original state transition, after
policy reads, so a delayed read cannot renew that ceiling; an elapsed ceiling
rejects. The page shows that actual deadline. Other compositions keep the thirty-minute
default; no automatic renewal, persisted Enable or revived Session/approval is
introduced. Identity-proof and STAGE confirmation windows are unchanged.
Authentication requires that selected Profile's Principal;
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

The bounded first-party App integration under [MCP contract §9](mcp-vnext-contract.md#9-first-party-app-composition-and-controls)
adds a dormant production owner and local control panel beside the P11 editor.
It does not change those startup prohibitions or P0/P12 authority: only an
explicit trusted composition can attach the existing P0 and P12/P8 services.
First-party controls reauthenticate before finite enablement/target approval,
then use P3 `approveTarget`; no READ-to-STAGE upgrade exists. The existing
database close authority awaits this owner before Restore/rollback/rebuild,
and replacement is disabled. Real pairing/credential/transport integration
remains inactive; synthetic tests are not a production binding. The original
P11 notice describes policy editing and proves no current connection status.

The source-only extension in MCP contract §10 adds an explicit P15-backed branch
to that dormant owner. It creates the same P0/P12 graph against its management
owner, retains only existing request/Session custody, and delegates independent
pairing and Authentication verification to P15. The original §9 branch still
authenticates before enablement; the credential branch requires P0 paired state,
then finite enablement and independent P15-authenticated connection admission,
disabling on any failure before exposing business access. The original channel
must revalidate and return the identical Session on every control/Port use.
Profile/Grant selection cannot pair; missing Grant does not prevent pairing but
denies business admission. UI request/confirmation/proof controls remain
unavailable without explicitly supplied admitted services. P27's inactive
first-party adapter keeps all cryptographic/E0/CAS/comparison and Bridge Pin
rules below unchanged. Normal startup supplies none of these services, and real
Windows/Bridge/channel acceptance remains pending. No security exception follows.

## 11. P13 Windows security readiness (accepted static readiness)

[Windows Host security readiness](windows-host-security-readiness.md) owns the
production gap/dependency matrix, static TCP/mTLS versus Named Pipe screening,
CredentialPort mapping proposal, isolated experiment authorization checklist and
real PASS/FAIL/fallback criteria. It distinguishes existing offline proof,
official API support, real Windows evidence still missing and unsupported
promises. It supplies no credential implementation, listener or production wiring.
P13 is accepted as a static readiness checkpoint through merged PR #264. P14
(auxiliary CI-engineering sub-stage) makes the External offline Application/IPC/
origin regression matrix standing coverage in the PR contract shards; it adds
offline Linux evidence only and clears no WINDOWS_PENDING item.

At P13, an approved environment independent of the primary host's kernel, exact bounded
scope/resources and new explicit user experiment authority are not established
by this checkpoint; dynamic admission is BLOCKED. P17's section 6 tier amendment
permits separately approved L1/L2 functional subsets; complete acceptance keeps
the independent-kernel G0-I requirement. Ordinary primary-host VMs,
synthetic tests and design approval cannot clear the security/stability gates.
Sections 2/5/6 retain B-class isolation, same-SID proxy risk, protected credentials/
Discovery and the permanent halt on primary-host AF_UNIX experiments. If a hard
property cannot be proved, keep Host closed; no authentication fallback or silent
change to P0/P4/Grant semantics. HOST_STABILITY_HALT = ACTIVE;
TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED; AR-R6B remains inactive.

P18/P19 supply bounded, inactive native Infrastructure under readiness §§10–11:
one Windows helper with user-scope DPAPI, parent-handle-relative protected-object
creation/inspection and `runtime.lock`/`bridge\client.lock` OS exclusion, plus
explicit Dart FFI owners. ABI 2 extends the existing helper; it creates no second
Credential Store or Principal and changes no section 12 association semantics.
No store, issuer, Discovery publisher or P12/P15/Host composition is supplied.
Native compile and fake-only checks are G0-L0; real ACL/NTFS/lock behavior remains
LOCAL-L1 PENDING and full cross-SID/system acceptance remains G0-I. Existing
HALT/Transport/AR-R6A states are unchanged.

## 12. P15 External credential boundary (offline implementation candidate)

P14 is accepted through merged [PR #265](https://github.com/duanzhijian200443/shiroha_quiz/pull/265).
Its 273 standing files and complete External coverage remain hard-failing;
P15 extends existing standing tests without changing that list or its shards.
The following minimal contract is reviewed before P15 implementation. It owns
OS-independent association and verified-attempt rules only, not a certificate
profile, secure-store format, Windows adapter or production activation.

Profile identity and Credential Identity are separate. The latter is an opaque
association identifier, not a claimed Profile, name, PID, brand or process.
Verified leaf DER SHA-256 remains a future candidate: a digest alone proves
neither chain/role/validity nor private-key possession. Pairing possession and
channel authentication are distinct verification events. App owns protected
association authority; Bridge owns its future client key. P0 remains the sole
Principal/PairingState/Session authority; P1/P4/P7/P8 retain all current policy.

The dedicated association port reads by locally selected Profile and atomically
registers/revokes one association with an expected revision. Missing is null;
corrupt and temporarily unavailable are distinct fixed failures, with no repair
or fallback. Revision zero means never registered; committed revocations retain
monotonic tombstones. CAS precedes idempotency: identical current registration
with the exact revision is unchanged, but stale requests never overwrite it.
One active Credential cannot belong to two Profiles, and an active Profile cannot
silently replace its Credential. Replacement requires explicit revoke, fresh
composition and fresh local approval/proof; there is no rotation convenience API.
The backend enforces integrity, uniqueness, management validation at its commit
boundary and bounded current snapshots. A snapshot's validity is monotonic:
change, unavailable/corrupt state or backend invalidation permanently kills it.
Future backends unable to guarantee this contract cannot be wired into the port.

The boundary is compiled trusted offline composition only. Local request and
approval delegate to P12 using its opaque Profile reference. A private challenge
binds original request, selected Profile, installation, exact runtime instance/generation,
expected Credential, expected association revision and finite deadline. A trusted
injected verifier performs asynchronous verification and checks event/channel
liveness; no accepting verifier is supplied in production. Its boolean decision
is authority only because composition owns that verifier, never because a wire
DTO says verified. Pairing and authentication use separate methods. Tests alone
provide synthetic verifiers, never actual crypto acceptance.

No public constructor or method creates accepted verification evidence. Only
successful verification, fresh management/store checks and a live snapshot open
one private bounded P0 call window; externally constructed P0 evidence, strings,
fingerprints and JSON fail the synchronous port. Attempts are one-use, owner-
bound and finite; disconnect, generation change and snapshot invalidation deny
consumption. P12/P4 reload the selected Profile before returning a Session;
Grant revocation and egress still use existing per-call/final-release checks.
Offline limits default to thirty seconds per challenge, sixteen pending operations/local
requests and 1024 verified event identities per boundary lifetime. Slots remain
owned through actual settlement; reaching a limit denies admission. These are
bounded offline candidates, not measured Windows transport/security capacity.

Registration has one durable commit point in the association backend, followed
by P12's existing P0 proof completion. There is no cross-store atomicity claim,
new SQLite transaction or Profile/Grant write. Failure before commit leaves P0
pending proof; uncertain commit or post-commit failure never reports paired.
An association residue alone is non-authorizing; missing P0 completion requires
fresh explicit recovery/proof. Actual P0 proof completion remains P0-owned:
losing its acknowledgement does not undo pairing or grant Enablement. Do not
auto-compensate by overwriting a possibly newer record. Evidence is discarded on
every exit. Registration adds neither Grant nor Enablement.

After validating current local management, association revocation closes evidence/
admission and delegates P8/P12 owning drain/generation invalidation before the backend revoke CAS. A failed
revoke keeps that runtime closed and reports failure, not durable success. No
historical STAGE effect is rolled back. Shutdown also drains pending verification
and association work before runtime replacement. Disconnect does not invent a
P0 per-Session revoke operation. Restart reads no association automatically;
replacement is unpaired/disabled and requires fresh proof, binding and enablement.

MCP §17.12's separately authorized development residual-recovery entry exposes
this SAME local revocation through an optional first-party Application port.
It binds a one-use comparison view to the selected opaque management reference,
original association snapshot and exact identity/installation/revision, rechecks
before dispatch and calls the original owned Host/P15 revoke path. No MCP route,
direct UI Store write, new Grant/Enable authority or P0 reset is added. The
original Host response and subsequent runtime close remain separate observations;
the first-party idle slot is released before full close is joined, and expected
terminal invalidation cannot turn acknowledged success into failure. Readiness
§9.C.8 owns the explicit fresh-runtime/revoke-first/new-P27 conditions; partial,
corrupt and unknown objects remain refusals.
Portable B0 excludes credentials/associations; Restore and raw rollback require
the existing close/drain and fresh trusted recovery, never Session resurrection.
Orphan associations after portable Restore stay untouched/non-authorizing.
Their cleanup or reassignment requires a separately approved recovery contract;
P15 cannot invent a missing Profile to reclaim a surviving credential.

For the explicitly authorized normal development mode in MCP §17.12, Windows
readiness §9.C.8 additionally permits **fresh first-party confirmation of an
existing credential for this runtime**. This is an explicit new P15 evidence
purpose, not automatic restart hydration, P27 re-enrollment or Authentication
evidence relabeled as Pairing. The original Host/channel verifier owns one live
mTLS candidate for a locally selected opaque Profile; P15 owns its one-use
private evidence and original P0 remains the only state machine. No Session or
P8 entry exists while confirmation is pending, and the proof channel never
parses or dispatches P9/P10 business input.

The candidate slot is occupied before asynchronous validation. Bind original
channel, exact credential/installation, association snapshot/revision, Profile
grant revision, runtime/generation and both clocks. Keep the original thirty-
second maximum. Only the user's exact local decision may finish the proof;
confirmation rechecks current management, association and original snapshot,
liveness, expiry and composition before and after the private P0 window. The
original request -> approve -> complete sequence reaches `pairedDisabled`;
the association completion branch is read-only and cannot call `register()`.
Waiting/denial must not advance P0; failure after entering original pending
states cannot silently reset them. No accepting/default verifier is added.

The decision Future and original connection-done Future have different owners:
P15 settles the decision and its verification work; Host closes the channel and
resources before connection-done; the first-party operation joins both without
placing Host.done inside P15's pending-work drain. Cancellation, page closure,
revocation, observed disconnect and expiry invalidate the candidate immediately;
slot release waits for actual work and original transport settlement. Unknown
cleanup remains a failure. UI projections expose safe comparison data only.

No key, certificate, association or Pin is created/replaced by confirmation.
Only the separately authorized original P26 high-water update remains possible
when connecting. Identity confirmation may be Grantless but requires an intact,
non-revoked Profile and its exact active association. No Profile/Grant is
supplied, and B0-scrubbed or orphan records still refuse.
After proof-channel settlement, independent finite Enable and a fresh business
authentication are required. The App-owned binding checks the selected Profile,
live P0 Enable and the revision frozen at Enable on every business channel,
without relying on UI polling or caching an old Session. Per-tool channel end
does not revoke that finite Enable; outer adapter loss withdraws Enable and old
STAGE/target approval. Existing default bindings retain their own behavior.
Initial P27, durable Proposal, original-key lifecycle lookup and local COMMIT
authority remain unchanged. This adds no persistent authority or second P0.

P15 supplies no Windows storage/crypto implementation or production wiring.
The later P20 Data candidate implements this same association port, with its
production source and activation boundary owned by Windows readiness §12.
It introduces no P0–P15 authorization change or runtime composition.
P24's inactive Exchange file-I/O candidate is owned by Windows readiness §16.
Its fixed-kind/ID Native access, P22-decoded public DTOs and creator-only cleanup
receipts supply no verification evidence, pairing transition, consumption order
or association commit. P0/P15 remain the only owners of those decisions.
P27-E0 extends this inactive infrastructure with strict-P22 controlled reads
and explicit owner-bound one-use Consume/Release capabilities (readiness §16).
Native binds the exact original bytes and retained object identity; deleting a
file supplies neither P15 evidence nor user approval, possession, Association
commit or Pairing completion. E0 implements no D0 sequencing or P27-I0 workflow.
P25's inactive credential initialization and restricted Client leaf issuer are
owned by Windows readiness §17. An issued leaf and its exact-DER digest remain
public correlation material: neither proves Client possession nor creates a
Principal, PairingProof, Session, Association, Grant or Enablement. No active
production consumer called this infrastructure in the original P25 slice; its
dormant exception was the
[MCP §16](mcp-vnext-contract.md#16-dormant-windows-startup-and-credential-handoff-composition)
startup root, which activates no acquisition, Listener, transport or normal
startup. Its dormant [MCP §17 acquisition adapter](mcp-vnext-contract.md#17-dormant-protected-acquisition-and-child-process-custody)
reuses existing-only P25 validation and the same P24/P27 owners. Those historical
slices supplied no normal startup consumer or new authentication/Writer authority.
The later explicitly admitted Debug consumer and first-party initial P25/P27
setup are bounded by MCP §17.12 and readiness §§6/8/9.F; they preserve the same
authentication and Writer owners.
P26's inactive Discovery Publisher/Reader is owned by Windows readiness §18.
Fixed Native object access and same-ticket epoch/high-water persistence use
P19/P23/P25; P22 still owns the descriptor and independent trusted inputs.
Discovery data supplies no P15 evidence, Pairing, Session or connection
authority. P26 itself introduced no initial Pin or production consumer; the
original later consumer was the dormant
[MCP §16](mcp-vnext-contract.md#16-dormant-windows-startup-and-credential-handoff-composition)
startup root, which did not activate acquisition, publication or a normal
startup. The separately admitted Debug consumer in MCP §17.12 now uses those
same owners; it adds no Discovery-derived identity or automatic Pin creation.

P27-D0 freezes only the bounded bootstrap decisions in Windows readiness
§9.C.5/§9.C.8/§9.D; it does not implement or activate P27. First trust requires
an explicit trusted App public-material export and independent full-digest
comparison on the Bridge, with no automatic TOFU or Discovery-selected anchor.
App binds the initial digest to exact P22 Challenge bytes whose P24 creation
AND identity-bound Submission counterpart consumption both succeeded; Bridge
uses the original safely read, strictly decoded bytes, never a reconstructed
DTO. Failed/unknown Submission consumption blocks App display and further
Approval/Proof processing; an existing P15 request is not silently reset. Imported public inputs and comparison digests remain
non-authorizing. Initial manual comparison must finish within the live Challenge;
P27's concrete deadline cannot exceed 600 seconds, and extending the current
30-second request requires matching P15 binding and regression changes. The
post-verification private Evidence Window remains 30 seconds.

Initial Bridge kind 4 persistence is ordered after confirmed Association CAS
and P0 completion, followed by a separate trusted local two-surface manual
completion check. Before displaying it, App freshly validates the actual
persisted Association, exact identity, current management/runtime/generation
and P0 `pairedDisabled`. The displayed committed Revision comes from that
current record, not `expectedRevision + 1`. Bridge has no authenticated
post-display signal of App invalidation; App withdraws invalidated displays,
but cannot guarantee the Bridge observes withdrawal. The completion digest defined in
§9.C.5 binds the original initial-trust digest, actual Revision and confirmed
completion status. Bridge must retain the same in-memory Enrollment/key and
require explicit manual confirmation before one Missing-only protected-store
attempt. The Bridge's local monotonic, single-use confirmation window expires
no later than 120 seconds after successful Proof publication, and cannot be
renewed or used after Enrollment invalidation. That bound neither extends the
Challenge deadline nor P15's 30-second Evidence Window. No fourth Exchange
message, listener, implicit ACK, signed receipt or new authorization system is
introduced; neither digest is P15 evidence or a continuous authorization
credential. App-side invalidation after a valid display may not reach Bridge;
kind 4 persistence never provides authorization and current Application checks
remain mandatory. Current P15 private evidence production,
CAS/idempotency, P0 state ownership and separate Enablement remain unchanged.

Unknown CAS, P0 failure or lost completion acknowledgement supplies no manual
completion confirmation and cannot authorize kind 4. Bridge save failure,
unknown commit or resource-release failure never triggers an automatic retry;
existing valid credentials, corruption and Pin conflicts are not overwritten.
If App completed but Bridge exits before persistence, its unpersisted key is
lost and an unusable Association may remain. This availability cost is accepted:
no Association residue, manual digest or stored credential restores Paired,
Sessions or Enablement. Later explicit protected reads establish storage facts
only. Recovery uses the existing trusted fresh-runtime/standard-Pairing flow,
including revoke-first when a new credential replaces an active Association.
The readiness failure matrix owns each interruption boundary; no cross-process
atomicity, new cancel/reset API, background recovery or implementation authority
is inferred from this documentation amendment.

M1–M4 real security remain WINDOWS_PENDING; G0 and X0–X12 are unapproved and
not run. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED. No Codex process-brand authentication is claimed.

P27-I0 supplies the inactive Package 1 integration candidate described in Windows
readiness §19. `WindowsAppPairing`/`WindowsBridgePairing` provide explicit local
actions and safe display projections, with no production UI or Bridge process.
`WindowsPairingVerification` implements this existing P15 port using exact local
request correlation, actual injected P21 ECDSA primitives and original E0 Proof
consumption; Authentication always rejects. Decoded DTOs, displays and imported
digests still cannot produce P0 evidence. P15 exposes only read-only local
challenge correlation, a current-request guard and freshly confirmed persisted
Pairing facts; none is an authorization factory. Its trusted constructor may
select `0 < pairingRequestLifetime <= 600 seconds`; default Request lifetime
remains 30 seconds, with monotonic expiry and no revival after observed expiry.
The verifier independently enforces the original 30-second Evidence Window.
After acknowledged completion, `confirmedPairing` re-reads actual Association
Revision/current management and checks the same runtime and P0 `pairedDisabled`.
Only a refreshed App projection can support the independent completion action.
Package 1 SOURCE IMPLEMENTED / OFFLINE TESTED is a source-candidate boundary,
not Windows or real-process acceptance. REAL WINDOWS PENDING / FORMAL ACCEPTANCE
PENDING and all production activation gates remain unchanged.

Package 2's inactive transport source candidate is owned by Windows readiness
section 20. P20 optionally implements `ExternalCredentialIdentityLookup` by
re-reading the SAME strict protected association object, requiring a unique
active exact leaf-DER SHA-256 identity and returning its existing monotonic
snapshot. It creates no identity registry or new persistence. Only after TLS,
independent crypt32 peer-role policy and mathematical certificate checks may
that protected result select a local Management reference for P15. No CN,
display string or request field selects a Profile. P15 `openSession`, P0/P12
Enablement and P8/P7 current Grant/Context/Egress remain mandatory.
`WindowsChannelVerification` delegates Pairing unchanged to P27 and uses
different private, one-use connection-bound Authentication events. Close,
expiry, Disable, runtime replacement, Association invalidation and observed
Management revision changes latch those channel bindings invalid. They never
create Principal/PairingState/Grant authority or reuse a Pairing Proof.

The P8/P10 `whenSettled` barriers are read-only: they observe existing Gateway,
READ Registry, STAGE and Host owning work without closing, cancelling, retrying
or expanding authorization. Transport retains reservations until those owners
and response writing/failed close settle. P9 framing and P10's ten commands,
Schema Version 1, trusted Context construction and original SubmissionKey
reconciliation are unchanged. A separate pre-JSON allocation admission bounds
container/key-scanner work; it grants no schema validity or permission. Real
business channels, G0-L1/L2/G0-I, Package 3 and production activation are not
authorized by these source additions.

Package 3's inactive extension is owned by Windows readiness §21.
`WindowsTlsHost.owned` retains lifecycle and Store/lock custody inside the
existing transport Host, with read-only exact-composition identity checks.
It reuses P8 readiness, P26TlsStartup and P27/P15/P12 shutdown/drain rather than
adding another startup, PairingState, Session registry or business owner.
Only confirmed full settlement releases the Owner/runtime.lock; uncertain
cleanup stays closed with custody retained. Explicit local revoke delegates
P15's current-management/evidence-close/drain/Association-CAS order before
Store/Owner release, and failed CAS never revives the runtime.

Disconnect permanently invalidates its own Channel attempt; it does not claim
P0 per-Session revocation. Already-started STAGE retains P3 effect/settlement
and reconciles through a new trusted Session with its original SubmissionKey.
Restore/raw rollback still require old-runtime drain and fresh unpaired/
disabled composition. P26 residues remain inert and untouched because no
identity-bound Discovery delete API exists. No path deletion or silent trust
repair compensates for that limitation. Static package/Native/AOT-source checks
and the disabled Bridge entry prove no real packaged behavior. SOURCE
IMPLEMENTED / OFFLINE TESTED never means accepted/activated; all A/X real
Windows and formal acceptance gates remain pending.

## 13. P16 production primitive freeze (accepted static decision; PR #267)

P16 freezes the minimal production candidates that will have to satisfy
section 12's contract, owned by
[Windows security readiness](windows-host-security-readiness.md) section 9:
one local installation issuer plus server/client leaf roles (ECDSA
P-256/SHA-256, X.509 v3 profile with role EKU and exact-leaf-DER-SHA-256
identity, TLS 1.3 floor), a single dedicated DPAPI-wrapped External object
store with versioned binary formats and P15-compatible CAS, tombstone and
snapshot semantics, the cryptographic pairing possession proof (32-byte
nonce, fixed signed transcript, ECDSA signature, file-mediated exchange with
no listener and no P9/P10 change), and the owner-only NTFS Discovery root with
handle-verified publication and cleanup.

It selects candidates only: it changes no P0/P4/P7/P8 or P15 authorization
semantic, adds no production wiring, dependency or schema, and closes no
WINDOWS_PENDING item. Real acceptance requires G0 and the per-package
experiment grants. P17's section 6 / readiness §9.F amendment limits
BLOCKED_ON_G0 to real experiment/acceptance gates, not scoped L0 implementation.
Readiness §9.A.2 corrects X.509 signatures to ASN.1 DER ECDSA-Sig-Value while
Pairing Proof and Endpoint Descriptor retain fixed raw r‖s (64 bytes), with
ECDSA P-256/SHA-256 and exact leaf-DER credentialIdentity unchanged. P0
Pairing/Session authority, P1/P11 durable policy, P7/P8 current checks, S0
Provider credentials and the B-class isolation model (including the accepted
same-SID proxy risk) are unchanged. HOST_STABILITY_HALT = ACTIVE;
TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED; AR-R6B remains inactive.
