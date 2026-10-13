# P13 Windows Host Security Readiness

Status: **Accepted static readiness checkpoint (merged PR #264); P16 freezes the
production primitive candidates and formats in section 9 (merged PR #267).
P17 amends G0 experiment tiers and X.509 signature encoding only. P18 supplies
the first production Native Helper/FFI source slice under section 10. Real Windows security
acceptance is BLOCKED; no production Credential/Pairing/Transport/Host is
activated.**

Authority: [external boundary](external-agent-boundary.md) sections 2, 3, 5–10
own identity, B-class isolation, authorization and offline behavior.
[S0](../../architecture/s0-secure-credential-storage.md) owns Provider credentials;
[MCP vNext](mcp-vnext-contract.md) owns the later client projection, not identity.
This document owns the prerequisite assessment and future acceptance criteria;
its section 9 owns the frozen production candidate decisions, which select
candidates and close no WINDOWS_PENDING item.
The P13 checkpoint changes no business code, credential port, dependency, schema, protocol,
system configuration or production composition.

P14 standing offline coverage is accepted through merged PR #265. P15's offline
implementation candidate is owned by [external boundary §12](external-agent-boundary.md#12-p15-external-credential-boundary-offline-implementation-candidate).
It implements association/verification seams only; M1–M4 real credentials,
protected storage and authentication remain WINDOWS_PENDING. Formal G0-I and
real batch grants are unmet, and
X0–X12 have not been authorized or run. Its private runtime-binding object is
an offline event boundary, not a selected cryptographic nonce/wire format. No
Codex or other upstream process/brand authenticity is claimed.

P16 (section 9) converts the section 4 gap matrix and P15's offline boundary
into frozen production candidates: the certificate and identity model, the
secure credential storage backend and formats, the cryptographic possession
proof and exchange protocol, and the Windows Discovery/local-isolation rules,
plus the minimal implementation packages and their required experiment
authority. It implements nothing, generates no key or certificate, starts no
listener, changes no P0–P15 permission semantic and clears no WINDOWS_PENDING
item. P17 supersedes the single isolated-environment experiment gate with
section 6's tiers: normal implementation/offline work is G0-L0; real experiments
remain BLOCKED_ON_G0 without their exact batch grant (section 9.F).

**HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.**

## 1. Decision and evidence classification

Retain IPv4 Loopback TCP + mTLS as the preferred candidate and Named Pipe as
the sole fallback. Standard Dart APIs support relevant TLS primitives; that
does not prove protected Discovery, credential issuance/storage, handshake
resource bounds, Windows lifecycle safety or packaged interoperability.
No reviewed static evidence conclusively disqualifies TCP against the existing
hard properties. The gaps below prevent implementation activation and real
acceptance; they are not permission to weaken a hard property.

No experiment device/environment or batch authorization has been approved by
this document. Future dynamic admission is **BLOCKED** until the applicable
G0-L1, G0-L2 or G0-I prerequisites and exact batch grant are met. This does not
assert that no suitable device exists.
The static document can be delivered while that gate remains closed.

| Classification | Meaning |
|---|---|
| OFFLINE_CODE | Current repository implements the bounded property; cited P12/preceding tests and historical review support it. It is not a real credential/transport result, and P13 does not rerun those tests. |
| STATIC_API | Official API/platform documentation and inspected SDK/dependency source support a primitive. Integration, failure behavior and Windows release execution remain unproved. |
| WINDOWS_PENDING | Full acceptance needs separately authorized G0-I experiments on independent Windows; approved L1/L2 subsets yield local evidence only (§6). No PASS is recorded here. |
| UNSUPPORTED | A promise excluded by the frozen threat model or an operation outside this candidate; an implementation cannot claim it as a passed condition. |

Experiment evidence uses the following separate labels. OFFLINE_CODE maps to
OFFLINE and STATIC_API to STATIC; neither is a Windows result. WINDOWS_PENDING
remains pending for complete acceptance despite a successful local subset.

| Evidence | Can prove | Cannot prove |
|---|---|---|
| STATIC | API, format and design feasibility | Actual Windows security behavior |
| OFFLINE | Pure algorithms and Application contracts | OS permissions or real connections |
| LOCAL-L1 | Security-primitive functions on the specified device/version/objects | Cross-device stability or complete production security |
| LOCAL-L2 | The specified bounded Loopback/TLS behavior | Formal Host release safety |
| INDEPENDENT-WINDOWS | Actual security results in the specified independent experiment environment | Unexecuted cases or other environments |

P12 is accepted only within its offline scope through merged
[PR #263](https://github.com/duanzhijian200443/shiroha_quiz/pull/263).
Its [contract CI](https://github.com/duanzhijian200443/shiroha_quiz/actions/runs/38233209424)
completed 7/7 successfully, and its
[final Reviewer closure](https://github.com/duanzhijian200443/shiroha_quiz/pull/263#issuecomment-6122245804)
recorded zero P0/P1/P2 and REVIEW APPROVAL. That same review session performed
the user-authorized fixed-target Windows offline checks: External 387 twice,
IPC 112, widget/Origin/B0 46, totaling 932 successful executions. It explicitly
disclosed the departure from a separate Verifier session. This document neither
claims independent-session verification nor invents a VERIFICATION APPROVAL.
Exact merge/head/base identities and execution evidence remain in Git/PR.

### Repository evidence anchors

| ID | Current source/contract and historical test evidence |
|---|---|
| E1 | [P0 TrustCore](../../../lib/application/external/external_trust_core.dart), [P12 coordinator](../../../lib/application/external/external_trust_coordinator.dart), [P12 tests](../../../test/application/external/external_trust_coordinator_test.dart), [memory tests](../../../test/application/external/tcp_core_memory_test.dart): one Principal per selected Profile, synthetic proof, finite enablement and generation invalidation. |
| E2 | [P4 Admission](../../../lib/application/external/external_runtime_admission.dart), [P8 Host](../../../lib/application/external/local_host_dispatch.dart), [P8 tests](../../../test/application/external/local_host_dispatch_test.dart): current management binding, exact execution Session, readiness and real owning drain. |
| E3 | [P11 management](../../../lib/application/external/local_authorization_service.dart), [P1 authorization](../../../lib/application/external/external_authorization.dart), [P11 tests](../../../test/application/external/local_authorization_service_test.dart): non-secret policy only, current revision/Scope/Egress, no pairing activation. |
| E4 | [P9 codec](../../../lib/data/external/ipc_envelope_codec.dart), [P9 tests](../../../test/data/external/ipc_envelope_codec_test.dart), external boundary section 7: exact framing and header-before-body allocation; no authentication. |
| E5 | [P10 projection](../../../lib/data/external/ipc_command_projection.dart), [P10 tests](../../../test/data/external/ipc_command_projection_test.dart), external boundary section 8: authentication/P8 binding before business parsing; preserved effect evidence. |
| E6 | [P3 STAGE](../../../lib/application/external/external_generated_stage.dart), [Proposal repository](../../../lib/data/repositories/generated_proposal_repository.dart), [P12 B0 tests](../../../test/application/external/external_trust_backup_test.dart), [P8 B0 tests](../../../test/application/external/local_host_backup_test.dart): sole writer/key reconciliation and restore/restart boundaries. |
| E7 | [S0 port](../../../lib/data/persistence/engine_credential_store.dart), [S0 adapter](../../../lib/data/credentials/secure_engine_credential_store.dart), [dependency lock](../../../pubspec.lock): Provider-only namespace and typed failures; not an External credential implementation. |
| E8 | [main composition](../../../lib/main.dart), [MCP v0 contract](../../architecture/mcp-v0-contract.md), [P11 source guards](../../../test/application/external/local_authorization_architecture_test.dart), [CI configuration](../../../.github/workflows/pr-contract-checks.yml): no production external activation; P14's standing shards cover the External offline Application/IPC regression matrix, which is not Windows credential/transport acceptance. |
| E9 | [P15 association port](../../../lib/application/external/external_credential_association.dart), [P15 boundary](../../../lib/application/external/external_credential_boundary.dart), [standing P12/P15 tests](../../../test/application/external/external_trust_coordinator_test.dart), [B0 tests](../../../test/application/external/external_trust_backup_test.dart): offline CAS/failures, exact runtime/event binding and private P0 windows; test-only memory authority, no Windows storage/crypto proof. |

## 2. Candidate primitives and static screening

Public references were read for this checkpoint. Current Dart API pages reflect
Dart 3.13.5 and current Flutter platform pages reflect Flutter 3.47; they are not
the repository's pinned toolchain. Repository CI pins Flutter 3.41.9, and the
inspected local SDK reports Dart 3.11.5/windows_x64. Its `dart:io` source also
contains the relevant TLS, DER and minimum-version APIs. Versions are evidence
context, not an authorized upgrade. Future experiments must freeze their exact
SDK, lockfile, architecture and release artifacts and recheck these references.

| Question | Static result and smallest candidate | Remaining real proof / rejection threshold |
|---|---|---|
| Standard TLS | [SecureServerSocket.bind](https://api.dart.dev/dart-io/SecureServerSocket/bind.html) exposes required client certificates; [SecureSocket.connect](https://api.dart.dev/dart-io/SecureSocket/connect.html) takes a trust context. Use an explicitly provisioned context, require client certificates, verify the exact admitted leaf and prohibit accepting bad certificates or TLS key logging. STATIC_API. | Valid, missing, forged, wrong-anchor, expired and wrong-role certificates must be tested. A handshake completing is not business authorization. |
| Handshake admission | Direct secure-server binding has no documented handshake-deadline parameter. [ServerSocket.bind](https://api.dart.dev/dart-io/ServerSocket/bind.html) plus [SecureSocket.secureServer](https://api.dart.dev/dart-io/SecureSocket/secureServer.html) is a candidate way to count accepted TCP sockets before TLS. The raw socket carries no business protocol and is destroyed on failed/late TLS. This is the same TCP/mTLS candidate. STATIC_API plus design inference. | A Future timeout alone does not cancel native work. Prove actual socket destruction, late-completion disposal, bounded native/TLS buffers and slot retention through settlement. If that cannot be demonstrated with the approved SDK, TCP remains blocked. |
| Numeric loopback | Bind an `InternetAddress.loopbackIPv4` object, require the actual local address to equal 127.0.0.1 and use `shared: false`. No hostname resolution, wildcard or IPv6 listener. API support is static only. | Inspect actual bound address and reject publication if it differs; test no LAN/wildcard listening and unauthorized local connection denial before business parsing. |
| Certificate/key loading | [SecurityContext](https://api.dart.dev/dart-io/SecurityContext-class.html) imports PEM/PKCS12 and private-key bytes. Use app-specific anchors without ambient roots, role-separated leaves, explicit validity and a frozen minimum TLS policy. The API does not provide CA/CSR generation or a Windows non-exportable-key signing-handle interface. | Windows release/AOT must load the chosen bounded formats, enforce server/client identity and certificate validity, and deny old rotated credentials. Do not infer CRL/OCSP or live revocation guarantees from a TLS API. |
| Identity mapping | [X509Certificate](https://api.dart.dev/dart-io/X509Certificate-class.html) exposes DER and validity. Candidate identity is a SHA-256 digest of the verified leaf DER, registered to one existing opaque Profile reference by trusted local management; subject/CN, a supplied fingerprint or the SDK's SHA-1 accessor is not authority. | Verify collision/conflict rejection, active local credential registration, exact installation/role and replay/rotation invalidation. The cryptographic suite, certificate profile and registry format need their own bounded approval before implementation. |
| Key generation/issuance | Dart's TLS context loads material; it does not issue it. Windows [BCryptGenerateKeyPair](https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/nf-bcrypt-bcryptgeneratekeypair) and [CryptSignAndEncodeCertificate](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptsignandencodecertificate) support primitives for a minimal native crypto helper. STATIC_API, not a selected implementation. | Prove key ownership, CSR/challenge signature checks, intended SAN/EKU/validity and issuer protection. No certificate algorithm, third-party crypto dependency or native package is selected by P13. |
| Storage and native boundary | Reuse S0's authority separation, typed missing/corrupt/unavailable failures and explicit compensation principles. Do not reuse `engine.<providerId>`, its 4096-rune API-key limit, Provider migration or bulk deletion. A separately approved External namespace/storage boundary is required. | The lock resolves flutter_secure_storage 10.3.1 / Windows 4.1.0. [The versioned Windows package](https://pub.dev/packages/flutter_secure_storage_windows/versions/4.1.0) stores by default one DPAPI-wrapped JSON map file and keeps an AES-GCM/Credential Manager-key legacy path; neither satisfies the External contract (§9.B.1). Prove missing/corrupt-key behavior without silent rekey, ACLs and owner-only operations. No Provider entry may change. |
| Discovery/Windows integration | A minimal Windows adapter is justified for security-descriptor creation/inspection and object-identity-safe publication/cleanup, which current external code does not implement. Flutter documents [Win32/FFI integration](https://docs.flutter.dev/platform-integration/windows/building); transitive ffi/win32 dependencies are not authority to add a new adapter. | Prove exact DACL/owner, reparse/parent substitution resistance and replacement/cleanup by object identity. Failure must close the candidate. A directory name or profile-local path alone is insufficient. |
| Packaging | [Dart AOT executables](https://dart.dev/tools/dart-compile) and [Flutter Windows distribution](https://docs.flutter.dev/platform-integration/windows/building) are supported building blocks. S0's Flutter MethodChannel plugin is not evidence that a standalone Dart AOT Bridge can use that backend without a Flutter engine. | Freeze native dependency loading and a minimal standalone Bridge storage/crypto solution. Test packaged release, not just JIT or the developer machine. TLS credentials are separate from code-signing certificates; no OS root installation or release change follows from this plan. |

### Storage and Discovery constraints

[Windows DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
provides user-associated protection; using its machine-wide flag would not
provide the required user boundary. It does not isolate programs sharing that
user identity. It is one possible dedicated External backend, not a property
automatically inherited from S0. [Credential Manager reads](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credreadw)
use the current token's logon credential set. The plugin's
[CRED_PERSIST_LOCAL_MACHINE](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentialw)
means persistence across this user's logons on this computer; it must not be
confused with DPAPI's machine-wide decryptability flag.

Discovery, public trust anchors and credential association metadata need
integrity even when they contain no private key. Proposed objects are inside a
separate experiment-owned local NTFS root, protected at creation with explicit
owner-SID rights and only separately justified system rights. No null DACL or
permissive inherited Everyone/Users/anonymous rights are accepted.
[DACL semantics](https://learn.microsoft.com/en-us/windows/win32/secauthz/access-control-lists)
distinguish an absent DACL from an empty one. Both directory and child-object
rights must be checked: [file security](https://learn.microsoft.com/en-us/windows/win32/fileio/file-security-and-access-rights)
does not make a parent's descriptor an access check for every child.

The later adapter must create or securely open and validate the actual object,
parents and volume before use; reject unexpected owners, reparse traversal and
unsafe pre-existing objects. [CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)
supports security attributes and reparse-related flags, but a final-component
flag alone is not a proven defense for substituted parents. Atomic publication
and cleanup must retain verified handle/file identity and this runtime's random
ownership identifier, not just a pathname, PID or stale descriptor. An uncertain
object is left untouched and the Host remains closed; no broad stale-file sweep.
No AF_UNIX lease/unlink experiment is implied by these Windows requirements.

## 3. Credential, pairing and Host trust boundary

The following is a future candidate composition, not a production route.

```mermaid
flowchart TD
    U[Trusted local Shiroha selection and approval] --> P[P11 opaque existing Profile reference]
    U --> A[App-owned issuer and protected trust registration]
    B[Bridge-owned key in separate protected External store] --> C[Fresh signed pairing challenge]
    A --> C
    C --> V[Trusted adapter verifies possession and current registration]
    P --> T[P0 unique Principal and PairingState]
    V --> T
    E[Explicit local finite enablement] --> T
    M[Authenticated TLS connection and protected server anchor] --> V
    T --> S[P0 Session and P4 current binding]
    S --> H[P8 and P7 current Grant Scope Revision Egress]
    X[Untrusted P9 bytes and P10 business input] --> H
    H --> D[Existing owning services and P3 transaction]
    D --> R[Original Proposal and SubmissionKey reconciliation]
```

The smallest candidate responsibility split is:

1. App owns the installation issuer/server credential, approved trust anchor,
   credential-to-Profile association and revocation decision. Bridge generates
   and holds its own client key; only public enrollment material reaches App.
   Never bundle a reusable private key or install a general OS trust root.
2. App locally selects an existing unrevoked opaque Profile reference and
   registers its P0 Principal using the accepted P12 seam. CSR names, JSON ids
   and historical Origin cannot choose or reconstruct that Principal.
3. Local request/approval binds the expected credential identity to one pairing
   request. A fresh challenge must bind request, selected Profile, installation,
   runtime generation, intended key/certificate and finite expiry. Trusted
   verification must reject reused, expired, mismatched or replaced challenges.
   Approval alone cannot produce `PairingProof` or a paired state.
4. Bootstrap public enrollment/challenge delivery is a separate locally approved
   control-plane design still to be frozen. P9/P10 have no pairing route. Do not
   add one to their fixed business schema or use an unauthenticated business
   listener. A lab may use explicitly authorized local public-material exchange;
   it is not acceptance of a real client enrollment UX/protocol.
5. Perform asynchronous TLS/secure-store/crypto work in infrastructure. The
   existing synchronous `ExternalCredentialPort` only accepts adapter-owned,
   channel-bound verified attempt objects and checks current generation,
   registration, validity and liveness; missing/stale evidence returns null or
   a fixed failure. It must reject externally constructed `PairingProof`,
   `AuthenticatedPeerEvidence`, Profile strings and claimed fingerprints.
   Adapter evidence expires or is invalidated on disconnect/rotation/replacement.
   It is not a second Principal system or a durable Session table.
6. `provePossession` supplies only the existing P0 request/credential result
   after that verification. `authenticate` supplies only the verified credential
   identity; P0 maps it to its already registered Principal. Explicit finite
   enablement remains a separate local action. P4 then admits the current Session;
   P8/P7 still check current business authority and final release.

The credential association must be integrity-protected outside the non-secret
Profile/Grant tables and refer only to their existing App identity. Its format,
creation/rotation commit points and failure reconciliation require separate
approval. On restart, validate it and bind existing Profiles afresh with business
access disabled. On Restore, surviving credential material does not resurrect
the old association, pairing or enablement; fresh local recovery/proof is required.
B0 does not create/copy/delete secure credentials. No auto-healing corrupt trust
record, issuer/key regeneration, Provider-key reuse or schema change is approved.

The current P12 coordinator is named `.offline` and cannot be relabeled as a
production entrypoint. Any future production wiring requires its own bounded
contract/acceptance review without changing P0/P4 authorization semantics.

### B-class and cross-user cases

Other SIDs may TCP-connect; the contract does not promise OS-level rejection at
connect. Their unauthorized credentials and protected-object accesses must fail.
A separately approved legitimate client under another SID, with its own provisioned
key, approved trust material and current Profile/Grant/enablement, may obtain
business access. For that positive lab case, supply approved public endpoint/trust
information into that client's own protected root; do not make the App owner's
protected Discovery or secrets readable to other SIDs. Multi-user provisioning
and distribution are unresolved production details, not an inferred feature.

Same-SID Bridge proxying is the accepted residual risk. User-wide account takeover,
administrator/kernel attackers, brand/process attestation from a certificate,
absolute local denial-of-service prevention, and guaranteed non-exportable TLS
keys never present in process memory are UNSUPPORTED promises. Loopback is not
authentication; mTLS is not Windows ACL isolation. None of these exclusions
relaxes current Grant/Scope/Egress or explicit local COMMIT.

## 4. Production security gap and dependency matrix

All production implementation/experiment rows require new authority; P13 authorizes only
this static assessment. P15 separately authorizes OS-independent offline seams,
not protected Windows objects or experiments. Dependencies refer to row numbers and G0
(approved environment and exact experiment grant, section 6).

| ID / boundary | Current status and evidence | Missing proof / minimal next step | Failure closure | New authority / prerequisite |
|---|---|---|---|---|
| M1 Credential Authority | OFFLINE_CODE E1/E9 association rules; production issuer/client key ownership absent. STATIC_API native crypto primitives. | Freeze Bridge key ownership, App issuer/leaf roles and protected one-credential/one-Profile registration; implement only a reviewed bounded helper. Prove possession, conflict and rotation. | Reject unknown/duplicate/wrong-role credentials; do not mint a Principal from claims or regenerate trust automatically. | Implementation + key-generation grant; G0, M2. |
| M2 Secure Storage | OFFLINE_CODE E7 for Provider rules and E9 for separate association/failure port; STATIC_API Windows stores. Production External store absent. | Dedicated namespace, bounded certificate/key material, current-user protection, exact read/write/delete scope, corrupt/missing/unavailable distinction and compensation; standalone Bridge backend proof. | Missing denies connection; corrupt hard-denies; unavailable closes admission with fixed transient classification. No plaintext or Provider fallback, bulk deletion or silent rekey. | Dedicated storage/crypto resources; G0. |
| M3 Pairing Proof | OFFLINE_CODE E1/E9 state/proof gate and private request/runtime-bound windows; cryptographic freshness/bootstrap absent. | Bind local approval to fresh request/key/install/generation challenge and independently verify a possession signature. Freeze control-plane delivery separately. | Failure remains pending proof; no paired state, credential acceptance or permission expansion. | Enrollment/crypto grant; G0, M1, M2. |
| M4 Client Authentication | OFFLINE_CODE E1/E2/E5/E9 map/admission and one-use verifier adapter; real cryptographic/TLS events absent. | Authenticate TLS leaf and protected registration before business input; async proof -> adapter-owned live attempt -> existing P0/P4. | Reject wrong owner/Profile/credential/generation/role and all payload-derived identity; no Session fallback. | TLS/adapter grant; M1–M3, M6, M8. |
| M5 Windows Isolation | STATIC_API DACL/current-user primitives; no External cross-SID experiment. | Negative SID cannot read/modify owner's protected objects; positive separately provisioned SID obeys B-class business admission. Same-SID proxy risk remains documented. | Reject unauthorized object/business access; do not claim all TCP connect calls are refused. | Two lab principals and explicit account/ACL authority; G0, M2, M6, M8. |
| M6 Protected Discovery | No production discovery publisher/consumer. STATIC_API file/handle security. | Secure root/child creation, owner/DACL/volume/reparse checks, authenticated anchor, atomic publication and object-identity cleanup; independently validate both ends. | Missing/stale/tampered/uncertain discovery is unavailable; leave foreign objects untouched; no temporary unprotected replacement. | Object-creation/ACL grant; G0, M2, M1 for server trust. |
| M7 Loopback Transport | No external listener. STATIC_API explicit IPv4 binding. | Require actual 127.0.0.1, no sharing/wildcard/resolution, bounded raw accept -> required TLS, and cleanup of owned sockets only. | Reject startup/address mismatch; destroy candidate sockets; publish no usable endpoint. | G0-L2 batch for local subsets; G0-I for formal acceptance; M6, M9. |
| M8 mTLS | Standard primitives STATIC_API; all real validation WINDOWS_PENDING. | Server/client trust, exact leaf registration, SAN/EKU/validity, protocol floor, key access, anchor replacement, rotation/revocation and resumption policy. | Never accept bad certificates, unknown roots, expired/wrong-role/retired identities or TLS key logging; invalidate connections on credential/anchor change. | Certificate/TLS grant; M1, M2, M3, M6. |
| M9 Resource Limits | OFFLINE_CODE E2/E4/E5 for per-frame/business bounds; no connection/native TLS budget. | Numeric lab limits, pre-TLS slots, global decode reservations, one bounded request/response pipeline, real deadline destruction and measured native/heap/backpressure behavior. | Reject before unbudgeted allocation/handler entry; keep owning slots until settlement; close slow/over-budget channels. | Bounded load grant; G0, M7, M8. |
| M10 Lifecycle | OFFLINE_CODE E1/E2/E5/E6 for controlled drain/restart/B0. OS crash/socket/Discovery recovery absent. | Block accepts and new calls, drain owning work, invalidate evidence and generation, then swap/cleanup; cold start disabled; test crashes and stale endpoint impostors. | No late-ready publication or permission revival; uncertain cleanup leaves Host closed, without forced data rollback. | Controlled termination/restart/B0 grant; M4, M6–M9. |
| M11 Effect Recovery | OFFLINE_CODE E5/E6 original key/Proposal and commit-vs-revoke authority. Real disconnected client absent. | Cut response after commit, reconnect with fresh admitted Session, reconcile original key; absent result stays unknown. | No automatic STAGE retry, second writer/journal/Receipt table or inferred zero effect. Bridge absence never opens SQLite. | Synthetic-data effect/failure grant; M4, M9, M10. |
| M12 Packaging | Existing Flutter Windows project/locks; standalone Bridge/native deployment absent. STATIC_API E7/E8 and AOT docs. | Exact x64 release artifacts, native ABI/dependency loading, space/Unicode paths, restricted launch environment, upgrade/cold start and trusted endpoint handoff. | Missing/invalid native/backend/anchor artifact keeps Host disabled; no build/download/elevation fallback. | Build/package/launch grant; G0, M1–M11. |

M2/issuance format and M6 can be designed in parallel, but their runtime
publication waits for G0. M7/M8/M9 must be assessed together before any business
payload crosses a live connection. All security and stability gates are separate;
security success cannot clear HOST_STABILITY_HALT. P16's section 9 freezes the
selected production candidates for M1/M2/M3/M6/M8 inputs; the rows below keep
their acceptance, failure-closure and closure authority.

## 5. Framing compatibility and resource acceptance

Existing E4/E5 limits stay fixed: header 16 bytes, ID at most 64 bytes, request
6,324,224 bytes, response 229,376 bytes, protocol error 32 bytes, decoder/frame
byte ceiling 6,324,304. P10 retains its separate exact schema/version and the
1 MiB original Submission limit; P4/P5 output is 32 KiB, P6 output 24,000 bytes.
The decoder admits header and ID before body allocation. These are OFFLINE_CODE
properties, not aggregate connection/TLS memory guarantees.

For two concurrently admitted maximum request frames, explicit decoder bytes
plus worst-case decoded UTF-16 storage alone can reach
`2 × (6,324,304 + 2 × 6,324,224) = 37,945,504` bytes, before parser copies,
caller buffers, outputs, TLS/native allocations or business objects. P9's byte
ceiling therefore cannot be used as a process resident-memory ceiling.

The following is a **proposed first-lab budget**, not production capacity or a
measured PASS. The future grant must explicitly freeze it or approve a reviewed
replacement before running load; an absent numeric budget is BLOCKED.

| Resource | Proposed experiment ceiling / required observation |
|---|---|
| Accepted live TCP sockets / TLS handshakes | 8 total / 2 pending handshakes, counting pre-authentication work; overflow destroyed without business parsing. |
| Active frame pipelines | 2 globally; one request per connection; reservation retained through real decode/business/output settlement, not merely caller timeout. No unbounded envelope queue. |
| Explicit protocol byte / decoded-string reservations | 16 MiB / 32 MiB globally, separately measured; includes retained ingress/egress copies within those categories. Reserve conservatively before allowing payload allocation. |
| Write queues | At most one response per connection and 512 KiB globally; enforce the unchanged per-frame response limit before enqueue. |
| Handshake / incomplete-frame deadlines | 5 seconds handshake; 2 seconds no-progress; 10 seconds total frame assembly. Timeout must dispose the real socket and any late TLS result. |
| Business calls | Preserve each existing service guard: READ at most 16 global / 4 per Profile; STAGE at most 16 global / 4 per exact Session. The proposed shared transport pipeline ceiling is stricter. READ retains its complete two-second bound; STAGE keeps owning work until true settlement. |
| Measured memory / handle recovery | For the isolated minimal candidate harness, predeclare a warmed baseline; proposed peak process private-memory delta <=128 MiB and settled handle/slot counts return to baseline after each bounded trial. Measure native/TLS/OS buffers too; no unlimited logging or queue can be excluded. |

Stream pause and an OS listen backlog are not substitutes for a measured bound.
Limit parser admission and copies as well as P9 buffers; abort the trial at its
approved ceiling rather than escalating load. If these provisional bounds are
insufficient, report measurements and request a new reviewed scope/budget instead
of silently increasing them. P13 implements or tests none of these limits.

## 6. Future experiment authorization and environment

### G0 tiers (P17 amendment)

This amendment permits applications for controlled primary-host experiments;
it grants no experiment execution authority. Each real batch needs separate,
explicit user approval. An implementation task, a merged contract, or another
batch's success never supplies that approval or clears HOST_STABILITY_HALT.

| Tier | Permitted scope / gate |
|---|---|
| G0-L0 — normal development | On the primary computer, write C++/Win32 Native Helper, Dart FFI Adapter, Credential Store, Discovery and Host source under normal scoped task authority; compile, analyze, format and run offline pure-algorithm/Mock tests that touch no real Windows security objects. No real-experiment grant is needed. Code authority still does not authorize Host activation or later Git actions. |
| G0-L1 — controlled host security primitives | Only after individual user approval: DPAPI Protect/Unprotect on separate test objects; NTFS DACL/Owner inspection in the approved test directory; experiment-only locks/handles and normal release; finite atomic file replacement; temporary test keys/certificates. Exact operations and quantities must be granted. No sockets/listeners. |
| G0-L2 — controlled host Loopback | May be requested only after necessary L1 prerequisite evidence passes and the current implementation has independent review. One bounded 127.0.0.1 TCP/mTLS candidate, real TLS 1.3 handshake, authentication/connection behavior with no business routes, exact resource counting and closure. No LAN/wildcard, production Host activation, unauthenticated business route, STAGE or unapproved stress test. |
| G0-I — independent Windows formal acceptance | A separately controlled physical Windows machine or remote Windows host with a kernel independent of the primary computer. Complete the original A0–A12 matrix and corresponding X0–X12 trials under their exact grants. A normal primary-host VM does not automatically qualify. Security acceptance and system-stability acceptance close separately. |

Every L1 application must freeze the user-selected device, empty test root,
objects, operations and quantities. The root must be completely separate from
formal Shiroha data, credentials, databases and personal files. Freeze backup
and recovery responsibility, a maximum run time, memory/handle/resource budgets,
STOP conditions and cleanup rights. The Native Helper must pass source review
and necessary memory, handle and error-path checks before its real calls.
Ordinary experiment processes stay non-elevated. No global certificate trust
store, system account or formal ACL change is allowed. Creating a second SID
or performing aggressive negative cases needs separate explicit authority;
L1 grants neither by default and cannot substitute for G0-I cross-SID acceptance.

Every L2 application must additionally freeze port/bind method, socket and
handshake counts, time/memory/handle ceilings, source SHA and artifact hashes,
wrong-certificate rejection cases, STOP and recovery plans. L1 approval does
not authorize L2; each L2 batch needs its own user approval. Section 5's proposed
lab budget is not an implicit L2 grant or permission to escalate load.

For every real batch, freeze source/head/base, artifacts, OS edition/build/patch,
architecture, toolchain/lockfile, scope and budget; name an independent
fixed-target Verifier and independent Reviewer. Drift invalidates affected
evidence. Each approval applies only to its named tier, objects, operations,
trial counts and time window; no inheritance to another experiment.

**This P17 PR only revises the contract for requesting L1/L2. No L1, L2 or
G0-I experiment is authorized or executed by it.**

### G0-I formal acceptance prerequisites (original G0 retained)

Full formal acceptance remains unmet. Every G0-I batch needs a new explicit
user grant identifying:

- A separately controlled physical Windows machine or remote Windows host whose
  kernel does not depend on the primary computer. A normal VM running on the
  primary host does not qualify automatically. Identify owner, device, recovery
  responsibility and isolation boundaries; no suitable device is assumed.
- Exact serviced Windows edition/build/patch level, architecture, local NTFS
  test volume, SDK/Flutter/native toolchain/lockfile and artifact hashes. The
  proposed first batch is Windows 11 x64; VS C++/ATL requirements must be met.
  [Current Flutter platform documentation](https://docs.flutter.dev/reference/supported-platforms)
  lists Windows 10/11 x64/Arm64, but is newer than this repository's CI SDK.
  Windows 10 requires explicitly verified ongoing servicing and SDK support;
  Arm64 or another packaging model needs a separately named batch, not inferred
  acceptance from an x64 run.
- Two named disposable local principals with different SIDs. Privileged account
  preparation is a separately authorized setup action; ordinary App/Bridge runs
  remain non-elevated. Do not alter the primary user's accounts, ACLs or stores.
- An empty dedicated experiment root, separate secure namespaces and synthetic
  SQLite/B0 assets only. No official App profile, saved Provider key, user document
  or private corpus; no sharing of the primary machine's data directories.
- Exact allowed sockets/ports, credentials/objects/permissions, process termination,
  trials/time/load ceilings, evidence output and cleanup rights for each X row.
  No LAN/wildcard exposure, global trust-root installation, firewall/driver/kernel
  changes, AF_UNIX or production Host/MCP activation is included.
- An inventory of original lab configuration and owned artifacts; a restorable
  device image/approved recovery procedure before mutations. Record only fixed
  failure categories, counts, generation/test IDs, public digest references and
  sanitized timestamps. No keys, PEM/private blobs, TLS key logs, prompts, full
  payloads, secret environment variables or unrestricted memory dumps.
- Named stop/recovery operator and independent fixed-target Verifier/Reviewer.
  Freeze head/base, build artifacts, OS and budget per run. Environment or target
  drift invalidates the affected evidence; do not resume by guessing state.

The original X0–X12 request below is an approval checklist, not runnable
instructions. Each complete row retains its G0-I formal acceptance goal and
prerequisites; local subsets are classified separately below. Storage/object and credential
primitive trials precede TLS setup; socket-bearing rows also require explicitly
approved X0 resources. Permission to one row does not
grant another, or authorize production activation.

| Experiment | Unique primary goal / criterion | Resources to explicitly authorize | Dependencies |
|---|---|---|---|
| X0 | A0: exact loopback-only candidate startup | Named ephemeral loopback sockets, protected server material/descriptor and primitive processes; numeric resource preflight; no business routes. | X1, X3; static budget/storage/crypto/Discovery contracts approved. |
| X1 | A1: unique credential-to-Profile mapping using real possession proof | Disposable client/issuer keys and public certificates; protected association entries; local approval surface only. | X3; M2 format/storage design. |
| X2 | A2: deny absent/forged/wrong-anchor credentials | Bounded positive-control and negative TLS/proof attempts and disposable alternate anchors; exact loopback sockets. | X0, X1, X3. |
| X3 | A3: protected-object cross-SID secrecy/integrity | Named lab accounts; explicitly owned NTFS objects/DACLs and credential namespaces; bounded read/write/replace attempts. | Approved object/security design. |
| X4 | A4: B-class positive/negative business admission | Two disposable principals; independent client keys and approved public endpoint/anchor copies in each owned root; synthetic Grant. | X0–X3, X6, X7. |
| X5 | A5: no authority resurrection | Explicit disable/revoke/expiry, candidate restart and synthetic B0 Restore/raw rollback; no Provider-store mutation. | X4, X7 resource preflight. |
| X6 | A6: reject bad lengths before body allocation | Synthetic bounded P9 header/ID variations over the candidate channel; allocation counters, exact time/trial caps; no business routes. | X0–X3. |
| X7 | A7: bounded connections/backpressure/settlement | Approved 8/2/2 ceilings or approved replacement; slow peers, cancellation, bounded connection cuts and numeric measurements; primitive phase before route-bearing trials. | X0–X3, X6; then X4 for business settlement cases. |
| X8 | A8: committed/lost STAGE reconciliation | Synthetic Proposal/key/SQLite, controlled response cut after commit and fresh reconnection; exact owning checkpoints. | X4–X7. |
| X9 | A9: Bridge has no alternate business writer | Bounded App absence/not-ready/closed runs and file-open/access audit for the synthetic DB. | Packaged candidate Bridge; no real DB. |
| X10 | A10: retain external allowlist and MCP v0 | Existing offline compatibility fixtures and, only if separately named, synthetic retained-v0 stdio runs. No vNext registration or protocol expansion. | Candidate artifacts; standing regression target. |
| X11 | A11: owner-safe endpoint cleanup | Two candidate runtime processes (the superseded/second one must fail closed under the 9.D supersession/single-writer lock while the holder keeps serving — including concurrent initialization and store-commit attempts, which must never interleave read–CAS–commit transactions), disposed sockets and experiment-only descriptors; bounded termination/replacement races and foreign-object sentinels. | X3, X7; object-identity cleanup design. |
| X12 | A12: release launch/recovery compatibility | Named release/AOT artifacts, native DLL dependencies, space/Unicode install roots, disposable cold-start/upgrade/crash scenarios. | X1–X11; packaging model frozen. |

Address/TLS/storage/Discovery validity is a common preflight for every socket
trial, not a business success inferred from X6/X7. Abort admission if the actual
listener is not exactly 127.0.0.1, the peer/anchor is invalid, or protected-object
security/ownership cannot be proven. Initial primitive trials expose no business
routes; route-bearing trials require those preflights plus the applicable gates.
X7's primitive resource phase must pass before X4 exposes business routes; its
owning-business settlement cases then reuse the admitted X4 composition. This
phase distinction does not grant more resources or require a circular dependency.

### X0–X12 local subset mapping (P17)

Each local entry below is eligible for a separate application only, not an
approved run. Local evidence must identify the exact subset and retains the
row's dependency checks for that subset; missing prerequisites block it. Every
complete X/A goal still requires G0-I, the original section 7 standard and
independent Verifier/Reviewer evidence. No LOCAL-L1/LOCAL-L2 result automatically
marks an A row PASS or closes security/system-stability acceptance.

| Original row | Possible local evidence under an exact batch grant | Still required under G0-I |
|---|---|---|
| X0 / A0 | L2: single bounded numeric Loopback bind, actual address and normal close; L1 supplies test credential/descriptor primitives first. | Complete startup/publication and configuration-substitution rejection matrix. |
| X1 / A1 | L1: temporary key/certificate encoding, possession-signature verification and test association operations on synthetic identities only. | Complete fresh proof/selected-Profile mapping, uniqueness, substitution, rotation and authenticated-peer correlation. |
| X2 / A2 | L2: bounded valid/missing/forged/wrong-anchor/expired/wrong-role test-certificate rejection cases explicitly listed in the grant, with no business routes. L1 may supply pure primitive checks. | Full proof/TLS replay, retired-identity and no-Session/handler/content matrix. |
| X3 / A3 | L1: owner/DACL inspection, DPAPI round trip, test locks and finite atomic replacement on owned test objects; no second SID or aggressive negative cases inferred. | Complete unauthorized cross-SID secrecy/integrity, reparse/parent substitution, corruption and no-silent-rekey matrix. |
| X4 / A4 | None under L1/L2: real B-class business admission exceeds their scope. Existing OFFLINE checks remain useful. | Two-principal positive/negative admission with current synthetic policy after original dependencies pass. |
| X5 / A5 | L1: explicitly scoped test-object credential invalidation/reload functions; L2: normal connection closure only. These prove no business-authority lifecycle. | Complete disable/revoke/expiry/rotation/restart/B0 Restore/raw rollback and no-resurrection matrix. |
| X6 / A6 | No live framing trial under the authentication/connection-only L2 scope; existing P9 OFFLINE length/allocation checks remain useful. | Full real-channel malformed-header/ID allocation and safe-close matrix at unchanged limits. |
| X7 / A7 | L2: exact socket/handshake/handle counts, deadlines and normal closure inside its approved budget, including only explicitly approved bounded slow/cut cases. No stress or business settlement inferred. | Full frozen frame/queue/memory/backpressure/cancellation/owning-business-settlement matrix. |
| X8 / A8 | None: STAGE and committed response-loss trials are forbidden in L1/L2. OFFLINE reconciliation tests remain useful. | Real-channel durable commit/lost response, revoke ordering and original-key reconciliation. |
| X9 / A9 | STATIC/source guards and OFFLINE unavailable-path checks under L0; no local real App/Bridge business run implied. | Packaged Bridge absence/readiness/close/recovery and synthetic-DB access audit. |
| X10 / A10 | L0 STATIC/OFFLINE compatibility regressions; L1/L2 add no tool/publication authority. | Complete current compatibility/allowlist criterion; any named runtime stdio trial needs its own G0-I grant. |
| X11 / A11 | L1: owned test-lock contention and normal handle release; L2: its one candidate's normal socket close. No crash, competing Host or foreign-object attack trial inferred. | Full two-runtime/store-writer exclusion, termination/replacement races and foreign-object-safe cleanup. |
| X12 / A12 | L0: compile/inspect release artifacts; L1: separately approved primitive-only helper loading in space/Unicode test paths. | Complete packaged App/Bridge cold-start/upgrade/abnormal-close, endpoint supersession and invalid-artifact matrix. |

### Immediate stop and recovery

**HOST_STABILITY_HALT = ACTIVE.** Primary-host old AF_UNIX ROOT-ACL,
Endpoint Lease and Close/Unlink dynamic experiments remain permanently halted
and must never rerun automatically. High-risk crash, driver or kernel anomaly
reproduction remains forbidden on that host. New TCP/DPAPI/CNG/NTFS experiments
there may run only through their exact G0-L1/L2 exception grants; those grants
do not lift the halt or carry authority to another experiment.

Stop on a blue screen, hard hang, kernel/driver anomaly, unexpected elevated
process/system mutation, wrong bind address, secret exposure, unauthorized object
or business access, ownership uncertainty, budget excess, unexplained data
change or data corruption, unknown handle ownership, target/environment drift or
failure requiring an unapproved primitive. Do not reproduce a blue screen to
prove causality or automatically retry on the primary host. The reported
AF_UNIX-associated event remains a reported instability with no proven complete
kernel-failure causal chain; it establishes neither inevitable TCP/mTLS failure
nor TCP/mTLS safety.

Block new candidate work first. On a responsive approved test device, close/drain
owning services before authorized teardown; interrupted callers do not prove
settlement. For an unresponsive device, use only the preapproved recovery operator
and image procedure; mark in-flight STAGE unknown. Preserve sanitized evidence
and the original submission keys. Cleanup is limited to positively owned lab
objects; do not delete foreign endpoints/credentials, wipe Provider stores,
terminate unrelated processes or destroy Proposal/user data. No automatic retry.

## 7. Real acceptance and fallback thresholds

All A rows currently remain WINDOWS_PENDING. The offline column describes
existing evidence, not tests run in P13. Each real result must cite one fixed
target/environment/trial record and the measured counters; missing or ambiguous
evidence is INCONCLUSIVE/BLOCKED, never PASS. No item is waived because the
candidate is loopback-only or a lower-level primitive trial succeeded.
P17 changes only experiment eligibility: complete A0–A12 acceptance still needs
G0-I evidence for the original criteria below; LOCAL-L1/LOCAL-L2 is subset
evidence only. Windows security and system-stability acceptance remain separate.

| ID | Offline boundary already covered | Required real PASS / corresponding FAIL |
|---|---|---|
| A0 | Standard numeric IPv4 API support only. | Candidate listener's actual local address is exactly 127.0.0.1; wildcard, LAN, IPv6 and shared publication are rejected, including configuration substitution. Any other reachable listener/address or unprotected descriptor publication is FAIL. |
| A1 | E1/E2 unique Principal/opaque binding. | Valid fresh cryptographic possession proof and current registration resolve exactly one selected existing Profile; duplicate identity, substituted Profile or another generation never resolves. X2/X4 must then confirm the authenticated TLS peer uses that same registered identity. Wrong binding or claim-derived identity is FAIL. |
| A2 | E1/E5 synthetic rejection and auth-before-business parsing. | Missing/forged key, unknown/retired leaf, wrong anchor/role, invalid validity or replayed/expired pairing challenge yields no usable Session, handler or content. Bad-certificate bypass, trust-on-first-use from Discovery or fallback is FAIL. |
| A3 | No real Windows object proof. | Other unauthorized SID cannot read, alter, replace, delete or redirect protected credentials/association/Discovery/anchor objects, including unsafe inheritance, reparse/parent replacement and corrupt-key cases. Any successful protected access or silent rekey is FAIL. |
| A4 | E1/E2 separate Profiles and current Grant checks. | Unauthorized SID may connect but receives no business access. A separately provisioned cross-SID credential with current approved Profile/Grant/enablement behaves according to B-class; no read of the owner's protected Discovery is required. All-cross-SID-connect rejection and brand/process attestation are UNSUPPORTED promises, not pass substitutes. |
| A5 | E1/E2/E6 disable/expiry/revoke/generation/B0. | Revoke, finite enablement expiry, restart, credential/anchor rotation and Restore deny old Session/Context and unreleased egress. Fresh authentication cannot renew old execution authority; raw rollback may retain policy/history but starts disabled and requires fresh proof/rebinding. Revival is FAIL. |
| A6 | E4 complete-header/ID validation precedes payload allocation. | Zero/high-bit/over-limit/unsupported header or invalid ID allocates no declared body, enters no handler and closes the decoder/channel safely. Exact ceilings remain unchanged. Late allocation/reuse/resynchronization or weakened limits is FAIL. |
| A7 | E2/E4/E5 per-frame/business limits and owning drain. | All frozen connection/handshake/frame/queue/memory/time counters remain within the authorized numeric budget; slow/fragmented/coalesced input, cuts, cancellation, deadline and shutdown release real resources only at settlement. Budget excess, unlimited buffering or premature slot reuse is FAIL. |
| A8 | E5/E6 both STAGE transaction orderings and original-key recovery. | Cut output after durable commit; fresh admitted reconnection/current policy reconciles the same original key/Proposal with no auto-retry/duplicate or formal Question commit. Revoke-first publishes none; publication-first retains history while withholding unauthorized output. Unknown/absent is not invented zero effect. Contradiction is FAIL. |
| A9 | E8 contract/compiled composition boundary. | App absent, not-ready, closed or recovering gives bounded unavailable/denied behavior. Bridge neither opens the business SQLite DB nor loads repositories/migrations or starts a replacement writer. Any such fallback is FAIL. |
| A10 | E2/E8 exact ten internal external routes and six MCP v0 READ tools. | Current compatibility checks retain those surfaces and deny every external COMMIT/DESTRUCTIVE/Built-in route. P13/candidate trials register no vNext tools. Changed v0 or expanded authority is FAIL. |
| A11 | E2 controlled owning shutdown; no real endpoint ownership proof. | Normal close, abort/startup race, crashed prior runtime and competing replacement leave another process's sockets/descriptors/credential objects and sentinel data untouched. Cleanup uses proven ownership/object identity; ambiguous state fails closed without deleting it. Wrong deletion or shared/wildcard listener is FAIL. |
| A12 | Static AOT/platform support only. | Exact packaged release/native backend works non-elevated from space/Unicode paths and a sanitized launch environment, after abnormal close, upgrade and cold start. Old endpoint/anchor cannot impersonate the new App — a second live External runtime must fail closed (9.D supersession single-liveness and store single-writer exclusion: it neither serves, publishes, binds nor writes store objects while the holder lives), a stale signed descriptor (including one paired with the retired still-valid leaf, or below the pinned epoch) is refused or can reach only a dead endpoint, and a successor is accepted on first sighting without re-enrollment after a same-generation restart; invalid native/store artifacts keep it disabled. JIT-only success, developer-only dependencies or authorization revival is FAIL. |

Disconnected channels must stop accepting new calls and drop their adapter-owned
attempts; no disposed connection can recreate its Session. P0 has no standalone
per-Session close API, so do not claim it revokes one Session merely because a
socket closes. Runtime disable/generation invalidation remains P0-owned, P7/P8
execution stays exact-Session-bound, and another current legitimate Session of
the same Principal retains P4–P6's existing READ-reference semantics. Already
started work settles in its owning service; disconnect never proves rollback.

### Named Pipe fallback

TCP/mTLS stays blocked if required crypto/storage, Discovery integrity, bounded
TLS admission, credential validation or release/AOT behavior cannot be proved
within the frozen model. Report the specific failing A/M property and static or
isolated evidence before proposing the fallback; no automatic switch or third IPC.

[Windows Named Pipe security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
supports explicit descriptors, but defaults include broad read access and generic
write rights can also permit instance creation. A separately authorized fallback
must freeze narrowly scoped rights, local-only operation, server impersonation
defense, authenticated peer/credential mapping, resources, cleanup and packaging.
Pipe ACLs alone do not grant a Profile/Grant, establish a trusted App server or
pass Application authorization. It must pass all applicable A criteria, retain
the B-class business rules and support the explicitly approved cross-SID case;
if this requires changing frozen semantics, STOP for user direction.

If neither candidate satisfies every hard security and stability property, keep
production Host and AR-R6B closed. Do not lower trust, add plaintext keys or an
unauthenticated business fallback to make the connection work.

## 8. Smallest subsequent responsibilities and activation gate

These are bounded future responsibility packages, not task state or automatic
authorization. Each needs its own explicit scope/ownership, fixed acceptance and
independent review; none is started by P13 or a merged readiness document.

| Package | Smallest responsibility | Exit condition |
|---|---|---|
| Experiment batch authorization | Apply for the appropriate G0-L1/L2 or G0-I batch at the real-call boundary; section 9 already freezes certificate/challenge/storage/Discovery formats. This is not another general offline design stage or a prerequisite to G0-L0 code. | Complete exact batch grant and prerequisites before real calls. |
| Credential and protected objects | Implement only approved issuance/Bridge custody, separate External storage, association and owner-safe Discovery primitives. No business listener/Host publication. | X1/X3 primitive proof plus corruption/rotation/failure closure on isolated Windows. |
| TLS and bounded adapter | One TCP/mTLS candidate, verified attempt mapping, pre-auth admission/timeout/destruction and bounded P9/P10 consumption. Existing business owners remain unchanged. | X2/X4/X6/X7 isolated proof; no unauthenticated business path. |
| Lifecycle/effect/release evidence | Actual disconnect/crash/drain/Restore/reconciliation, foreign-object cleanup and packaged App/Bridge acceptance over synthetic data. | X5/X8–X12 at the exact target; required Windows Verifier and Independent Reviewer approval. |
| Separate production activation decision | Evaluate all security evidence and independently close system-stability acceptance in an approved environment; explicitly authorize any production wiring. AR-R6B remains a separate stage. | No missing A property, no open blocking findings, final-target CI/review/required Verifier, explicit activation authority and an explicit decision concerning HOST_STABILITY_HALT. |

No package may silently expand schema v34, B0 v2, P9/P10 schemas, formal COMMIT,
Provider storage or the accepted identity model. A required change to a frozen
contract, unapproved native primitive, inadequate independent environment or a
test possible only through high-risk primary-host experiments is BLOCKED. Static
design can record that blocker; implementation and experiment stop at that boundary.

## 9. P16 production primitive freeze

Status: **Accepted static freeze (merged PR #267), with P17's bounded encoding
and experiment-gate amendments in 9.A.2, section 6 and 9.F. No production credential, certificate, key,
secure store, Discovery object, TLS context, listener or Host is implemented,
generated, activated or measured by P16. Every real Windows behavior below
remains WINDOWS_PENDING; real experiments remain BLOCKED_ON_G0 without the
applicable environment and exact batch grant. G0-L0 implementation/offline work
requires normal scoped task authority, not L1 approval (sections 6 and 9.F).**
This section closes the design half of the
section 4 gaps (M1–M3, M5–M6 and the M8/M9 inputs) with concrete, versioned,
reviewable decisions, so the next stage is real implementation and isolated
Windows acceptance, not another offline design round. P15 remains the owner of
the offline association/evidence contract this production layer must satisfy;
P0/P4/P7/P8 authorization semantics, S0 Provider authority, the B-class
isolation model and the frozen P9/P10 schemas are unchanged and are not
duplicated.

Decision markers used below: **FROZEN** (selected candidate; implementation and
review follow it), **WINDOWS_PENDING** (real acceptance requires an authorized
experiment; no PASS is recorded) and **UNSUPPORTED** (excluded promise). Static
evidence keeps the section 1 classes (OFFLINE_CODE / STATIC_API).

Toolchain context actually inspected for this decision: repository CI pins
Flutter 3.41.9; the local SDK reports Flutter 3.41.9 / Dart 3.11.5 windows_x64.
`pubspec.lock` pins flutter_secure_storage 10.3.1 /
flutter_secure_storage_windows 4.1.0 / ffi 2.2.0 / win32 5.15.0 (transitive).
Version claims below hold for those exact artifacts; a version change
invalidates the affected evidence until rechecked.

### 9.A Certificate and identity model (P16-A)

#### 9.A.1 Roles and responsibility split (FROZEN)

One local installation trust domain with three roles, all ECDSA P-256:

| Role | Owner / custody | Signs / performs | Never does |
|---|---|---|---|
| Installation issuer | App; private key in the App protected store (9.B) | Client and server leaf issuance, `SHIROHA-EXTERNAL-ENDPOINT-V1` descriptor signatures, anchor-rotation records; its self-signed certificate is the single trust anchor | TLS itself; authentication; any Bridge custody |
| Server credential (leaf) | App; private key in the App protected store | The TLS server side on 127.0.0.1 only | Issuing anything |
| Client credential (leaf) | Bridge; private key generated by the Bridge and kept in the Bridge store | The pairing possession proof (9.C) and the TLS client side | Receiving or exporting private material |

The issuer key never leaves the App process/store and is used only during
explicit initialization, enrollment and rotation actions. The Bridge generates
its own key pair; only public enrollment material ever reaches the App. No
reusable private key is bundled and no OS trust root is installed or touched:
the anchor is pinned per installation inside the two protected roots (9.D).

Basis: CNG `BCryptGenerateKeyPair` / `BCryptSignHash` / `BCryptVerifySignature`
(bcrypt.dll; CNG has provided ECDSA P-256 since the Vista-era Windows; the
frozen first target is Windows 11 x64 per section 6) and crypt32 certificate
encode/inspect APIs (`CryptSignAndEncodeCertificate`,
`CertCreateCertificateContext` / `CertGetCertificateContextProperty`). Both
build directions are `dart:io` plus one minimal Win32 helper over SDK-built-in
`dart:ffi`; nothing in this model needs the Flutter engine, so the Flutter
Windows build and the standalone Dart AOT Bridge share the identical code path
(real packaged AOT run remains WINDOWS_PENDING, A12).

#### 9.A.2 Algorithms and sizes (FROZEN)

- Key algorithm: ECDSA on NIST P-256 (secp256r1 / prime256v1), 256-bit keys.
- Signature algorithm remains ECDSA P-256 with SHA-256. Encoding depends on
  the record; the table below supersedes the universal raw-64-byte rule.
- Private-key blobs in the protected stores: PKCS#8 DER (id-ecPublicKey +
  prime256v1); certificates: DER (X.509 v3), converted to PEM text only when
  handed to a Dart TLS context.

| Use | Signature encoding |
|---|---|
| X.509 issuer/server/client certificate | Standard ASN.1 DER ECDSA-Sig-Value: `SEQUENCE { r INTEGER, s INTEGER }`, carried by the certificate's signatureValue BIT STRING (zero unused bits); variable length, never arbitrary raw 64 bytes. |
| Pairing Proof (9.C.2) | Fixed 64-byte raw r‖s, unchanged. |
| Endpoint Descriptor (9.D) | Fixed 64-byte raw r‖s, unchanged. |
| Other custom signed records | Preserve their own frozen format. If none is defined (including the 9.A.6 anchor-rotation record's byte format), mark encoding UNDEFINED; a separate bounded contract is required before implementation/use. Neither certificate DER nor raw r‖s is inferred. |

Normative basis: [RFC 3279 §2.2.3](https://www.rfc-editor.org/rfc/rfc3279.html#section-2.2.3)
defines the ECDSA integer sequence; [RFC 5758 §3.2](https://www.rfc-editor.org/rfc/rfc5758.html#section-3.2)
applies it to SHA-256 and requires `ecdsa-with-SHA256`
(1.2.840.10045.4.3.2) with absent AlgorithmIdentifier parameters, not NULL.
[RFC 5280 §4.1.1.3](https://www.rfc-editor.org/rfc/rfc5280.html#section-4.1.1.3)
defines the certificate signatureValue container;
[ITU-T X.690 (2021), §§8.3 and 10.1](https://www.itu.int/rec/T-REC-X.690-202102-I/en)
governs integer/shortest DER length encoding.

Raw r and s each represent an unsigned big-endian integer, left-zero-padded to
exactly 32 bytes. For DER, validate `1 ≤ r,s < n` (P-256 group order), remove
unnecessary leading zeros, then add exactly one `0x00` sign octet only if the
first remaining octet's high bit is set. ASN.1 INTEGER is signed: omission of
that octet would encode a negative value. Use primitive INTEGERs in order r,s,
the shortest definite lengths and no extra padding, fields or trailing bytes.
When decoding DER to raw, reject noncanonical, negative, zero or out-of-range
values; remove only the necessary sign octet and left-pad each to 32 bytes.

CNG raw ECDSA signing output and X.509 DER signature encoding are distinct
formats. The reviewed certificate-encoding path owns conversion, the signed
TBSCertificate bytes and validation of the resulting DER certificate against
the profile. Never copy raw 64 bytes directly into signatureValue or assume
that a Native API will repair arbitrary supplied encoding. API-specific input
contracts must be reviewed; certificate parsing alone is not signature proof.

Package 1 must freeze public, fixed offline vectors with message/TBSCertificate
bytes, SHA-256 digest, P-256 public key, original raw signature, expected DER
signature/certificate and expected verification/rejection result. Include
leading-zero removal and high-bit sign padding for either/both integers,
shortest lengths and raw↔DER round trips. Negative vectors cover raw-in-X.509,
missing/redundant sign zeros, negative/zero/out-of-range integers, swapped r/s,
truncation, extra fields/trailing bytes, nonminimal/indefinite lengths and
wrong algorithm parameters. Correct fixtures must verify; malformed fixtures
must fail closed. Use published/fixed synthetic fixtures: P17 generates no
real key/certificate and performs no CNG experiment. This changes no P9/P10
schema, Pairing Proof transcript/wire format or credentialIdentity definition.

Rationale: P-256 is the one modern ECC curve with first-class CNG support
(`BCRYPT_ECDSA_P256_ALGORITHM`) and first-class BoringSSL support
(`ecdsa_secp256r1_sha256`), so one key profile serves both the TLS and the
possession-proof roles with no third-party crypto dependency. RSA-2048 is
rejected as larger and slower with no benefit for a loopback installation CA.
Ed25519 is rejected because Windows CNG does not provide it; using it would
force an unapproved third-party crypto library into the trust path.

Fail-closed: any stored or peer key whose size, curve or OID differs from the
frozen profile is `dataCorrupt` (stored) or `verificationRejected` (peer).

#### 9.A.3 Certificate profile (FROZEN)

All objects are X.509 v3 signed with ecdsa-with-SHA256, serial = 16 random
bytes, `notBefore = generation time − 5 minutes` (skew allowance). No CRL, OCSP
or AIA extensions exist or are consulted.

| Field | Installation issuer | Server leaf | Client leaf |
|---|---|---|---|
| Basic Constraints | critical, CA:TRUE, pathLen:0 | critical, CA:FALSE | critical, CA:FALSE |
| Key Usage | critical, keyCertSign | critical, digitalSignature | critical, digitalSignature |
| Extended Key Usage | absent | serverAuth (1.3.6.1.5.5.7.3.1), non-critical | clientAuth (1.3.6.1.5.5.7.3.2), non-critical |
| SAN | absent | critical, exactly one GENERAL_NAME iPAddress = 127.0.0.1 | absent |
| Validity | 3650 days | 730 days | 730 days |
| Subject CN | "Shiroha External Installation Issuer" (display only) | "Shiroha External Host" (display only) | "Shiroha External Bridge" (display only) |

Subject/CN/SAN text is display metadata only — never identity, never
authorization, never a Profile selector. A wrong-role leaf (EKU/KU/BC
mismatch), a missing or duplicated server SAN, or a non-P-256 SPKI is a fixed
role rejection (9.A.7). Expiry is a hard rejection with no grace period and no
renewal API: a re-issued leaf has a new DER, therefore a new credential
identity, and requires a fresh pairing (9.A.5/9.A.6).

#### 9.A.4 TLS protocol and validation rules (FROZEN; real handshake WINDOWS_PENDING)

- Both peers are the repository's own Dart stacks; both `SecurityContext`s set
  `minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3` (verified local SDK
  3.11.5 `dart:io` API; default is tls1_2). TLS 1.2 and below are refused with
  no silent fallback. Renegotiation must remain disabled
  (`allowLegacyUnsafeRenegotiation` stays false).
- `dart:io` exposes no cipher-suite selection API (inspected local SDK
  `security_context.dart`: only ALPN, minimum version and the renegotiation
  flag). The cipher policy is therefore the BoringSSL default set under
  TLS 1.3 — an accepted engine-policy dependency, not a claim. A hard cipher
  requirement would leave TCP blocked; no custom cipher list is promised.
- Contexts are created with `SecurityContext(withTrustedRoots: false)` only.
  `defaultContext`, ambient Mozilla roots, OS stores and any `onBadCertificate`
  acceptance handler are prohibited in External code paths (source-guard test
  in Package 1). The App server context loads the chain (leaf first, issuer
  last: the first PEM block is the served identity certificate — the pinned
  SDK 3.11.5 dartdoc's root-first wording for `useCertificateChain` is
  contradicted by its runtime behavior, where issuer-first bytes fail
  `usePrivateKeyBytes` with `KEY_VALUES_MISMATCH`; the frozen byte order is
  therefore first block = leaf and the dartdoc wording must not be followed)
  via `useCertificateChainBytes`, the server key via `usePrivateKeyBytes`
  (PKCS#8 PEM text), trusts exactly the
  issuer via `setTrustedCertificatesBytes`, advertises it via
  `setClientAuthoritiesBytes`, and binds with `requestClientCertificate: true`
  and `requireClientCertificate: true` (signatures verified in local SDK
  `secure_server_socket.dart`). The Bridge client context trusts exactly the
  pinned anchor and loads its own chain/key.
- Endpoint binding: the listener binds an `InternetAddress.loopbackIPv4` object
  with `shared: false`, and the runtime fails closed unless the actual bound
  address is exactly 127.0.0.1 (A0). The Bridge connects only to
  `InternetAddress.loopbackIPv4` on the descriptor's port; no hostname
  resolution, wildcard or IPv6.
- Verification is three explicit layers, all mandatory:
  1. BoringSSL handshake: chain to the pinned anchor, certificate signatures,
     validity windows, TLS 1.3 `CertificateVerify` (channel possession). A
     failed handshake destroys the socket before any business byte.
  2. Native policy re-check on the peer leaf DER (`SecureSocket.peerCertificate.der`,
     verified accessor in the local SDK): EKU contains the required role
     OID, KU is exactly `digitalSignature`, BasicConstraints present and
     CA:FALSE, SPKI is id-ecPublicKey + prime256v1, certificate signature
     algorithm is ecdsa-with-SHA256, validity window re-checked. Extension
     inspection uses crypt32 context properties, not hand-rolled DER parsing.
  3. Identity binding: SHA-256 of the exact leaf DER must equal the registered
     `credentialIdentity` for the selected Profile (9.A.5), and the server leaf
     digest must equal the digest published in the runtime's signed descriptor
     (9.D).
- `peerCertificate.sha1`, subject strings and any client-claimed fingerprint
  are never used. No TLS key-logging support is added. Real handshake,
  extension and rejection behavior remains WINDOWS_PENDING under A0/A2
  (X0/X2): valid, missing, forged, wrong-anchor, expired and wrong-role
  certificates must be exercised on the approved environment.

#### 9.A.5 credentialIdentity mapping (FROZEN)

`credentialIdentity` is the lowercase hex SHA-256 of the leaf DER exactly as
the registering side held it at pairing time and exactly as
`X509Certificate.der` returns it at TLS time; both byte strings must be
identical. The P15 association record stores it (bounded to 256 text
characters; 64 hex characters in practice) and keeps the P15 uniqueness rules
unchanged: one active identity per Profile, one active Profile per identity,
tombstones retain revisions.

**A leaf digest is only a correlation identifier; it never proves that the
client holds the private key.** Possession is proven only by the pairing
signature over the 9.C.2 transcript (enrollment) and by the TLS 1.3
`CertificateVerify` (channel). Subject, CN, SAN, serial, PEM text, `sha1` and
any supplied fingerprint are not identity and cannot select, reconstruct or
reactivate a Profile or Principal.

#### 9.A.6 Rotation, revocation and anchor replacement (FROZEN; lifecycle WINDOWS_PENDING)

- Client credential rotation: only explicit. The association is revoked
  through the P15 CAS/revoke path (tombstone retained, evidence closed,
  generation invalidated); the Bridge then enrolls a fresh key/leaf and
  completes fresh approval and possession proof. There is no renewal API, no
  duplicate active credential and no automatic re-issue.
- Expiry behaves like revocation for access: an expired leaf fails layers 1–3
  and its identity opens nothing. Re-enrollment is the only recovery.
- Server credential rotation: a new leaf from the same issuer. Because the
  server context loads once per listener lifetime, rotation is a controlled
  shutdown → re-issue → restart → republish descriptor (Package 3 acceptance);
  the 9.D supersession single-liveness rule forbids an old and a new listener
  from coexisting.
  The republished descriptor carries the new runtimeInstanceId, the new leaf
  digest and a strictly higher durable `publicationEpoch`; the Bridge's 9.D
  epoch high-water refuses any descriptor whose epoch is below its pinned
  value — including a coherent stale descriptor paired with the retired
  still-valid leaf, which the descriptor's self-consistent digest binding
  alone cannot order — while mixed descriptor/leaf pairs fail the digest
  binding. The in-memory P0/P12 generation may restart at the same numeric
  value in a new process; it is informational here and never used for
  ordering, so routine restarts need no re-enrollment.
- Issuer/anchor replacement: a new issuer key/cert is accepted only with an
  anchor-rotation record signed by the previous issuer key and carrying the
  new anchor; the Bridge verifies it against its pinned anchor before
  replacing its copy. Without a valid old-key signature — including after
  old-key loss — the only path is explicit re-enrollment of every client
  (fresh pairing). There is no trust-on-first-use, no silent anchor swap and
  no automatic cross-Profile rebinding. App-side replacement follows the same
  rule and is a deliberate local action.
- Live revocation infrastructure (CRL/OCSP) is UNSUPPORTED: none exists and
  none is claimed as a substitute for the explicit association revoke.

#### 9.A.7 Fixed rejection semantics (FROZEN)

| Condition | Fixed behavior | P15 failure mapping |
|---|---|---|
| Expired / not-yet-valid beyond the skew allowance | Reject; no grace, no retry-with-old-cert | handshake failure or `verificationRejected` |
| Wrong role (EKU/KU/BC/SAN/SPKI mismatch) | Deterministic layer-2 rejection | `verificationRejected` |
| Wrong anchor / foreign or missing chain | Layer-1 rejection; socket destroyed before business bytes | handshake failure; no business path |
| Retired, revoked or unregistered identity (digest mismatch) | Reject before any P0 window | `unauthorized` |
| Torn or unparsable stored object | Hard deny; object left untouched | `dataCorrupt` |
| Missing certificate where TLS requires one | Handshake fails; connection destroyed | pre-business failure |

All rejections map onto the existing P15/`ExternalFailure` vocabularies; no new
failure kind, retry or fallback path is introduced.

#### 9.A.8 Required real acceptance (WINDOWS_PENDING)

The valid / missing / forged / wrong-anchor / expired / wrong-role / retired
leaf matrix over a real TLS 1.3 handshake (A2, X2); exact leaf authentication
and digest binding (A1, X4); TLS 1.3 floor enforcement and absence of TLS 1.2
negotiation; PKCS#8 and chain loading in the Flutter Windows AOT build and in
the standalone Dart AOT Bridge; certificate encoding output validated against
the frozen profile. None of these may be claimed from static inspection alone.

### 9.B Secure credential storage (P16-B)

#### 9.B.1 Investigated backend evidence (REJECTED: flutter_secure_storage_windows)

The locked `flutter_secure_storage_windows` 4.1.0 was inspected at source
level for this decision (Dart `lib/src/flutter_secure_storage_windows_ffi.dart`
and `windows/flutter_secure_storage_windows_plugin.cpp`):

- The default path stores every key of the app in ONE JSON map file
  (`flutter_secure_storage.dat` in Roaming `%APPDATA%`) encrypted as a single
  DPAPI blob (`CryptProtectData`, flags 0, user scope).
- A corrupt, undecryptable or mis-parsed map is DELETED and rethrown — all
  entries are destroyed as a side effect of one bad read.
- An unreadable file (`FileSystemException`) is silently treated as an empty
  map — a read error becomes "missing".
- There is no revision, CAS, uniqueness or tombstone concept; writes are
  read-modify-write of the whole map.
- The legacy `.secure` path keeps its AES-GCM key in Credential Manager; a
  wrong-size key triggers silent delete-and-rekey, permanently losing prior
  data.
- The package imports `package:flutter/*` and `path_provider`, so a standalone
  Dart AOT Bridge cannot use it at all; directories are created with inherited
  ACLs and writes are plain `ofstream` without atomicity.

Verdict: this backend cannot satisfy the P15 association contract (corrupt must
hard-deny without bulk deletion; missing and unavailable must stay distinct;
CAS/uniqueness/tombstone semantics; snapshot monotonicity) and cannot serve the
Bridge. It must not be used for External objects — not for the App store, not
for the Bridge store, and not with prefixed keys inside the same shared map.
S0's Provider secure store is likewise not reused and cannot serve the Bridge;
`engine.*` keys, Provider migration and Provider deletion semantics never
change.

#### 9.B.2 Selected backend (FROZEN; exactly one backend, no fallback backend)

A single dedicated External object store: versioned binary object files in the
owner-only NTFS root of section 9.D, each wrapped with user-scope DPAPI
(`CryptProtectData` / `CryptUnprotectData`, flags 0 — no machine-wide flag, no
plugin, no Flutter dependency). The Flutter App process and the standalone Dart
AOT Bridge call it through the same minimal native helper over SDK-built-in
`dart:ffi` (no new pub dependency; the helper is loaded by absolute path from
the process directory and is part of the release artifact — Package 3). The
helper resolves the root via `SHGetKnownFolderPath(FOLDERID_LocalAppData)` —
never from environment strings and never from version-info company/product
names (the investigated plugin's mechanism).

Why this is the minimal compliant candidate: DPAPI user scope protects the
objects at rest and binds them to the user's logon; the 9.D ACLs block
cross-SID access; and the format plus commit rules are fully owned by us,
which is exactly what the P15 CAS/tombstone/monotonic-snapshot contract needs.
Rejected alternatives:

- CNG/NCrypt non-exportable keys: `dart:io` TLS requires key bytes in a
  `SecurityContext` (verified local SDK API), so a non-exportable signing
  oracle cannot serve the TLS role; non-exportability is UNSUPPORTED and not
  claimed.
- Credential Manager records: 2,560-byte blob ceiling, no CAS/atomicity,
  target-name collisions and the plugin-recorded silent-rekey hazard.
- SQLite (including the business database): credential and association
  material is explicitly integrity-protected outside the non-secret
  Profile/Grant tables (section 3), S0's E7 boundary marks the Provider seam
  as Provider-only, and the Bridge never opens SQLite.
- flutter_secure_storage(_windows): rejected per 9.B.1.

There is exactly one backend. No second store may be implemented as a fallback
and no runtime switch between backends exists. If X1/X3 disprove a required
behavior (DPAPI semantics, rename atomicity, ACL enforcement), the affected
package STOPS and returns for review; TCP/mTLS stays blocked meanwhile.

Access/update/revoke boundaries: the App process is the sole reader/writer of
the App trust store and the association store; a Bridge process is the sole
reader/writer of its own client store; no component copies objects across
roots, exports them, or includes them in backups, exports or logs. Revocation
follows P15: evidence and admission close and owning drain completes before
the revoke CAS commits; a failed revoke leaves the runtime closed and reports
failure, never durable success.

#### 9.B.3 Object formats (FROZEN, version 1)

All objects are DPAPI blobs whose plaintext payload is strictly decoded;
unknown magic, version, kind, length or reserved content is `dataCorrupt` —
no best-effort parsing, no migration, no auto-upgrade. Every write replaces
whole objects atomically (9.B.4). Field bounds mirror P15 (`profileId` UUID v4,
`installationId` ≤128 UTF-8 canonical lowercase UUID text, `credentialIdentity`
64 hex characters, revisions 1–2147483647, matching `ExternalAuthLimits`).

| Object kind | Payload (plaintext, before DPAPI) |
|---|---|
| 1 issuerKeyPair | magic `SHREXOBJ`, version 1, kind 1, installationId (u16le length + UTF-8), publicationEpoch (u64le; 0 at creation, +1 committed per descriptor publication), issuer PKCS#8 DER (≤ 256 B), issuer cert DER (≤ 1 KiB) |
| 2 serverKeyChain | magic, version 1, kind 2, server PKCS#8 DER, server leaf DER, issuer cert DER |
| 3 associationStore | magic, version 1, kind 3, `u32le recordCount ≤ 64`, then per record: record version 1, profileId (16 raw UUID v4 bytes), installationId (u16le length + UTF-8), credentialIdentity (32 raw SHA-256 bytes), revision (u64le), revoked (1 byte, 0/1), updatedAtUtcMs (u64le, backend bookkeeping only, 0–9007199254740991 like P15 times; not part of the P15 port record) |
| 4 bridgeClient | magic, version 1, kind 4, client PKCS#8 DER, client leaf DER, issuer cert DER, pinned installationId, pinned discovery epoch high-water (u64le) |

Caps: one object file ≤ 64 KiB; association records ≤ 64 (exceeding the bound
fails registration `resourceLimit`); temp/leftover files ≤ 32 per directory
(9.B.4). The association payload IS the P15 store: one record per Profile
including tombstones, validated at the commit boundary exactly as the P15 port
requires.

#### 9.B.4 Write, CAS and recovery rules (FROZEN; OS behavior WINDOWS_PENDING)

- Single writer, OS-enforced (store objects): each root has exactly one
  writing process for its store objects — the App root's kinds 1–3 and the
  Bridge root's kind 4 — and every read–validate–CAS–commit transaction on
  them runs while that process holds the root's exclusive no-sharing writer
  lock (App: `runtime.lock`, Bridge: `bridge\client.lock`; 9.D). The lock is
  taken non-blocking before the process's first store operation (only the root
  directory and the lock object itself precede it) and held for that process's
  store-owning lifetime (9.D), so no transaction ever runs outside it; the
  in-process bounded commit queue serializes only within that exclusive
  holder. The 9.C.5 exchange files are single-consumption atomic `CREATE_NEW`
  writes with no read–modify–write transaction; they are not store objects and
  do not use these locks. Lock contention is a fixed fail-closed result
  (`temporarilyUnavailable`-class: zero mutation, no open or write), never a
  wait, a retry loop or a per-process queue that downgrades the exclusion.
  Atomic file replace provides durability, not cross-process mutual exclusion;
  cross-process writers are excluded, not merely "unsupported".
- Commit protocol: read current object → validate → apply the mutation in
  memory (expected-revision CAS, uniqueness scan, tombstone retention) →
  serialize → DPAPI-protect → create temp `~tmp-<runtimeId16>-<rand8>` in the
  same directory with the explicit owner DACL (`CREATE_NEW`) → write + flush
  (`FlushFileBuffers`) → atomic replace by handle
  (`SetFileInformationByHandle`/`FileRenameInfo` with replace;
  `MoveFileExW` + `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH` is the
  documented alternative) → success is reported only after the replace call
  reports success. The whole read-through-replace sequence runs only while the
  root's writer lock is held (single writer above); the atomic replace is its
  final durability step, not its mutual-exclusion mechanism. A crash before
  the replace leaves the previous valid state; after it, the new valid state.
- P15 contract mapping (unchanged semantics, backend realization only):

| P15 requirement | Backend realization |
|---|---|
| Read returns a snapshot with monotonic validity | Whole-object read yields a validated snapshot; validity dies permanently on any later commit, read error, or store close/re-init; a cached record never substitutes for a read |
| Register/revoke CAS on expected revision | Compare at the commit boundary; mismatch = `staleRevision`, no write |
| Identical active tuple with exact revision | Unchanged success (idempotent); never a second write |
| Revoke retains a monotonic tombstone | Revoked record kept in place with its revision preserved |
| One active credential per Profile; one Profile per credential | Uniqueness scan inside the serialized commit |
| `validateManagement` at the commit boundary | Caller-provided validation runs at the commit boundary before the replace |
| Missing / corrupt / unavailable distinctions | Failure table below |

- Failure mapping (all typed; uncertain commit is never success):

| Condition | Result | Recovery |
|---|---|---|
| Object absent (never written / legitimately missing) | Missing — current null record semantics | Register starts from revision 0; connections stay unauthorized until paired |
| Decrypt/decode/invariant failure | `dataCorrupt` hard deny; object untouched | Explicit local re-initialization only; no auto-delete, no rekey, no regeneration |
| Writer-lock contention, I/O, sharing, volume or ACL-verification failure | `temporarilyUnavailable`; zero mutation; snapshots invalidated | New explicit operation only; no retry loop |
| Replace outcome ambiguous (temp written, replace uncertain) | `commitUnknown`; never reported as success | Fresh read; idempotent same-tuple/exact-revision registration; stale requests fail CAS |
| Crash mid-write | Old-or-new valid state; `~tmp-` leftovers inert | Leftovers are ignored by the loader, never read; bounded count fails new writes closed beyond the cap until explicit local cleanup |

#### 9.B.5 Integrity and anti-replacement (FROZEN)

- At-rest tamper detection: DPAPI integrity plus strict decode plus full
  record validation; any of these failing is `dataCorrupt`.
- Cross-SID replacement and redirect: blocked by the 9.D DACL and reparse
  rules; a cross-SID write, substitution or parent-redirect must fail at the
  OS boundary (A3).
- Same-SID whole-object replacement, including replay of an older valid blob
  (rollback), is NOT detectable by DPAPI or ACLs and is explicitly accepted
  inside the already accepted same-SID risk. Impact is bounded: runtime
  authority is in-memory only; a restart always starts unpaired/disabled; a
  binding is usable only with current management, explicit enablement and
  fresh possession proof; revisions never decrease within a runtime. No
  anti-rollback (TPM/monotonic-counter) promise is made.

#### 9.B.6 Explicit exclusions (FROZEN)

No automatic repair of a corrupt trust anchor or association; no silent
generation of replacement keys; no plaintext or Provider (`engine.*`) fallback
or reuse; no cross-Profile or cross-Installation rebinding; no bulk deletion
and no "delete corrupt file" behavior; no B0/rollback read or write of these
objects; no cleanup of orphaned associations (they stay non-authorizing until
a separately approved recovery contract). S0's Provider namespace, migration
and deletion semantics remain unchanged and untouched.

### 9.C Pairing and possession proof (P16-C)

This section freezes the production cryptographic realization of the P15
private one-use verification window. The P15 boundary, its state machine, its
failure vocabulary and its one-use/approval-order rules remain the contract;
the synthetic verifier remains test-only. **Without the real cryptographic
proof specified here, the P15 synthetic verifier is not production pairing and
may never be wired as one.**

#### 9.C.1 Challenge nonce (FROZEN)

- 32 bytes from the platform CSPRNG (Dart `Random.secure()`, backed by the OS
  entropy source on Windows — STATIC_API) generated by the App per
  registration request.
- One nonce per request; a duplicate among live requests (bounded at the P15
  pending limit of 16) is rejected. Single use: any completion attempt —
  success or failure — consumes the challenge and its nonce, per the P15 rule.
- Deadline: `expiresAtUtcMs` with `0 < deadline − issuance ≤ 600 s`. The
  production binding supplies the concrete value within this ceiling; P15's
  offline 30-second constant is its offline candidate and its evidence-window
  value. The evidence window (verification → P0 consumption) stays at the
  P15 30 seconds, enforced by the adapter's monotonic `isLive`, independent of
  the challenge deadline. A production deadline longer than the offline
  30-second constant requires the matching P15 binding and test update in the
  same package; the current offline expiry must not be assumed to accept it.

#### 9.C.2 Signed transcript and proof format (FROZEN)

The possession proof is the ECDSA-P256-SHA256 signature (raw r‖s, 64 bytes) by
the client leaf key over `SHA-256(transcript)`, where the transcript is the
following exact byte layout (no text encoding, no newlines, no optional
fields):

| Field | Bytes | Content |
|---|---|---|
| Domain | 26 | ASCII `SHIROHA-EXTERNAL-PROOF-V1` followed by one NUL byte |
| Kind | 1 | `0x01` pairing possession (channel proof is TLS `CertificateVerify`, never this message) |
| Nonce | 32 | The 9.C.1 nonce, raw |
| RequestId | 16 | Raw random request identifier |
| ProfileId | 16 | Raw UUID v4 bytes |
| InstallationId | 2 + n | `u16le` length n ≤ 128 + UTF-8 canonical lowercase UUID text |
| Generation | 8 | `u64le` P0/P12 runtime generation |
| RuntimeInstanceId | 16 | Raw per-App-runtime random identifier |
| CredentialIdentity | 32 | Raw SHA-256 leaf digest |
| ExpectedRevision | 8 | `u64le` expected association revision |
| ExpiresAtUtcMs | 8 | `u64le` challenge deadline |

The App reconstructs this transcript exclusively from its own pending-request
state; wire fields are never trusted as transcript inputs. The proof file
(`exchange/proof-<submissionId32hex>.bin`, 9.C.5) carries only magic
`SHREXPRF`, version 1, submissionId, requestId and the 64-byte signature — the
App correlates requestId/submissionId with its local request and verifies with
the public key recorded at leaf issuance.

#### 9.C.3 Replay and substitution resistance (FROZEN)

- Proof replay: the nonce and challenge are single-use and consumed on any
  attempt; a replayed proof finds no pending request (or a consumed one) and
  is rejected; an expired challenge is rejected regardless of signature
  validity.
- Cross-installation substitution: the transcript binds installationId,
  runtimeInstanceId and generation; verification compares them against the
  live runtime, so a proof minted for another installation or generation never
  authorizes.
- Cross-session misuse: pairing possession and channel authentication are
  distinct events with distinct P15 methods and kind-tagged attempts; a
  pairing proof can never open a Session and a TLS channel can never complete
  a pairing.
- TLS replay: each connection performs a fresh TLS 1.3 handshake (ephemeral
  ECDHE plus `CertificateVerify` over that handshake); no resumption API is
  configured or relied upon, so a captured handshake cannot authenticate a new
  connection.

#### 9.C.4 Approval ordering (FROZEN)

Strict order, owned by the unchanged P0/P15 state machine: `requestPairing` →
trusted local user `approvePairing` → `completePairing(proof)`. Approval alone
never produces a `PairingProof` or a paired state; completion without approval
is rejected; a failed proof consumes the P15 request and leaves P0 in
`approvedPendingProof` — never paired, with recovery only per 9.C.8; runtime
enablement remains a separate explicit action and is never part of pairing.

#### 9.C.5 Bootstrap submission and exchange (FROZEN)

There is no pairing listener, no new P9/P10 command and no P9/P10 schema
change: pairing uses a file-mediated control plane inside the protected root
and is processed only on explicit trusted local actions (management UI
refresh/act). No unauthenticated business or pairing listener exists at any
stage.

Flow:

1. The Bridge generates its P-256 key pair in-process (helper) and writes the
   enrollment submission atomically into `exchange/` (`submission-<32hex>.pub`,
   `CREATE_NEW`): magic `SHREXSUB`, version 1, submissionId (16 B), client
   public key (65 B uncompressed point), display label (≤ 64 UTF-8, display
   metadata only), client build string (≤ 32 UTF-8). Cap 1 KiB.
2. The App validates the file (exact name, owner/DACL/reparse per 9.D, size,
   strict decode), issues the client leaf with the issuer key, computes the
   credentialIdentity, creates the pairing request (P15/P0 `requestPending`),
   writes the challenge file `pairing-<32hex>.chal` atomically — magic
   `SHREXCHA`, version 1, submissionId, requestId, nonce, profileId,
   installationId, generation, runtimeInstanceId, publicationEpoch,
   credentialIdentity, expectedRevision, expiresAtUtcMs and the issued client
   leaf DER (≤ 2 KiB) —
   and removes the submission (its content is now represented by the leaf and
   the request). Cap 4 KiB.
3. The user approves locally (P11 management surface; UI copy is not frozen
   here).
4. The Bridge reads the challenge file, self-checks (leaf chains to the pinned
   anchor, leaf public key equals its own, digest matches the field), signs
   the 9.C.2 transcript and writes the proof file atomically (≤ 256 B).
5. The App processes the proof only on an explicit trusted local action:
   correlates it with the local request, rebuilds the transcript, verifies the
   signature and all P15 checks, then runs the P15 completion path (association
   register CAS, P0 completion).

File rules: exact names only; strict versioned decode; single consumption;
foreign or unexpected files are left untouched; population bounded at 32 files
per directory; exceeding bounds fails new pairing work closed
(`temporarilyUnavailable`) without any sweep. Interrupted flows leave only
inert public-material files; nothing durable exists before the association
commit (9.B.4), and no automatic retry exists.

#### 9.C.6 Private-key non-leakage (FROZEN design; A1 evidence WINDOWS_PENDING)

- Protocol messages carry only: the 65-byte public key (submission), the
  issued public leaf, and the 64-byte signature (proof). No message type
  carries private key material.
- The Bridge key is created, used and stored only inside the Bridge (own root,
  9.D); the App never receives it in any form.
- At the TLS layer the client key is used through the standard TLS 1.3
  `CertificateVerify`; no exported key material is transmitted.
- Scoped statement: "does not leave the Bridge" means not transmitted by the
  protocol and not placed in App-owned or published objects. It is not a claim
  of same-SID OS-level isolation (accepted risk, 9.D) and not of
  non-exportability (UNSUPPORTED, 9.B.2). X1/A1 verify that exchange,
  discovery and evidence artifacts contain no private material.

#### 9.C.7 Post-verification evidence consumption (FROZEN; maps to P15 unchanged)

Real verification means: signature valid, leaf/chain/role/validity passed,
challenge live, store and management current. Only then does the adapter mint
its private attempt object (immutable; holding the verified fields and the
live correlation) and hand it to the P15 verification port; `verifyPairing`
returns true exactly once for that success, and `isLive` is monotonic — false
after close, generation change, snapshot invalidation or the 30-second
evidence window, and once false never true again. `provePossession` remains
the only producer of `PairingProof`, inside the P15 private call window;
externally constructed evidence, strings, fingerprints and decoded files never
satisfy the port. No second pairing state machine, Session table or Principal
system is introduced anywhere in this design; pairing state stays P0-owned and
durable policy stays P1/P11-owned.

#### 9.C.8 Failure and unknown-result recovery (FROZEN)

- Invalid, expired, replayed or duplicate proof → `verificationRejected`; the
  challenge is consumed; trust state is unchanged (no paired state, no partial
  Grant or Enablement). The normal flow cannot continue inside that runtime:
  the consumed P15 registration can never be completed again (`unauthorized`),
  a different request is `pairingConflict` while P0 retains
  `approvedPendingProof` (only `unpaired` or `recoveryRequired` admits one),
  and re-approval outside `requestPending` is impossible. There is no
  cancel/reset pairing interface and this document does not assume one;
  adding one would change the frozen P0 state machine and requires separate
  authorization. Frozen recovery: an explicit trusted local action closes and
  rebuilds the External runtime (a fresh composition — pairing state is
  in-memory and is discarded, not merely disabled), then re-registers the
  existing Profile and runs a standard fresh pairing through 9.C.4/9.C.5: a
  new request, a new challenge and nonce, with the 9.A.6 revoke-first rule
  when a different credential replaces an active association. No automatic
  retry loop, no silent re-issue.
- Association commit unknown → the 9.B.4 recovery rule (fresh read; idempotent
  same-tuple/exact-revision registration; stale requests fail CAS).
- P0 completion acknowledgement lost → the durable fact remains only the
  association record; runtime pairing state is in-memory and absent after
  restart; recovery is a fresh explicit pairing flow (registration is
  idempotent for the same active tuple). Never a silent resurrection.
- Repeated failures never expand permission: no state advances without
  cryptographic success, current management and explicit local approval.

### 9.D Windows Discovery and local isolation (P16-D)

Frozen root candidate: `%LOCALAPPDATA%\Shiroha\external\`, resolved via
`SHGetKnownFolderPath(FOLDERID_LocalAppData)` inside the helper (non-roaming by
construction). Layout:

| Path | Writer | Intended reader | Content |
|---|---|---|---|
| `app\trust\issuer.bin`, `app\trust\server.bin` | App | App only | 9.B.3 kinds 1–2 |
| `app\state\associations.bin` | App | App only | 9.B.3 kind 3 |
| `bridge\client.bin` | Bridge | Bridge only | 9.B.3 kind 4 |
| `bridge\client.lock` | Bridge | Bridge only | 9.B.4 Bridge-root single-writer lock object (exclusive no-sharing handle, same recipe as `runtime.lock`) |
| `runtime.lock` | App | App only | 9.B.4/9.D single-writer + supersession lock object (exclusive no-sharing handle held from before the first store operation through full runtime dispose; lock liveness is OS handle state, never a PID/age heuristic) |
| `discovery\endpoint.bin`, `discovery\anchor.der`, `discovery\installation.id` | App | any same-user process | 9.D published objects |
| `exchange\submission-*.pub`, `exchange\pairing-*.chal`, `exchange\proof-*.bin` | Bridge/App per 9.C.5 | the counterpart process | 9.C.5 files |

The App creates the root, `app\`, `discovery\` and `exchange\`; the Bridge
creates `bridge\` on first enrollment with the same security recipe
(create-if-absent). Each process takes its root's writer lock
(`runtime.lock` / `bridge\client.lock`, 9.B.4) exclusively before its first
store operation and holds it for its store-owning lifetime.
`installation.id` is minted once at External
initialization (UUID v4) and persisted in the App trust store as the kind 1
`issuerKeyPair` field (9.B.3) — the authoritative copy the published
`discovery\installation.id` is cross-checked against; its loss, an absent or
corrupt store field or a mismatch with the published copy fails closed (all
associations and descriptors bind it) and is recovered only by an explicit
local reset — never by silent re-mint.

DACL and owner rules (FROZEN):

- Creation uses explicit security attributes with a protected DACL containing
  exactly one allow ACE — the current user SID with full access (container and
  object inherit for directories). No inheritance from parents, no deny ACEs,
  no Everyone/Users/Authenticated Users/ANONYMOUS rights, no null DACL.
- Verification on every open (helper): open with `READ_CONTROL` (identity
  checks use `FILE_FLAG_OPEN_REPARSE_POINT`); verify the owner SID equals the
  current SID; verify the DACL is present, protected, with only the expected
  ACEs; reject reparse points at every level we created (root, subdirectories,
  objects); verify the volume via the handle (local fixed NTFS via
  `GetVolumeInformationByHandleW`); reject UNC, removable and network volumes.
  Any mismatch fails closed and keeps the Host closed.
- Parent chain: the only accepted ancestors are the OS-provided
  `%LOCALAPPDATA%` (accepted as-is) and the App-created `Shiroha` level
  (validated: directory, no reparse, current-SID owner) — checked on every
  open, not only at creation.

Integrity of published objects: `endpoint.bin` is signed (magic `SHREXEPD`,
version 1, runtimeInstanceId, publicationEpoch (u64le), generation
(informational; never used for ordering), `u16le` port, server leaf SHA-256,
installation UUID, publishedAtUtcMs, then the 64-byte issuer-key signature
over `SHA-256("SHIROHA-EXTERNAL-ENDPOINT-V1" || 0x00 || preceding bytes)`);
`anchor.der` is the issuer certificate DER and is cross-checked byte-wise
against the App store at publish time; `installation.id` is canonical UUID
text and cross-checked against the store. Mixed or stale combinations fail
closed on the consumer side because the signature, the installationId match,
the epoch high-water ordering below and the server-leaf digest binding must
all hold.

Publication and cleanup (FROZEN): the App is the sole publisher. Supersession
single-liveness and store single-writer (FROZEN): the runtime acquires an
exclusive no-sharing handle on the root `runtime.lock` object before its
first External store operation — necessarily before creating any endpoint
listener — and holds it until the runtime is fully disposed, including any
post-close revocation commit; every 9.B.4 read–CAS–commit transaction on the
App-root store objects runs under this held handle. A second External runtime
fails closed instead of serving, publishing, binding or writing store objects,
so an old listener can never coexist with its successor and
two processes can never interleave store transactions on one root (an
in-process runtime swap disposes the old runtime first and the successor
re-acquires the lock before its own store work; a crashed process releases
the lock with its handles). Each publication first commits
`publicationEpoch + 1` to the kind 1
object under the 9.B.4 CAS rules, then writes the descriptor carrying that
committed epoch; a crash between the two steps leaves the descriptor file at
its previous self-consistent publication and the skipped epoch is harmless.
Publish = temp `~tmp-<runtimeId16>-<rand8>` (explicit DACL) → write → flush →
rename-replace; the writer revalidates owner/DACL/reparse after publication.
Cleanup may delete only (a) objects this runtime created and still tracks by
handle-verified identity (volume serial + file index re-checked on reopen) and
(b) `~tmp-` files whose name carries this runtime's random ownership id.
Everything else — leftovers of crashed runtimes, foreign sentinels, unknown
names — is left untouched; ambiguous state leaves the Host closed and never
triggers a sweep or a temporary unprotected replacement.

Object identity over paths (FROZEN): all security-relevant decisions (read,
replace, delete) use verified handles and captured identities, never path
strings alone. **A plain Flutter directory path or application-support path
string proves nothing about Windows object isolation; only the reviewed
owner/DACL/volume/reparse/handle-identity checks above enter security
acceptance.** Directory names, profile-local locations and ACL-less
conventions are not evidence.

Cross-SID test boundary (FROZEN; real runs WINDOWS_PENDING, M5/A3):

- Negative: a second disposable principal must fail to read, modify, replace,
  delete or redirect any protected object (App store, the first user's Bridge
  store, discovery, exchange) and must fail to cause owner-side deletions;
  reparse/parent-substitution attempts from that SID fail at the ACL boundary.
- Positive (B-class): a separately provisioned client under another SID, with
  its own protected root, its own keys and an owner-provided copy of the
  PUBLIC material (operator-mediated in the lab), may connect and receive
  business access only through the existing P0/P4/P7/P8 checks. Production
  multi-user provisioning and distribution remain unresolved and unfrozen: v1
  supports same-user Bridge only, and cross-user enrollment write paths are
  not part of v1.

Bridge use of public trust (FROZEN): at enrollment the Bridge pins into its
own store the anchor DER, the installation id and the enrollment-time
`publicationEpoch` it validated from the 9.C.5 challenge; afterwards it never
trusts discovery objects blindly — it verifies the endpoint signature against
the pinned anchor, matches installationId, requires the served descriptor's
`publicationEpoch` to be at least the pinned epoch (below is refused before
any TLS; every publication commits a unique strictly increasing epoch, so an
equal epoch can only repeat the publication the pin was set from or an
acceptance came from, never a different one), matches the server-leaf digest,
connects only to the descriptor's 127.0.0.1 port, and advances the stored
epoch only after the signature and installationId checks pass. Freshness
never rests on the descriptor alone: the 9.D supersession single-liveness
rule guarantees at most one live runtime and listener per installation, so a
cached old descriptor whose epoch is already reached
can only point at an endpoint that no longer exists and the connection fails
closed, while an unseen successor is accepted on its first sighting through
its strictly higher epoch — no re-enrollment is needed when a restarted
runtime reuses the same numeric generation, and the kind 4 epoch survives
Bridge restarts. A signature authenticates the issuer, never currentness;
the residual — a same-SID process replaying a descriptor together with copied
key material — remains inside the accepted same-SID boundary (9.B.5, section
3), and no unsigned freshness signal is accepted (A12 negative cases; X11
supersession trials). Anchor updates are accepted only via the 9.A.6
old-key-signed rotation record.

Same-SID proxy risk: unchanged and re-affirmed in the exact section 3 terms —
another program under the same user may call a paired Bridge and proxy its
credential; cross-process isolation among same-SID processes is not promised
and none of the above claims it. Loopback is not authentication; these ACLs
protect cross-SID and at-rest boundaries only. Administrator/kernel attackers
remain UNSUPPORTED.

### 9.E Minimal implementation packages (P16-E)

Rules for every package: no additional simulated Principal, Session,
Credential Store or Transport may be introduced to stand in for the real
implementation — the P15 offline candidate remains test coverage only; the
frozen primitives are real code (one native helper plus Dart adapters) or they
are not delivered. Each package requires its own explicit scope/ownership and
grant; G0 (section 6) is a precondition for every real experiment; the X rows
below are the section 6 experiment table. `dart:ffi` is SDK-built-in and needs
no new pub dependency; any other new dependency requires separate explicit
authority. No package may activate a production Host or business listener, and
no package touches AR-R6B.

The table's X-row grants cover full G0-I acceptance; section 6 separately maps
local L1/L2 subsets. Its required-real-authorization column does not gate L0
code/compile/offline work.

| Package | Smallest responsibility | Offline-testable portion | Required real authorization | Targets (M → A) | STOP boundary |
|---|---|---|---|---|---|
| 1. Credential / Protected Object primitives | The native helper (known-folder resolution, DACL create/verify, DPAPI wrap/unwrap, atomic replace, the exclusive no-sharing handle locks (liveness/supersession and single-writer), BCrypt keygen/sign/verify, certificate encode, extension inspection) built into release artifacts; Dart adapters: the 9.B store (CAS/uniqueness/tombstones/snapshots), discovery publisher/validators, leaf issuance from submissions, the 9.C exchange protocol, and the P15 port/backend implementations in composition-side wiring only | Format codecs, CAS/state machines with fakes, transcript/signature test vectors, source guards (no `defaultContext`, no `onBadCertificate`, no `engine.*`), CI-runnable | G0; X1 (issuance/possession), X3 (protected-object cross-SID) | M1, M2, M5, M6 → A1, A3 | No listener, no business Host, no production composition activation; if X1/X3 disprove DPAPI/ACL/rename behavior → STOP (no fallback backend) |
| 2. TCP/mTLS secure adapter | Exact `127.0.0.1` bind, TLS 1.3 contexts loaded from the store, bounded pre-TLS admission (section 5 budget: slots, deadlines, real socket destruction), the three-layer peer verification, adapter-owned attempt mapping into the P15 boundary, unchanged P9/P10 consumption | Only limit/format logic with fakes; every handshake behavior is real-environment | G0; X0, X2, X4, X6, X7 (X3 for object behavior) | M4, M7, M8, M9 → A0, A2, A4, A6, A7 | Any accept-bad-certificate, cipher or admission/resource excess → STOP; TCP stays blocked; no protocol weakening and no automatic Named Pipe switch |
| 3. Windows lifecycle and release acceptance | Disconnect/timeout/revoke and generation invalidation, B0/restart behavior, real-channel STAGE response loss (X8), Bridge-no-alternate-writer audit (X9), crash/foreign-object cleanup (X11), AOT packaging/native loading/Unicode and spaced launch (X12), standing v0/MCP compatibility (X10) | X10 standing regression only | G0; X5, X8–X12 | M10, M11, M12 → A5, A8–A12 | Any stability anomaly triggers the section 6 stop/recovery rules; no activation decision exists inside this package |

Ordering: 1 → 2 → 3, serial. Package 1 can be written, compiled and
offline-tested under normal G0-L0 task authority without an L1 experiment
grant. Split implementation by dependency into bounded, independently reviewed
PRs; one PR need not deliver all of Package 1. Start with the minimal Windows
Native Helper, controlled Win32 memory/handle release, Dart FFI Adapter,
frozen versioned object codecs, dedicated DPAPI Credential Store Adapter and
runtime.lock/client.lock single-writer protection, with offline tests and source
guards against the actual implementation. Do not introduce a second Profile,
Principal, PairingState or CredentialStore business authority. Necessary real
DPAPI/ACL/key/certificate calls stop at G0-L1; local communication stops at
G0-L2. Local subsets prove only their exact functions; full protected-object
acceptance still requires X1/X3 under G0-I. Packages are responsibility slices,
not automatic authority; each starts with its own scoped implementation grant.

Not delegated to any package: production Host activation, AR-R6B, schema/B0/
P9/P10 changes, Provider-store changes, or any change to frozen authorization
semantics. The final production activation remains the separate decision gate
of section 8 (last row) and requires the complete A-row evidence, a required
Windows Verifier, independent review and explicit user authority.

### 9.F G0 boundary, remaining blockers and completion meaning

P17 supersedes P16's single environment gate, without re-freezing the full P16
design. Section 6 owns tier prerequisites, per-batch approval and X-row subset
mapping:

| Class | Examples | Authority required |
|---|---|---|
| G0-L0 | Native-helper/adapters/Host source, compile/analyze/format, versioned codecs, pure algorithms/Mocks/fixed public vectors and source guards; no real Windows security object or communication | Normal scoped task authority on a dedicated branch; no L1 experiment grant required |
| G0-L1 | Exact test-only DPAPI/NTFS/lock/atomic-replace/key/certificate primitive batch | Individual user grant, reviewed helper and section 6 preconditions; LOCAL-L1 only |
| G0-L2 | One bounded 127.0.0.1 TCP/mTLS candidate, TLS 1.3 authentication/connection and resource closure, no business routes | Necessary passing L1 evidence, independent implementation review and a separate exact L2 user grant; LOCAL-L2 only |
| G0-I | Original X0–X12 / A0–A12, including cross-SID, business lifecycle/effect and packaged acceptance | Independent-kernel Windows environment and exact row grants, fixed-target Verifier and independent Reviewer; complete formal criteria unchanged |

Explicit non-inference: the user continuing development does NOT authorize
actual system credential modification, generation or installation of formal
certificates, SID/ACL/Discovery object changes, starting a real TCP/mTLS
listener, or high-risk stability reproduction on the primary host. The
permanent stop on primary-host AF_UNIX experiments
([external boundary section 6](external-agent-boundary.md)) is unchanged.
HOST_STABILITY_HALT remains ACTIVE: high-risk crash/driver/kernel reproduction
is forbidden, while new TCP/DPAPI/CNG/NTFS local experiments require their
individual L1/L2 exception grants. The primary computer may be named in such a
future application; P17 itself authorizes no real calls, listener or test run.

**BLOCKED_ON_G0** now describes real experiments lacking their applicable
environment/prerequisites and exact batch grants, not G0-L0 code development.
Formal Windows acceptance remains blocked until G0-I and complete A evidence;
production activation additionally retains section 8's separate security and
system-stability decisions, Verifier/Reviewer and explicit user authority.
Previously unfrozen details (multi-user provisioning, enrollment UX, release
packaging specifics, undefined custom signed-record formats) need bounded
decisions only when their implementation requires them; they do not create
another general offline authentication design stage or a second business owner.

P16 completion means: production credential, certificate, possession-proof,
Windows secure storage and Discovery candidates have concrete minimal
specifications, and the next real implementation's authorization and
verification needs are stated. It does NOT mean any real Windows security
acceptance passed.

P17 completion means the X.509 encoding conflict is corrected, controlled
primary-host L1/L2 applications have explicit gates, the AF_UNIX halt is
preserved, full Windows acceptance still needs complete evidence, and the next
authorized work package can directly implement Package 1. No real experiment
or production Credential/Host activation is granted; no automatic P18 or AR-R6B.
Any local success leaves the following statuses unchanged until a separately
authorized full acceptance/activation decision:

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.

## 10. P18 Native Helper and FFI foundation

This first Package 1 slice supplies production source in
`windows/external_native` and `lib/data/external/native`. It is a primitive
boundary, not a Credential Store or an authentication implementation. P0/P12
still own Principal, PairingState and Session; P15 still owns association and
verification authority. No Application port or existing failure vocabulary is
redefined, and neither P12 nor P15 is wired to this adapter.

### Native ABI and ownership

The independent Windows x64 C++17 DLL `shiroha_external_native.dll` has six
explicit C exports, with `__cdecl`, fixed-width integers and ABI version 1:

| Export | Parameters / result |
|---|---|
| `shiroha_native_abi_version` | No arguments; `uint32_t` version |
| `shiroha_native_buffer_alloc` | `uint64_t capacity`; zero-initialized `uint8_t*`, or null on invalid size/allocation failure |
| `shiroha_native_buffer_free` | Original live `uint8_t*` from this DLL, exactly once; null is a no-op |
| `shiroha_native_local_app_data` | `uint32_t version`, output pointer, `uint64_t capacity`, aligned `uint64_t* written`; `int32_t` status |
| `shiroha_native_dpapi_protect` | Version, borrowed input pointer, `uint64_t length`, output pointer/capacity/written; `int32_t` status |
| `shiroha_native_dpapi_unprotect` | Same memory/length protocol as Protect; `int32_t` status |

Memory bounds are 1–65536 bytes, with checks before arithmetic, narrowing or
OS calls. This is a primitive memory bound, not an object codec or file-size
admission check: DPAPI expansion beyond the output capacity fails `resourceLimit`
without a partial result. Zero-length inputs are rejected. Caller pointers
must designate live, disjoint storage of the stated extent; arbitrary foreign,
interior or freed allocation pointers are outside the C memory contract.
Invalid null, overflow, extent, alignment and alias arguments fail before the
OS operation; invalid address/alias results are unusable and may remain
untouched. For valid disjoint output/count memory, failures clear the output
and set written to zero. Success copies only initialized result bytes.

The helper owns the allocation header and recorded capacity. Free wipes the
whole payload and header before releasing them with the same C allocator.
No C++ container or exception crosses the ABI. OS-produced DPAPI buffers are
helper-owned: all returned bytes, including decrypted plaintext, are wiped
before `LocalFree` on success and failure. Known-folder allocations are
released by `CoTaskMemFree`, also on failure. Output is copied only after
success and length validation; RAII retains cleanup on every return path.
The Dart adapter borrows no returned native storage: it copies into caller-owned
Dart bytes, then releases all native allocations in nested `finally` paths.
The caller is responsible for bounded use/disposal of sensitive Dart copies;
native zeroization does not promise removal of Dart GC copies.

| Native status | Infrastructure failure |
|---|---|
| 0 | Success, still subject to Dart result/length validation |
| 1 | `invalidInput` |
| 2 | `abiMismatch` |
| 3 | `resourceLimit` |
| 4 | `temporarilyUnavailable` |
| 5 | `dataCorrupt` |
| Unknown status / invalid successful result | `invalidNativeResult`, hard rejection |

Wrap failure is unavailable; unwrap failure is corrupt. Neither maps to
Missing or starts deletion, rekey, regeneration, trust reconstruction or an
alternate backend. No Windows error code, unsafe exception text, path or
secret is included in the exception. These are local Infrastructure categories,
not new P15 failures or external MCP output.

### Implemented scope and activation boundary

The real wrappers call `CryptProtectData` / `CryptUnprotectData` with flags 0,
null description/output-description, entropy, reserved and prompt arguments.
There is no machine-scope, Provider/plugin backend or persistence. The real
known-folder wrapper calls `SHGetKnownFolderPath(FOLDERID_LocalAppData)` through
Windows Unicode APIs and returns UTF-16LE without a terminator. Dart strictly
validates length, NUL and surrogate pairs and returns a redacted path value.
That value establishes no owner, DACL, volume, reparse or handle validation;
no External directory is created and no arbitrary caller root is accepted.

`WindowsExternalNative.open()` is explicit. Production uses only the absolute
directory of `Platform.resolvedExecutable` for the DLL, with no PATH/current-
directory/environment search or alternate candidate. Non-Windows, missing DLL,
symbol failure and incompatible ABI deny operations. ABI is checked on open
and before every operation/allocation. Import and startup perform no native
operation; no Runner startup logic or Agent/MCP route invokes the helper.
The CMake target links only the required Windows system libraries (crypt32,
shell32, ole32, uuid); it depends on neither Flutter nor Runner. The Windows
bundle includes the DLL as packaging only. Standalone AOT Bridge packaging,
native load and runtime acceptance remain Package 3 work.

### Evidence boundary and remaining work

Local G0-L0 evidence includes actual MSVC Windows x64 compilation/linking of
the independent target and inspection of all six exported names and required
system imports. The opt-in C++ offline executable links the core with fake
operations only; its import table contains neither DPAPI nor known-folder
calls. It covers invalid versions/pointers/lengths/overflow/aliases, output
bounds, fixed failures, fake partial failures, zeroization before local release,
Unicode and task-allocation cleanup. These tests prove core memory/call contracts,
not real OS security behavior.

Bounded local check commands (from an MSVC/CMake-capable developer shell) are:

```powershell
cmake -S windows/external_native -B build/p18-native -G "Visual Studio 17 2022" -A x64 -DSHIROHA_NATIVE_OFFLINE_TESTS=ON
cmake --build build/p18-native --config Debug
ctest --test-dir build/p18-native -C Debug --output-on-failure
dumpbin /exports build/p18-native/Debug/shiroha_external_native.dll
dumpbin /imports build/p18-native/Debug/shiroha_external_native.dll
dumpbin /imports build/p18-native/Debug/shiroha_native_offline_test.exe
```

These commands do not configure the Flutter/plugin tree, install artifacts,
load the production helper or execute its security functions. Full Windows
tree configuration can trigger existing plugin dependency downloads and is
outside this bounded native check recipe.

Standing PR shards now also cover the Dart fake-call adapter and source guards:
platform/loader/version rejection, result copy/release on all exits, strict
UTF-16, native failure classification, exact frozen wrapper parameters, absent
production composition, no Provider/plaintext fallback and no ambient TLS-root
or accept-bad-certificate shortcut. CI remains Linux/offline; exact compile,
toolchain and command outcomes belong to PR evidence. No full Flutter bundle
or AOT Bridge build/run acceptance is claimed by this slice.

Actual known-folder resolution, DPAPI behavior and Windows protected-object
validation are **LOCAL-L1 PENDING**, with no L1/L2 grant or security function
execution. Credential Store persistence/CAS/tombstones, protected directory/file
objects, NTFS identity checks, runtime.lock/client.lock, key/certificate issuance,
pairing crypto, discovery, Listener and Bridge integration are absent. The next
separately scoped Package 1 slice prioritizes protected file objects, NTFS
validation and exclusive writer locks before wiring the versioned DPAPI store.
Anchor-rotation record encoding remains UNDEFINED and is not implemented.

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
