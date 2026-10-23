# MCP vNext Local Generation Profile

Status: **FROZEN target capability surface; not implemented by AR-R0.**

Authority/activation: [index](README.md). Owns MCP projections/protocol and
reference-package boundary, not business identity, authorization or commit.
Full wire schemas/version identifiers are frozen in AR-R6B before exposure.

## 1. Local Tools-only profile

External Client -> stdio MCP bridge -> authenticated local IPC -> App Host ->
Application. Identity/context/egress rules are owned by
[external-agent-boundary.md](external-agent-boundary.md). Bridge has no database,
repository, migrations or alternate App writer.

| Tool | Minimum input intent | Safe output / permission |
|---|---|---|
| open_generation_context | Optional server-minted target reference | Without target: bounded/paged authorized target metadata; with target: opaque handle and approved evidence references; READ |
| search_questions | context handle, bounded search/cursor | Context-scoped question projection; READ |
| get_question_detail | context handle, server-returned question reference | Authorized typed question projection; READ |
| retrieve_file_content | context handle, bounded lexical query | Verified current RAG snippets/evidence; READ with permitted derived cache |
| get_file_passage | context handle, returned evidence reference/cursor | Bounded verified parsed passages and coverage/exclusion metadata; READ |
| propose_generated_questions | context handle, submission key, typed candidates | Durable Proposal identity/count/receipt, explicitly staged not committed; STAGE |
| get_question_proposal | Proposal reference or submission key | Currently authorized lifecycle/count/safe receipt, without needing old handle; READ |

Generation targets are selected in Shiroha pairing; no extra list_learning_spaces
is needed. get_question_draft/list_pending_proposals are excluded from MVP;
external clients do not edit the local review copy and can reconcile by key.
No W0/SPL external staging, commit, delete, OCR activation or arbitrary file path.

P4 is accepted in merged PR #251; P5's accepted unpublished Application-only
Question READ foundation under external-agent-boundary §3. Future search/detail
projections must carry its Context-bound QuestionRefs/cursors, current READ +
questionContent + exact Scope and final release checks, never raw storage ids or
MCP v0's unscoped entry. P5 (merged PR #253) publishes no tools or wire schema;
its original File/Evidence snapshots remain empty. P6's unpublished Application
candidate creates separate explicit File Contexts and bounded lexical/passage
reads using current READ + fileContent + exact File/Project scope, current F1
generation and final release checks. Future projections must carry its random
File selection/Passage/cursor references, safe coverage/exclusion metadata and
real derived-cache execution evidence; no raw IDs or request-supplied scope.
No new tool or wire schema is published. That focused external contract §3 owns
the candidate interfaces, budgets and lifecycle semantics.

P8 adds only an offline trusted Host dispatch/startup/drain seam under that
external contract. It creates no MCP projection, stdio bridge, protocol JSON
decoder, transport or public tool. Future adapters must obtain authenticated
Sessions from the trusted credential authority, never from request metadata.

P9 freezes only an unpublished internal IPC envelope v1 under external boundary
§7. It is independent of MCP protocol and Submission schema versions, and does
not parse Tool Schema, publish a client protocol, register tools or establish
authentication. Its opaque text must pass future adapter schema and independent
trusted authentication/authorization before any P8 call.

P10's unpublished offline business schema v1 is owned by external boundary §8.
It is independent of this MCP profile and P9/Submission versions. Trusted test
composition supplies authentication and P8 execution Contexts, with ten explicit
typed mappings and safe response whitelists. It registers no MCP tool, stdio
bridge or production Host/transport; AR-R6B remains inactive.

Both retrieval and passage read current verified SourceDocument through
Application. No raw managed originals, URLs, binaries, diagnostics or unsafe
fallback content. source_not_ready instructs parsing in App rather than invoking
OCR. Page/cursor output distinguishes remaining content and excluded structure;
search hits are not evidence of complete document reading.

Projections perform shape/schema parsing and encoding. Application validates
typed semantics, authorization, scope and egress. Validate structured result
against its declared schema; output encoding failure preserves known receipt.
Object-shaped structured output with safe compatible text supports legacy
clients; never pass repository maps. Business/tool failure and JSON-RPC protocol
error remain distinct. Safe errors include unavailable/busy/unauthorized/stale,
invalid submission/idempotency conflict and known or unknown execution outcome.
No raw exception/body or existence leak.

## 2. v0 coexistence and protocol versions

[MCP v0](../../architecture/mcp-v0-contract.md) retains exactly six READ_ONLY
tools, existing envelopes and independent entrypoint. vNext is a separate
profile/entrypoint; it is not a seventh v0 tool, v0 authentication retrofit or
authority to mutate. `mcp_dart` stays under `lib/mcp/**`; no SDK/dependency change
is authorized by this checkpoint.

Version MCP wire, Shiroha profile, submission schema and IPC envelope separately.
Use the pinned SDK's compatibility support rather than implementing Provider/
MCP versions in the business layer. Unknown versions fail explicitly. AR-R6B
tests actual supported modern and legacy protocol behavior, not only direct
callback invocation.

Official protocol reference verified during design is 2026-07-28: stateless
per-request metadata/server discovery, explicit handles and Tasks extension.
This observation does not freeze SDK behavior forever or claim every installed
client supports that revision. Recheck official SDK/protocol at implementation;
any upgrade requires a separately reviewed compatibility change.

Tools list is deterministic for the same configured profile/modules, not changed
per open context. Definition visibility is not authorization. READ annotations
are hints; STAGE is not read-only and idempotent is asserted only when the
business contract supports it. Annotations never grant COMMIT.

## 3. Lifecycle, progress and cancellation

Map request cancellation/deadline through IPC to Application. READ cancellation
stops unreleased content where possible. STAGE past durable commit returns or
reconciles its receipt; disconnect/timeout cannot imply undo or zero effect.
Report fixed progress stage/counts only, without query/candidate/source content.

App absence/restart/restore/revoke follows external boundary; never open SQLite
as fallback. stdout is exclusively protocol framing; safe logs use stderr.
No MCP logging/raw-body export is introduced. Protocol request id is not durable
submission identity. Each in-flight unknown STAGE is reconciled by its key.

## 4. Complete workflow

```mermaid
sequenceDiagram
    actor User
    participant Client as Any external Agent
    participant Bridge as MCP bridge
    participant App as Host / Application
    participant Data as Data transaction
    User->>App: Pair and approve targets/files/egress
    Client->>Bridge: open_generation_context
    Bridge->>App: Authenticate and authorize
    App-->>Client: Opaque context + safe references
    Client->>Bridge: search/detail/retrieve/passages
    Bridge->>App: Revalidate scope and egress
    App-->>Client: Safe authorized content
    Note over Client: Generate typed candidates externally
    Client->>Bridge: propose_generated_questions + submission key
    Bridge->>App: Typed admission and current grants
    App->>Data: Durable original/items/pending stage
    Data-->>App: Stage receipt
    App-->>Client: Staged, not committed
    User->>App: Review edits/decisions and explicit confirm
    App->>Data: Revalidate + typed Question/review/receipt/terminal CAS
    Data-->>App: Atomic commit result
    Client->>Bridge: get_question_proposal
    Bridge->>App: Authenticate and authorize outcome query
    App-->>Client: Pending/rejected/committed + safe receipt
```

Every MCP client that supports Tools can complete this flow; Resources/Prompts
are optional future projections with the same authorization. Prompts only guide
use; Resources only expose safe authorized snapshots. MCP Tasks, sampling,
external formal approval and hosted remote transport are excluded from MVP.

## 5. First-party reference integration

Codex is a reference client, not a business Module or a special Proposal origin.
A separate integration repository packages manifest/MCP/Skill/assets, not the
Flutter repository. Skill teaches open/read/check duplicates/generate/stage/
review/status and must never say staged means formally saved.

Preferred current portable layout is root plugin.json/mcp.json/skills/assets
with OpenAI-specific metadata in extensions.com.openai. Legacy .codex-plugin
overlay is compatibility, not a requirement to build Shiroha-specific business.
Use installed shiroha-mcp bridge; do not pub-get/build Flutter or auto-download/
install executables through lifecycle hooks. Bare command or contained plugin
relative executable is validated with supported Codex versions. Manifest,
bridge and capability-profile versions are distinct; paths/Windows env casing
must pass real launch fixtures.

