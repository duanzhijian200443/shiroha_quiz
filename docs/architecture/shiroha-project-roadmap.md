# Shiroha Canonical Project Roadmap

Status: **Canonical project stage/status authority**.

This file evolved from the former N0 post-P5 roadmap. It now serves as the repository-wide authority for project stage ordering, completion/deferred status, and cross-stage follow-up work. Focused architecture/product contracts remain authoritative inside their own domains, while merged code and tests provide implementation evidence.

R1–R8 core refactor and P5 typed manual answer repair are complete. The historical post-P5 sequence is retained below as provenance, but historical plans must not be treated as current scheduling authority.

## Current stage status snapshot

Current product availability amendment: **P6 file supplemental answering is
SHELVED**. Ordinary Answer Completion exposes queue/set detail and
single-question P7 AI generation/review/commit only; supplemental file
selection and matching/review launch are closed for every file format.
P6 implementation, dependency wiring, diagnostic entrypoint and offline
coverage remain retained. File Library, normal document import, committed
data and shared Candidate/Review/typed persistence contracts are preserved.
The COMPLETE rows below record delivery history, not P6 availability;
restoration requires separately authorized implementation and acceptance.
See `p6-supplemental-answer-matching.md` and
`answer-completion-question-sets.md` for the current availability boundary.

The canonical sequence below records the original post-P5 dependency and stage
decisions. Delivery has since advanced some independent read-side stages ahead
of that historical order. The following stages are now complete:

```text
F0
F0.1
J0
T0
M0 / M0.1
U1-R1
U1-P0
C0
A0
```

Current implementation snapshot:

```text
C0 Conversation Foundation — COMPLETE
A0 Built-in Agent v0 — COMPLETE
W0 Safe Agent Write — COMPLETE
F1-P0 Parsed Artifact canonical contract — COMPLETE
F1-D0 Parsed Artifact domain/codec — COMPLETE
F1-D1 v20 parsed artifact persistence — COMPLETE
F1-A1 Parsed Artifact lifecycle orchestration — COMPLETE
F1-I1 Deterministic generation adapter — COMPLETE
F1-I2 Explicit OCR generation — COMPLETE
F1-CL Parsed Artifact closure — COMPLETE
F1 Parsed Artifact Lifecycle — COMPLETE
S0-P0 Secure credential storage canonical contract — COMPLETE
S0-D0 Secure credential core seam — COMPLETE
S0-D1 Secure storage adapter — COMPLETE
S0-D2 Legacy migration + production wiring — COMPLETE
S0-CL Secure credential storage closure — COMPLETE
S0 Secure Credential Storage — COMPLETE
P6-P0 Supplemental-answer matching canonical contract — COMPLETE
P6-D0 Supplemental-answer transient domain — COMPLETE
P6-X0 Supplemental-answer SourceDocument projector — COMPLETE
P6-Q0 Supplemental-answer typed target snapshot — COMPLETE
P6-M0 Supplemental-answer deterministic matcher — COMPLETE
P6-R0 Supplemental-answer review lifecycle — COMPLETE
P6-C0 Supplemental-answer confirm/CAS/typed commit — COMPLETE
P6-U0 Supplemental-answer bounded Preview/Review activation — COMPLETE
P6-V0 Supplemental-answer offline acceptance/closure — COMPLETE
P6 Supplemental-answer matching — COMPLETE
P6-SV-C1 Source inspection authority — COMPLETE
P6-SV-A Explicit source verification authority — COMPLETE
P6-SV-C2 Read-only original source viewer — COMPLETE
P6-SV-B Source verification Review flow — COMPLETE
P7-P0 AI answer candidates canonical contract — COMPLETE
P7-D0a Producer-neutral Candidate/origin — COMPLETE
P7-D0b Generic review-decision core — COMPLETE
P7-D1 Bounded AI answer provider port + strict HTTP adapter — COMPLETE
P7-I0 AI generation Application use case — COMPLETE
P7-C0 Confirmation + transactional answer-only persistence — COMPLETE
P7-U0 Minimal typed-question Presentation integration — COMPLETE
P7-V0 Focused validation / privacy / concurrency / acceptance — COMPLETE
P7-CL Canonical closure — COMPLETE
P7 v0 — CLOSED / FROZEN
UI-R0 Final IA Sync / Freeze — COMPLETE
UI-R1 Today modes + bounded navigation migration — COMPLETE
UI-CL Focused UI closure — COMPLETE
UI Finalization v0 — CLOSED / FROZEN (historical three-mode Today)
Today refresh — unified dashboard + independent ordinary pools + singleton-plan detail implemented
Today deferred — new statistics, multiple plans and full plan management
RAG1-P0 through RAG1-CL — COMPLETE
RAG-1 Lexical Retrieval — COMPLETE
RAG-2 Semantic Embedding — DEFERRED
RAG-3 Hybrid Retrieval / Rerank — DEFERRED
SPL-1-P0 StudyPlan Agent Tool v0 contract freeze — COMPLETE
SPL-1-D0 Domain + transient draft + planning/candidate read seams — COMPLETE
SPL-1-D1 v22 persistence + durable CAS commands — COMPLETE
SPL-1-I0 Agent planning tool + draft/adoption Presentation — COMPLETE
SPL-1-U0 Today / 特训 + dynamic selection + Practice seam — COMPLETE
SPL-1-V0 Focused acceptance — COMPLETE
AGENT-FB Bounded Fallback v0 — COMPLETE / CLOSED
OCR-UX Explicit OCR Activation v0 — COMPLETE / CLOSED
CONV-MOVE Conversation Relocation v0 — COMPLETE / CLOSED
U1-LIFECYCLE-UX Closure v0 — COMPLETE / CLOSED
OBS-1 Unified Operation Trace v0 — COMPLETE / CLOSED
B0-P0 .shiroha Backup / Restore canonical contract — COMPLETE
B0-D0 Package / Manifest Core — COMPLETE
B0-E0 Export — COMPLETE
B0-I0 Whole Restore + Rollback — COMPLETE
B0-U0 Minimal UI — COMPLETE
B0-V0 Round-trip / corruption acceptance — COMPLETE
B0-CL Closure — COMPLETE
Current runtime schema — v28
B0 .shiroha Backup / Restore — CLOSED / FROZEN
```

B0-P0 through B0-CL are COMPLETE and B0 v0 is CLOSED / FROZEN. The canonical
contract and closure status are in
`docs/architecture/b0-shiroha-backup-restore.md`. The C0-era note that
persisted User Messages predated a `.shiroha` package remains historical
rationale, not a current deferral.

The current UI Finalization route is `UI-R0 -> UI-R1 -> UI-CL`. The old
UI-R2 / UI-R3 large redesign plans are superseded and are not current
implementation stages. The final Presentation / Navigation IA authority is
`docs/product/ui-finalization-ia-freeze.md`.

This amendment updates current scheduling status without rewriting the
historical sequence as if it had originally been delivered in this order.
`docs/product/u1-agent-first-ia-freeze.md` is the current authority for U1
Presentation and Navigation semantics; retained U0 domain/lifecycle semantics
remain valid as described there.
`docs/product/A0 Built-in Agent v0.md` is the current authority for the bounded
A0 runtime/product contract.
`docs/product/W0 Safe Agent Write.md` is the focused authority for the current
W0 proposal, approval, scope, replay and typed-write contract.

## Agent refactor frozen target route

### Windows MCP first scheduling amendment (2026-10-19)

**Prioritize Windows desktop MCP functional development; defer Windows
high-assurance real security experiments as a whole.** This supersedes scheduling
in the retained route/history below, without relaxing production prerequisites.
MCP v0 retains its exactly six READ_ONLY tools and completed local actual-use
validation. MCP vNext prioritizes the seven-tool protocol, READ/STAGE, Proposal
queries, controlled App composition, user Review and Windows Codex integration.
Reuse existing Application, Proposal, Review, Gateway, IPC and permission owners;
do not rebuild the business layer or create another writer.

Before asking the user whether to resume security experiments, Windows MCP
functional development must satisfy all of the following:

- Implement the complete vNext target tools and protocol behavior, including the
  target Proposal lifecycle/status query, not only historical STAGED publication.
- Complete isolated end-to-end validation with a real MCP client.
- Validate STAGE, durable Proposal persistence, explicit user Review/approval,
  idempotency and original-key recovery across disconnect/restart.
