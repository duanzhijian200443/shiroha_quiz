# Agent Runtime v1 / External Agent / MCP vNext Contract Index

Current scheduling: **Windows desktop MCP functional development first; Windows
high-assurance real security experiments DEFERRED**. The
[roadmap amendment](../../architecture/shiroha-project-roadmap.md#windows-mcp-first-scheduling-amendment-2026-10-19)
owns the complete functional exit conditions: full seven-tool READ/STAGE and
Proposal queries, controlled App/user Review, durable/idempotent recovery,
isolated real-client end-to-end proof and Windows Codex launch/lifecycle/errors.
Reuse existing Application/Proposal/Review/Gateway/IPC/permission mechanisms.
MCP v0 retains its six READ_ONLY tools and completed local actual-use validation.
Trial 1A follow-up real experiments and G0-L1/L2/I batches are deferred, including
new high-assurance experiment infrastructure, repeated preflights and separate
preparation tasks. Existing Native Helper/DLL/Pin/Custodian/authentication/transport
candidates, security criteria and historical evidence are retained. Only after
functional completion may the user separately decide whether and how to resume;
there is no automatic restart or production-enablement inference.

The bounded [STAGE stdio source composition](mcp-vnext-contract.md#7-bounded-stage-stdio-source-composition)
adds an independent seven-tool server and explicit P3/P7–P10 App wiring, exercised
only with synthetic credentials/data and real SDK stdio clients. The standalone
default refuses business calls. This source slice does not activate full AR-R6B,
the production Host/Transport or any Windows experiment.

Status: **FROZEN target architecture; AR-R1/AR-R2/AR-R3 COMPLETE / CLOSED;
AR-R4 module contribution kernel COMPLETE / CLOSED; AR-R5A COMPLETE / CLOSED;
AR-R5B generated Review UI COMPLETE / CLOSED;
AR-R6A P2 external historical Origin accepted in merged PR #249;
P3 durable STAGE / reconciliation accepted in merged PR #250;
P4 shared runtime admission / bounded READ Context accepted in merged PR #251;
P5 Context-scoped Question search/detail accepted in merged PR #253;
P6 explicit File Snapshot / lexical retrieval / passages accepted in merged PR #255;
P7 trusted external Capability/Receipt integration accepted in merged PR #256;
P8 offline Host dispatch accepted in merged PR #258;
P9 offline IPC Envelope foundation accepted in merged PR #260;
P10 offline IPC command projection accepted in merged PR #261;
P11 trusted local Profile/Grant management accepted in merged PR #262;
P12 offline trust binding accepted in merged PR #263;
P13 Windows security readiness accepted as a static checkpoint in merged
PR #264; real acceptance BLOCKED. P14 standing External CI coverage accepted
in merged PR #265. P15 offline Credential boundary IMPLEMENTATION CANDIDATE.
P16 production primitive freeze accepted as a static decision in merged PR #267;
P17 tiered experiment-gate / X.509 encoding amendment is documentation only;
P18 Native Helper/FFI production source slice has G0-L0 evidence, real Windows
functionality LOCAL-L1 PENDING; P19 protected-object and P20 association source
slices are merged, with PR #277 isolated-root P20 functional evidence;
P21 credential/certificate primitives are merged in PR #278, inactive G0-L0;
P22 is merged in PR #280; P23 is merged in PR #281; P24 is merged in PR #282;
P25 is merged in PR #283; P26 adds inactive G0-L0 protected Discovery
publisher/reader only; P27-E0 adds an inactive G0-L0 identity/content-bound
Exchange consumption foundation. P27-I0 adds inactive Pairing integration:
PACKAGE 1 SOURCE IMPLEMENTED / OFFLINE TESTED only; real acceptance pending.
Package 2 adds an inactive G0-L0 TCP/mTLS transport candidate (readiness §20):
PACKAGE 2 SOURCE IMPLEMENTED / OFFLINE TESTED only; real TLS/Windows acceptance
pending. Package 3 adds inactive lifecycle/recovery and static release
candidate checks (readiness §21): PACKAGE 3 SOURCE IMPLEMENTED / OFFLINE TESTED
only; final-target CI/review and real Windows/formal acceptance remain pending.

R6A-B1 (`l1_b1_unified.h`, `l1_b1_admission_worker.cpp`,
`tests/l1_b1_unified_test.cpp`) unifies the G0-L0 offline diagnostic
infrastructure for all five G0-L1 trials (`L1-ADMISSION`, `L1-CRYPTO`,
`L1-OBJECTS`, `L1-STORE`, `L1-RELEASE`) over the same E2–E5 and Package 1
foundations: a dedicated zero-crypto `shiroha_l1_b1_admission_worker` OBJECT
candidate and `UnifiedAdmissionController`, `B1ObjectsDiagnostic` (60s),
`B1StoreDiagnostic` + `StorePrimitiveLedger` (60s, single kind per batch),
`B1ReleaseLedger` (30s) and strict per-Trial operation allowlists. All three
default runtime denials (E0/E3/E5) remain closed and all five G0-L1 trial
requests remain `DRAFT_NOT_AUTHORIZED` (`executionAuthorized = false`). Highest
eligible description after actual passing checks:
**R6A-B1 L1 UNIFIED SOURCE READY / OFFLINE TESTED**. See
[readiness R6A-B1](windows-host-security-readiness.md#r6a-b1-unified-g0-l1-diagnostic-infrastructure-g0-l0)
and [diagnostics R6A-B1](../../../windows/external_native/diagnostics/README.md#r6a-b1-unified-g0-l1-diagnostic-infrastructure-g0-l0-only).

B2 extends the same five unapproved request templates with a shared fixed-target
artifact inventory, separate Controller/Worker resource inputs, external custody
and evidence prerequisites, and the first Admission operation ledger. See
[readiness B2](windows-host-security-readiness.md#r6a-b2-fixed-target-preparation-boundary-g0-l0)
and [Admission application](windows-host-acceptance-preparation.md#b2-fixed-target-applications-and-stop-1-g0-l0).
No runnable fixed Admission entry or crash-surviving external custody/evidence
bridge exists; the result stays **B2-L1-ADMISSION BLOCKED** pending those source
interfaces, artifact review and exact user decisions. Default denials stay closed;
the shared machine template is neither execution authority nor a second database.

The [B2-R1 amendment](windows-host-security-readiness.md#b2-r1-admission-wiring-amendment-g0-l0)
adds dedicated closed Controller/Worker EXE candidates over the same injected
composition, independent measurement/pin ports, a sole-creator Custody port and
bounded redacted Evidence sink with end-to-end Fake tests. It supersedes the
earlier absence of source interfaces, while actual cross-process custody and
retention remain BLOCKED. This is **B2 ADMISSION SOURCE BLOCKED** overall;
source/Fake closures grant no real execution or acceptance.

The [B2-R2 amendment](windows-host-security-readiness.md#b2-r2-batch-custodian-and-windows-admission-adapters-g0-l0)
completes the per-batch Custodian candidate (`shiroha_l1_r2_custodian_candidate`),
compile-only Windows identity/pin/persistence/owner adapters (`shiroha_l1_r2_windows`),
nine-field three-process resource budgets and hard OS call ceilings (`kPolls=512`,
`kUiEvents=128`, `<=256` `ReadFile` blocks per `<=16 MiB` artifact) with Fake
three-process and crash-window tests. Live execution stays unconditionally
denied (`exit 10`), and all five L1 requests remain `DRAFT_NOT_AUTHORIZED`.
Highest status is **B2 WINDOWS ADMISSION SOURCE REVIEWABLE / OFFLINE TESTED**.

The [B2-S1 amendment](windows-host-acceptance-preparation.md#b2-s1-trial-1a-root-preparation-source-g0-l0)
adds the one-shot Trial 1A root-preparation source (`l1_s1_root`) and an unlinked
`shiroha_l1_s1_windows` OBJECT: complete approved parent pins, one parent-relative
exclusive `NtCreateFile` carrying the approved Owner/DACL in the create, actual
File ID/security revalidation, a bounded in-memory Pin borrow and one-shot
named-Owner closes. Fake-only tests cover drift, budget, evidence, handoff and
close; no Worker, Grant or production directory is involved and live execution
stays unconditionally denied. The approved device/account/paths/operators and
operation budget remain `REQUIRES USER DECISION`, so **B2-TRIAL1A BLOCKED**
remains and the highest status is unchanged.

The [Trial 1A entry amendment](windows-host-acceptance-preparation.md#b2-trial-1a-fixed-target-diagnostic-entry-g0-l0)
composes S1/R2 behind one typed fixed-target entry, an unlinked Windows OBJECT
and a separately buildable pure refusal EXE (exit 10). Three process/permission
checks and the complete combined budget precede create/Pin handoff; the existing
R2 evidence commits the entry binding. Fake coverage exercises the same injected
composition. Actual device/account/path/artifact/Owner/budget selection, upstream
pin acquisition, independent fixed-target evidence and separate real authority
remain required; source readiness does not make Trial 1A authorization-ready.

The [Trial 1A Pin acquisition amendment](windows-host-acceptance-preparation.md#b2-trial-1a-pin-acquisition-amendment-g0-l0)
adds the missing upstream source to that SAME application: one deduplicated
existing-object inventory, parent-relative opens with actual identity/Owner/DACL
checks, exact Entry/S1 borrows and one complete budget including final closes.
The Windows adapter is unlinked and unconditionally denied. Eligible mechanical
status is **TRIAL1A PIN ACQUISITION SOURCE READY / OFFLINE TESTED**; actual fixed
device/account/objects/artifacts/budgets/owners and independent evidence still
require selection and a separate real grant. **B2-TRIAL1A BLOCKED** remains.

The [consolidated Trial 1A application](windows-host-acceptance-preparation.md#trial-1a-final-readiness-and-one-consolidated-authorization-application)
collects the selected current Windows computer's remaining account/path/Pin/
artifact/budget/owner decisions and the complete existing-chain operation ledger.
`RealEntry`/`WindowsRealEntry` now implement the actual typed controlled source
chain, existing local-human UI, post-launch measured PID/time binding, exclusive
R2 spent-permit consumption and bounded time/resource/ownership accounting.
Empty/partial/existing tombstones deny restart replay. Fake exercises the same
chain and process latch; the actual diagnostic entry DLL now links all required
Windows adapters, checks its own distinct loaded artifact pin before consumption,
and retains custody/final ledger for process lifetime. It is inspected statically
and never loaded/invoked by L0. Original legacy/public denials remain unchanged.
The eligible ceiling is **TRIAL1A REAL ENTRY SOURCE IMPLEMENTED /
OFFLINE VERIFIED**, not authorization-ready or real acceptance. Trial 1A issues
no Grant and launches no Custodian/Worker.
Read-only preflight and the eventual exact one-time invocation have distinct
permission scopes in that same application; no new general G0-L0 stage is added.

The E5 controlled diagnostic composition connects the same E4 issuance,
write-ahead consumption, suspended Worker, six-message IPC and E2 Supervisor/
Native settlement under one fixed-target local-human Controller. Extra directory,
Controller budgets and manual recovery scope are bound into the existing target
hash. Controller/Worker remain unlinked OBJECTs, without executable entries;
E0/E3/E5 real gates all deny. Highest eligible description after actual passing
checks: **E5 CONTROLLED ADMISSION SOURCE READY / OFFLINE TESTED**.
See [readiness E5](windows-host-security-readiness.md#e5-controlled-diagnostic-admission-composition-g0-l0)
and [independent Trial 1 / Trial 2 applications](windows-host-acceptance-preparation.md#e5-two-independent-single-trial-applications).
No real identity/root/entry/recovery approval, NTFS proof or LOCAL-L1 PASS is
inferred; all existing HALT/Transport/AR-R6A/Windows/formal gates remain unchanged.

The L1-CRYPTO E4 Windows admission candidate adds unlinked compile-only
Approval UI / Grant IO / suspended-Worker OBJECT leaves to the same E2
Supervisor: a two-step local-human prompt and receipt, target-then-object
identity binding, CREATE_NEW durable-request one-use with a locked conditional
burn, UTC window validation with monotonic 30000ms supervision, six 64-byte
message types with 24-part settlement and an injected suspended-Worker port.
Only Fake approval/persistence/deadline/custody paths are tested; the real entry
and integrated backend still deny, the real leaves are not linked, registered
with CTest or activated, and no real Windows UI/process/IPC/crypto experiment
ran. See
[readiness E4](windows-host-security-readiness.md#e4-local-human-single-use-admission-source-candidate-g0-l0)
and [diagnostic boundaries](../../../windows/external_native/diagnostics/README.md#e4-local-human-admission-candidate-g0-l0-only).
Highest scope: L1-CRYPTO E4 ADMISSION SOURCE IMPLEMENTED / OFFLINE TESTED.
executionAuthorized=false, L1-CRYPTO DRAFT_NOT_AUTHORIZED, all 13 A0–A12
WINDOWS_PENDING rows and the real ceiling/root/SID/window/owner decisions remain;
HOST_STABILITY_HALT = ACTIVE / TRANSPORT = BLOCKED / AR-R6A = NOT_ACCEPTED
are unchanged.

The L1-CRYPTO E3 Windows admission candidate adds unlinked compile-only Win32
Token/object/lock/burn/observation leaves and injects durable-consumption/Worker
ports into the same E2 Supervisor. Its actual Windows backend still denies
trusted approval, identity and launch; consume stays UNKNOWN before I/O.
Only Fake races/reconstructed-client replay/UNKNOWN/STOP/settlement are tested;
no real cross-process durability or runnable L1 grant is claimed. See
[readiness E3](windows-host-security-readiness.md#e3-windows-admission-source-candidate-g0-l0-only)
and [diagnostic boundaries](../../../windows/external_native/diagnostics/README.md#windows-admission-candidates-e3-source--compile--fake-only).
Highest scope: L1-CRYPTO WINDOWS ADMISSION SOURCE PREPARED / OFFLINE TESTED.
Exact new C: root/objects/SID/device/window/OS ceilings/owners/approval source,
durable journal and IPC/process plan remain REQUIRES USER DECISION.
No actual Windows leaves are executed; executionAuthorized=false,
L1-CRYPTO DRAFT_NOT_AUTHORIZED and all A0–A12 WINDOWS_PENDING remain.

The L1-CRYPTO E2 admission candidate adds complete 106-ABI attempt budgets,
diagnostic-only direct CNG/crypt32 settlement observation, and pure OFFLINE
one-use grant/Supervisor/evidence models. Highest scope is L1-CRYPTO ADMISSION
SOURCE HARDENED / OFFLINE TESTED; real Windows protected grant consumption,
identity/IPC/process supervision and execution remain BLOCKED. E0 default denial,
executionAuthorized=false, REAL WINDOWS/FORMAL ACCEPTANCE PENDING remain intact.

AR-R6A-L1-CRYPTO-E0 adds an isolated default-off CMake compile-only L1-CRYPTO
harness candidate (7-symbol ABI allowlist, fixed `l1_crypto_execution_not_authorized`
deny entry, Fake-only offline CTest and static PE header/import/dependents
audits): L1-CRYPTO HARNESS SOURCE READY / OFFLINE TESTED only; `L1-CRYPTO`
stays `DRAFT_NOT_AUTHORIZED`; real Windows/formal acceptance and execution
grants remain pending.**

The Provider seam, typed capability/executor/projection path and Runtime split/
transcript are delivered in the preceding merged stages. Historical AR-R3
activation recorded an earlier-head review mismatch on AR-R2's PR #241; under
AGENTS.md's current historical merged-stage rule, merged #241 and #242 are
accepted preceding stages without inventing a missing approval record.
AR-R4 was accepted and merged in [PR #243](https://github.com/duanzhijian200443/shiroha_quiz/pull/243),
with final-head standing CI success and independent repair-review closure.
Current open candidates still require final-target CI and independent review.

AR-R4 implements the source contribution kernel and default feature registration
as described in `module-system.md`. It retains existing capability semantics,
Provider protocol, Runtime loop/lifecycle, transcript and fallback behavior.
AR-R5A implements durable generated proposals, review CAS and atomic approval
at schema v32 with B0 package v2, accepted in merged
[PR #244](https://github.com/duanzhijian200443/shiroha_quiz/pull/244).
AR-R5B adds first-party Inbox/completed history, structural typed preview/editor,
Review Flush/CAS and explicit approval/rejection with Receipt recovery, using a
persisted local data-owner identity and restore-invalidated Application sessions.
`generated-question-proposals.md` owns this accepted behavior (merged PR #245).
P1 non-secret Profile/Grant v33 storage is accepted through merged PR #248.
P2 strict historical external Origin/v34 compatibility is accepted through merged
PR #249. P3 supplies the accepted, unpublished transport-independent durable STAGE and narrow
reconciliation described in GeneratedQuestion §11 (merged PR #250). Its current Grant
checks share the owning SQLite publication transaction with revoke authority.
P4's accepted unpublished Application/Data path (merged PR #251) extracts that existing runtime
binding authority and adds bounded READ target metadata/opaque Contexts under
external-agent-boundary §3. Target metadata requires READ + questionContent;
STAGE reconciliation remains independent. Schema v34/B0 v2 are unchanged.
P5's accepted unpublished Context-scoped Question search/detail (merged PR #253) is under
the same external contract §3, sharing the Registry and StudyQuery's safe
projection while Data owns exact-scope reads and final release revalidation.
Original P4/P5 File/Evidence snapshots remain empty. P6 adds separate explicitly
selected File Contexts, RAG-1 lexical retrieval and continuous safe Chunk passage
reads under independent current READ + fileContent + exact File/Project scope.
It reuses P4 Registry/budgets and verified F1/Chunker/Index/derived-cache evidence;
no transport, MCP or general Principal is wired in P6, accepted through merged
PR #255 with its required independent verification and semantic review.
P7 adds unpublished trusted external Principal/Kernel/Receipt integration under
Application capabilities §7. Its exact-Session execution Context is separate
from the unchanged P4-P6 Principal/generation-bound READ references. Existing
services still own business authorization, budgets and transaction effects.
P7 is accepted within its unpublished scope through merged PR #256. P8 adds an
offline-only trusted Host dispatch/startup/drain seam under external boundary §3,
accepted in merged PR #258. P9's accepted unpublished infrastructure framing/codec (PR #260)
under external boundary §7 only validates bounded envelopes, never identity or
business authority. P10 adds the accepted offline command-schema/projection
under §8, using current authenticated P8 binding before parsing, trusted P8
Context inputs and ten typed P7 routes, with safe output and original local
effect evidence retained on encoding loss. It adds no production wiring.
P10 is accepted within its offline scope through merged PR #261. P11 adds a
first-party settings page and Application management views under external
boundary §9, reusing P1 policy/CAS/B0 authority. Profile and Bank management
queries are internal read-only queries, including empty existing banks; File
and Project choices reuse the existing trusted Application services. It configures
non-secret access rules only: clients remain unpaired and disabled. There is no
credential, Principal, Session, Enablement switch or production Host wiring.
P11 is accepted within its local scope through merged PR #262; external boundary
§10 records its successful CI/fixed-target verification and zero-blocker semantic
review without inventing a later review-approval marker. P12's accepted offline scope
under §10 links existing opaque Profile selections to the sole P0 Principal and
PairingState authority, generation-bound P4 admission and P8/P7 current policy
checks. Local selection, proof and finite enablement remain distinct operations;
shutdown drains actual owning work before generation invalidation. Only test
composition provides synthetic credentials. Real SQLite restart and B0 retain
historical Proposal/key facts without reactivating old runtime authority.
P12 is accepted through merged PR #263 with final CI success and Reviewer
APPROVAL. Its final fixed-target offline verification was performed by that same
review session under explicit user instruction; no separate independent Verifier
session or VERIFICATION APPROVAL is claimed. External boundary §10 links the
historical closure. This acceptance establishes no real credentials or transport.
P13's [Windows security readiness](windows-host-security-readiness.md), owned by
external boundary §11, is accepted as a static readiness checkpoint through
merged PR #264: static feasibility/gaps and isolated Windows experiment/
acceptance/fallback gates, with no implementation or runtime authority.
P14 (auxiliary CI-engineering sub-stage, merged PR #265) makes the External offline Application/
IPC/origin regression matrix and the repeatedly re-verified widget/RAG/Agent
config suites standing PR contract coverage; that is Linux-offline evidence only
and clears no WINDOWS_PENDING item. Independent environment approval and new
experiment authorization remain missing; formal dynamic acceptance is BLOCKED and
AR-R6B stays inactive.
P15's offline candidate under external boundary §12 adds a dedicated protected
association port and private one-use verification windows into P0/P12. Pairing
and channel authentication are distinct; current Profile management, association
CAS and runtime-instance/generation/liveness checks remain mandatory. Only tests
provide memory storage/synthetic verification. It supplies no production crypto,
secure storage or external authentication composition, and clears no M1–M4 real
Windows requirement. G0 and X0–X12 remain unapproved and unexecuted. P15 tests
extend the existing 273-file standing coverage without changing its shards.
P16 (external boundary §13) freezes the production primitive candidates under
[windows-host-security-readiness.md §9](windows-host-security-readiness.md):
certificate/identity model, a single DPAPI-backed External object store,
cryptographic possession proof and the owner-only Windows Discovery root, with
minimal implementation packages and their required experiment authority. P16
selects candidates only — no implementation, dependency or schema change, and
no WINDOWS_PENDING item is cleared. P17 supersedes the single isolated gate
with G0-L0 ordinary development, separately approved G0-L1 security-primitive
and G0-L2 bounded Loopback functional batches, and independent-kernel G0-I full
Windows acceptance. G0-L1/L2 are applications only; this amendment authorizes
no experiment. BLOCKED_ON_G0 applies to real experiments lacking exact grants,
not code/compile/offline work under scoped implementation authority. Full
A0–A12 / X0–X12, separate security/stability closure and independent
Verifier/Reviewer remain required; local success is no automatic A PASS.
P17 also corrects X.509 signatures to ASN.1 DER ECDSA-Sig-Value while Pairing
Proof/Endpoint Descriptor remain raw r‖s (64 bytes), with P-256/SHA-256 and
credentialIdentity unchanged. Readiness §§6, 9.A.2 and 9.F own these amendments.
P17's handoff specified direct Package 1 implementation in bounded
dependency slices, with actual-implementation offline tests/source guards;
there is no new general offline authentication design stage and no Package 1
code implementation was authorized by the P17 documentation task.

P18 supplies the first Package 1 production source slice: an independent
Windows x64 C++17 Native Helper, versioned C ABI, bounded native memory,
known-folder resolution and user-scope DPAPI wrappers, plus a shared explicit
Dart FFI adapter. [Readiness section 10](windows-host-security-readiness.md#10-p18-native-helper-and-ffi-foundation)
owns the ABI/ownership/failure contract. Local native compilation/export checks
and fake-only core/Dart tests establish G0-L0 mechanical evidence, not real
Windows functionality. No Credential Store, protected root, key/certificate,
Host or Bridge composition is supplied; LOCAL-L1 remains PENDING.
P19 and P20 are merged source slices under readiness §§11–12: protected
objects/single-writer ownership and the kind 3 association backend. Merged
PR #277 records isolated-root first-create, replacement and DPAPI readback
with no temporary residue. Production-root/full Windows acceptance remains
pending; this is neither G0-I nor transport/Host acceptance.
P21, merged in PR #278, under readiness §13 supplies inactive P-256 primitives,
PKCS#8 conversion, raw/DER signatures, X.509 structure/vector checks and strict
kind 1/2/4 codecs with a minimal explicit Dart adapter. It is G0-L0 only,
without production credentials, store publication or runtime activation.
P22, merged in PR #280, under readiness §14 supplies strict pairing-transcript, exchange-file-payload
and Discovery descriptor codecs, fixed public vectors and pure validation against
explicit trusted inputs. Decoded DTOs/signature results supply no P15 authority.
No file publisher/reader, actual crypto operation, pairing flow, Host/Bridge or
transport is activated; this is G0-L0 format/validation implementation only.
P23, merged in PR #281, under readiness §15 adds SOURCE IMPLEMENTED / OFFLINE TESTED fixed kind
1/2/4 protected-object transactions and `WindowsCredentialObjectStore`, with
strict existing-object decoding, user-scope DPAPI and Win32 handle-relative
publication. ABI 3 adds three optional exports while preserving P20 behavior.
REAL WINDOWS PENDING / FORMAL ACCEPTANCE PENDING remain explicit; no credential
initialization, signing/rotation, Pairing, Discovery I/O or startup is activated.
P24, merged in PR #282, under readiness §16 adds SOURCE IMPLEMENTED / OFFLINE TESTED fixed-kind/ID
Native Exchange create/read and creator-only cleanup with strict P22 codec
boundaries and directory-identity-bound cross-process quota exclusion. ABI 3
adds three optional exports while preserving all eighteen existing exports.
REAL WINDOWS PENDING / FORMAL ACCEPTANCE PENDING remain explicit; no Pairing
transition, consumption order, credential ticket, Host/Bridge activation or
startup is supplied. P20's isolated-root functional result is not extended.
P25, merged in PR #283, under readiness §17 is an inactive credential initialization/issuance source
candidate: explicit App Issuer/Server creation, persisted cryptographic validation,
partial-Server recovery and restricted Client leaf issuance. P23 gains only a
same-ticket create-if-missing operation; its write API, formats and ABI remain
unchanged. Public fixed-vector tests supply offline evidence only; real Windows
acceptance, Client possession, Pairing and production wiring remain pending.
P26 under readiness §18 adds SOURCE IMPLEMENTED / OFFLINE TESTED fixed-kind
protected Discovery Publisher/Reader Native/FFI and Data adapters, same-ticket
kind 1 epoch advancement with P25-backed signing-state validation and
conditional existing kind 4 high-water updates. P22 trust inputs remain
independently supplied; no initial Pin, listener, TLS, authorization or
production wiring is added. REAL WINDOWS PENDING / FORMAL ACCEPTANCE PENDING
remain explicit.
P27-E0 under [readiness §16](windows-host-security-readiness.md#p27-e0-identity-bound-consumption-foundation-inactive-g0-l0-only)
adds SOURCE IMPLEMENTED / OFFLINE TESTED identity/content-bound Exchange
consumption infrastructure only. Three optional ABI-3 exports
(`shiroha_native_exchange_read_begin`, `shiroha_native_exchange_consume`,
`shiroha_native_exchange_release`) preserve the existing twenty-three exports.
Bounded Owner-bound Reader Tickets retain object identity pins and exact original
bytes; full P22 strict decoding precedes controlled-read delivery. Explicit
Consume revalidates identity and exact content on the protected deletion handle;
Release drops the pin without deleting. Ordinary P24 Read and creator Cleanup
remain unchanged. No P15 verification evidence or business authorization is
created by E0 itself; P27-I0 below owns Pairing sequencing and D0 consumption timing.
REAL WINDOWS PENDING / FORMAL ACCEPTANCE PENDING remain explicit; no production
Host/Bridge, Transport or Runtime Enablement is activated.
P27-I0 under [readiness §19](windows-host-security-readiness.md#19-p27-pairing-and-package-1-offline-integration-g0-l0-only)
adds inactive App/Bridge local action ports, actual Pairing mathematical
verification through P21 primitives, existing P15/P0 completion and Missing-only
initial Bridge Pin persistence after two independent manual comparisons.
The trusted Request deadline is bounded by 600 seconds, defaulting to the
unchanged 30 seconds; the private Evidence Window remains 30 seconds and the
single-use Bridge completion window is at most 120 seconds. Package 1 reaches
SOURCE IMPLEMENTED / OFFLINE TESTED only. No real UI/process Pairing, Windows
security acceptance, listener, TLS, new authorization or production wiring is
claimed. Section 19's table is the Package 1 integration coverage index.

Package 2 under [readiness §20](windows-host-security-readiness.md#20-package-2-tls-and-bounded-host-adapter-g0-l0-only)
adds an inactive SOURCE IMPLEMENTED / OFFLINE TESTED TCP/mTLS transport
candidate: explicit Raw IPv4 accept with bounded TLS upgrade, isolated explicit
TLS 1.3 contexts, an optional certificate-only ABI-3
`shiroha_native_peer_certificate_policy` export, P20 read-only inverse
association lookup, private one-use P15 channel evidence, P26-acknowledged
publication and the unchanged P9/P10/P8/P7 pipeline under fixed first-candidate
ceilings (one request per connection). Source guards keep the group unwired; no
listener, TLS context, credential object, Host or Bridge production composition
is activated. REAL WINDOWS PENDING / FORMAL ACCEPTANCE PENDING remain explicit;
G0-L1, G0-L2 and G0-I keep their separate grants. Package 3's now-delivered
source candidate below is not production lifecycle/release activation.

Package 3 under [readiness §21](windows-host-security-readiness.md#21-package-3-lifecycle-and-release-source-candidate-g0-l0-only)
adds an inactive owned-Host lifecycle, recovery evidence and static release
inspection candidate: `WindowsTlsHost.owned` transfers one already acquired App
Owner with `runtime.lock` custody into the SAME Package 2 Host, validating the
exact P26/P25 Owner, P20 Store, P27 Pairing verifier, attached P15 boundary and
P12 coordinator, with a one-use `claimRuntime` and the `inactive -> preparing
-> ready -> closing -> closed` phases. Sticky fail-closed shutdown closes
admission and waits accepted work, P8/P7 owning settlement, P27 operations,
P15/P12 verification/drain and a started revoke CAS before P20 Store close,
releasing the Owner/`runtime.lock` last; uncertain cleanup retains custody and
never reports clean closure. Channel close invalidates only its own attempt;
explicit `revoke()` delegates the P15 management check -> evidence/admission
close -> drain -> Association CAS without reopening a failed CAS. The A8
offline fixture cuts a Fake Channel after the actual P3 commit and reconciles
the original SubmissionKey through a fresh P15 Session without restage.
`WindowsExternalReleaseCandidate` performs pure package/PE inventory checks
without loading, and the default-disabled `tool/external/bridge_candidate.dart`
AOT entry refuses activation (64/78); source guards keep the group unwired.
Package 3 reaches SOURCE IMPLEMENTED / OFFLINE TESTED only: it is neither
production activation nor an A-row acceptance, and no real
shutdown/restart/revoke/crash/release trial or AOT/Release build is performed.
REAL WINDOWS PENDING / FORMAL ACCEPTANCE PENDING remain explicit; G0-L1, G0-L2
and G0-I keep their separate grants.

AR-R6A-L1-CRYPTO-E0, recorded under [readiness §21](windows-host-security-readiness.md#21-package-3-lifecycle-and-release-source-candidate-g0-l0-only),
adds the isolated G0-L0 harness candidate for the future L1-CRYPTO primitive
batch. The default-off `SHIROHA_L1_CRYPTO_CANDIDATE_BUILD` CMake option compiles
a separate `shiroha_l1_crypto_candidate` executable from only the pure memory
core, CNG P-256 and crypt32 peer-policy translation units, linking only
`crypt32`/`bcrypt`/`psapi`. Its entry unconditionally refuses real execution
(`l1_crypto_execution_not_authorized`, exit 10); resolution admits only the
7-symbol ABI allowlist and rejects the other twenty ABI-3 exports before any
lookup; the synchronous 1/3/3/6(3+3)/3 reservation ledger, single-attempt
disposal slots, 18-point resource sampling and 30-second candidate ceiling stay
fixed. `check_offline.ps1` audits PE headers, hardening, DLL dependents and
import tables without running it, and runs the Fake-only
`shiroha_l1_crypto_probe_offline` CTest; the real candidate is never a CTest
entry. The L1-CRYPTO request remains `DRAFT_NOT_AUTHORIZED`
(`executionAuthorized = false`), and the highest status is L1-CRYPTO HARNESS
SOURCE READY / OFFLINE TESTED only. No real key/certificate operation, execution
grant or Windows acceptance is included; REAL WINDOWS PENDING / FORMAL
ACCEPTANCE PENDING remain explicit, and G0-L1, G0-L2 and G0-I keep their
separate grants.

E2 extends the isolated L1-CRYPTO candidate with cumulative 45 allocation/45 free
attempt budgets (106 ABI total, at most 5 live buffers), non-owning diagnostic
observation of the same CNG/crypt32 RAII wrappers and their failure/UNKNOWN
settlement, and pure grant/Supervisor/evidence models. Forced Fake Win32 tests
exercise the actual wrappers without linking security APIs; the ordinary Native
gate inspects those targets before CTest. Grant consumption is modeled only in
memory; Windows identity/protected persistence/cross-process atomicity, real
process/IPC/STOP supervision and artifact closure require separate authorization.
Highest scope is L1-CRYPTO ADMISSION SOURCE HARDENED / OFFLINE TESTED. No real
ceiling/account/time window is chosen, no experiment is run, and the original
entry stays unconditionally disabled with executionAuthorized=false.

E3 under [readiness E3](windows-host-security-readiness.md#e3-windows-admission-source-candidate-g0-l0-only)
extends the SAME E2 Supervisor with independent WindowsOperations ports
(trusted approval, measured binding, time, durable conditional consume, unique
Worker start, independent observation), adds the default-off, unlinked
compile-only Win32 Token/object/lock/burn/observation OBJECT source with a
static source guard, and covers the durable-request journal, single-owner
Worker start, exit/STOP cross-latching and immutable terminal evidence
(including the bounded adapter-refusal first-failure/terminal-BLOCKED
transition) in Fake tests only. The real backend always fails
trusted_approval/inspect/start and returns UNKNOWN before any consume I/O;
G0-L0 SOURCE / COMPILE / FAKE ONLY proves no real cross-process durability or
scheduling. Highest scope is L1-CRYPTO WINDOWS ADMISSION SOURCE PREPARED /
OFFLINE TESTED; no production or ABI change is included, executionAuthorized =
false and L1-CRYPTO DRAFT_NOT_AUTHORIZED remain, all 13 A0–A12
WINDOWS_PENDING rows and the pending user grants stay open, and
HOST_STABILITY_HALT = ACTIVE / TRANSPORT = BLOCKED / AR-R6A = NOT_ACCEPTED are
unchanged. Exact new root/objects/SID/device/window/ceilings/owners/approval
source, durable journal and IPC/process plan stay REQUIRES USER DECISION.

E4 under [readiness E4](windows-host-security-readiness.md#e4-local-human-single-use-admission-source-candidate-g0-l0)
adds the local-human one-shot admission candidate over the SAME E2 Supervisor and
GrantTarget. A two-step `ApprovalPromptModel`/response gates issuance; the
immutable target hash excludes the derived approval flag and a second hash binds
that target to the created receipt/grant object IDs, while the 256-byte receipt
and 128-byte journal keep the issue/request/consume/start order. CREATE_NEW
reservation and a locked conditional burn precede one suspended-create attempt;
an uncertain reply, lost receipt, pin drift, failed post-creation inspection or
UNKNOWN keeps custody and never reissues the Batch. UTC alone validates the
approval window while monotonic time alone drives the inclusive 30000ms deadline,
so a late handshake earns no extension and a HELLO/SAMPLE after the deadline is
never admitted. Diagnostic IPC is six types over fixed 64-byte frames with
44/3/3008 byte caps and 24-part settlement; the Windows Approval UI, Grant IO and
CREATE_SUSPENDED/Resume leaves stay compile-only in the unlinked OBJECT library,
with no CTest entry, production link, Host/Bridge/Store/TLS/ABI change or
activation. Fake approval/persistence/deadline/custody tests only: real Approval
UI, NTFS durability, process/IPC/crypto, deadline and recovery behavior remain
unproven. Highest scope is L1-CRYPTO ADMISSION SOURCE IMPLEMENTED / OFFLINE
TESTED; executionAuthorized = false and L1-CRYPTO DRAFT_NOT_AUTHORIZED remain,
all 13 A0–A12 WINDOWS_PENDING rows stay open, and every real Worker/Controller
ceiling, new root, SID/device/window, STOP/recovery/evidence owner and recovery
operation stays REQUIRES USER DECISION.

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
Production Host/IPC and full MCP vNext production exposure remain inactive;
READ fallback continuation remains an unimplemented target. Authentication,
authorized Context/bank Scope, STAGE Review and App-only writes are unchanged;
the vNext production entry stays disabled. Current product behavior
continues under the existing capability contracts.

## 1. Authority and ownership

`ARCHITECTURE.md` owns repository-wide dependency and typed-core invariants.
This directory owns the focused target contracts listed below. Location under
`docs/product/` does not turn protocol details into Application semantics or
limit the module contract to Assistant features.

| Target truth | Canonical owner |
|---|---|
| Turn lifecycle, Provider outcomes, transient transcript, turn policy | [agent-runtime-v1.md](agent-runtime-v1.md) |
| Typed capabilities, permissions, effects, receipts and projection boundaries | [application-capabilities.md](application-capabilities.md) |
| Compile-time modules, contributions, dependencies and storage compatibility | [module-system.md](module-system.md) |
| External identity, grants, context handles, egress and local Host/IPC | [external-agent-boundary.md](external-agent-boundary.md) |
| Windows credential/IPC security readiness, frozen primitives, tiered local experiment gates and independent Windows acceptance | [windows-host-security-readiness.md](windows-host-security-readiness.md) |
| Windows acceptance evidence matrix, entry gaps and unapproved L1/L2/I request templates (G0-L0 only) | [windows-host-acceptance-preparation.md](windows-host-acceptance-preparation.md), [static plan](windows-host-acceptance-plan.json) |
| MCP profile, Tools, protocol schemas and reference-client packaging boundary | [mcp-vnext-contract.md](mcp-vnext-contract.md) |
| Generated question admission, durable Review, atomic commit and retention | [generated-question-proposals.md](generated-question-proposals.md) |

Shared authorities remain in place rather than being copied here:

- [ADR-003](../../architecture/adr-003-agent-mcp-and-write-boundary.md): peer
  adapters and explicit Application approval.
- [RichContent](../../architecture/rich-content-foundation.md),
  [typed edit provenance](../../architecture/typed-review-edit-provenance.md),
  [R7C](../../architecture/r7c-review-result-writer-activation.md) and
  [R7C.1](../../architecture/r7c1-attempt-aware-typed-commit-finalization.md):
  typed authority and existing import-specific Review/commit behavior.
- [RAG-1](../../architecture/rag1-project-retrieval.md): verified source,
  lexical cache and Built-in Agent per-turn file egress.
- [B0](../../architecture/b0-shiroha-backup-restore.md): package, staged schema
  validation, restore and credential exclusion.
- [S0](../../architecture/s0-secure-credential-storage.md) and
  [Provider Registry](../../architecture/ai-config-provider-model-registry.md):
  existing Provider credentials and model configuration.
- [OBS-1](../../architecture/obs-1-unified-operation-trace-v0.md): diagnostic
  identity, privacy and logging. New event fields must be incorporated there in
  the stage implementing them, without duplicating the event schema here.
- [UI Finalization](../ui-finalization-ia-freeze.md),
  [Today](../today-home-refresh-freeze.md) and
  [retained U1 semantics](../u1-agent-first-ia-freeze.md): Presentation/IA.

## 2. Runtime transition and supersession

AR-R0 superseded no existing runtime contract. AR-R1 replaces only Provider round
settlement/classification and extends OBS-1 terminal evidence, preserving A0 turn
behavior and every AGENT-FB policy/barrier. OBS-1 owns the new event schema.
Future activation must update the affected owners and precise supersession
references in the same implementation candidate. A merged document, interface
stub or feature flag alone is not implementation acceptance.

| Existing owner | Preserved authority | Intended transition |
|---|---|---|
| [A0](<../A0 Built-in Agent v0.md>) | Delivered turn lifecycle and READ behavior | Runtime implementation portions migrate in AR-R1/AR-R3; one final Assistant message remains invariant |
| [AGENT-FB](<../AGENT-FB Bounded Fallback v0.md>) | All current fallback eligibility and barriers | Remains unchanged through AR-R6; bounded READ continuation is an AR-R7 opt-in policy change |
| [W0](<../W0 Safe Agent Write.md>) | Fill-missing-answer proposal and typed command | Business lifecycle retained; generic dispatch/presentation wiring may migrate |
| [SPL-1](<../SPL-1 StudyPlan Agent Tool v0.md>) | Transient draft, adoption and ActiveStudyPlan | Business lifecycle retained; draft persistence is deferred |
| RAG-1 | Source/cache authority and Provider-bound grants | External recipient authorization belongs to the external boundary, not an implicit extension of Built-in grants |
| [MCP v0](../../architecture/mcp-v0-contract.md) | Exactly six READ_ONLY tools and existing entrypoint | Coexists with a separate vNext profile; not expanded or retired here |
| OBS-1 | Existing events, identities and privacy | New safe terminal events are added during implementation |

Older schema numbers in capability closure documents describe those stages;
the current runtime schema is determined by current code and ARCHITECTURE.md.
This checkpoint changes no schema, dependency, runtime, UI or permission.

## 3. Target structure and non-goals

```text
Built-in Agent ---------------------------> Application Capability Kernel
UI / explicit approval Commands ---------> Application -> Domain
External Client -> protocol adapter
                -> authenticated local Host -> Application
Data / Infrastructure -------------------> Application ports / Domain

Compile-time Module -> capabilities -> optional UI / Agent / MCP projections
```

The App is the sole business writer. The Built-in Agent does not call MCP.
External clients are brand-neutral untrusted inputs; MCP initially exposes
READ + STAGE only. Formal Question commit requires explicit Shiroha UI approval.
Retain the dedicated Shiroha External Host architecture: Codex, Claude and
other external Agents use their own MCP Bridges to the same Host, then the
authenticated and authorized READ/STAGE services. Each Bridge is a protocol
adapter, never a second business authority or writer. P17 preserves this
target and all P0–P16 results; it activates no production Host or MCP vNext.

Excluded: generic multi-agent/graph frameworks, distributed workflows, event
sourcing, actors/brokers, microservices/cloud backend, dynamic DLL/ZIP/Dart
plugins, reflection/service locator/automatic DI, database-per-module, vector
DB replacement, arbitrary shell, autonomous external COMMIT/DESTRUCTIVE,
first-release hosted remote transport and MCP Tasks. Existing W0/SPL transient
drafts are not migrated to durable storage by this route.

## 4. Frozen implementation order

Stage identifiers below are namespaced **AR-R*** (Agent Refactor). They are not
the historical R1-R8 typed-core stages. The project
[roadmap](../../architecture/shiroha-project-roadmap.md) owns stage order and
implementation status; this table defines the contract checkpoints and bridges.
It is not an execution handoff or a delivery-status database.
The Windows-first amendment prioritizes remaining MCP functionality and necessary
Windows Codex integration ahead of real security experiments. The AR-R6A/AR-R6B
production prerequisites below still apply; functional/source progress does not
close them. A frozen gate blocking real-client validation remains an explicit
open condition under the roadmap checklist, not an admission waiver.

| Stage | Primary responsibility / prerequisite | Required acceptance / bridge | Estimate |
|---|---|---|---|
| AR-R0 | Contract ownership checkpoint | Target/current distinction; valid links; no runtime change | 1 PR |
| AR-R1 | Provider terminal/failure/OBS; after AR-R0 | Detailed classification and one round terminal; legacy fallback semantics unchanged | 1 PR |
| AR-R2 | Capability/executor/projections; after AR-R1 | Existing tool I/O/error parity; direct-call authorization; typed receipts; legacy Dispatcher facades delegate | 1 PR |
| AR-R3 | Runtime split/transcript; after AR-R2 | Turn/cancel/persistence parity; complete replay groups; public Runtime facade retained | 1 PR |
| AR-R4 | Module/contribution kernel; after AR-R3 | Deterministic graph; missing/duplicate/cycle failure; disabled contribution absent, storage retained | 1 PR |
| AR-R5A | Durable generated Proposal and atomic writer; after AR-R4 | Restart/CAS/idempotency/rollback; additive schema and B0 validation together | 1 PR |
| AR-R5B | Minimal generated Review UI; after AR-R5A | Typed preview/edit/flush/approval parity; not an Assistant-wide rewrite | 1 PR |
| AR-R6A | External authority/context/Host; after AR-R5A | Transport spike passes; pairing/revoke/egress/restart/restore and Windows boundaries | 1 PR |
| AR-R6B | Tools-only stdio profile; after AR-R5B and AR-R6A | Generic synthetic stdio end-to-end; modern/legacy protocol; v0 unchanged | 1 PR |
| AR-R7 | Opt-in READ continuation; after AR-R3, scheduled after MVP | Receipt-based replay authorization; no STAGE/unknown/file-grant replay; legacy-policy rollback | 1 PR |
| AR-R8 | Assistant controller/artifact decomposition; after AR-R6B | Existing UI lifecycle/action parity; no new permission or IA | 1 PR |
| AR-R9A | Optional MCP Resources/Prompts; after AR-R6B | Same authorization; Tools-only workflow still sufficient | 1 PR |
| AR-R9B | Separate Codex reference package; after AR-R6B | Supported-version and clean Windows installation proof; no business authority | 1 PR |

AR-R2 is estimated at one PR. Total baseline is **13 PRs**, an estimate rather
than a cap. Split further if an independently reviewable security, persistence
or compatibility responsibility requires it. Serialize by default.

Never combine Provider classification with fallback policy, Proposal schema
with external authentication/IPC schema, Host authority with its initial MCP
exposure, minimal Review with Assistant-wide cleanup, or generic MCP with Codex
packaging. Do not combine schema work with a repository directory migration.

External Agent MVP is reached after AR-R6B. Module registration MVP is reached
after AR-R4 and exercised by the AR-R5/AR-R6 feature additions. AR-R7/AR-R8 and
optional AR-R9 projections do not block generic external generation; the necessary
Windows Codex functional integration is included in the Windows-first exit
conditions. Minimal Review is part of AR-R5.

## 5. Deferred decisions and evidence

Remaining bounded implementation choices include context TTL value
(15 minutes is a candidate, not a frozen product limit) and platform
packaging/minimum supported Codex version. The selected Windows P0 IPC candidate
still needs validation under [external boundary sections 5–6](external-agent-boundary.md). AR-R6A/AR-R9B
must close their acceptance checkpoints before publication. Full wire schemas,
new storage codecs and numerical resource limits are frozen with the stage
implementing them; this target does not invent a current API.

Stage-specific meaningful tests enter hard-failing PR contract CI. New Windows
IPC/launcher behavior requires Windows CI or an independent fixed-target
Verifier when standing CI cannot cover it. Default proof uses synthetic fixtures;
real Providers, private files and installed-client runtime acceptance require a
separately authorized scope. Green mechanical checks are not semantic approval.

Feature disable retains published storage compatibility; no rollback drops user
data or runs a binary unable to read the upgraded schema. Exact Git/PR/CI evidence
stays in Git and review records, not these contracts.
