# Agent Runtime v1 / External Agent / MCP vNext Contract Index

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
P22 is merged in PR #280; P23 is merged in PR #281; P24 adds inactive G0-L0
protected Exchange file I/O with creator-only cleanup only.**

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
P24 under readiness §16 adds SOURCE IMPLEMENTED / OFFLINE TESTED fixed-kind/ID
Native Exchange create/read and creator-only cleanup with strict P22 codec
boundaries and directory-identity-bound cross-process quota exclusion. ABI 3
adds three optional exports while preserving all eighteen existing exports.
REAL WINDOWS PENDING / FORMAL ACCEPTANCE PENDING remain explicit; no Pairing
transition, consumption order, credential ticket, Host/Bridge activation or
startup is supplied. P20's isolated-root functional result is not extended.
HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.
Production Host/IPC, MCP vNext and READ fallback continuation remain unimplemented
targets. Current product behavior
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
after AR-R4 and exercised by the AR-R5/AR-R6 feature additions. AR-R7/AR-R8/AR-R9
do not block external generation. Minimal Review is part of AR-R5.

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