- Complete necessary Windows Codex client integration, launch, connection,
  disconnection and error-handling functional validation.
- Attribute every remaining blocker specifically to production authentication,
  transport admission or formal security acceptance, with no unfinished MCP
  business functionality described as a security-only blocker.

These are **functional completion** conditions, not production enablement or
formal security acceptance. PR #309's bounded source/synthetic stdio evidence
below is retained and does not alone satisfy this checklist. Functional runtime
validation needs its own authorized isolated scope; this amendment starts none.
If a frozen admission contract blocks a required real-client check, record that
exact blocker and leave the condition open rather than inventing an exemption.

Defer follow-up Trial 1A real experiments and all G0-L1, G0-L2 and G0-I batches.
Do not schedule new Windows high-assurance experiment infrastructure, repeated
preflights or separate experiment-preparation tasks during this priority.
Retain existing Native Helper, DLL, Pin, Custodian, authentication and transport
candidates, security specifications and historical acceptance records; no deletion
or rollback. After the functional conditions above are met, the user separately
decides whether to resume experiments and their exact scope; nothing restarts
automatically and no earlier batch grant is inherited.

**HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
MCP vNext production entry remains disabled.** Authentication, authorized Context,
bank Scope, STAGE Review and App-only writes remain mandatory. Production access
still requires admitted authenticated App/Bridge transport, trusted pairing,
finite enablement and target approval, followed by production exposure acceptance
under [MCP contract §7](../product/agent-refactor/mcp-vnext-contract.md#7-bounded-stage-stdio-source-composition).
Deferral or functional/synthetic success changes none of these gates or the
existing formal security acceptance criteria.

### Retained implementation history and production dependencies

The bounded MCP-vNext STAGE source slice under
[MCP contract §7](../product/agent-refactor/mcp-vnext-contract.md#7-bounded-stage-stdio-source-composition)
provides independent stdio projection and explicit App-side composition for
synthetic end-to-end Proposal/Review acceptance. It preserves the original
production Host/Transport/AR-R6A gates and does not complete or activate full
AR-R6B; the standalone production entry defaults to unavailable.

The [Agent refactor contract index](../product/agent-refactor/README.md) owns the
focused frozen target contracts. This roadmap owns their stage order; existing
runtime contracts stay active until each scoped implementation is accepted.
The documentation-only checkpoint activates no Runtime, Module, external
authorization, generated Proposal, schema or MCP vNext implementation.

AR-R0's contract checkpoint is delivered. AR-R1's bounded Provider round
normalization, detailed failure bridge, DeepSeek classification and exactly-one
OBS terminal evidence are delivered and accepted: **COMPLETE / CLOSED**.

AR-R2's typed Application capability kernel and AR-R3's bounded Runtime owners/
transient transcript are delivered and accepted: **COMPLETE / CLOSED**.
The earlier AR-R2 final-review-record mismatch documented at AR-R3 activation
is historical; current AGENTS.md treats preceding merged PRs #241/#242 as
accepted without manufacturing a retrospective approval marker.

AR-R4 implements explicit source modules, deterministic layered graph ordering,
finite typed registrars, frozen atomic publication and retained feature storage
compatibility. It is **COMPLETE / CLOSED**, accepted and merged in
[PR #243](https://github.com/duanzhijian200443/shiroha_quiz/pull/243) after
final-head standing CI and independent repair-review closure. Default Agent/prompt/MCP/UI behavior is
retained. AR-R5A durable Proposal/review/atomic writer is **COMPLETE / CLOSED**,
accepted in merged [PR #244](https://github.com/duanzhijian200443/shiroha_quiz/pull/244),
at additive schema v32 with B0 package v2. AR-R5B generated Review UI is
**COMPLETE / CLOSED**, accepted in merged PR #245: one existing app_settings data-owner UUID,
restore-invalidated first-party sessions, module-controlled Inbox/completed
history, structural typed preview/edit, Review Flush/CAS, explicit subset
approval/all-rejected rejection and matching Receipt recovery. The generated-
question contract owns this bounded behavior. Final-target
standing CI and independent semantic review remain gates for new candidates.
AR-R6A has accepted pure-memory TCP core (PR #246) and the frozen TCP security
decision/HOST_STABILITY_HALT (PR #247). P1 non-secret Profile/Grant storage is
accepted in merged PR #248 at v33 under `external-agent-boundary.md` §6, with portable
B0 scrub and raw rollback compatibility. This does not authenticate clients or
enable external business access. P2 strict external historical Origin/v34
compatibility is accepted through merged PR #249 under `generated-question-proposals.md`
§10. P3 adds accepted unpublished Application/Data durable STAGE and narrow reconciliation
under §11 (merged PR #250), using existing v34 Proposal/key authority
and a shared SQLite STAGE/revoke transaction boundary. It adds no real credentials,
pairing UI or transport/Host wiring. P4's accepted unpublished implementation (merged PR #251) adds
shared P3 runtime admission, bounded opaque READ Contexts and exact-scope Target
metadata under external-agent-boundary §3, requiring READ + questionContent and
only the four approved metadata fields. File/Evidence snapshots are empty; no
content read or STAGE authority is inferred. Schema v34/B0 v2 remain unchanged.
P5's accepted unpublished Context-scoped Question search/detail (merged PR #253) is under
external-agent-boundary §3, with scope-first Data keyset selection, strict typed
authority, shared safe projection and current-authority final release. Opaque
QuestionRefs/cursors share P4's unchanged capacity and Context lifetime. Files,
general external Principal, MCP vNext and Host/Transport stay outside this scope.
P6 adds accepted unpublished Application/Data behavior (merged PR #255) for explicitly selected File
Snapshots, RAG-1 lexical retrieval and bounded continuous safe Chunk passages.
File egress independently requires current READ + fileContent + exact File
Scope matching the selected Context Project, plus current verified F1 identity.
Original P4/P5 empty file Contexts are never implicitly upgraded. P4's Registry,
TTL/budgets and RAG-1's Chunker/Index/derived-cache effect authority are reused.
P6's required CI, independent verification and semantic review are accepted with
its merged PR. P7 adds accepted unpublished behavior (merged PR #256) for trusted external
Capability execution and transient typed Receipts over P3-P6, with an exact-Session
execution Context and unchanged original READ reference semantics. P8 is accepted
within its unpublished offline scope through merged PR #258: trusted readiness/
Session entries, ten typed P7 routes and close/drain before runtime replacement.
P9 is accepted through merged PR #260 within its unpublished offline scope under external
boundary §7, with strict versioned bounded framing, opaque untrusted UTF-8 text,
no identity factories or dispatch, and no production wiring. P10's offline
IPC command projection is accepted through merged PR #261 under external boundary
§8: independent business schema v1, authenticated P8 binding before parsing,
ten typed P7 input mappings, operation-specific safe output and unchanged
owning effect/reconciliation/drain authority. Contexts are supplied by trusted
offline P8 composition, with no wire authority factory. P11's trusted local
Profile/Grant settings flow is accepted within its local scope through merged
PR #262 under external boundary §9; §10 records the available historical
CI/Verifier/zero-blocker review evidence and merged-stage acceptance.
It reuses P1 exact READ/STAGE, Scope, separate Egress, revision CAS and B0 gates
at schema v34/package v2. Management configures non-secret rules only; external
clients remain unpaired/disabled. No Credential, Session or Host is published.
P12 is accepted through merged PR #263 under external boundary §10: an unpublished
offline coordinator connects existing opaque Profile references to P0's unique
Principal/PairingState and P4 generation-bound admission, then P8/P7 current
Grant/Scope/Revision/Egress. Synthetic credentials are test-only. Disable/expiry,
revoke, shutdown/owning settlement, SQLite restart and B0 invalidate old runtime
authority while P3 Proposal/original-key reconciliation remains unchanged.
Final CI succeeded and Reviewer APPROVAL closed its offline scope. The final
fixed-target verification was performed by the same review session under explicit
user instruction, not a separate independent Verifier session; §10 links that
disclosed historical exception. It supplies no production pairing/Session/Host.
P13's static readiness package is accepted through merged PR #264 under external
boundary §11 and
[Windows security readiness](../product/agent-refactor/windows-host-security-readiness.md):
production gap/dependency matrix, standard Dart/Windows candidate screening,
isolated-environment authorization checklist and real security/fallback criteria.
P14 (accepted through merged PR #265; auxiliary CI-engineering sub-stage, not part of the frozen P13 experiment
package) makes the External offline regression matrix standing coverage in the
PR contract shards: complete External Application and IPC data-plane suites plus
the repeatedly re-verified widget/Origin/RAG/Agent-config regressions. That is
Linux-offline evidence only and clears no WINDOWS_PENDING item.
P15 is an offline Credential-boundary implementation candidate under external
boundary §12: separate protected association read/CAS/revoke contracts, typed
missing/corrupt/unavailable outcomes and private short-lived verified windows
into the original P0/P12. It retains unique opaque Profile binding, separate
local approval/proof and finite enablement, current P4/P7/P8 authorization and
original SubmissionKey recovery. Tests alone implement memory storage/verification;
no certificate suite, production secure format or Windows adapter is approved.
M1–M4 real acceptance remains WINDOWS_PENDING; G0/X0–X12 remain unapproved.
Existing standing P12/B0 test files carry the new offline cases; P14's 273-file
coverage/omission gate and four shards remain unchanged.
P16's static freeze is accepted in merged PR #267 under external boundary §13
and [Windows security readiness](../product/agent-refactor/windows-host-security-readiness.md) §9:
the certificate/identity model, the single DPAPI-backed External object store,
the cryptographic pairing possession proof and the owner-only Windows
Discovery root, plus the minimal implementation packages and their required
experiment authority. P16 is a static decision only; it implements nothing,
adds no dependency or schema and clears no WINDOWS_PENDING item.
No real Credential/Transport experiment or Host implementation is activated.
P17's bounded documentation amendment corrects X.509 signatures to ASN.1 DER
ECDSA-Sig-Value and retains raw r‖s (64 bytes) for Pairing Proof/Endpoint
Descriptor, with P-256/SHA-256 and credentialIdentity unchanged. Its G0 tiers
allow normal G0-L0 code/compile/offline development, applications for separate
G0-L1 test-only Windows primitive batches and G0-L2 bounded 127.0.0.1 TCP/mTLS
batches without business routes, and retain independent-kernel G0-I for complete
A0–A12 / X0–X12 acceptance. Readiness §§6 and 9.F own exact prerequisites,
evidence classes, local subsets and STOP rules. No real batch is approved here;
BLOCKED_ON_G0 concerns ungranted real experiments/acceptance, not L0 source work.
Local success cannot mark complete A PASS, activate Credential/Host or lift the
permanent primary-host AF_UNIX halt. Security and stability close separately.
Design completion is not
production security or system-stability acceptance and does not start AR-R6B.
No business authorization/writer,
schema, B0 format or Host authority is expanded. Full MCP vNext production
exposure and formal Host integration remain inactive;
real TCP/mTLS is unverified, Transport
is BLOCKED and AR-R6A is NOT_ACCEPTED. HOST_STABILITY_HALT remains active.
AR-R6B, AR-R7 and later implementation stages remain inactive.

**P17's handoff specified Package 1 production-code implementation as the next
work package, with no new general offline authentication design stage.**
The first bounded implementation slices cover the minimal Windows Native
Helper, controlled Win32 memory/handle release, Dart FFI Adapter, already-frozen
versioned object codecs, dedicated DPAPI Credential Store Adapter and
runtime.lock/client.lock single-writer protection, with offline tests and source
guards exercising the real implementation. Split by dependency and reviewable
responsibility; do not require all of Package 1 in one PR. Writing, compiling
and pure offline testing under scoped implementation authority do not depend
on L1 approval. Real DPAPI calls, ACL mutation and test key/certificate generation
stop at their L1 grant boundary; local communication stops at L2. There is no
second Profile, Principal, PairingState or CredentialStore business authority.
The P17 documentation task implemented none of those slices and started no P18.

P18 is the first Package 1 production source slice under
[Windows readiness section 10](../product/agent-refactor/windows-host-security-readiness.md#10-p18-native-helper-and-ffi-foundation):
independent Windows x64 C++17 Helper, versioned C ABI and controlled memory,
known-folder resolution, user-scope DPAPI wrappers and reusable explicit Dart
FFI. Local native compile/export checks and fake-only core/Dart tests are
G0-L0 evidence. Real calls remain LOCAL-L1 PENDING; protected root/store,
certificate issuance, Host and Bridge composition are absent. This slice
changes no P0–P15 authorization, S0, schema, B0 or P9/P10 semantics and clears
no Windows acceptance item. The next separately scoped slice prioritizes
protected file objects, NTFS/owner/DACL/volume/reparse validation and
runtime.lock/client.lock exclusion, then the versioned DPAPI Credential Store.
TRANSPORT remains BLOCKED, AR-R6A NOT_ACCEPTED and HOST_STABILITY_HALT ACTIVE;
no P19, Package 2/3 or AR-R6B is activated by this source delivery.

P19 extends the same inactive helper under
[Windows readiness section 11](../product/agent-refactor/windows-host-security-readiness.md#11-p19-protected-objects-and-single-writer-ownership):
protected-directory creation/validation, parent-bound child handles, Owner/
protected DACL/fixed NTFS/reparse/file identity checks and OS-exclusive App/
Bridge locks with explicit Dart lifetime. Its native Windows compile/import/
export and fake-only core checks join standing CI; no real Windows security
function or Host is activated. Credential Store persistence/CAS, crypto,
publication and runtime composition still require separate scoped work.
LOCAL-L1/G0-I acceptance remains pending and the three halt/acceptance states
above remain unchanged. This source scope does not start P20, Package 2/3 or
AR-R6B.

P20 adds the unactivated production App association backend under
[Windows readiness §12](../product/agent-refactor/windows-host-security-readiness.md#12-p20-protected-app-association-store).
It implements the existing P15 port with strict kind 3 binary encoding,
P18 user-scope DPAPI and P19-owned handle-relative file transactions/CAS.
The Native ABI becomes 3 while retaining P18/P19 call compatibility; standing
offline checks cover the codec, association semantics and injected file failures.
No kind 1/2/4 store, certificate, Discovery, TLS or Host activation is supplied.
P20 is merged; PR #277 records isolated real Windows first-create and
existing-target replacement plus exact DPAPI readback, with no temporary residue.
Production-root, full Dart Store and formal LOCAL-L1/G0-I acceptance remain pending.
HOST_STABILITY_HALT = ACTIVE, TRANSPORT = BLOCKED and AR-R6A = NOT_ACCEPTED.

P21, merged in PR #278, is the inactive Credential / Certificate primitive G0-L0 slice under
[Windows readiness §13](../product/agent-refactor/windows-host-security-readiness.md#13-p21-credential-and-certificate-primitive-candidate-g0-l0-only).
It adds bounded CNG P-256 generation/sign/verify source, explicit ECC-to-PKCS#8
conversion, raw r||s / DER and X.509 structure/vector codecs, strict length-prefixed
kind 1/2/4 objects, and an explicit optional Dart crypto adapter in the same helper.
ABI 3 retains all twelve existing exports and adds three optional crypto symbols.
Compilation, static/source checks and offline/fake vectors prove only G0-L0.
No real key/certificate experiment, store publication, TLS, Discovery, Host,
AR-R6B or production Principal/Session composition is activated. The above
halt/acceptance states remain unchanged; full acceptance requires separate grants.

P22, merged in PR #280, supplies only the inactive Discovery/Pairing Bootstrap Codec G0-L0 candidate
under [Windows readiness §14](../product/agent-refactor/windows-host-security-readiness.md#14-p22-discoverypairing-bootstrap-codec-foundation-g0-l0-only):
strict possession transcript, exchange submission/challenge/proof payloads and
signed endpoint descriptor bytes, with explicit framing, public fixed vectors,
injected digest-signature checks and caller-owned trusted anchor/installation/
leaf-digest/high-water inputs. It neither creates P15 evidence nor reads/writes
actual Discovery/exchange objects. Real signing/issuance, protected publication,
approval/nonce/evidence lifecycle, Pairing, Host/Bridge, Transport and Windows
acceptance remain separately unimplemented/pending. No ABI, P0/P12/P15 state,
P9/P10, schema/B0, S0 or activation gate changes. HOST_STABILITY_HALT = ACTIVE;
TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.

P23, merged in PR #281, adds the inactive Protected Credential Object Store G0-L0 candidate under
[Windows readiness §15](../product/agent-refactor/windows-host-security-readiness.md#15-p23-protected-credential-object-store-candidate-g0-l0-only):
SOURCE IMPLEMENTED / OFFLINE TESTED fixed kinds 1/2/4, shared owner transaction
exclusion with P20, strict P21 object decoding, P18 DPAPI and Win32
handle-relative publication. ABI 3 adds three optional exports; the original
fifteen and kind 3 association semantics remain compatible. REAL WINDOWS PENDING
and FORMAL ACCEPTANCE PENDING include these new objects; P20's isolated-root
functional result is not extended. Initialization, issuance/rotation, Pairing,
Discovery/exchange I/O, Transport and Host activation remain outside this slice.
HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.

P24, merged in PR #282, adds the inactive Protected Exchange File-I/O G0-L0 candidate under
[Windows readiness §16](../product/agent-refactor/windows-host-security-readiness.md#16-protected-exchange-file-io-source-candidate-p24-g0-l0-only):
SOURCE IMPLEMENTED / OFFLINE TESTED fixed-kind/ID Native Exchange create/read
and creator-only cleanup beneath the App-created exchange directory, with
strict P22 codec boundaries, bounded 1024/4096/256 caps and a
directory-identity-bound short cross-process quota exclusion. ABI 3 adds three
optional exports; the original eighteen retain their signatures and behavior.
REAL WINDOWS PENDING and FORMAL ACCEPTANCE PENDING include named-mutex
cross-process/cross-session behavior, NTFS/DACL/parent/reparse enforcement and
handle-based deletion; P20's isolated-root functional result is not extended.
Consumption authority (P27), Pairing, Discovery publication, Transport and Host
activation remain outside this slice. HOST_STABILITY_HALT = ACTIVE;
TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.

P25, merged in PR #283, is an inactive Package 1 implementation candidate, not a new frozen stage,
under [Windows readiness §17](../product/agent-refactor/windows-host-security-readiness.md#17-credential-initialization-and-issuance-foundation-p25-g0-l0-only).
It adds explicit App Issuer/Server initialization, persisted cryptographic
validation, explicit partial-Server recovery and restricted Client leaf issuance.
Same-ticket create-if-missing extends P23 without changing write, object layouts,
P20 semantics or the twenty-one ABI-3 exports. Cross-kind commits remain separate;
unknown commits never report success or trigger rekey. Client issuance supplies
no possession/Pairing/Association evidence. Standing offline coverage uses public
P21 vectors and an independent test-only P-256 verifier. Real Windows security,
certificate/TLS acceptance, Discovery publication, enrollment and production
wiring remain pending. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED.

P26 is an inactive Package 1 implementation candidate under
[Windows readiness §18](../product/agent-refactor/windows-host-security-readiness.md#18-protected-discovery-publisher--reader-foundation-p26-g0-l0-only),
not a new frozen stage. On merged P25 (PR #283), it adds fixed protected
Discovery Publisher/Reader Native/FFI and Data adapters, P25-backed signing
state validation, same-ticket kind 1 epoch increment and conditional existing
kind 4 high-water advancement. P22 trust inputs remain independently supplied;
no initial Pin, authorization or production runtime is created. SOURCE
IMPLEMENTED / OFFLINE TESTED applies only to the inactive foundation. Discovery
Windows security/durability, Listener/TLS peer binding, enrollment and G0-I
acceptance remain pending. HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED;
AR-R6A = NOT_ACCEPTED.

The retained target is Codex/Claude MCP Bridge → Shiroha External Host →
authenticated and authorized question-bank READ/STAGE services.

P27-E0 adds an inactive identity/content-bound Exchange consumption foundation
under [Windows readiness §16](../product/agent-refactor/windows-host-security-readiness.md#p27-e0-identity-bound-consumption-foundation-inactive-g0-l0-only).
Optional ABI-3 controlled reads retain bounded Owner-bound pins and exact original
bytes; P22 strict decoding precedes delivery, Consume rechecks the same object
and bytes on a protected read/delete handle, and Release never deletes. P24 plain
Read and creator Cleanup stay intact. The source/offline foundation supplies no
P27-I0 sequencing, P15 evidence, Pairing, Association, kind 4 initialization or
runtime activation. Real Windows sharing/deletion/durability and independent
formal acceptance remain pending. HOST_STABILITY_HALT = ACTIVE;
TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.

P27-I0 completes the inactive Package 1 source/offline integration candidate under
[Windows readiness §19](../product/agent-refactor/windows-host-security-readiness.md#19-p27-pairing-and-package-1-offline-integration-g0-l0-only).
The App/Bridge local action ports coordinate P25 issuance, exact P24/E0 bytes,
D0's two independent comparisons, actual P21-backed possession verification,
existing P15 Approval/CAS/private evidence and P0 `pairedDisabled`, then one
Missing-only kind 4 save. P15 default 30-second behavior remains, with a trusted
bounded Request deadline and a separate 30-second Evidence Window. No alternate
PairingState, Store, authorization, ABI or wire format is introduced. This is
PACKAGE 1 SOURCE IMPLEMENTED / OFFLINE TESTED only: REAL WINDOWS PENDING and
FORMAL ACCEPTANCE PENDING, with no App/Bridge process experience or production
activation claim. AR-R6B and Release remain inactive.

Package 2 adds an inactive source/offline TCP/mTLS candidate under
[Windows readiness section 20](../product/agent-refactor/windows-host-security-readiness.md#20-package-2-tls-and-bounded-host-adapter-g0-l0-only).
Explicit Raw IPv4 accept precedes bounded TLS upgrade; isolated TLS 1.3 contexts,
optional certificate-only crypt32 ABI-3 policy, current protected Association
lookup and separate P15 channel verification precede P0 Session/P9/P10/P8/P7.
Shared candidate reservations and existing owning settlement constrain admission
and output; no business permission, wire/schema or production startup changes.
This remains a source/offline candidate, with no real Windows handshake,
measured native-memory capacity or production Host availability claim.
Package 3 source lifecycle coordination is described below; production Host
and AR-R6B remain inactive. HOST_STABILITY_HALT = ACTIVE;
TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED; REAL WINDOWS PENDING and
FORMAL ACCEPTANCE PENDING. G0-L1, G0-L2 and G0-I each retain their separate
prerequisites and exact user grants.

Package 3 adds the inactive Windows lifecycle/recovery/release source candidate
under [Windows readiness §21](../product/agent-refactor/windows-host-security-readiness.md#21-package-3-lifecycle-and-release-source-candidate-g0-l0-only).
The existing TLS Host owns exact-composition/readiness, shutdown and lock-last
custody through original P8/P27/P15/P12/Association settlement; failed cleanup
retains quarantine. P15 remains revoke authority and P3 remains the sole STAGE
commit/reconciliation owner. Static Native/FFI/export/import and package/PE/
disabled-Bridge checks add no runtime activation. PACKAGE 3 SOURCE IMPLEMENTED /
OFFLINE TESTED is the bounded candidate boundary, with standing CI and independent
review still required. Package 1–3 source integration does not close real TLS,
Windows resources/crash/cross-process/AOT or any full A0–A12 acceptance.
Discovery cleanup safely retains residues; no new deletion ABI or recovery
writer exists. G0-L1/L2/I require their separate grants. HOST_STABILITY_HALT =
ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED; REAL WINDOWS = PENDING;
FORMAL ACCEPTANCE = PENDING. AR-R6B and production activation remain inactive.

The E5 diagnostic composition under
[readiness E5](../product/agent-refactor/windows-host-security-readiness.md#e5-controlled-diagnostic-admission-composition-g0-l0)
and R6A-B1 unified G0-L1 offline infrastructure under
[readiness R6A-B1](../product/agent-refactor/windows-host-security-readiness.md#r6a-b1-unified-g0-l1-diagnostic-infrastructure-g0-l0)
connect E4 admission/IPC with the same Supervisor, an unlinked zero-crypto
`L1-ADMISSION` Worker candidate, `L1-CRYPTO` owners, `L1-OBJECTS` / `L1-STORE`
isolated diagnostics, `L1-RELEASE` sole-owner settlement and strict per-Trial
operation allowlists (`R6A-B1 L1 UNIFIED SOURCE READY / OFFLINE TESTED`),
remaining unlinked/offline source with all three default runtime gates denied.
Source/Fake readiness does not advance real AR-R6A acceptance. All five G0-L1
trials (`L1-ADMISSION`, `L1-CRYPTO`, `L1-OBJECTS`, `L1-STORE`, `L1-RELEASE`)
remain `DRAFT_NOT_AUTHORIZED` and require separate fixed-target trials,
independent evidence and user grants; no general stage is added.
The [B2 fixed-target preparation boundary](../product/agent-refactor/windows-host-security-readiness.md#r6a-b2-fixed-target-preparation-boundary-g0-l0)
extends those same templates with artifact, resource, recovery and evidence
requirements. Real Admission remains blocked by the absent fixed executable
composition and external crash-custody/evidence handoff, as well as unselected
device/budgets and independent target approval. No default denial is lifted;
preparation does not advance real acceptance or grant the next trial.
The [B2-R1 source amendment](../product/agent-refactor/windows-host-security-readiness.md#b2-r1-admission-wiring-amendment-g0-l0)
adds closed diagnostic entry candidates plus measurement, sole-creator custody
and evidence interfaces with Fake end-to-end coverage. Actual independent OS
custody/retention remains blocked; no third process/service or live authority
is introduced, and real acceptance is unchanged.
The [B2-R2 adapter completion](../product/agent-refactor/windows-host-security-readiness.md#b2-r2-batch-custodian-and-windows-admission-adapters-g0-l0)
adds the per-batch Custodian candidate, compile-only Windows identity/pin and
persistent evidence adapters, nine-field three-process resource limits and
hard OS call bounds with Fake crash-window verification (**B2 WINDOWS ADMISSION
SOURCE REVIEWABLE / OFFLINE TESTED**). All runtime gates remain closed and all
five L1 trials remain `DRAFT_NOT_AUTHORIZED` pending user target selection and
per-batch authorization.

The [Trial 1A controlled-entry candidate](../product/agent-refactor/windows-host-acceptance-preparation.md#trial-1a-final-readiness-and-one-consolidated-authorization-application)
now supplies the typed real Windows invocation, existing bounded human UI,
post-launch identity binding, R2 exclusive spent-permit anti-replay and complete
observation/operation/settlement budgets over the same S1/Entry/Pin source.
Its source/offline ceiling is **TRIAL1A REAL ENTRY SOURCE IMPLEMENTED / OFFLINE
VERIFIED** after passing checks; the fully linked diagnostic entry DLL is never
loaded/invoked by L0. It adds an atomic process bootstrap, distinct mapped-image
file pin check and retained final-result custody; original legacy/public denials and
all real/formal acceptance gates remain unchanged. The current
development computer is selected only as the proposed 1A device; exact private
target selections, independent evidence and a one-time user grant remain pending.
No new general infrastructure stage or Trial 1B/other L1 scope is added.

Use namespaced AR-R identifiers to distinguish this route from historical
R1-R8 typed-core stages:

```text
AR-R0 contract -> AR-R1 Provider -> AR-R2 capability -> AR-R3 Runtime/transcript
-> AR-R4 modules -> AR-R5A durable Proposal
                   -> AR-R5B minimal Review UI ----+
                   -> AR-R6A external Host/IPC ----+-> AR-R6B Tools-only MCP MVP
-> AR-R7 bounded READ fallback -> AR-R8 Assistant decomposition
-> AR-R9A optional Resources/Prompts; AR-R9B independent Codex reference package
```

AR-R7 technically requires AR-R3 but is scheduled after external MVP. AR-R9B
requires AR-R6B, not AR-R9A. Execution is serial by default. The baseline estimate
is 13 PRs, not a hard cap; independently reviewable boundaries may require more.
Provider normalization must preserve current fallback policy. New durable
Proposal and external authorization storage have separate additive schema/B0
checkpoints. Minimal generated Review precedes MCP MVP; Assistant-wide cleanup
does not. Context TTL, validation of the selected Windows P0 IPC candidate under
the [external boundary](../product/agent-refactor/external-agent-boundary.md), and
reference-package platform/version choices close their bounded
implementation-spike checkpoints before publication.

## Current follow-up backlog

This table is the repository-level status authority for cross-stage work that is
not yet CLOSED. Design notes outside the repository may provide UI/detail
context, but they do not change implementation status by themselves.

| ID | Status | Current evidence / next scope |
|---|---|---|
| **IMPORT-UX-1** | COMPLETE | Document import selects the real QuestionBank before parsing, silently remembers the target, freezes `bankName`/`folderName` per task and PDF batch, and confirms frozen targets in Review without renaming. Optional default-off perfect-score auto commit accepts only clean typedV2 RD0 snapshots through the existing typed lease/CAS writer, with manual Review fallback. `bankName` remains globally unique; no bankId, duplicate-name support, legacy backfill, AI classification, or schema change. |
| **ARCH-EXAM-GENERATION-LIFETIME** | BACKLOG / HARDENING | Random mock-exam selection still happens before the final `ExamMutationCommand.createExamPaper` mutation lease. The durable create is gated; full selection-to-create lifetime ownership remains a low-risk hardening item. |
| **UI-RWD-1** | PARTIAL | Shared `contentMaxWidth` constraints and Assistant/File Library breakpoints already exist. App-wide narrow/wide/desktop acceptance and consistent responsive policy are not yet closed. |
| **P6-ACT-1** | COMPLETE | P6-ACT-1 introduced bank-scoped ordinary-user activation from the BankDetail surface through explicit LibraryFile selection into the existing P6 matching/review/typed-answer authority. ANSWER-COMP supersedes the whole-bank menu with selected-set full `ExplicitQuestionScope` activation; the ProjectScope entry surface remains unactivated. |
| **P6-ACT-2** | COMPLETE | P6-ACT-2 added bank-scoped explicit direct external-file acquisition through existing File Library ingestion, deterministic F1 parsing, explicit scanned-PDF OCR confirmation when required, and the existing P6 matching/review/typed-answer authority. ANSWER-COMP now reuses this source flow for selected-set full `ExplicitQuestionScope` activation; ProjectScope entry, image OCR activation and automatic OCR remain out of scope. |
| **P6-SV** | COMPLETE | Explicit original-source verification is delivered end to end. SV-C1 added the read-only inspection authority that verifies managed bytes against LibraryFile size/SHA-256 and binds one stable current ParsedArtifact generation (PR #197). SV-A made every P6 `fill` and `replace` start `required` and demand an explicit `verifySource(candidateId, inspection)` before an opaque, session-issued, once-claimable confirmation may reach the existing typed answer authority (PR #198). SV-C2 added the read-only in-app original source viewer (PR #199) and SV-B wired inspection -> explicit verification -> confirmation into the Review surface through the composition root (PR #200). Viewing never verifies; a missing inspection service keeps Review readable while every write stays closed; each review transition revokes older snapshots. No schema change and no second answer writer. This row records merged implementation evidence only: an independent closure review over PRs #197-#200 is still outstanding, so the group is not recorded as CLOSED / FROZEN. |
| **P6-SV-D** | DEFERRED | In-app source verification renders `application/pdf`, `text/plain`, `text/markdown` and `image/*` only. DOCX and unknown MIME types never fall back to extracted text, so their candidates stay `required` and cannot be committed through P6. Extending coverage, or recording a product decision to keep those sources review-only, needs its own scope and authorization. |
| **ZIP-BUNDLE-1** | LEGACY ROUTE IMPLEMENTED / MODERNIZATION DEFERRED | Text Direct Read already accepts `.zip` through `ZipDocumentAdapter` (Markdown/TXT/images and relative image resolution). F1 `ParsedArtifact` generation still rejects ZIP as `unsupportedRoute`; follow-up work is lifecycle/asset/admission modernization, not a greenfield ZIP implementation. |
| **BANK-PKG-1** | PLANNED | Data-management UI contains a disabled “导入结构化题库包 / 暂未开放” placeholder. A versioned `.shiroha-bank` package/import contract and implementation do not yet exist. |
| **ANSWER-COMP-P0** | COMPLETE / FROZEN | Docs-only design authority is frozen in `docs/architecture/answer-completion-question-sets.md`. It defines durable ImportedQuestionSet identity, strict document_v4 seed metadata, QuestionRepository-owned atomic membership commit, consistent Answer Completion queries, full-set P6 ExplicitQuestionScope activation, single-question P7 reuse, and the “补充答案 → 待补答案” secondary UI. Production implementation continued through the ANSWER-ENTRY-GUARD, D0, and D1 stages below. |
| **ANSWER-ENTRY-GUARD** | COMPLETE | Typed questions can no longer enter the legacy `answerSingleQuestion` AI path: the old-editor entry is gated by an Application typed-aware route decision on the real persisted `storageId`, with the defensive editor check retained; the valid legacy AI answer/explanation path remains usable. Merged as PR #182. |
| **ANSWER-COMP-D0** | COMPLETE | Domain/Application contracts plus the strict document seed codec are frozen: `ImportedQuestionSet` / `ImportedQuestionSetItem` value contracts, the reserved `_questionSetCaptureV1` exact-key envelope with a non-normalizing decoder, and safe fixed failures. No schema, runtime seed persistence, dispatch, or UI. Merged as PR #184. |
| **ANSWER-COMP-D1** | COMPLETE | Additive v28 schema implements the frozen durable relation: `imported_question_sets` / `imported_question_set_items`, composite primary key, both unique shapes, position CHECK, cascade foreign keys, bank lookup index, and the required cross-bank, bank-move detach, empty-set cleanup, and bank-immutability triggers, with a strict schema validator and an additive v27 → v28 migration that never backfills. Current runtime schema is v28; D1 itself adds no QuestionSet writer, query, dispatch, or UI. Later stages are recorded below. |
| **ANSWER-COMP-B0** | COMPLETE | Whole backup/restore preserves set identity, ordered membership and soft provenance, validates the v28 schema/relationship constraints, and rejects invalid relations. Standing contract coverage includes `test/backup/answer_completion_backup_test.dart`. |
| **ANSWER-COMP-I0a / I0b / I0c** | COMPLETE | New document intake captures strict `document_v4` metadata through diagnostics, Review and retry; historical v3 remains ungrouped. QuestionRepository owns typed/legacy atomic Question + set/member + task completion writes. Top-level documents dispatch independently; multi-file intake requires an existing bank, single-file proposed banks remain compatible, ZIP stays one task, and image/clipboard entries create no seed. Q0/U0/P6/P7 activation is recorded in the rows below. |
| **ANSWER-COMP-Q0 / U0** | COMPLETE | Merged as PR #190. One Application read projection answers the Answer Completion queue and imported-set detail: per-set pending/unsupported/completed category with total/answered/missing counts, ungrouped questions kept separate, and eligibility distinguishing missing/answered/legacy/corrupt members. All of it is read in one short transaction, and Presentation consumes only that projection. No schema change. |
| **ANSWER-COMP-P6 / P7** | COMPLETE | Merged as PR #190. A selected complete set activates the existing P6 authority through a full-set `ExplicitQuestionScope` whose membership is revalidated when the supplemental session binds; a single typed question reuses the existing P7 generation/review/commit boundary through a transient review surface. No second answer write path, no persisted candidate state, no new provider call site. ANSWER-COMP-V0 and ANSWER-COMP-CL are COMPLETE. |
| **ANSWER-COMP-V0** | COMPLETE | Focused deterministic acceptance covers import rollback, seed lifecycle, B0 validation, committed-set lifecycle, coherent query races, full-set P6 and single-question P7/legacy entry boundaries. Authoritative tests and the requirement map live in `test/answer_completion_v0_acceptance.md`; core suites run as standing PR contracts. |
| **ANSWER-COMP-CL** | COMPLETE | Answer Completion v0 — CLOSED / FROZEN. Current runtime is v28; the focused contract and repository architecture agree on durable grouping, import ownership, query consistency and existing P6/P7 activation. No typed-admission R1, stable bank ID, batch AI or RAG-2 activation. |
| **TYPED-ADMISSION-R1** | PLANNED / HARDENING | `OcrTypedCandidateGate` remains batch-wide all-or-nothing. A future bounded refactor may reduce one question's structural-admission failure blast radius without weakening fail-closed semantics. |
| **HOME-TRAINING-V3** | PARTIAL | Frozen contract `SHIROHA-HOME-TRAINING-IPF-V3` lives at `docs/product/home-training-v3.md`. P0–P4b and B1–B4 are merged; accepted AR-R5A advances the global runtime to v32 without changing the v31 ImportTask event contract. PR #230 (B2), #232 (B3/I1) and #234 (B4/I2) are historical merged deliveries. B5 implements P10a/P10b/I3: facade-backed TaskCenter UI, shared production query/command/retry injection, safe Home badge and exact-target review/file-selection bridges. CP3 composition is implemented; acceptance requires final-head/current-target CI and independent Reviewer evidence. PlanConfigScreen compatibility retirement, B6 and CP4 remain pending. No persistent task-package completion markers are required. Normal delegated handoffs stay in active context; explicit Automation may keep non-authoritative PR-body resume state. Exact execution history is Git/PR/CI/Reviewer. StudyPlan remains the single global ActiveStudyPlan, independent of TrainingContent. |
| **RAG-2 / RAG-3** | DEFERRED | RAG-1 local lexical retrieval is COMPLETE. Semantic embeddings and hybrid/rerank retrieval remain separately deferred. |

Status rules:

- **COMPLETE / CLOSED / FROZEN** means the scoped contract and required
  acceptance are closed; later work must be a new scope.
- **PARTIAL** means production pieces exist but the roadmap acceptance is not
  complete.
- **PLANNED / BACKLOG / DEFERRED** means no automatic activation. A separate
  task/authorization is required.
- Legacy functionality may remain supported even when its modern lifecycle
  integration is deferred; such work must be described as modernization rather
  than “not implemented”.
- When a merged PR materially changes one of these statuses, update this file
  in the same PR or an immediate documentation-only follow-up.

## 1. Product/architecture direction

Shiroha now grows around three stable layers:

```text
Typed Learning Core
  QuestionDraftV2 / RichContent / ReviewSession / PersistedQuestion
        |
        v
Learning Asset Layer
  LibraryFile / ParsedArtifact / Project
        |
        v
Intelligence & Access Layer
  Application Tools / Built-in Agent / MCP / Approval Write
```

The goal is expansion around the typed core, not another repository-wide refactor.

## 2. Canonical stage sequence

| Stage | Goal | Primary deliverable | Schema expectation |
|---|---|---|---|
| **N0** | Architecture contract synchronization | `ARCHITECTURE.md`, ADRs, this roadmap, stale-baseline markers | unchanged (v15) |
| **U0** | Information-architecture design freeze | Navigation/entry-point contract only; no fake Project data model | unchanged |
| **F0** | File Library foundation | `LibraryFile`, managed storage, ingestion lifecycle, metadata | additive migration candidate |
| **J0-P0** | Bank identity decision | Decide `bank_name` compatibility vs additive stable `bankId` registry | decision only unless separately approved |
| **J0** | Project v0 | Optional Project plus file/bank references; no file duplication | additive migration candidate |
| **U1** | Information-architecture migration | Replace the primary Subject-library navigation role with Project-aware UI while retaining compatibility surfaces | normally unchanged beyond F0/J0 |
| **B0** | Whole backup/restore foundation | Versioned ZIP-compatible `.shiroha` package: sanitized DB snapshot + managed LibraryFile bytes; B0 v0 CLOSED / FROZEN | unchanged (B0 itself adds no schema migration; current runtime is now v28 due to later additive migrations) |
| **C0** | Conversation foundation | Persistent Conversation/User Message history and Conversation-level File context | additive v19 |
| **T0** | Application Tool Layer | Reusable query/service facade shared by UI, Agent and MCP | unchanged |
| **M0** | MCP v0 | Implement the existing exactly-six-tool `READ_ONLY` contract | unchanged |
| **A0** | Built-in Agent v0 | Supported configured provider + optional provider-native Web + local read tools | unchanged |
| **W0** | Safe Agent write | Draft/Stage -> Review -> explicit user approval -> application command -> typed persistence | preferably unchanged |
| **S0** | Secure credential storage | Move provider credentials out of SQLite into a bounded secure credential seam; keep runtime schema v20 | unchanged (v20) |
| **F1** | Parsed Artifact lifecycle | Reparse/version/cache identity needed by P6/Agent/RAG; split into F1-P0..F1-CL sub-stages | additive v20 implemented in F1-D1 |
| **P6** | Supplemental-answer matching | Produce supplemental `AnswerCandidate` values from files; do not invent a new write path | preferably unchanged |
| **P7** | AI answer candidates | Produce AI `AnswerCandidate` values; confirmation uses the same answer command boundary | unchanged |
| **RAG-1** | Local lexical retrieval | verified F1 chunks, v21 FTS5 cache, Application seam, transient Agent egress grant | additive v21 |
| **RAG-2/3** | Semantic and hybrid retrieval | embeddings, hybrid retrieval, rerank | deferred |
| **Future** | Platform/ecosystem expansion | Windows workbench, HarmonyOS, LAN/sync, MCP v1+ | later |

F1 is intentionally not a hard prerequisite for J0. F0 can establish original-file identity/storage first; deeper artifact persistence is introduced when a concrete use case (reparse, P6, Agent file analysis or RAG) requires it.

## 3. N0 completion contract

N0 is documentation/contract work only. It must not change production Dart code, schema, packages or runtime behavior.

N0 is complete when:

- repository-wide layering in `ARCHITECTURE.md` matches the post-R8 code direction;
- `AGENTS.md` no longer tells new work to preserve the obsolete `UI -> Service -> Repository` rule;
- accepted asset and Agent/MCP boundaries are captured in ADRs;
- R0-era baseline documents are clearly marked historical when they contain obsolete current-state facts;
- Bank identity is explicitly recorded as a J0 prerequisite decision, not silently solved during N0.

## 4. Stage invariants

### F0 — File Library

Must establish:

```text
external file
  -> FileIngestionService / equivalent application boundary
  -> app-managed storage
  -> LibraryFile metadata + fileId
```

Rules:

- original bytes are long-lived user assets;
- SQLite does not store the original file as a blob;
- durable identity uses `fileId` + managed storage key/relative identity, not absolute paths;
- importing a file into a question bank is one possible action, not the file's lifecycle owner;
- deleting/replacing a ParsedArtifact does not delete confirmed questions;
- no full artifact-history framework is required in F0.

F0.1 adds flat, manual File Library Folder classification through additive v18
metadata/relation tables. A file has at most one Folder; unclassified is the
absence of a relation; Folder and Project relations remain independent.

### J0 — Project

Project is an optional long-lived learning context, not a mandatory folder.

Recommended relation shape:

```text
Project
  <- project_files -> LibraryFile
  <- project_banks -> QuestionBank identity
```

Rules:

- one file may be referenced by multiple Projects without duplicating bytes;
- unassigned assets remain valid (`projectId = null` / Unclassified UX);
- existing subject/folder data is retained until a separately authorized migration;
- do not add `library_files.project_id` as the only ownership relation.

### J0-P0 — Bank identity decision

Before persisting Project-to-bank relations, explicitly choose one bounded strategy:

A. use current `bank_name` as a temporary compatibility relation and record migration debt; or

B. add a stable `bank_registry`/`bankId` identity while keeping current `bank_name` compatibility projection.

Choose B only if it can remain additive and does not reopen QuestionList/Practice/WrongBook typed architecture. Otherwise choose A and defer the identity migration.

### B0 — `.shiroha` Backup / Restore

B0 v0 is CLOSED / FROZEN. `docs/architecture/b0-shiroha-backup-restore.md`
is the canonical authority. B0 packages the sanitized SQLite snapshot plus
managed `LibraryFile` original bytes behind `packageVersion = 1` and
independent SQLite `schemaVersion`; B0-D0 through B0-CL are COMPLETE.

Frozen stage graph:

```text
B0-P0 Contract Freeze -> B0-D0 Package / Manifest Core -> B0-E0 Export
  -> B0-I0 Whole Restore + Rollback -> B0-U0 Minimal UI
  -> B0-V0 Round-trip / corruption acceptance -> B0-CL Closure
```

B0 adds no second migration authority. B0 itself adds no schema migration;
current runtime is now v28 due to later additive migrations.

### T0 — Application Tool Layer

Do not start by wrapping repositories in MCP handlers.

Implement reusable application semantics first, e.g. query/command services or a tool facade. Presentation adapters should receive safe DTOs, not repository maps.

### M0 — MCP v0

M0 implements `docs/architecture/mcp-v0-contract.md` as written. v0 stays exactly six read-only tools:

- `list_question_banks`;
- `get_study_overview`;
- `get_due_review_summary`;
- `search_questions`;
- `get_question_detail`;
- `get_weak_questions`.

Do not add File/Project tools to `mcp.study.v0`. They belong in a later contract/version.

### C0 — Conversation foundation

C0 adds a dedicated `ConversationService`, v19 Conversation/Message/File
relations, and real history navigation. New Conversation remains transient
until the first valid User Message; first persistence and all later append or
attachment recency mutations are transactional. Message ordering uses an
explicit per-conversation sequence.

Learning Space deletion preserves history through `SET NULL` without changing
the scope to Global. File context is independent of Project and Folder
membership and never owns file bytes. Bank attachment remains deferred because
the compatibility `bank_name` is not stable durable identity.

C0 does not add Provider, Agent, Web, RAG, MCP tools, or a fake Assistant reply.
It exposes only the additive Assistant-message seam needed by A0.

### A0 — Built-in Agent

A0 is complete. The Agent calls the same application query/tool layer as
UI/MCP, but does not route through MCP transport.

A0 closes the following bounded read-side behavior:

```text
conversation
+ provider-native Web (when enabled and supported)
+ Shiroha read tools
```

The current provider/model allowlist and runtime limits remain implementation
parameters rather than canonical roadmap commitments. The complete current A0
contract and accepted limitations are recorded in
`docs/product/A0 Built-in Agent v0.md`.

A0 does not include destructive writes or a generic Agent framework.

### W0 — Safe write

W0 is COMPLETE. Its first capability is frozen as a Built-in Agent proposal to
fill a missing answer on an existing typed question. The Agent may stage only
`null -> structurally non-empty` answer proposals; existing manual typed-answer
repair retains its replace and clear semantics through the shared typed
persistence authority.

Permission model:

```text
READ        autonomous inside granted scope
DRAFT/STAGE proposal only
COMMIT      explicit user approval
DESTRUCTIVE extra approval or unavailable
```

Agent/MCP never call SQLite directly. Formal question creation/answer mutation must converge on typed application commands and existing typed persistence semantics.

Proposal staging must complete scope/target admission before loading or
returning preview-visible target content. Learning Space staging uses the
current Project and current name-based `project_banks` relation as compatibility
authority. Unauthorized and nonexistent targets share a safe non-enumerating
failure boundary.

COMMIT requires an explicit Presentation approval bound to one exact transient
proposal. One dedicated data-layer transaction must revalidate the source
Conversation/User Message, scope, current Project relation, target bank, full
typed-draft compare-and-set and formal typed write. Application must not compose
independent repository checks and call them atomic. W0 adds no schema migration
and does not expand MCP v0.

Deterministic proposal fingerprints deduplicate semantic replay. Each source
User turn has at most one active/pending write proposal; a different payload
creates a new identity and supersedes the older active proposal.

W0 is COMPLETE. The W0-CL canonical closure checkpoint confirmed focused
verification, semantic review and no unresolved P0/P1/P2 findings, and did not
automatically activate F1, P6 or P7.

See `docs/product/W0 Safe Agent Write.md`.

### S0 — Secure credential storage

S0 moves AI/OCR/Agent provider credentials out of SQLite plaintext into a
bounded secure credential seam. The secure store is the sole credential
authority; SQLite keeps non-secret engine metadata only (legacy plaintext
exists only as migration retry input until migration DONE). S0-P0 (canonical
contract), S0-D0 (core seam), and S0-D1 (real secure adapter,
flutter_secure_storage dependency gate user-authorized), S0-D2 (legacy
migration + production wiring), and S0-CL (closure) are COMPLETE. S0 Secure
Credential Storage is COMPLETE. Runtime schema stays v20; no UI, Agent, MCP,
F1, or P6/P7/RAG changes are included.

See `docs/architecture/s0-secure-credential-storage.md`.

### F1 — Parsed Artifact lifecycle

F1-P0 is COMPLETE and wrote canonical documents only; it implemented no
production code, tests, or schema migration. F1-D0 (ParsedArtifact domain and
codecs), F1-D1 (v20 parsed artifact persistence), and F1-A1 (Application
lifecycle seam and orchestration) are also COMPLETE. F1-I1 (deterministic
production generation adapter for `pdf_text`/`docx_text`/`txt`/`markdown`)
is COMPLETE and reuses the existing parser truth. F1-I2 (explicit
`ocr_pdf`/`ocr_image` ParsedArtifact generation through
`OcrDocumentClient -> OcrSourceDocumentAdapter`) is COMPLETE with offline/mock
testing only; `auto` never triggers OCR, and the question OCR pipeline is not
part of artifact generation. F1-CL is COMPLETE: focused verification PASS,
final full semantic review APPROVE, closure repair merged via PR #65, and no
open P0/P1/P2/P3 findings. F1 Parsed Artifact Lifecycle v0 is COMPLETE.
P6, UI, Agent, and MCP stages were NOT STARTED at F1-CL. There is no UI,
Agent, or MCP activation.

Frozen stage graph:

```text
F1-P0 -> F1-D0 -> F1-D1 -> F1-A1 -> F1-I1 -> F1-I2 -> F1-CL
```

Schema history: F1-D1 implemented the additive v20 artifact tables without
modifying earlier tables. RAG-1 later raises the current runtime schema to v21;
see `rag1-project-retrieval.md`.

Governance:

- all F1 stages are `SERIAL`; a checkpoint must complete and freeze before the
  next stage starts, and later stages never auto-activate;
- F1-CL is the closure point: focused verification followed by the final full
  semantic review;
- mid-stage review escalation is allowed only for a truly unresolved Class C
  decision or still-unfrozen schema/CAS semantics;
- there is no F1-U; UI entry/redesign remains deferred.

See `docs/architecture/f1-parsed-artifact-lifecycle.md`.

### P6/P7 — Answer candidate producers

P6 is currently shelved at the ordinary UI entry; its producer code remains
retained. P7 remains the active Answer Completion producer. Historical stage
completion below does not reopen the P6 product entry.

The long-term shared shape is:

```text
Manual / Supplemental file / AI
              |
              v
       AnswerCandidate
              |
              v
       Preview / Review
              |
        user confirmation
              |
              v
 AnswerRepairCommandService (or equivalent application command)
              |
              v
      typed answer mutation
```

P6/P7 must not each create their own database-write protocol.

The frozen P6 contract is
`docs/architecture/p6-supplemental-answer-matching.md`. P6-P0 through P6-V0
are COMPLETE, and the P6 write path reuses the existing typed answer mutation
authority rather than creating a second answer writer. P7-P0 froze the
focused P7 v0 contract in `docs/architecture/p7-ai-answer-candidates.md` and
is COMPLETE (docs-only); P7-D0a, P7-D0b, P7-D1, P7-I0, P7-C0, P7-U0, and
P7-V0 are COMPLETE, P7-CL is COMPLETE, and P7 v0 is CLOSED / FROZEN.

### SPL-1 — StudyPlan Agent Tool

SPL-1-P0 froze the focused canonical contract in
`docs/product/SPL-1 StudyPlan Agent Tool v0.md`; SPL-1-P0 is docs-only and
COMPLETE. SPL-1-D0 (domain types, transient draft lifecycle, planning and
producer-neutral candidate read seams, deterministic preview, and the
read-only data implementation) is COMPLETE. SPL-1-D1 (schema v22, durable
ActiveStudyPlan persistence, formal adoption command, durable CAS, stop
command, source-turn/scope revalidation, and focused tests) is COMPLETE.
SPL-1-I0 (Built-in Agent `propose_study_plan` tool catalog and dispatcher,
runtime source-turn authority injection, deterministic allowlist tool result,
production fresh ID wiring, and Assistant typed proposal card / explicit
adoption / replacement confirmation / reject Presentation) is COMPLETE.
SPL-1-U0 (Today / 特训 real plan surface, deterministic dynamic selection
service, exact-order typed/legacy materialization seam, non-preview
PracticePage prepared-session path, and exact-planId stop CAS) is COMPLETE.
SPL-1-V0 (focused acceptance over the real production chain — proposal
staging, explicit adoption, transient-vs-durable restart, provenance-vs-
ownership, live dynamic selection, non-preview Practice path, typed/legacy
materialization, replacement/stop CAS, advisory states, and frozen
Agent/MCP/schema catalogs — on synthetic SQLite with zero production code
changes) is COMPLETE. SPL-1-CL (canonical closure / freeze of the SPL-1 v0
contract and capability, docs-only) is COMPLETE. SPL-1 StudyPlan Agent Tool
v0 is CLOSED / FROZEN; its durable persistence stage used schema v22, while
the current runtime schema is v28. SPL-1 follow-up roadmap items do not
auto-start.

The frozen capability chain is:

```text
real learning state
-> Built-in Agent planning
-> propose_study_plan
-> Application validation
-> transient StudyPlanDraft
-> deterministic preview
-> explicit user adoption
-> durable ActiveStudyPlan (exactly one global singleton)
-> Today / 特训 dynamic selection
```

Frozen boundaries:

- StudyPlan is a strategy/selection layer above the existing review/FSRS
  semantics; adoption and selection change zero review state, and mastery is
  not terminal (mastered questions remain selectable when due/weak per live
  FSRS state; `masteryReached` is advisory only).
- The Agent stages only a bounded plan draft; only explicit user adoption
  through an Application command with a durable transaction-level
  compare-and-set may persist the single ActiveStudyPlan. Chat text is never
  adoption.
- `propose_study_plan` is a separate Built-in-Agent catalog; the exactly-six
  A0 read-tool catalog and the exactly-six MCP v0 contract remain unchanged.
- Drafts are transient and bind runtime-injected source
  Conversation/User Message/scope; adoption revalidates source-turn validity
  and scope admission; the adopted plan is not Project-owned.
- v0 is one global ActiveStudyPlan with one-bank scope; `horizonDays` is
  advisory guidance only; no automatic expiry/deactivation.
- The legacy StudyPlanBank / StudyPlanBankCatalog / PlanConfigScreen quota
  terminology is untouched.
- Selection is dynamic policy over live candidates (producer-neutral
  `StudyPlanCandidate`, ordered due/weak/new pools, mandatory dedup,
  deterministic priority order) with no persisted question-id list.

See `docs/product/SPL-1 StudyPlan Agent Tool v0.md`.

## 5. Explicit non-goals for this roadmap

Until separately authorized:

- no R9-style global refactor;
- no physical retirement of legitimate V1 compatibility rows/readers;
- no mandatory Project assignment for files/banks;
- no original file blobs in SQLite;
- no durable absolute paths as file identity;
- no built-in Agent -> MCP self-call;
- no MCP v0 scope expansion;
- no autonomous destructive Agent writes;
- no user-facing standalone "RAG knowledge base" product object;
- no simultaneous F0 + J0 + Agent + UI + schema mega-stage.

## 6. Documentation authority

- `ARCHITECTURE.md` is the current repository-wide boundary.
- ADRs under `docs/architecture/adr-*` record accepted architecture decisions.
- This file is the canonical project stage/status roadmap.
- `mcp-v0-contract.md` remains the authority for MCP v0 semantics.
- `docs/product/W0 Safe Agent Write.md` is the focused W0 write-boundary
  authority.
- R7/R8 focused documents remain the authority for frozen typed persistence/consumer invariants.
- `docs/architecture/f1-parsed-artifact-lifecycle.md` is the focused F1
  authority.
- `docs/architecture/p6-supplemental-answer-matching.md` is the focused P6
  authority.
- `docs/architecture/b0-shiroha-backup-restore.md` is the focused B0
  `.shiroha` backup/restore authority.
- `docs/architecture/p7-ai-answer-candidates.md` is the focused P7
  authority.
- `docs/product/SPL-1 StudyPlan Agent Tool v0.md` is the focused SPL-1
  StudyPlan authority.
- R0-era files marked historical describe the migration origin, not the current runtime state.

## Current Today Presentation amendment

`docs/product/today-home-refresh-freeze.md` supersedes only the historical
three-mode Today layout. Today now presents one scrolling dashboard with
bank-scoped summaries, independent new/due normal Practice starts, one active
plan and its lightweight detail, learning activity and a standalone MockCenter
route. Existing singleton StudyPlan selection/adoption/stop, import/task,
Assistant/Profile, normal grading/FSRS and typed authority are retained.
New statistics, multi-plan previews and full plan management remain deferred.