Git/local marketplace distribution is the initial reference-package route.
Public-directory hosted/local eligibility and Windows executable installation/
discovery/minimum client version remain NEEDS IMPLEMENTATION-SPIKE in AR-R9B.
No public-hosted deployment or signing/release change is authorized here.
Claude/Gemini/Qwen/Cursor/Ollama/custom clients use the same generic profile;
future protocol adapters do not alter Proposal Domain. Plugin removal never
deletes App data. Reference package works without Resources/Prompts.

Official design sources (recheck at implementation):
[MCP revision](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
[Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools),
[Tasks extension](https://modelcontextprotocol.io/extensions/tasks/overview),
[Plugin packaging](https://developers.openai.com/plugins/build/plugins),
[public submission](https://developers.openai.com/plugins/deploy/submission).

## 6. Acceptance / rollback

AR-R6B proves Tools-only synthetic end-to-end over actual stdio protocol, input/
output schemas, pairing/context scopes, non-enumeration, passage coverage,
cancel/progress, unavailable/revoke/restart, duplicate/lost stage response and
authorized outcome lookup. v0 exactly-six and SDK-confinement regressions stay.
AR-R9 separately proves optional projections and installed reference package.
Disable vNext entrypoint/Host routes without changing v0, Proposal data or typed
Question compatibility. Runtime/Provider/UI rewrites are not MCP prerequisites.

## 7. Bounded STAGE stdio source composition

`MCP-vNext-STAGE-END-TO-END` supplies an independent stdio server and an explicit
inactive App composition. This is a synthetic functional/source slice of the
target above, not full AR-R6B acceptance or production activation. The pinned
`mcp_dart` 2.4.0 SDK owns modern `2026-07-28` discovery and legacy `2025-11-25`
initialization; actual SDK clients exercise both over subprocess stdio. No SDK
or dependency upgrade is introduced. The v0 entrypoint and six tools are unchanged.

The seven tool names above remain deterministic. This bounded projection uses
camelCase P4/P10 references and a separate candidate `profileVersion: 2` result
envelope, exactly `{profileVersion, data, error}`. A success has operation data
and null error; a failure has null data and a fixed safe code. Text content is
the JSON serialization of the same object as `structuredContent`. Every tool
declares input/output schemas; P10 additionally validates deep result whitelists.
Request metadata, protocol request IDs and clientInfo never enter authentication,
Profile selection, target approval or Submission identity.

Profile v2 supersedes the bounded v1 candidate, with server implementation version
0.2.0 and declared result profileVersion fixed to 2 for every tool/error. Clients
must validate that version/output schema; no profile-v1 response is silently
reinterpreted or negotiated. MCP modern/legacy protocol support is unchanged.
Only get_question_proposal's operation data changes; other tool data retains its
original P10 v1 semantics. This profile version is independent of IPC business,
P9 framing, Submission and persisted Proposal versions.

| Tool | Bounded projection input / behavior |
|---|---|
| open_generation_context | No target: optional pageSize/cursor -> P10 target page. targetRef alone -> P10 contextRef. contextRef alone -> authorized File choices. contextRef + fileRefs -> separate File contextRef; no implicit upgrade or evidence approval. Mixed selector modes reject. |
| search_questions | contextRef, query, optional pageSize/cursor -> P10 search page. |
| get_question_detail | contextRef, questionRef -> P10 safe structural detail. |
| retrieve_file_content | contextRef, query, optional limit -> P10 verified retrieval page. |
| get_file_passage | contextRef, passageRef, optional cursor -> P10 passage page. |
| propose_generated_questions | contextRef and content-only `submission` object in unchanged GeneratedQuestion Submission v1. P3 alone admits items/content/provenance/key/fingerprint. |
| get_question_proposal | Original submissionKey, fresh authentication, no old handle -> independent READ lifecycle query through P7/P8 and current IPC schema v3; current READ/proposalMetadata and both original/current target Scope are mandatory. Legacy IPC v2 remains separately supported. |

Optional fields have documented bounded projection defaults (pageSize 20, limit
8, cursor null); required/nullable P10 fields are still explicitly materialized.
P10's original business schema-v1 commands, lifecycle-only schema-v2 command and
P9 envelope v1 are unchanged. External boundary §8 owns the explicit v3 selection
extension now used by this App composition and the inactive Bridge in §14.
No raw bank/Profile/
permission/Grant field is accepted from a client. There is no external COMMIT.

App composition receives existing services, an authentication port and a
snapshot of already App-approved StageContexts. Trusted first-party control may
explicitly replace that bounded snapshot; no MCP tool can do so. The protocol
composition never calls `approveTarget`.
For STAGE, the READ handle resolves through the owning registry; its target bank,
nullable Project/Folder and revision must match a supplied approval bound to the
identical authenticated Session. P8/P3 validate the original approval, expiry,
current durable policy and final release. No second handle registry, completion
journal, writer, schema or transaction is created. Authentication is pinned to
that exact Session for the existing P10 invocation, preventing a fresh Session
from inheriting old approval. Missing approval fails closed; READ alone grants no
STAGE. File selection never approves GeneratedEvidence.

STAGE data remains exactly P10's proposalId/submissionKey/publication
`STAGED`/formalCommit `NOT_REPORTED`. This confirms historical publication only;
it does not claim pending/committed Review status, counts or a COMMIT Receipt.
get_question_proposal instead returns exactly submissionKey, lifecycleStatus,
requestedCount, actualCount, committedCount, rejectedCount. GeneratedQuestion §12
owns persisted-state validation, non-enumeration, counts and final release;
IPC v2/v3 deeply validate this whitelist and the declared MCP result schema exposes
these six fields only. Pending review withholds intermediate decisions. No
content, internal IDs, edited data or formal Question mappings leave this path.
P3/P10 v1 reconciliation and v3's explicit original-key reconciliation remain
available to trusted composition under the original STAGE-only authority;
READ lifecycle never inherits it.
An uncertain/lost response is reconciled by original key, never automatically
restaged. Cancellation is forwarded to existing owning control; close/EOF stops
new work and drains the supplied composition. Encoding/connection failure cannot
claim rollback or erase the original durable Proposal.

Run the isolated functional fixture with:

```text
flutter test --concurrency=1 test/mcp/vnext_mcp_end_to_end_test.dart
```

Only the test App owns a temporary synthetic SQLite file and synthetic credential
port. The stdio subprocess has no persistence dependency. Its test-only reverse
RPC link shares those same stdio pipes; it opens no socket/listener and is not a
production transport, Windows proof or alternative trusted credential adapter.
Tests cover mixed valid question kinds, existing Review UI
and explicit UI COMMIT, unchanged formal bank before approval, same-key
reuse/conflict, lost-response reconciliation across real database close/reopen,
unauthorized/expired/revoked/unavailable rejection and exact-Session isolation.
The lifecycle extension additionally covers independent READ/metadata/scope
authority, local UI approval and rejection, mixed terminal counts, withheld
intermediate decisions and exact original-key status after database/stdio reopen
and fresh authentication. The existing standing PR contract shard includes this
real stdio fixture; no test enables production transport.

The standalone `lib/mcp/vnext_mcp_entrypoint.dart` defaults to `unavailable` for
every business call. Startup installs only the dormant App owner in §9, and no flag/CLI
argument enables synthetic credentials or the test link in production.
HOST_STABILITY_HALT remains ACTIVE, TRANSPORT BLOCKED and AR-R6A NOT_ACCEPTED.
Actual STAGE use is blocked by admitted production authenticated App/Bridge
transport and admitted first-party pairing/credential integration; §9 supplies
the dormant first-party finite-enablement/target-approval composition,
followed by AR-R6B production exposure acceptance. The minimal future scope is to
provide the admitted transport's `VnextMcpPort` binding and trusted approved
Session/target inputs, preserving P3/P7/P8/P10 and UI COMMIT. If choosing a less
restrictive production transport instead, the governing external boundary and
Windows readiness/AR-R6A activation contracts must first be explicitly amended;
this slice grants no such exception and adds no Windows security experiment.

## 8. Isolated installed Windows Codex compatibility

The separate [Windows Codex guide](../../architecture/mcp-vnext-windows-codex.md)
owns launch instructions and evidence classification. Opt-in tests use the actual
installed CLI/Desktop `codex.exe` app-server MCP client with a child-only isolated
home, Flutter SDK VM, explicit repository cwd and no model turn or user credentials.
They check seven-tool discovery, schemas/annotations, profile-v2 production refusal,
repeated sessions, EOF/reconnect and bad launch paths. A test-only PID wrapper
delegates to the unchanged production entry; it supplies no App/authentication.

Codex discovery and production refusal remain distinct from synthetic business
success. The opt-in installed-client STAGE suite now connects the unchanged
seven-tool server to the SAME SDK synthetic App through a test-only disposable
file mailbox, avoiding Codex's unsupported private App notifications. The App
alone supplies existing credential-proven Sessions, current grants, explicit
target approval and `VnextMcpAppComposition`; no test credential/transport option
enters production. Actual `mcpServer/tool/call` exercises STAGE, durable pending
Proposal, existing local Review UI approval/rejection, original-key lifecycle,
duplicate/conflict, authority/expiry failures and lost-reply recovery after
Codex disconnect plus SQLite reopen. Only executed installed-client tests prove
this path; SDK success and skipped opt-in cases are separate evidence.

The mailbox is neither an authorization source, durable key journal nor alternate
writer. It forwards cancellation/availability, dispatches each request once,
never retries a STAGE and is removed with the isolated home. It opens no socket.
Recorded MCP processes must exit on Codex EOF. A separate opt-in installed-client
File READ suite reuses the same mailbox with `FileReadHarness`, current exact
File/Project grants and real P6/F1/RAG/FTS5 services. Actual Codex calls list file
choices, create a separate File Context, retrieve and read PassageRefs/cursors;
source/policy invalidation and bounded coverage/exclusion semantics are checked.
P4 parent-target prerequisites, independent fileContent/File scope and separate
STAGE approval remain unchanged. Only executed cases prove client acceptance;
the Windows guide records repeatable commands and evidence limits. Product
App/Bridge transport and real pairing/authentication remain absent; §9 adds
the dormant App control composition. Its implementation and independent security
admission gates must not be conflated. The broader Windows functional checklist,
AR-R6B and production Host/Transport admission are not closed by this bounded
slice. The v0 six-tool entry and existing real-bank registration are unchanged.

## 9. First-party App composition and controls

`MCP-VNEXT-APP-FIRST-PARTY-INTEGRATION` supplies the product App composition and
local controls independently of production transport activation. `main.dart`
passes the SAME authorization and GeneratedProposal repositories, existing
GeneratedLocalAuthority factory and verified F1/RAG services to one
`McpVnextAppIntegration`. It captures explicit READ repository ports over that
same DatabaseHelper; there is no separate database, writer or schema. Existing
GeneratedQuestionService/Inbox/Review/explicit local COMMIT remain the only
formal proposal approval path. MCP has no COMMIT route.

Windows startup is dormant: no TrustCore, CredentialPort, coordinator, P8 Host, listener,
IPC or MCP server is created or started. The existing P11 settings page includes
first-party Profile selection, connection/PairingState, 5/10/30-minute local
enablement, explicit STAGE target confirmation and disable controls. Without an
admitted authenticated binding it shows unconnected/unavailable and cannot
enable access. Saving a policy or selecting its ID proves no authentication.
Other platform startup does not install this Windows control composition.
The policy-only notice remains applicable to the original P11 editor.

The explicit `attachTrusted` composition entry requires an existing P0 authority,
readiness owner and opaque authentication-attempt supplier from an admitted
App/Bridge integration. It implements no credential adapter or pairing state
machine. Only isolated tests currently supply that binding; no startup/UI option,
test mailbox, synthetic credential or production TLS candidate installs it.
Real first-party pairing/credential/transport wiring remains inactive under
the frozen external and Windows readiness contracts. This slice does not claim
production connectivity or independently admit that future caller.

FirstPartyExternalAccess delegates Profile registration and finite enablement to
P12, authenticates the current selected Principal through P0 before enablement,
and opens the Session through P12 only after enablement. The pre-enable
authenticated peer is distinct from a business-enabled Session. It reauthenticates
and checks current policy/Session for target approval and each App Port call.
P0/P12 and P1/P3/P4/P7/P8 remain the owning authorities. Switching Profiles,
disconnect, policy revision/revoke, expiry and disable discard local approvals
and Session custody; regrant/reconnect does not automatically resume access.

STAGE target choices come from the existing local Review target query, including
exact nullable Folder and Project snapshots. Only confirmation of the displayed
App-minted choice calls the existing P3 `approveTarget`, with empty evidence in
this bounded UI. P3 checks current STAGE/Scope/Egress. READ handles and File
selection cannot trigger approval, and confirmation grants no missing permission.
The MCP composition receives only the resulting bounded approval snapshots and
matches the exact authenticated Session/target/revision as before.

An explicit `enableStageApprovalWait: true` attachment may instead install the
single Application-owned request lifecycle in external boundary §8, “P10 opt-in
first-party STAGE wait”. FirstPartyExternalAccess gives only its current local
control view the request's App-generated target and confirm/reject actions.
The original TLS request retains its own independently authenticated Session;
the UI's auxiliary authentication connection never substitutes for it. Closing
or replacing the view cancels an unfinished decision. App close/Restore cancels
input synchronously, then drains validation, P8/STAGE, I/O and real close before
releasing local owners. Nothing restores this approval after reconnect/rebuild.

Shutdown blocks new controls/Port work synchronously, discards approvals and
awaits P12/P8/Port plus local-operation settlement before releasing local owners.
The existing `SqliteBackupDatabaseAuthority` receives this before-close barrier
from main and awaits it before production database close, including B0 swap and
raw rollback; failure preserves the open database. DatabaseHelper is unchanged.
App exit awaits this same close, and recomposition awaits it before invalidating
the old local authority. Fresh composition is dormant and never restores Session,
Context or approvals. The original durable Proposal/SubmissionKey remains the
sole recovery authority, accessible only after fresh trusted authorization.

Deterministic acceptance is registered in the existing standing P11 architecture
shard (`local_authorization_architecture_test.dart`) via its synthetic fixture.
It exercises the actual product root with temporary SQLite and existing F1/RAG,
local control Widgets, denied unpaired/unauthenticated/non-STAGE/unapproved
submissions, finite expiry, revoke/regrant/disconnect, owning STAGE drain before
database close, reconstruction/original-key lookup and real B0 Restore/rollback.
Existing stdio/MCP v0/local Review and isolated installed-Codex File READ/STAGE
regressions remain distinct required evidence. No real application data is used.

The authorized Windows App smoke also executes the actual desktop runner through
`tool/mcp_vnext_windows_app_smoke.dart`, reusing `main.dart`'s composition with
explicit temporary data paths and a rejecting engine credential store. It
installs no synthetic MCP authentication. The
[Windows guide](../../architecture/mcp-vnext-windows-codex.md#isolated-windows-flutter-app-smoke)
records observed dormant controls, user-confirmed page reconstruction/cold
restart and ordinary bank use, plus separate deterministic Session/approval
invalidation evidence. That smoke establishes no formerly authenticated real
Session, production connectivity or independent Verifier approval. The source-only
pairing extension in §10 supplies local lifecycle wiring; admitted credential
services and actual App/Bridge binding remain unavailable.

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
Production MCP vNext remains disabled. Trial 1A and G0-L1/L2/I do not resume.

## 10. Inactive first-party pairing integration

`MCP-VNEXT-FIRST-PARTY-PAIRING-INTEGRATION` extends §9 with source-only local
request, separate user confirmation, proof completion and current display/failure
handling. Profile/Grant editing and selection never start pairing. P0 alone owns
Principal/PairingState/Session, P15 owns evidence and Association CAS, and P1
remains the policy owner. No format, schema, permission database or external
management/COMMIT route is added.

The explicit `McpVnextAppIntegration.attachCredentials` entry composes ONE P15
boundary and its P0/P12/P8 graph against the same management owner. Its required
verifier factory receives that exact management owner, so the existing Windows
channel verifier can bind its protected lookup to the same Profile references.
Stores/verifier and local pairing/channel services are trusted composition
inputs, never UI/request fields. `FirstPartyExternalAccess` retains only a local
request handle and the original authenticated Session/connection. The original
§9 `attachTrusted` entry remains compatible; it does not acquire pairing actions.
Neither entry is called by normal startup. No synthetic credential, accepting
verifier, native operation, listener or transport is installed by construction.

The UI can request pairing, separately confirm approval, and explicitly request
proof verification. It accepts no credential identity, proof, revision or claimed
Profile from an external client. Without an admitted service it shows pairing
unavailable and disables those actions. Available source compositions display
P0's actual pending/paired states and freshly queried public comparison data.
Failed/expired/unknown processing withdraws comparison data and requires explicit
runtime close/drain/reconstruction; selection cannot reset a failed attempt.
There is no automatic pairing retry, credential replacement or success fallback.

`WindowsFirstPartyPairing`, inside the existing inactive `windows_pairing.dart`,
adapts the same `WindowsAppPairing` P27 owner. It obtains an independently received
Submission ID from trusted composition, delegates Challenge/E0 consumption,
approval and proof completion, exports the existing public trust display once
through a trusted local export callback, and refreshes initial/completion displays
from P27/P15. The export does not confirm comparison or save a Bridge Pin. P27's
independent Bridge comparison, proof publication and separate Missing-only kind 4
save remain mandatory. No copied digest is authentication or continuous completion
evidence. Failed public export is not automatically retried. P27's verifier still
rejects Authentication; it cannot implement the separate connection opener.

Only P0 `pairedDisabled` may begin explicit finite enablement. The credential
branch then obtains a connection whose Session was created through P15's
independent Authentication event. Wrong Principal/generation, failed connection
validation or P4 policy admission immediately disables that enablement. Pairing
alone never yields a business Session. The connection callback must revalidate
its original owning channel and return the identical P0 Session or null (the
existing `WindowsTlsSession.authenticate` contract); no fresh Session inherits
target approvals. Current P4/P7/P8 policy and final-release checks remain in force.
The inactive Windows binding exposes `firstPartyConnection` as a direct
projection of that same Session/authenticate pair, without another evidence
event, connection attempt or Session owner.
Missing/revoked Grant denies business access, independently of pairing. READ
never grants STAGE, and only separate local confirmation of an App-selected
target invokes P3 approval. Formal COMMIT remains exclusively local Review UI.

Shutdown closes P15 evidence and P27 requests, drains the same P12/P8 and local
operations before releasing owners/database, and invalidates old Session and
approval custody. Replacement starts unpaired/disabled even with a surviving
Association. Existing revoke/CAS, expiry, B0 and reconstruction owners are reused.

Standing offline acceptance is registered in
`local_authorization_architecture_test.dart` through
`first_party_pairing_cases.dart`: actual App composition + P15 + temporary SQLite,
using the existing explicitly synthetic event/association facilities. It covers
request/approval/proof, independent authentication, finite enable/disable,
invalid/foreign/repeated inputs, missing/READ-only policy, expiry/revoke/restart,
local Widget confirmation and pending-verification/database-close settlement.
The same fixture also composes the actual App root with P27, the existing P20
fake-Native store, public mathematical proofs and the original Windows channel
verifier through `firstPartyConnection`, covering the complete local
pair/confirm/prove/authenticate/enable/target-approve/STAGE/disable sequence.
It separately withholds an old Session when shutdown races the final async
channel validation. No listener or actual Windows primitive participates.
`windows_pairing_test.dart` separately exercises the first-party P27 adapter with
the existing public mathematical fixtures and fake Native boundary. Neither
fixture is real Windows/security or installed App/Bridge pairing acceptance.

This closes the bounded lifecycle source-wiring scope only. Section 12 supplies
the inactive public export/Submission/completion adapter. Actual protected
credential acquisition, Windows process/channel bindings and real
Windows/App/Bridge acceptance remain pending; the bounded Bridge local controls
source slice below supplies the previously missing onboarding interface. Those
remaining gaps are not represented by synthetic success or an admission-only
remainder.
There is no production startup flag for these services. HOST_STABILITY_HALT =
ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED. No DPAPI, real certificate
generation, ACL, TCP/mTLS, Trial 1A or G0-L1/L2/I experiment is authorized.

## 11. Inactive first-party Bridge onboarding controls

`MCP-VNEXT-BRIDGE-FIRST-PARTY-ONBOARDING` supplies
`WindowsBridgeOnboarding` in the existing P27 library, exported by the existing
default-disabled `tool/external/bridge_candidate.dart`. There was no active Bridge
local surface to extend. This is the minimal independent local control interface;
it creates no Agent, business Host, UI framework or second PairingState/Session.
The standalone main still rejects activation. Construction performs no Windows
operation and installs no default App/MCP consumer.

Trusted composition supplies the existing `WindowsBridgePairing` owner and two
independent local App readers correlated by the original Submission ID. The
public-material reader returns only copied, untrusted `BridgeAppPublicMaterial`
bytes, adapting §10's explicit `exportPublicTrust` output or an independent local
import. It does not obtain anchors from Discovery. The completion reader adapts
the App's current `FirstPartyPairingRequest.display` or first-party control status
after confirmed App completion. These callbacks carry public comparison data only, never verified
identity, proof or authorization. There is no fourth Exchange payload, receipt,
credential database or additional persisted flag.

The local host binds these separate actions to explicit user operations:

1. `beginEnrollment` delegates P27 key generation and original Submission
   publication; `display` exposes its public Submission ID for the App handoff.
2. `inspectAppTrust` reads independent App Issuer DER/Server digest, delegates
   original Challenge consumption custody and P27 verification, then exposes all
   64 lowercase digest characters. Import does not confirm first trust.
3. Only after the user compares both full local initial digests,
   `confirmInitialAndPublishProof` delegates the original P27 confirmation and
   Proof publication. The App still requires its separate local Approval and
   explicit Proof completion; this Bridge method cannot perform either action.
4. `inspectAppCompletion` reads the App's actual committed Revision and full
   completion digest, delegates P27's CAS/idempotency consistency check and
   displays the complete local digest and actual Revision. A malformed, missing
   or inconsistent completion closes the local attempt; importing a matching
   display never saves a credential.
5. Only after the user independently compares both completion digests AND both
   Revisions, `confirmCompletionAndSave` delegates the existing one-use,
   Missing-only kind 4 save. A caller's Revision must also match the displayed
   imported actual Revision. Acknowledged `pinSaved` is historical storage
   success only; it creates no Session, Grant or Enablement.

`BridgeOnboardingDisplay` is a transient public controls projection. It holds no
Enrollment/key and grants no authority. The host refreshes `display` while visible
and withdraws comparison data on failure; retained screenshots/copies are not
freshness evidence. The same P27 monotonic/UTC checks apply without renewed
deadlines: at most 600 seconds before Proof and 120 seconds after it, with the
original live Challenge deadline and separate P15 Evidence Window unchanged.
The frozen manual protocol cannot observe App invalidation after a valid display.

Cancellation and surface closure call `close`: invalidate the SAME Enrollment,
wipe its private memory, withdraw all comparison fields and release its retained
E0 read without deleting public files. Pending local input drains before close
returns; late input, restored clocks/context, duplicate actions and failures
cannot reopen that controller. Failures expose fixed categories, never arbitrary
reader error text. Recovery is explicit fresh local controls/Enrollment and the
existing App runtime/revoke-first recovery rules, with no automatic retry.
The caller retains Pairing adapter/Store/Owner/writer-lock custody through drain.

Standing `windows_pairing_test.dart` covers both confirmations, the complete App
adapter/P27/P15/Fake Native path, incorrect summaries/Revisions, malformed
Challenge/Proof, duplicate actions, expiry/invalidation, late local input, key wiping,
E0 release and existing/corrupt/unknown Pin outcomes. The existing actual App-root
fixture also uses these Bridge controls. Public mathematical fixtures and Fake
Native prove source wiring only. Section 12 supplies the inactive public-material,
Submission and fresh completion-reader adapter. Actual protected credential
acquisition, Windows App/Bridge process integration and authenticated channel wiring still require
implementation/acceptance. No real DPAPI, ACL, certificate generation, listener,
formal Bridge service or production MCP is activated. HOST_STABILITY_HALT =
ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED. Trial 1A and G0-L1/L2/I remain
unresumed; independent Windows security/process acceptance remains pending.

## 12. Inactive App-Bridge pairing handoff

`MCP-VNEXT-APP-BRIDGE-PAIRING-HANDOFF` supplies `WindowsPairingHandoff` in the
same P27 library, also exported by the default-disabled Bridge source entry.
Explicit trusted composition passes the existing App and Bridge Pairing owners,
uses the adapter as its `FirstPartyPairingPort`, and binds its `bridge` controls
to separate local user actions. Construction performs no I/O or activation.
This is an in-process source composition seam, not a Windows process transport.

The adapter passes the Bridge Enrollment's ORIGINAL Submission ID into
`WindowsFirstPartyPairing`. P27/E0 still publish, read and consume that one
Submission and its exact Challenge/Proof bytes. No request record, Exchange
payload, persistent journal, protocol or credential owner is added. The existing
request handle and a bounded transient copy of the public export are retained
only for the lifetime of this composition.

`exportPublicTrust` feeds `readAppPublicTrust` with immutable copies of Issuer DER
and Server Leaf digest only. Each read matches the original live Submission and
revalidates the original App display before returning. Bridge independently
checks the Challenge and calculates its full initial digest. Import never
confirms trust: both surfaces still display all 64 digest characters, and only
the first explicit human comparison action permits Proof publication. App
Approval and P15 completion remain separate explicit actions.

`readAppCompletion` queries that SAME request's current `display`, which obtains
P27/P15's actual confirmed Association Revision and full completion digest.
No expected-Revision arithmetic or cached success supplies the result. Bridge
checks the returned actual Revision/digest against its original Enrollment;
only the second explicit full-digest AND Revision comparison may invoke its
existing one-use Missing-only Pin save. Saving the Pin ends Bridge Enrollment
custody without closing the App's existing pairing owner. The App still queries
P15, and subsequent business use requires independent Authentication and policy.

Missing, foreign, expired, duplicate or invalidated inputs latch the handoff
closed and withdraw its retained data and Bridge display. App request calls
also guard the original Enrollment while it is live. Close through the existing
App credential-service lifecycle immediately invalidates the handoff/Enrollment,
then drains outstanding handoff reads, Bridge controls and the existing App
P27/P15/P12 owners. Caller-owned protected Store/Owner/writer-lock release remains
outside this adapter. Late results and old handles cannot restore custody;
recovery requires explicit close/drain/fresh composition. Deadlines are never
renewed and no automatic retry/approval or unknown-result success is added.
The frozen manual protocol still cannot guarantee observation of App invalidation
after an earlier valid completion display; copied displays grant no authority.

Standing `windows_pairing_test.dart` covers the actual adapter with existing
public mathematical fixtures, Fake Native and business owners: original E0
consumption, both confirmations, exact-revision idempotency, wrong/cross Enrollment
IDs, missing Submission/export/Challenge/Proof, failed/unknown CAS, wrong Revision,
expiry, delayed reads, cancel/close/revoke and stale/rebuilt handles. The existing
`first_party_pairing_cases.dart` actual App-root integration now uses this
adapter instead of fixture-defined handoff callbacks, through P15 completion,
separate channel authentication, target approval and isolated STAGE.

Delivery is limited to inactive public handoff source wiring and isolated
functional acceptance. Actual protected credential acquisition, admitted native
public-material/process transfer, Windows App/Bridge process composition and
seven-tool authenticated cross-process wiring remain implementation AND
acceptance work. Section 13 supplies the bounded Bridge IPC client source only.
This seam makes no real Windows credential, process or security claim.
Normal startup, production App/Bridge and MCP vNext STAGE remain disabled.
HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
No real DPAPI, certificate generation, ACL, listener/TCP/mTLS, Trial 1A or
G0-L1/L2/I experiment is activated or authorized.

## 13. Inactive bounded Bridge IPC client

`WindowsTlsBridge.request(requestId, payload)` sends exactly one opaque P10
request through its existing, fully server-verified `TlsChannel`. The same P26
Discovery/kind-4/anchor/Server-DER checks must finish before use. P9's existing
codec enforces the unchanged strict request ID, SHIP/v1, UTF-8 and size limits.
The Bridge neither parses business permissions nor selects a Profile/Session,
creates a trusted Context or adds any business writer. App channel Authentication,
`OfflineIpcCommandProjection`, P8/P7 and the original owners remain authoritative.

Sending and reading use chunks of at most 64 KiB. Response admission validates
the P9 header before body allocation, refuses request-kind replies, checks exact
ID/type/length/UTF-8 and requires EOF after the sole complete response. Protocol
errors, wrong IDs, malformed/truncated frames, duplicate replies or trailing
bytes fail closed. A valid response remains an `UntrustedIpcEnvelope`; business
schema/result interpretation stays outside this transport.
Clean peer EOF may make the channel unavailable before the final EOF read;
it does not discard an already complete matched response. Local cancellation,
deadline and composition/certificate invalidation still reject its release.
One connection can make only one attempt, including concurrent/late calls and
failed requests.
No reconnect, batch, automatic STAGE retry or startup binding is supplied.

The default 2-second no-progress and 10-second total frame deadlines cover the
exchange, including writes and response/EOF waiting. They cannot be renewed by
slow progress. Section 14's explicit STAGE waiting profile is the sole bounded
exception; it does not alter ordinary READ deadlines. Existing `TlsResourceBudget` ceilings account for the pipeline,
TLS rings, bounded frame/scratch and decoded text before allocation/I/O. Close
immediately cancels result availability and makes old requests unusable, then
waits the original read/write and acknowledged close. Deadline/cancel alone
never releases resources; failed close poisons admission and retains uncertain
reservations while still waiting pending I/O. The same Host separately retains
its existing P8/P10 settlement barrier through in-flight App writes.

`TlsBridgeException` exposes fixed transport/protocol classifications only.
Once a write is attempted, transport failure reports `executionUnknown`, never
business failure, rollback or safe retry. STAGE recovery remains an explicit App
query using the ORIGINAL `submissionKey`; Envelope IDs do not replace it.
Nothing changes P9/P10 wire formats, resource ceilings or Session/Context custody.

Standing `windows_tls_transport_test.dart` includes the Bridge cases with the
existing Fake TLS, public cryptographic fixtures, isolated SQLite and original
Host: authorized READ, trusted STAGE, absent enablement/approval, malformed and
lost responses, strict IDs, fragmentation/maximum sizes, normal peer closure
before/during final EOF validation, EOF cancellation/invalidation, deadlines,
disconnect, duplicate requests, delayed/failed close and committed-STAGE settlement
with original-key recovery. These are deterministic source checks only.

The three completion boundaries remain distinct:

| Boundary | Bounded capability / remaining work |
|---|---|
| Bridge business communication source | Single P9 request/response and close/drain implemented in the inactive authenticated transport candidate; Fake TLS exercises real App P10/P8. |
| Seven-tool cross-process projection | Section 14 supplies inactive v3 READ/File/lifecycle binding and explicit same-connection first-party STAGE waiting through App P8/P7. Defaults still refuse STAGE before encoding/send. Real process composition remains pending; synthetic links remain test-only. |
| Real Windows security admission | Still pending: protected credentials, actual TLS/OS resource/close behavior and independent frozen Windows acceptance; offline success proves none of these. |

Normal App/Bridge startup and production MCP remain unchanged and disabled for
this candidate. No DPAPI, ACL, certificate issuance, TCP/mTLS Listener, Trial 1A
or G0-L1/L2/I run is activated. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED. Fake TLS success is never real Windows channel acceptance.

## 14. Inactive Bridge seven-tool protocol projection

The explicitly constructed
`VnextMcpBridgePort` over ONE already connected, server-verified
`WindowsTlsBridge` uses the shared P10 business-schema-v3 mapping. Construction
does no I/O. Neither normal startup nor the
standalone entries install it. It never connects/reconnects, supplies an App
Session/Context, approves a target or adds a writer/authorization registry.
The seven tool schemas, implementation version 0.2.0, modern/legacy MCP support
and result `profileVersion: 2` remain unchanged.

`VnextMcpCommand` is the shared App/Bridge mapping: selector modes, defaults,
exact P10 command/version/input and strict P9/P10 response projection are defined
once. It describes untrusted selectors, not execution authority. External
boundary §8 owns the complete exact eleven-command v3 matrix, input bounds and
legacy v1/v2 compatibility. P9 stays `SHIP/v1`; P10 retains its fixed four-field
business root. Context-selected commands include required non-null `contextRef`;
lifecycle and internal reconciliation include only the original `submissionKey`.
Responses pass the original deep P10 codec and match P9 ID, command, version 3
and applicable original key. A validated null-capability v1 pre-command error is
accepted only as failure. An old-version success never becomes v3 success and
never causes a downgrade/retry. No unsafe body/exception escapes.

TLS/P15/P0 authenticates S, P8 `bindSession(S)` creates E before strict parsing,
then compiled App `IpcTrustedContextBinding` selects original P8 `openRead`,
`openProposalLifecycle`, `openReconciliation` or conditional `openStage`.
The same E and newly minted execution Context enter P8/P7 dispatch. Revalidation
may return identical S or null, never a replacement Session. The existing P4
registry revalidates READ references by current Principal, effective runtime
generation, revision, expiry and kind. Session B of that same Principal may
revalidate A's READ reference, but each execution Context belongs only to its
new exact Session. Foreign/old/revoked/expired references fail closed. Proposal
query instead needs only its original key and fresh independent
READ/proposalMetadata plus original/current target scopes; no prior READ Context
or STAGE authority is required. Bridge never performs those trusted openings.

Classification stays cheap: the default Bridge refuses STAGE before payload
serialization/send. Explicit waiting permits one pre-approval bounded encoding,
send and App raw-text retention. Before `jsonEncode` the frozen GeneratedQuestion admission
bounds apply (1 MiB encoded submission, 16 nesting levels, 50 items), so an
oversized or too deep submission returns `invalidRequest` without allocating the
encoded payload and without sending a frame. Escaped UTF-8 JSON size is bounded
without calling arbitrary `toJson`; non-JSON objects reject. Transport resource
reservations precede the lazy payload builder. P10 parses only the bounded outer
command/raw string before approval; P3 candidate admission and STAGE handler
entry occur only after fresh human confirmation. This preserves the frozen P9/P10
and seven MCP tool schemas.

The TLS Host explicitly selects exactly one composition mode: retained legacy
supplied Context for v1/v2, or App v3 binding for this same Host. v3 refuses old
request versions rather than supplying a legacy Context. This changes no
authentication, Session custody or TLS resource ceilings. The only deadline
exception is the explicit STAGE phase below.

| Tool | Actual Bridge mapping (v3) | App authorization and Context path |
|---|---|---|
| open_generation_context | No selectors -> `external_list_targets`; targetRef alone -> `external_create_read_context`; contextRef alone -> `external_list_file_selections`; contextRef + fileRefs -> `external_create_file_context`. Mixed modes reject. | First two mint root `openRead(E)`; P4 verifies current READ/Scope and App target/cursor. Last two revalidate parent via `openRead(E, contextRef)`; P6 verifies file choices and creates a separate File Context. No evidence approval. |
| search_questions | `external_search_questions {contextRef,query,pageSize,cursor}` | Fresh `openRead(E, contextRef)`; original P4/P5 questionContent/Scope and Context-owned cursor, final release. |
| get_question_detail | `external_get_question_detail {contextRef,questionRef}` | Same READ binding; original P5 verifies QuestionRef ownership and safe structural output. |
| retrieve_file_content | `external_retrieve_file_content {contextRef,query,limit}` | Fresh `openRead(E, contextRef)` for original File Context; P6 current fileContent/Scope, F1 verification, FTS and final release. |
| get_file_passage | `external_get_file_passage {contextRef,passageRef,cursor}` | Same File Context binding plus original PassageRef/cursor ownership and source validation. |
| propose_generated_questions | Default refuses before Submission serialization/send. Explicit waiting sends one bounded v3 `external_stage_generated_questions {contextRef,submissionJson,externalRequestId:null}`. | Same-Session first-party confirmation creates original P3 approval, then original P8 `openStage`; ordinary synthetic App binding retains its existing-approval path. No other Session inherits approval. |
| get_question_proposal | `external_get_proposal_lifecycle {submissionKey}` | Fresh `openProposalLifecycle(E, originalKey)` with independent READ/proposalMetadata and BOTH original/current target scopes. No STAGE permission/old READ reference. P9 Request ID never selects a Proposal. |

Issue #324's explicitly approved source-only exception uses the ORIGINAL
authenticated connection/Session and P8 entry for one Application-owned human
decision. App composition, Host and Bridge each default `enableStageApprovalWait`
to false. External boundary §8 owns the exact lifecycle and timing: 2-second
preparation, default/max 120-second human wait, 10-second completion, 132-second
Bridge final-response/EOF window after upload and 142-second whole exchange.
Upload and response-frame progress retain 2/10-second limits. With P9's single
final response, the Bridge cannot observe intermediate phase transitions; this
explicit bounded silence allowance is required. No protocol frame/schema changes.
The current UI must explicitly confirm the App target for this Submission;
S/E/generation/R/target, enablement, current policy and availability are rechecked
before and after original P3 approval. Only one pending request per generation,
no queue, no held SQLite transaction/B0 lease while waiting; real settlement and
acknowledged close precede slot release. Reject/cancel/timeout/revoke/revision/
target drift/disconnect/close/Restore invalidate late input. EOF observation is
joined after own close, never before replying. No cross-connection ticket,
Session inheritance, READ-to-STAGE upgrade, automatic approval or retry is added.

Each Port makes at most one transport attempt. Concurrent/late calls cannot send
again; a fresh Port cannot revive the consumed/closed Bridge. Cancellation or
caller withdrawal closes that same owner, and close waits its actual pending
I/O and acknowledged cleanup. Ordinary deadlines, failed-close reservations
and Host business settlement retain §13's rules; explicit waiting uses the
bounded exception above. Fixed pre-send failures
remain failures; a transport failure after attempted writing remains
`outcome_unknown`. Malformed or mismatched P10 data is withheld as `invalidResult`.
No STAGE retry or success fallback is introduced. Original-key recovery is an
explicit fresh authorized lifecycle query. A missing Proposal does not prove
that unresolved owning work cannot still publish. READ binding and execution
share the at-most-two-second budget and final egress; cancellation, timeout,
disconnect or withdrawal releases no withheld data. Projection settlement now
includes pending binding before P8 owning settlement. Failed close retains its
reservations. App close/Restore drains owners and invalidates Session/Context/
approval custody; fresh composition/reconnect never revives it. Durable Proposal
identity and P3 idempotency/conflict/recovery remain original-key based.

Standing `windows_tls_transport_test.dart` includes
`vnext_mcp_bridge_cases.dart`: the real modern/legacy stdio SDK/server, existing
test-only reverse link, actual Bridge Fake TLS and isolated App P10/P8/SQLite
produce fresh-connection target/search/detail READ. The same fixture exercises
File selection/Context, actual F1/FTS retrieval/Passage and independent original-key
metadata against isolated SQLite. P10's v3 suite covers same-Principal A/B READ,
foreign/wrong-kind/old-generation/revoked/expired rejection, exact-Session STAGE
isolation, strict version/input/response matrices and binding interruption/drain.
Bridge regressions retain default zero serialization/send/publication for STAGE, strict
IDs/keys/response versions, concurrent calls, cancel/deadline/disconnect and
retained settlement. Existing §13 lost committed STAGE/original-key recovery,
§7 synthetic Review/reopen, modern/legacy stdio, MCP v0 and Windows Codex remain
required regressions. `first_party_stage_approval_cases.dart` in that same TLS
suite adds actual Widget click after 10 seconds, bounded negative/close races,
resource retention, real B0 Restore and committed response loss/original-key
lookup. The Windows guide records explicit Codex timeout compatibility; installed
client execution is separate evidence. No real Windows process/credential/security
acceptance is claimed. Real process/credential wiring remains incomplete.

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
Production App/Bridge, listener, DPAPI, certificate issuance, ACL, personal data,
Trial 1A and G0-L1/L2/I remain unactivated. Fake TLS and the stdio reverse link
prove source integration only; admitted cross-process security remains pending.

## 15. Inactive Windows process-side functional composition

The explicit `attachCredentials` transport factory receives the SAME App-owned
P12 coordinator and `VnextMcpAppComposition` after P8 readiness. It cannot receive
client identity, Grant or execution Context fields. The returned
`McpVnextAppTransport` must retain that exact binding; a foreign binding is rejected
without starting or closing its transport. `McpVnextWindowsTransport` joins the
existing inactive `WindowsTlsHost` to this attachment and verifies exact P8/P10
identity and inactive phase. No parallel business graph, writer, Session factory
or IPC format is introduced. Factories construct only; the existing Host `start`
owns the explicit prepare/bind/publication pipeline.

App close/Restore cancels local approval immediately and awaits original
transport, P15/P27 and P8 settlement before releasing App owners/database.
Shutdown is latched, including failure. `WindowsTlsHost.owned` also accepts the
trusted `closeLocalConnections` drain for auxiliary first-party authentication
channels. That original closer must settle before Store/Owner/runtime.lock
release; failure poisons admission and retains the Owner, without retry. It is
required when the composition owns such auxiliary channels. It creates no
Session and cannot replace channel revalidation. Protected credential acquisition
and correct wiring of this closer remain the trusted factory's responsibility.

`McpVnextWindowsBridge` supplies the inactive Bridge process-side connection
owner. Its explicit synchronous factory captures existing credential/Discovery
owners and receives no request input. One independent MCP call constructs and
connects one `WindowsTlsBridge`, then invokes the original single-use
`VnextMcpBridgePort`. Concurrent calls return busy; there is no queue or retry.
The next independently requested call authenticates a fresh connection. EOF/close
blocks new calls immediately, closes a connecting/active channel and waits its
original operation. Unknown close permanently blocks admission and propagates
unconfirmed cleanup to the process owner. Credential owners must outlive this
barrier. No automatic STAGE retry follows any unknown result.

STAGE defaults off in this owner as well as App, Host and connection. Mismatched
Bridge profiles fail closed. Explicit isolated enablement reuses §14's original
Session/submission/revision/exact-target human wait and first-party confirmation.
The seven schemas, P9/P10 versions, one request/response/EOF, deadlines, original
key idempotency and App-only Review/COMMIT are unchanged.

The standing P11 architecture suite imports `windows_app_transport_cases.dart`:
actual product App + P27 Handoff/manual comparisons + owned Host + Bridge,
using existing public mathematical credentials, Fake TLS and temporary SQLite.
It covers all seven routes, explicit approval, same-key idempotency, original
local Review/COMMIT, policy revision/revoke/Disable, channel/Bridge EOF, Listener
exit, App close, real B0 Restore, lost response/key query and local-channel drain.
The existing TLS lifecycle suite covers failed local-channel cleanup retaining
the Owner. Earlier §7/§9/§14 reopen, exact-Session, target, cancellation, modern/
legacy protocol, v0 and Review regressions remain required. No new test transport
framework or production test adapter is supplied.

The opt-in installed-client test `windows_app_transport_codex_test.dart` uses the
existing disposable mailbox to reach this same composition and all seven tools.
The Windows guide records only executed binaries. The mailbox and Fake TLS prove
isolated process-boundary functionality, not actual Windows process transfer of
protected credentials or a production App/Bridge bootstrap. Normal App and
standalone vNext startup still reject business access; static gates permit only
the dormant trusted root in section 16 to consume these Windows composition
files. Ordinary App/standalone consumers remain forbidden.

Remaining product work includes actual protected credential acquisition, real
process bootstrap/handoff and admitted TLS binding. Draft #327's Codex short-tool-
deadline cancellation compatibility remains BLOCKED; this slice neither changes
timeouts nor repeats its diagnostic matrix. Formal Windows security admission
remains separately pending. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED. This source delivery is not full AR-R6B acceptance and
does not satisfy AR-R9B prerequisites or authorize Trial 1A/G0-L1/L2/I.

## 16. Dormant Windows startup and credential handoff composition

`lib/composition/mcp_vnext_windows_startup.dart` lifts reusable section 15
fixture wiring into a minimal trusted product root. Constructors only retain
objects/callbacks: no Owner acquisition, protected read, process launch, TLS
context, Discovery publication or Listener activation occurs at construction.
There is no default acquirer or normal-startup/standalone consumer. Explicit
`start` is a seam for separately admitted composition, not a safety admission
grant or an alternate startup protocol.

The trusted App acquirer transfers exclusive custody of ONE existing acquired
App Owner/runtime.lock, original P20 Store, P25 credentials/P24 Exchange and P27
verifier, plus existing App readiness, injected primitives, local authentication
I/O and process custody. It must never return another live runtime's resources.
Read-only checks of the existing App attachment and Owner's one-use runtime
claim reject borrowed active resources without closing or invalidating them.
It owns partial acquisition/launch cleanup if it fails before transferring a
bundle; unknown cleanup must retain those resources and report failure.
No MCP arguments, environment variables or client JSON construct these inputs.
Existing-only P25 validation precedes `attachCredentials`; there is no implicit
initialization/recovery/rekey. The original App method creates the sole P15/P0/
P12/P8 graph. Its services bind P27 Pairing to the same verifier/boundary/Store;
P26 uses that Pairing Runtime ID and the original P0 generation. The exact App
P8/P10 binding enters `WindowsTlsHost.owned` and `McpVnextWindowsTransport`.
Only that Host performs prepare/bind/publication and closes its protected Owner.
No second Principal, Session, Grant, Context registry or database Writer exists.

The trusted local opener returns its actual TLS channel and validated server
plan. The SAME `WindowsChannelVerification` authenticates it and returns the
original P15 Session/revalidation callback. The required closer closes all raw,
connecting and authenticated local channels/plans, cancels pending opens and
awaits their original work. The composition also joins any pending local open/
authentication operation; neither a returned Session nor cancellation substitutes
for settlement. `McpVnextWindowsProcessOwner.stopAndWait` owns actual interrupted
launch/exit settlement, not process identity or permissions. The dormant adapter
in section 17 supplies this custody without replacing the startup graph.
Both drains join the Host's existing closer before
Store/runtime.lock release, latched across App/Host shutdown calls.

The Bridge acquirer transfers ONE exclusive existing Bridge credential/Discovery
Owner, independently established P27 trust inputs and trusted TLS I/O/primitives.
`McpVnextWindowsBridgeStartup` wires its P26 Reader and original
`McpVnextWindowsBridge`. `start` opens no network connection. Each independently
requested tool call uses the original fresh single-use connection; concurrent
calls return busy with no pool, queue, retry or substitute authentication. Close
blocks admission and joins original connection/business I/O and process exit
before credential Owner release. Failed raw cleanup or unknown process exit
retains the Owner; latched failure cannot reopen admission or report success.

App close/Disable/revoke/Pairing failure/Restore/runtime-currentness retain all
original P15/P0/P8 and first-party approval rules. Startup interruption, readiness/
bind failure and partial attachment join the same cleanup. Before Host custody,
successful App/P27/local/process/Store settlement is required for Owner release;
after transfer the Host alone releases it. Database close/B0 swap continues to
await the App integration barrier; failed settlement prevents database close.
Foreign App bindings are rejected without starting or closing their transport.
STAGE waiting remains an explicit default-false opt-in and requires the same
Session's manual App approval. P3 publication, seven schemas, P9/P10, COMMIT and
all identity/persistence formats are unchanged.

`windows_startup_cases.dart` is reached by the existing standing P11 architecture
suite through `windows_app_transport_cases.dart`; no separate CI list is added.
Public mathematical credentials, Fake Native/TLS/process custody and temporary
SQLite cover all seven tools, explicit STAGE approval/original-key query,
constructor inactivity, foreign binding/borrowed Owner, readiness/bind/acquire interruption,
pending local authentication, busy/EOF and failed raw/local/process cleanup.
Section 15's existing end-to-end tests now use the product App startup root and
retain Disable/revision/revoke/disconnect/Restore/Review/lost-response regressions.
Source guards allow this exact dormant root and forbid normal consumers and real
OS acquisition/launch implementations in that root. Section 17 adds only exact
inactive adapters outside it, with no normal startup consumer.

Evidence remains four distinct conclusions: **SOURCE WIRED**, **FAKE VERIFIED**
only by executed tests, **REAL WINDOWS NOT VERIFIED**, **FORMAL ADMISSION NOT
PASSED**. Section 17 supplies dormant protected-acquisition/process-custody source;
actual protected Windows acquisition, formal Bridge launch/exit, admitted TLS
binding and production cross-process integration remain unverified. They cannot
be proved by a Fake or injected callback. Section 17.1 separately records bounded
ordinary Dart child evidence; it does not execute those production paths.
Draft #327 short-deadline cancellation compatibility remains BLOCKED with no new
repair loop. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED. This source-only delivery neither completes full AR-R6B
nor accepts AR-R9B prerequisites or activates Trial 1A/G0-L1/L2/I/production vNext.

## 17. Dormant protected acquisition and child process custody

`mcp_vnext_windows_acquisition.dart` adapts the existing Native Loader and
`ExternalProtectedObjects` into section 16's original dependency bundles.
Construction only captures trusted callbacks. Explicit App acquisition opens
the fixed adjacent Native DLL through `WindowsExternalNative.open`, acquires ONE
App Owner/runtime.lock, constructs P20/P25/P24/P27 adapters over that Owner and
performs P25 existing-only validation. Missing, partial, corrupt or mismatched
credentials reject without initialization, recovery, rotation or replacement.
Primitive injection exercises the same assembly with Fake Native and public
mathematical credentials. App transport/local readiness/pairing controls remain
trusted composition inputs; the original startup still creates the sole graph.

Bridge acquisition opens ONE Bridge Owner/client.lock. The original P26 reader
and TLS Bridge retain existing kind-4, independent trust, high-water and peer
verification; acquisition neither enrolls nor creates an initial Pin. Both
acquirers are single-use, including contention/failure. Returned bundles must
retain the exact acquired resources and supplied process custody. A foreign
bundle is rejected without closing its resources. The same native Owner holds
an irreversible role-checked runtime claim for App or Bridge; repeated startup
cannot borrow or close the original runtime's Owner. Native OS locks continue
to exclude independently acquired writers. There is no second ownership registry,
authentication authority, policy store or database Writer.

Before transfer, acquisition joins original local-channel and process settlement,
then drains its P20 Store and closes its Owner. Unknown cleanup retains those
original resources with no retry. After transfer, section 16 and the existing
owned Host remain the sole closers. A malformed assembly that already claimed
the Owner is quarantined rather than released beneath a live runtime.

`WindowsBridgeProcess` is the minimal inactive process-custody adapter. Its
default I/O derives exactly the adjacent `shiroha_bridge.exe` and Native DLL from
`Platform.resolvedExecutable`, performs bounded reads and reuses the existing
Bridge candidate inventory/x64 PE inspection before creation. It accepts no
path/arguments/environment/request selectors. SDK creation uses an empty
argument list, no shell, no inherited environment and the original returned
Process object. The fixed environment has only `SHIROHA_PROCESS_ENV_PAD=`:
one inert empty value avoids Windows Dart SDK rejection of a zero-entry block.
No product code reads this entry; it selects no behavior and transfers no data.
No PID lookup/kill, elevation, restart, watchdog or service is
added. Existing stdin EOF requests shutdown. Actual original exit plus both
discarded output drains must settle; a non-cooperating child remains pending.
Unknown creation, failed input/drain or nonzero exit latches failure and preserves
upper-layer Owner/database custody. Repeat close joins the same result. Exit
notification immediately blocks new admission and initiates the original startup
shutdown, while that shutdown still waits for the original streams/process.

Static PE inspection is not signed-image/loader acceptance or proof that package
files cannot change between inspection and launch. No new image pin or private
cross-process credential-transfer protocol is invented. The unchanged standalone
candidate still refuses activation (64/78); normal App/vNext startup imports
neither new adapter. A separately admitted functional runtime, Windows loading/
exit behavior and package identity acceptance remain concrete integration gaps.

The existing P11 fixture exercises actual acquirer → section 16 startup → P27/
Host/Bridge → all seven tools using Fake Native/process/TLS and isolated SQLite.
It also covers contention, identity mismatch, duplicate acquisition/runtime,
partial failure, interrupted creation, abnormal exit, unknown input/stream close,
Owner retention and the database barrier. Source guards allow only these exact
dormant consumers. This original Fake-only evidence and installed-client stdio
evidence remain separate from section 17.1; standing CI registration is unchanged.
Fake success is **SOURCE WIRED / FAKE VERIFIED**, with production **REAL WINDOWS
NOT VERIFIED / FORMAL ADMISSION NOT PASSED**.
HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
Full AR-R6B, AR-R9B prerequisites and production vNext remain unaccepted; #327,
Trial 1A and G0-L1/L2/I are untouched and unactivated.

### 17.1. Windows ordinary-child lifecycle evidence

`test/mcp/windows_bridge_process_lifecycle_test.dart` is an independent
Windows-only suite. Its test `WindowsBridgeProcessIo` reuses synthetic PE
inspection and launches the existing Flutter SDK Dart executable with a temporary
script, no shell and no inherited environment. A test implementation of
`WindowsCreatedBridgeProcess` supplies original SDK exit and raw stream Futures
to the production `WindowsBridgeProcess`. It does not execute the private
fixed-adjacent launcher/child wrapper or `shiroha_bridge.exe`.

On 2026-10-23 the Executor actually ran all 12 cases on Windows with Dart 3.11.5:
ready output, stdin EOF, exit 0, independent byte-for-byte stdout/stderr checks
(256 KiB per stream plus markers), nonzero exit 23, interrupted creation/late
transfer, repeated close identity and original-exit retention passed. Separately
gated drain receipts prove that exit alone cannot release custody; these gates
and injected unknown-exit/input/drain failures are test controls, not OS failures.
The original App/Bridge startup and protected-acquisition fixtures use Fake
Owners/Native/TLS and isolated SQLite with the real ordinary-child results.
Confirmed settlement permits Fake Owner release; unknown/failed settlement
keeps admission closed and retains the Owner and App database/Restore close
barrier. A second ordinary child remains untouched. There is no launch retry,
PID lookup or termination. Test-side exit gates, a failure-only child deadman,
original exit/stream joins and temporary-directory removal bound cleanup;
the product has no deadman or forced-settlement timeout.

The first real run exposed SDK creation error 87 with a zero-entry environment.
An isolated `dart --version` control produced error 87 in four zero-entry starts
and exit 0 in four starts with the fixed empty-value padding entry. The bounded
process-layer repair supplies that entry while retaining no parent inheritance.
Every lifecycle child independently checks that its actual environment contains
exactly this one empty value. Source guards require the same fixed map.

| Evidence | Bounded conclusion |
|---|---|
| Fake Process | PASS: Executor reran the original P11 suite, including its Fake process/Startup cases; no Windows OS inference. |
| Windows test subprocess | PASS: 12/12 Executor cases actually executed; original Dart children exited and streams/temporary files settled. |
| Formal Bridge AOT/Loader | UNVERIFIED, including the fixed-adjacent production launcher/child wrapper. |
| Real credentials, TLS and production cross-process runtime | UNVERIFIED; Fake protected Owners and TLS are not real lock/security evidence. |

Standing contract CI runs on Linux and does not execute this Windows-only suite.
Final-head/current-target CI, independent Windows Verifier evidence and independent
Reviewer approval remain separate delivery/merge gates. Ordinary-child PASS
closes no A/X row, X12, formal Windows admission or full AR-R6B/AR-R9B prerequisite.
HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
