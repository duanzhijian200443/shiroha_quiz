# Shiroha Quiz Architecture Contract

Status: **Canonical architecture contract after R1–R8 and P5**.

This file describes the current dependency direction and the boundaries that all new post-P5 work must preserve. Historical R0/R1 migration documents remain useful as design provenance, but they are not current-state authority.

## Reading guide

Read sections 1–3 and 7–8 for the shared architecture baseline, then the
sections and focused contracts that own the affected capability. A reference in
an unrelated section does not require loading that contract. This guide changes
reading order only; all existing contracts and historical amendments remain valid.

| Task boundary | Relevant sections |
|---|---|
| Typed content / rendering / imports | 3–4 and the focused RichContent contracts |
| File Library / artifacts / retrieval | 4 and its focused lifecycle/RAG contracts |
| Conversation / Agent / MCP / write approval | 5–6; Agent refactor target index below |
| Credentials / provider configuration | 9 |
| Supplemental / single-question AI answers | 10–11 and Answer Completion v0 |
| Navigation / Practice / Today | 12 and applicable product contracts |
| StudyPlan | 13 |
| Runtime data locations | 14 |
| Review repair / photo answers | 15–16 |
| TrainingContent / StudyActivity / TaskCenter | `docs/product/home-training-v3.md` canonical contract |

Stage order and durable capability state belong to the focused canonical contract
and roadmap; Git/PR/CI/Reviewer own exact execution history. The stage
summaries below retain their recorded context and do not replace those sources.

## 1. Canonical dependency direction

```text
Flutter UI ───────────────┐
Built-in Agent Adapter ───┼──> Application Layer ──> Domain Layer
External MCP Adapter ─────┘
                                  ^
                                  |
                    Data / Infrastructure Adapters
                    - Repositories / SQLite
                    - Managed file storage
                    - OCR / AI / Web providers
```

`main.dart` and other explicit composition-root code may know concrete implementations in order to assemble the dependency graph. Feature code must not use the composition root as a service locator.

### Migration rule

The repository still contains pre-N0 screens/services that directly call repositories. N0 does **not** trigger a repository-wide rewrite. However, new post-P5 modules must not add new presentation-to-repository dependencies. When an existing direct dependency is touched for a new cross-surface capability, prefer introducing the smallest application service/facade needed by that capability.

## 2. Layer responsibilities

### Presentation adapters

Includes Flutter UI, the built-in Agent adapter, and the external MCP adapter.

Responsibilities:

- render or translate user/protocol interaction;
- collect bounded input;
- invoke application use cases/tools;
- project safe application results to UI/protocol DTOs.

Forbidden:

- direct SQLite / `DatabaseHelper` access;
- raw SQL or raw database-row handling;
- joining `question_v2_payloads` in presentation code;
- making a new post-P5 feature depend directly on a repository;
- treating provider DTOs or file-system paths as domain truth.

### Application layer

Owns use-case orchestration and cross-surface semantics, including:

- query services;
- command services;
- application tool facade used by Agent/MCP/UI;
- Project-context resolution;
- Draft / Review / Approval flows;
- business validation that spans repositories or external ports.

Application code may use repositories and infrastructure ports, but must not expose raw database maps, SQL, provider payloads, or absolute paths to presentation adapters.

### Domain layer

Owns stable business meaning and value objects, including the typed learning core:

- `SourceDocument` / `SourcePart` / `SourceRef`;
- `QuestionRegion` boundaries and typed assembly concepts;
- `RichContent` and typed content nodes;
- `QuestionDraftV2` and typed answers/options;
- `ReviewSession` semantics;
- `PersistedQuestion` typed/legacy union semantics.
- `Conversation`, `ConversationScope`, and ordered `ConversationMessage`
  semantics.

Domain code must not import Flutter widgets, SQLite, `DatabaseHelper`, provider DTOs, HTTP clients, or file-system APIs.

### Data / infrastructure

Owns physical persistence and external integration:

- SQLite schema, transactions, migrations and row mapping;
- repositories;
- managed file storage;
- OCR/AI/Web provider clients and DTO adaptation.

The External Windows primitive adapter in `lib/data/external/native` owns
explicit SDK FFI calls to the independent `windows/external_native` C ABI DLL.
It supplies bounded DPAPI memory operations, an unvalidated known-folder path
and explicit protected-object owners with parent-bound native handles and App/
Bridge OS-exclusive writer locks and fixed App association-file transactions.
The P20 Data adapter `WindowsCredentialAssociationStore` implements the existing
P15 association port using strict kind 3 plaintext, user-scope DPAPI and the
parent-bound Native file transaction. It adds no verifier or Application authority
and stays absent from normal startup and Agent/MCP. MCP contract section 16
adds only an explicitly invoked dormant composition over this same Store.
The inactive P21 Infrastructure candidate adds P-256/PKCS#8 primitives, strict
credential/certificate codecs and an explicit crypto adapter in the same helper;
no Application/Domain certificate or Windows dependency is introduced.
P22 adds inactive pure Data codecs for the pairing transcript, public exchange
payloads and Discovery descriptor, with explicit non-authorizing digest/signature
interfaces and caller-owned trust/high-water inputs. No file access, Native call,
P15 evidence producer or production composition is added.
The inactive P23 Data adapter `WindowsCredentialObjectStore` adds fixed kind
1/2/4 persistence through those same owners, strict P21 codecs, P18 DPAPI and
Win32 handle-relative native transactions; App kinds 1/2/3 share one ticket.
No credential lifecycle, initialization, issuer, Pairing or startup is supplied.
The inactive P24 `WindowsExchangeFileStore` uses P22's single strict codec and
optional ABI-3 fixed-kind/ID I/O. Native owns parent-bound Exchange access,
CREATE_NEW, bounded reads, directory-identity-bound short quota exclusion and
creator-only identity-pinned cleanup. Bridge opens App-created Exchange only;
no credential ticket, App lock, consumer workflow or production wiring is added.
P27-E0 extends that inactive adapter with optional ABI-3 owner-bound reader
tickets, retained object pins and exact-byte snapshots. Complete P22 decoding
precedes delivery of a controlled read; explicit Consume rechecks identity and
content on a protected read/delete handle, while Release only drops the pin.
This foundation owns no consumption timing, P15 evidence or Pairing workflow;
Windows readiness §16 owns its limits and pending Windows acceptance.
P25 adds explicit inactive App credential initialization and restricted Client
leaf issuance. It reuses these owners, P21 crypto/certificate codecs and a
same-ticket create-if-missing operation in P23's adapter. Persisted signatures,
key correspondence and exact issuer binding are verified before reuse; partial
initialization requires explicit recovery without replacing the trust root.
It supplies no Application authorization, Pairing or production wiring.
P26 adds inactive fixed-object Discovery publication/reading, P25-backed
cryptographic publication checks, same-ticket kind 1 epoch advancement and
conditional existing kind 4 high-water updates. Bridge uses its own Owner and
existing-only Discovery access; independent trust inputs remain mandatory.
No enrollment pin, listener, TLS, authorization or production wiring is added.
P27 adds inactive composition-side App/Bridge Pairing coordination and a real
cryptographic P15 verification adapter. E0 consumption binds original bytes;
independent local comparison/approval actions precede P15 CAS/P0 completion and
the separate Missing-only initial kind 4 save. P15 alone owns private evidence,
P0 alone owns PairingState, and Authentication still rejects in this adapter.
No startup/UI/Agent/MCP, listener or transport is wired. Trusted composition may
select a Pairing Request lifetime up to 600 seconds; the default Request and
post-verification evidence windows remain 30 seconds. Readiness section 19 owns
the Package 1 integration, bounded resources and explicit recovery interface.
The readiness contract sections 10–19 own these production source slices and
their pending Windows acceptance.

The inactive Package 2 transport group in `lib/data/external/windows_tls_*`
adds explicit Raw IPv4 accept/TLS upgrade, isolated TLS 1.3 context plans,
crypt32 peer-role policy through an optional certificate-only ABI-3 capability,
P20's read-only inverse query over the same protected associations and private
P15 channel attempts. P27 Pairing events remain separate. P0/P12 alone mint
Sessions; trusted P8 Contexts and unchanged P9/P10/P7 authorize every command.
The P8/P10 read-only settlement barrier lets transport reservations outlive a
caller result without creating another business lifecycle. No startup root
imports/starts this candidate. Readiness section 20 owns its offline/resource
limits; real TLS/Windows behavior and production activation remain pending.

The inactive Package 3 extension keeps lifecycle custody in that SAME
`WindowsTlsHost`: its owned constructor validates P27/P15/P12/P20/P26
composition identity, reuses P8 readiness and the sole P26 TLS startup, and
holds the acquired Owner/runtime.lock through connection/business/Pairing/
boundary/revoke-CAS/Store drain. Unknown cleanup never reports clean closure
or releases the lock. Socket disconnection invalidates channel evidence,
not a P0 Session or all Profiles. Read-only composition checks add no authority.
Pure package/PE checks and a default-disabled standalone Bridge source entry
perform no loading or alternate business writes. Readiness section 21 owns
the source/offline evidence and A0–A12 pending acceptance; no default startup,
schema/B0/S0, P9/P10 or AR-R6B behavior changes.

Persistence formats and provider formats are implementation details, not public application contracts.

## 3. Frozen typed-learning-core invariants

R1–R8 and P5 are closed architecture stages. New features build on them rather than reopening them.

1. For a typed persisted question, the `QuestionDraftV2` sidecar is the content authority.
2. The V1 `questions` row is a compatibility projection for typed rows, not a second content truth.
3. A corrupt/unsafe typed sidecar hard-fails; typed consumers must not silently fall back to V1 content.
4. `null` and explicit typed empty content remain distinct where the typed contract distinguishes them.
5. `QuestionList`, Practice and WrongBook consume typed questions through the typed-aware persisted-question seam.
6. Typed content mutation must not pass through the legacy editor or reconstruct authority from a V1 projection.
7. Review/FSRS state is separate from typed question content mutation.
8. `RichContent` is structural: a persisted `TextNode` is not reparsed later as Markdown/math/image syntax.
9. Current database schema is **v34**: the frozen v15 typed sidecar remains
   authoritative, with the additive v16 File Library, v17 Project, v18 flat
   File Library Folder, v19 Conversation, and v20 parsed-artifact tables, the
   additive RAG-1 derived lexical-retrieval cache and FTS5 objects, the
   additive v22 `study_plans` table, the additive v23 `answer_attempts` table,
   the additive v24 Provider / Model Registry / capability authority, v25 model
   origin/binding policy, v26 image AnswerAttempt modality, the v27 derived
   ContentAsset reclamation-observation table, and the v28 durable
   `ImportedQuestionSet` / ordered-membership schema with database-owned
   relationship invariants, plus the v29 TrainingContent / members / Category
   preferences configuration schema, v30 StudyActivity sessions/segments and v31
   nullable ImportTask current-attempt event timestamps and v32 durable generated
   Proposal originals/review/receipts/mappings, plus v33 non-secret external
   Profile/Grant policy, exact scopes and Egress categories. The authorization
   contract is owned by `external-agent-boundary.md` §6; P1 adds no authentication,
   pairing, runtime Enablement, external Origin, Dispatcher or Host wiring. B0
   scrubs its rows from portable copies and preserves original raw rollback state.
   V34 adds tagged external historical Origin in the existing Proposal Header,
   retains v32 physical-schema migration authority, and preserves all child data,
   local Review/COMMIT and B0 package v2. The generated-question contract §10 owns
   this candidate format; it adds no external STAGE or authentication factory.
   P2 is accepted through merged PR #249. P3's accepted unpublished Application/Data
   path (merged PR #250) reuses v34 for trusted external STAGE and narrow durable key
   reconciliation, with current Grant/revoke and publication sharing the existing
   SQLite authority. GeneratedQuestion §11 owns its App-bound Sessions, immutable
   Contexts, pending-only resource guard and final authorization release. No
   transport/Host/CapabilityExecutor projection or external COMMIT is wired.
   P4's accepted unpublished Application/Data path (merged PR #251) shares P3's runtime binding
   admission and adds bounded READ Context/target metadata under the external
   boundary §3. READ + questionContent + exact bank/Project scope is mandatory;
   only targetRef/bankName/projectId/folderName are released. Empty source
   snapshots authorize no file/content reads; STAGE authority stays separate.
   Schema/B0 and existing CapabilityPrincipal/Receipt semantics are unchanged.
   P5's accepted unpublished Question READ (merged PR #253) uses that same Context Registry for
   opaque QuestionRefs/cursors. Data owns current-scope keyset selection and
   exact typed/legacy materialization; Application owns bounded invocation and
   safe final release. StudyQuery and P5 share stateless content projection,
   without changing MCP v0 search/permissions. External boundary §3 owns P5's
   whitelist and lifecycle; no Host, transport or general Principal is wired.
   P6's accepted unpublished File READ (merged PR #255) creates separate explicit-file Contexts
   under independent current READ/fileContent/exact File-Project authority.
   It reuses that Registry and verified F1/RAG Chunker/Index with final source
   and Grant revalidation. Derived-cache evidence remains distinct from READ
   permission and output release. Original P4/P5 empty file Contexts are preserved;
   no schema, parser, business writer or external publication is introduced.
   P7's accepted unpublished Application Kernel (merged PR #256) adds a private,
   exact-Session external execution Context, explicit READ/STAGE registry and transient typed
   Receipt over those owning services. Original READ reference semantics remain
   Principal/generation bound; STAGE remains precise-Session bound. Durable
   reconciliation refers only to Proposal/original key. Existing Data transaction,
   current authorization, limits and final egress authority are reused; no
   transport, Host, credential adapter, formal COMMIT or new persistence is wired.
   Application capabilities §7 and external boundary §3 own this integration.
   P8's accepted offline LocalHostDispatchCore (merged PR #258) is under external
   boundary §3: trusted readiness and private Session entry, exact ten typed P7
   routes, original result/effect evidence and real close/drain before replacement.
   No default composition, listener, credential/transport adapter or MCP publication
   is wired. P9's accepted unpublished infrastructure IPC Envelope/Codec
   (merged PR #260) is under external boundary §7: bounded incremental framing produces
   untrusted UTF-8 text only, with no identity or business projection/dispatch.
   P10's accepted unpublished offline infrastructure command projection (merged PR #261) is
   under §8: current authenticated P8 Session binding before strict schema parsing,
   ten explicit typed routes and deep safe-result whitelists. Contexts remain
   trusted P8 composition inputs; encoding loss preserves original local evidence.
   No P3-P9 authority, production composition or transport is changed.
   P11 adds accepted first-party local Profile/Grant management (merged PR #262)
   under external boundary §9: page-owned management references, precise
   READ/STAGE and independent Scope/Egress editing, P1 revision CAS/transactions
   and B0 lifecycle protection. Its internal read-only Profile/Bank queries reuse
   existing v34 authority; File/Project choices use trusted Application queries.
   The settings page configures non-secret policy only, with clients unpaired
   and disabled. Production composition supplies only local management, never
   a Principal, Session, external Capability, credential or Host.
   P12's accepted unpublished offline scope (merged PR #263), under external
   boundary §10, uses existing
   opaque management references to register one P0 Principal per durable Profile,
   without string-based identity minting. Its local coordinator delegates pairing,
   proof, finite enablement and Sessions to the original TrustCore and binds P4
   admission by generation. P8/P7 retain current policy and owning release checks;
   shutdown drains before generation invalidation. Synthetic credentials remain
   test-only, and production has no external pairing/Session/Host composition.
   Final CI and Reviewer APPROVAL closed P12's offline scope; its fixed-target
   offline checks were performed by that same review session under explicit user
   instruction, not a separate independent Verifier session. Section 10 records
   the disclosed exception. P13's accepted static readiness (merged PR #264) under external
   boundary §11 and windows-host-security-readiness.md defines credential/Windows
   IPC gaps, isolated experiment authority and real acceptance/fallback gates.
   It activates no runtime and does not prove production security or stability;
   dynamic admission remains BLOCKED without a separately approved environment
   and explicit experiment authorization. AR-R6B remains inactive.
   P14 (merged PR #265) makes complete External offline regressions standing CI.
   P15's offline candidate under external boundary §12 defines a separate protected
   association port and trusted verifier seam with private one-use P0 evidence.
   It delegates all pairing/Session state to P0/P12 and policy to P1/P4/P7/P8;
   association CAS is not a cross-store SQLite transaction. At P15 delivery only
   test backends existed; P20–P27 add inactive storage/crypto source above, while real
   M1–M4/G0/X0–X12 Windows gates remain unmet. S0 engine.* authority is unchanged.
   P16 freezes the production primitive candidates under external boundary §13
   and windows-host-security-readiness.md §9: the installation-issuer/server-and-
   client-leaf trust split, one dedicated DPAPI-backed External object store
   satisfying the P15 contract, the cryptographic pairing possession proof and
   the owner-only Discovery root. It selects candidates only — no runtime,
   dependency, schema or permission semantic change. P17's bounded amendment
   in that readiness contract §§6/9.A.2/9.F separates X.509 DER signatures from
   custom raw r‖s and tiers G0: L0 code/compile/offline development needs scoped
   task authority; L1/L2 real local subsets need exact user batch grants; full
   Windows acceptance retains independent-kernel G0-I. BLOCKED_ON_G0 concerns
   real experiments/acceptance, not L0 code. No experiment or Host is activated;
   the next scoped implementation is Package 1, with no new general design stage.
   HOST_STABILITY_HALT stays ACTIVE; Transport BLOCKED and AR-R6A NOT_ACCEPTED.
   The generated schema is globally
   migrated and strictly validated independently of runtime module enablement.
   The v27 table records only
   continuous grace evidence; it is neither an ownership registry, a refcount,
   nor a persisted live-set authority. V26 only extends
   the modality CHECK; all columns, indexes, nullable correctness and append-only
   semantics remain unchanged. Image payload v1 requires a durable
   `source_file_id` soft evidence reference, permits optional/empty transcription
   and bounded feedback, and never duplicates correctness. Missing evidence does
   not invalidate history. Question/Explanation remain RichContent; student
   image answers are AnswerAttempt plus optional retained image evidence.
   `answer_attempts` is append-only durable answer
   history, separate from mutable Review/FSRS scheduling state in
   `review_states`; changing or resetting scheduling state does not rewrite or
   delete answer history.

### RichContent Foundation Phase 0

The FINAL/FROZEN additive architecture target for first-class `ImageNode` and
`TableNode`, draft-level asset inventory authority, codec evolution, recursive
privacy admission, compatibility projection, durable asset lifetime, and
block-native structural ownership is
`docs/architecture/rich-content-foundation.md`. The bounded Phase 2A/Train B
implementation now conforms for typed image/table admission, managed asset
durability, B0 package v2 coverage, and explicit resolver-backed rendering;
final live acceptance remains deferred. The D0 successor for ContentAsset
retention, writer ownership, inventory, and collection is
`docs/architecture/dm-p0-content-asset-lifecycle.md`; its lifecycle stages are
activated and closed together, and destructive collection runs only through that
document's gated maintenance path under an explicit user confirmation.

## 4. Learning asset expansion boundary

Post-P5 asset work introduces new objects around the typed core rather than replacing it.

```text
LibraryFile
  original user-owned file metadata + managed storage identity
        |
        v
ParsedArtifact / SourceDocument
  reproducible parser/OCR-derived structure
        |
        v
QuestionDraftV2 -> Review -> PersistedQuestion
  confirmed learning data
```

Rules:

- Original file bytes belong in app-managed storage, not SQLite blobs.
- SQLite stores stable file metadata and a managed storage key/relative identity, never a durable absolute platform path.
- `ParsedArtifact` is derived data and must not replace the original file as the user's source asset.
- Formal question/review data must survive artifact cache replacement/removal.
- `Project` is an optional organization/context layer. Assets may exist with no Project.
- Projects reference files/banks; they do not own or duplicate original file bytes.
- A File Library Folder is a flat, optional manual classification for
  `LibraryFile` only. One file has at most one Folder, while Project/Learning
  Space relations remain independently many-to-many.
- Folder deletion removes Folder membership only; the `LibraryFile`, managed
  bytes, Project relations, banks, questions, sidecars, and review state remain.

### ParsedArtifact lifecycle invariants

- Identity is generation-scoped: `SourceDocument.sourceId = artifactId`, never
  `fileId`; page, block, asset, and issue provenance bind to one specific
  artifact generation.
- Confirmed learning data is independent: artifact replacement, removal, or
  corruption never deletes or rewrites a confirmed `QuestionDraftV2`, persisted
  questions, or review/FSRS state, and the draft's existing `SourceRef` values
  remain unchanged.
- F1 v0 keeps one current artifact per file; it implements no artifact history
  or tombstone registry, and replaced or deleted historical artifacts are not
  guaranteed to be re-dereferenceable from unchanged `SourceRef` values.
- Consumers reach artifacts only through the Application lifecycle seam with
  safe outcomes and typed failures; adapters never receive SQLite rows,
  absolute paths, `ParsedDocument`, or provider DTOs.
- Storage is SQLite current metadata plus managed immutable sidecars; the
  SQLite commit is the only publish visibility point, and CAS conflicts
  preserve the current artifact.
- Persisted payloads admit only `SourceDocument`/`SourcePart`/`SourceRef`/
  `RichContent`/`ImportIssue`/safe `AssetRef` metadata, never provider bodies,
  raw diagnostics, absolute paths, or binary image bytes.
- A verified current `parsed_artifacts` row and its decoded `SourceAssetPart`
  identities form a derived runtime ContentAsset retention root. A revision
  head alone does not; an unreadable current payload blocks destructive scans.
  OCR artifact generation is also an ordinary runtime ContentAsset byte writer;
  B0 restore writes ContentAssets through a separate journaled recovery path.
  See `docs/architecture/dm-p0-content-asset-lifecycle.md` for the activated
  lifecycle stages, the acceptance evidence per row, and the rows that remain
  unproven.
- F1-D1 implemented the additive v20 artifact tables without modifying any
  earlier table. RAG-1 subsequently raised the runtime schema to v21 at its
  closure with derived lexical-retrieval cache tables and a dedicated FTS5
  index; the current runtime is v34.

See `docs/architecture/f1-parsed-artifact-lifecycle.md`.

### RAG-1 successor amendment

RAG-1 consumes only verified current F1 artifacts, preserves File/Project as
the product authority, and adds deterministic lexical retrieval behind an
Application seam. Local readability never implies provider egress: Built-in
Agent file-content access requires a transient per-turn grant and an
independent retrieval tool. MCP v0 remains exactly six read-only tools. See
`docs/architecture/rag1-project-retrieval.md`.

## 5. Conversation foundation boundary

Conversation Presentation consumes a dedicated `ConversationService` alongside
the existing workspace facade. The service owns safe application failures and
uses a `ConversationRepositoryPort`; SQLite wiring remains in the composition
root.

Assistant source presentation separates conversation/Turn coordination in
`ConversationController` from its single owned `AssistantArtifactController`.
The latter owns only transient artifact display, source bindings, action wait
state and recovery coordination; existing public artifact entrypoints forward
to it. Typed Proposal/draft lifecycles and formal writes remain in their owning
Application services. Dedicated card presenters consume the existing finite
Module UI Contribution slot. The focused boundary is
`docs/product/agent-refactor/assistant-artifacts.md`; this source decomposition
does not waive AR-R6B production admission or Windows/runtime acceptance.

- A new conversation is a transient draft until its first valid User Message.
- First persistence atomically creates the Conversation, sequence-1 Message,
  and selected `conversation_files` relations.
- Message order is the explicit per-conversation `sequence`, never a timestamp.
- A Conversation is either Global or scoped to a Learning Space. Project
  deletion uses `SET NULL` while preserving `scope_kind = learning_space`, so
  the orphan remains readable but unavailable for further message appends.
- Conversation/File relations are context references, independent of Project
  and Folder membership. They never own or duplicate file bytes.
- Conversation deletion cascades only to Messages and Conversation/File
  relations. File deletion removes only the relation.
- C0 persists User Messages only. Assistant persistence is an additive A0 seam;
  C0 does not synthesize an Assistant reply.
- Bank attachments, Provider, Web, RAG, Agent runtime, and MCP expansion remain
  outside C0.
- Existing subject/folder structures remain compatibility/product concepts until a separately authorized migration changes them.
- Bank identity is a J0 prerequisite decision. N0 does not introduce `bank_registry` or change current bank persistence.

See `docs/architecture/adr-002-learning-asset-lifecycle.md`.

## 6. Agent, MCP and application tools

Built-in Agent and external MCP are **peer adapters** over the same application capabilities:

```text
Built-in Agent
      |
      v
Application Tool / Query / Command Layer
      ^
      |
MCP Adapter <- External GPT / Claude / other MCP client
```

The built-in Agent must not call the app's own MCP transport. Shared business semantics live in the application layer, not in MCP protocol code.

MCP v0 remains the exactly-six-tool read-only contract frozen in `docs/architecture/mcp-v0-contract.md`. File/Project tools are MCP v1+ concerns unless that contract is explicitly revised.

Future mutation permissions follow:

```text
READ        -> adapter may execute within permission scope
DRAFT/STAGE -> may create a proposal, not formal data
COMMIT      -> requires explicit user approval through an application command
DESTRUCTIVE -> additional approval; may remain unavailable in early versions
```

No Agent or MCP tool may directly execute SQL or bypass the typed persistence/review boundary.

The bounded vNext STAGE stdio source slice is described in
`docs/product/agent-refactor/mcp-vnext-contract.md` §7. Its separate seven-tool
server and explicit inactive App composition reuse P3/P7/P8/P9/P10 and the local
Proposal Review UI. Trusted App-approved exact-Session targets remain mandatory;
client READ references never grant STAGE. The standalone entrypoint refuses
business calls until production transport/admission is accepted. Synthetic stdio
evidence grants no AR-R6A/AR-R6B production activation or external COMMIT.

The first-party App integration in `composition/mcp_vnext_app_integration.dart`
captures the existing production authorization, Proposal, local Review and
F1/RAG owners. Startup installs only its dormant local controls, not P0/P8,
credentials, an MCP server or transport. An explicitly supplied, admitted trusted
composition may attach the existing P0 authority through the retained App Port.
Application owns Profile selection, fresh authentication, finite enablement and
explicit P3 target confirmation; UI supplies no credential or READ-to-STAGE
upgrade. Database close drains the owner before B0 swap/rollback or rebuild;
replacement starts disabled. MCP contract §9 owns this bounded App slice and
the remaining production pairing/authentication/transport admission gap.
MCP contract §10 extends that owner with an explicit inactive P15 credential
composition, local request/approval/proof actions and original-channel Session
custody. The same P27 Data candidate exposes a first-party adapter; no startup
imports it. P0 remains the sole pairing/identity authority, P15 verifies evidence,
and a separate authenticated connection is required before business Session use.
Missing Grant never prevents independent pairing, nor does pairing grant access.
No synthetic service, protected-store/native operation or listener enters normal
startup. MCP contract §11 adds the inactive `WindowsBridgeOnboarding` local
control interface over the SAME P27 Enrollment: independent App public inputs,
full initial comparison before Proof and a second full digest/actual-Revision
comparison before the existing Missing-only Pin save. Close/failure/expiry
withdraws displays, wipes the original key and drains local input without another
PairingState, Session or persistent authority. The disabled standalone Bridge
exports that interface but starts nothing. MCP contract §12 connects the same
owners through `WindowsPairingHandoff`: original Submission ID, copied public
export and freshly queried P15 actual completion. Both manual comparisons and
existing close/drain remain mandatory; no request record or credential owner is
added. Actual credential acquisition, Windows App/Bridge process transfer,
authenticated process bindings and Windows acceptance remain pending. MCP
contract §13 adds one bounded opaque P9 request/response to the same verified
`WindowsTlsBridge`, with fixed deadlines, chunking, response correlation and
close/drain. Fake TLS reaches the existing P10/P8 READ/STAGE owners; no Bridge
business authority is added. MCP contract §14 adds an inactive
`VnextMcpBridgePort` over that same already verified, single-use connection.
App and Bridge share one seven-tool/P10 mapping and strict response projection.
P10 business schema v3 carries untrusted Context/original-key selectors; App
composition authenticates S, obtains P8 entry E before parsing, then uses original
P8 openings to create a fresh execution Context for the same E/S. The six READ/
File/lifecycle tools are expressible through that inactive source binding.
READ handles may be revalidated by a fresh current Session of the same Principal/
running generation; execution Contexts and approvals remain exact-Session.
Windows Bridge STAGE defaults to refusal before serialization/send. The explicitly
enabled source-only profile in external boundary §8 retains one bounded raw
Submission and original S/E/revision/generation/exact App target for the current
first-party UI's explicit confirmation. One request per generation waits at most
120 seconds without a SQLite transaction/B0 lease; original P3 `approveTarget`
and P8 `openStage` remain the only approval/dispatch path. STAGE-only finite
transport windows preserve one P9 request/final response/EOF; READ retains its
2/10-second bounds. Approval never transfers between Sessions; real drain/close
precedes resource release. P9 SHIP/v1, P10 v1/v2/v3 and MCP schemas stay unchanged.
No durable approval registry/schema is added. Real process wiring and real
Windows security admission remain pending as distinct conclusions.
This is source integration, not production admission
or activation.

MCP contract §15 joins the same dormant App graph to an explicitly supplied,
identity-checked TLS transport attachment and its full shutdown barrier. The
original owned Host additionally drains auxiliary first-party authentication
connections before releasing its protected Owner. An inactive Bridge composition
owns one newly authenticated connection per independent call, rejects concurrent
work and never retries an unknown STAGE. Neither Windows composition has a
production startup consumer. Existing P27 Handoff, P15/P0/P8/P10, original
first-party approval and App-only Review/COMMIT remain the authorities; no second
IPC protocol, writer or authorization framework is added. Fake TLS and installed
client mailbox evidence do not complete production process/credential bootstrap,
#327 short-deadline cancellation compatibility or formal Windows admission.

MCP contract §16 lifts trusted credential/Pairing/Discovery/TLS wiring into
`McpVnextWindowsAppStartup` and `McpVnextWindowsBridgeStartup`. Construction
performs no I/O; explicit trusted acquirers transfer exclusive original Owners.
App reuses `attachCredentials` and the SAME owned Host/Runtime; Bridge retains
the original single-connection-per-call owner. Pending local Authentication and
actual process-exit callbacks join owning settlement before credential/lock
release, with failure latched and custody retained. The dormant trusted
`mcp_vnext_windows_acquisition.dart` adapter acquires original Native Owners and
constructs existing P20/P25/P24/P27 resources, with existing-only App credential
validation and one-shot transfer. `WindowsBridgeProcess` checks the fixed adjacent
Bridge candidate and retains only its newly created SDK process object; stdin
EOF, original exit and both output drains precede release. Unknown launch/close/
exit retains the owning lock and database barrier. App and Bridge share the
original Owner's one-use runtime guard. Neither adapter has a normal startup
consumer; constructors perform no OS work. The independent Windows-only ordinary
Dart child suite in MCP §17.1 exercises this custody/startup ordering over Fake
protected Owners/TLS. Its observed SDK error-87 repair uses one fixed inert empty
environment value without inheriting parent values or adding startup selectors.
Ordinary-child evidence does not exercise the private adjacent launcher/child
wrapper, formal Bridge AOT/Loader, real credentials/TLS or production cross-process
runtime, and does not establish formal admission, full AR-R6B or AR-R9B acceptance.

MCP §17.2 now joins the formal `shiroha_bridge.exe` AOT entry to the existing
seven-tool unavailable endpoint. It accepts no activation/configuration arguments,
creates no credential/Session/Host and returns no authorized business data.
Fixed-adjacent process and Native ABI-loader checks are separately executable
in a disposable Windows package; the loader probe never acquires protected objects.
Installed-client AOT discovery/refusal/EOF evidence is distinct from authorized
App/P27/Host tests using Mailbox/Fake TLS and isolated SQLite. Real production
App/Bridge credentials, transport, active-business crash/Restore and #327
cancellation remain unresolved; normal production startup is unchanged.
MCP §17.3 connects the same dormant Bridge startup to the original stdio server.
Its entry now waits for EOF and the original latched port/Owner drain; explicit
close first closes protocol admission and then joins that same settlement.
Independent-process public Pairing handoff and actual local-I/O/process assembly
remain product integration gaps distinct from protected-resource/TLS admission.
MCP §17.4 supplies App-only original-request public export and independent Bridge
byte import over the SAME P27 controls. The bounded public representation carries
only original Submission/public trust or freshly queried completion data. It
adds no Exchange message, listener, Session, grant or business IPC route. Both
human comparisons remain explicit. Windows subprocess tests use separate Bridge
Enrollment custody and Fake protected storage; production delivery surfaces,
accepted local-channel selection and startup/custody assembly remain pending.

MCP §17.5 supersedes those bounded assembly gaps with explicit App/Bridge runtime
assemblers over the same protected acquirer, Native peer-policy adapter, TLS I/O
and P27 public handoff. App startup owns original child launch and can acquire
only the existing server-authenticated Profile Session, with pending-open close
and actual Host/process settlement preceding Store/Owner/database release. There
is no second authentication, Owner, Session registry or business protocol. Separate
Windows processes exercise public handoff and original business framing over Fake
security; formal AOT remains a separately tested refusal endpoint. Normal public
delivery/confirmation UI, pending Enable/Bridge interaction and trusted AOT
bootstrap/client-stdio handoff remain product gaps; real protected/TLS/native
security and formal Windows acceptance remain unexecuted. Production startup
stays disabled.
MCP §17.6 adds an explicit single-consumer stdio transfer over that SAME adjacent
child: client input/output forwarding replaces stdout discard, stderr stays
separate, and EOF/failed streams/exit join original settlement with no second
protocol or Bridge. Direct client-owned and App-child custody are alternative
choices, never concurrent owners of one stream. First-party pending Enable is
observable and cancellable through the default accepted-channel acquisition;
finite expiry/failure withdraws access, and fresh explicit Enable cannot inherit
old Session approvals. Windows AOT/installed-client refusal and separate Fake
security business tests execute these paths. Normal App/client registration,
trusted formal-AOT business bootstrap and public comparison UI remain product
work at that checkpoint. All production security/admission blocks remain unchanged.
MCP §17.7 adds a bounded inactive interaction slice: the existing App control
projects pending Enable/deadline/cancellation and accepts original public
Submission IDs through its Application port. The same P27 App handoff supplies
explicit Trust/fresh Completion exports. An independent Bridge local Widget
consumes an Application port over the original Onboarding, keeping both full
human comparisons and the separate Missing-only save. Imports never confirm;
page/scope closure retains the original operation/runtime drain. No UI imports
Data, holds credentials or adds Pairing/Session/approval authority. Widget/offline
coverage and a successful isolated native desktop smoke use Fake security; neither
is independent Windows verification or production admission. Ordinary
startup remains unavailable. MCP §17.8 supplies the explicit independent Bridge
UI host over the same P27 controller, with one process/OS-lock instance and a
shared cancellation/window/resource drain. Separate Windows test-only App/Bridge
entrypoints exercise public pairing through actual windows with Fake security.
MCP §17.9 supplies a non-activating trusted Bootstrap over the original protected
acquirer, independent trust/P26 validation, Bridge startup and stdio server. App
lifetime registration defaults unavailable; explicit direct-client and App-hosted
registrations reuse the original integration/Host barrier. Completed UI pairing
can drain its controller/Owner/lock before fresh business acquisition. Formal AOT
still supplies no admitted Bootstrap. An isolated Windows client patch proves
EOF-first business settlement and serialized discovery with the compiled test
composition. Installed Codex 0.144.1 remains incompatible with graceful business
shutdown. Supported client delivery, explicit admitted production registration
and real security admission remain open; process disappearance never substitutes
for the original drain.

MCP §17.10 adds executable compatibility selection before either registration or
Bootstrap may acquire resources. Product support is empty; only the exact isolated
EOF-first patch is eligible in explicit validation composition. Discovery joins
original settlement before business, and concurrent/live-business discovery and
Direct/Hosted selection reuse refuse. This selection owns no process or business
authority; original drain, failure retention and fresh-Session approval still
apply. Normal App/AOT refusal and all security admission blocks remain unchanged.

MCP §17.11 adds isolated Windows model-turn evidence with the same pinned client,
App registration and compiled Bridge Bootstrap. A loopback Responses fixture
scripts function calls; Codex's original thread/turn and MCP manager return real
App/Application results to that same turn. First-party STAGE approval, local
Review/COMMIT, fresh-Session approval and original-key recovery remain separate.
Pending EOF/App close/Restore/disconnect and committed-response-loss checks add
no authority or production path. This proves scripted turn orchestration only;
autonomous model choice, Desktop interaction, official-client lifecycle,
production registration and security admission remain unaccepted.

The bounded lifecycle extension adds independent READ Proposal metadata over
the same persistence owner, through P7/P8, retained lifecycle-only IPC schema v2
and explicit v3 original-key selection.
MCP profile v2 returns persisted pending_review/committed/rejected and safe counts
by original key under current Profile, READ/metadata and original/current target
Scope. GeneratedQuestion §12 owns this release; original P3 reconciliation and
P10 v1 retain their STAGE-only acknowledgement. No schema, writer or production
Host/Transport activation is added.

See `docs/architecture/adr-003-agent-mcp-and-write-boundary.md`.

The frozen Agent Runtime v1 / external capability / source-module / MCP vNext
target is indexed in [docs/product/agent-refactor/README.md](docs/product/agent-refactor/README.md).
That documentation-only checkpoint does not activate the target or supersede
A0, AGENT-FB, W0, SPL-1, RAG-1, MCP v0 or OBS-1 runtime behavior. Implementation
stages must preserve the current boundaries until their scoped transition is
accepted. In particular, Provider failure normalization does not relax fallback.

AR-R1's bounded Provider round seam is delivered and accepted (COMPLETE / CLOSED).
`agent-runtime-v1.md` owns its failure compatibility; OBS-1 owns terminal evidence.
AR-R2 adds the accepted typed Application Capability Kernel:
Agent and MCP projections invoke one CapabilityExecutor, whose immutable registry
binds typed identities to handlers over existing Application services. Permission,
actual effect, execution status and output egress are separate semantics. Direct
calls still require Application authorization; projection exposure grants none.
Legacy Dispatchers parse/encode through projections and delegate to this typed
path. The kernel has no Provider/MCP/JSON Schema/UI dependency. W0/SPL references
are transient service-lifecycle references; retrieval uses transaction cache
evidence and retains its Provider-bound grant and final serialization gate.
Schema/B0 and formal W0 commit/SPL adoption authority stay unchanged.
AR-R2 and AR-R3 are accepted merged stages under AGENTS.md's historical
merged-stage rule. The retained Runtime facade delegates to concrete
Coordinator/Engine/Policy/Finalizer responsibilities; ToolExecutor invokes
receipt-bearing projections; transient canonical transcript groups retain
complete calls/results/receipts. Provider-private continuation remains separate,
unresolved executions never replay, and history prunes only whole units.
No transcript/receipt reaches storage or logs.

Accepted AR-R4 adds explicit source contributions in
`application/modules`: validate the complete dependency graph, register/freeze
one ApplicationCapabilityRegistry, validate/freeze Agent/MCP/finite UI surfaces,
then publish one immutable composition. The production list captures explicit
services for Study, Retrieval, MissingAnswer and StudyPlan. Registered Agent
projections own their guidance; source removal removes those runtime surfaces
while global migrations/readers/validators and B0 compatibility remain.
The current UI IA and exactly-six MCP v0 wire owner are retained. Generic turn
lifecycle/round execution, Provider protocol, permissions/effects, transcript,
W0/SPL business lifecycles, fallback and B0 package v2 stay unchanged. AR-R4
retained schema v31. Accepted AR-R5A adds schema v32
durable generated Proposal originals, review CAS, explicit local approval and
one-transaction typed Question/receipt persistence. It contributes internal
READ only, with no Agent/MCP/UI surface. External Host/IPC remains separately
governed. AR-R7 adds an independent Runtime constructor opt-in (default false)
for bounded READ answer continuation: complete canonical groups and executor-minted
Receipt proofs, fresh target release authorization, no STAGE/unknown/file-grant
replay, no repeated handler and no private Provider state transfer. The fallback
tool phase is closed, shared budgets/deadline are retained and Finalizer remains
the sole final Assistant writer. Agent Runtime v1 §4 owns this policy; default
AGENT-FB, MCP, external authorization and schema are unchanged.
Accepted AR-R5B (merged PR #245) adds module-controlled first-party Inbox/history,
structural typed Review/edit/Flush/CAS, explicit approval/rejection and Receipt
recovery. Its local authority uses one UUID in existing app_settings, separate
owner-scoped read sessions and target-confirmation Contexts, invalidated on restore
recomposition.
It changes no schema, Proposal codec, Receipt, B0 format or Agent/MCP permissions;
P2's historical Origin format remains a candidate. See
`docs/product/agent-refactor/generated-question-proposals.md`.
See `docs/product/agent-refactor/module-system.md` for its finite registration
and compatibility scope. AR-R4 was accepted and merged in PR #243 after
final-head standing CI and independent repair-review closure.

## 7. Evolution discipline

- Do not start another R0–R8-scale rewrite merely to add File Library, Project, Agent, MCP or RAG.
- Prefer additive, bounded stages around the stable typed core.
- Do not migrate source model, persistence, Project, Agent and UI in one stage.
- New cross-surface business capabilities should be introduced once in the application layer and reused by UI/Agent/MCP.
- RAG is a retrieval implementation behind File/Project/Agent concepts, not a separate user-facing knowledge-base domain.
- Historical compatibility code is removed only when its legitimate responsibility is proven obsolete; code is not retired merely because it is old.

The canonical project roadmap and current stage/status authority is maintained in `docs/architecture/shiroha-project-roadmap.md`.

## 8. Architecture document authority

Current-state authority, in order:

1. `ARCHITECTURE.md` — repository-wide dependency and boundary contract;
2. active focused contracts in `docs/architecture/` and `docs/product/` (for example MCP v0, F1 parsed-artifact lifecycle, typed-persistence contracts and focused product capabilities); the Agent refactor directory explicitly distinguishes frozen targets from active runtime authority;
3. ADRs for accepted post-P5 architectural decisions;
4. `docs/architecture/shiroha-project-roadmap.md` for stage ordering and deferred decisions.

Files explicitly marked **Historical baseline** describe how a migration was planned or characterized at that time. They must not override this current contract.

## 9. Secure credential storage boundary (S0)

S0 Secure Credential Storage is COMPLETE. Stage status: S0-P0 (canonical
contract), S0-D0 (core seam), S0-D1 (real secure adapter), S0-D2 (legacy
migration + production wiring), and S0-CL (closure) are COMPLETE. Production
activation occurred strictly at S0-D2; the following is current runtime truth.

Provider credentials (AI/OCR/Agent engine API keys) are never persisted in
SQLite as plaintext and are never a runtime SQLite fallback.

- The secure credential store is the sole credential authority, keyed by a
  stable `engine.<engineId>` namespace.
- SQLite stores non-secret engine metadata only. New metadata writes always
  scrub `api_key`; legacy plaintext may temporarily remain only as migrator
  retry input until migration DONE (plaintext = 0), and is never read by any
  runtime path.
- Runtime hydration reads the secure store only: missing -> incomplete,
  unavailable -> typed transient failure, corrupt -> typed hard failure.
- UI, Agent, MCP, and providers never access the secure store directly; all
  access goes through the bounded credential port/adapter and the repository
  seam.
- No cross-store atomicity is claimed; save/delete define explicit commit
  points, compensation, and reconciliation (see the S0 focused contract).
- Credentials never enter MCP/public/query/persisted DTOs, logs, or exports
  (including `.shiroha`). They may exist inside bounded runtime provider
  value/request types whose string/log representation is REDACTED.

See `docs/architecture/s0-secure-credential-storage.md`.

### Provider and Model Registry boundary (schema v24)

Schema v24 separates Provider credential identity, discovered models,
capability claims, and capability bindings. New AI configuration writes use
this authority only; retained `ai_engines` rows are migration/rollback
evidence, not a second write target. Existing `AiEngineProfile` consumers are
served through a temporary repository projection.

Provider identity is the stable `provider_id`, also used by the unchanged S0
key `engine.<providerId>`. Runtime adapter selection uses explicit
`provider_kind`, never Base URL inference. Capability resolution uses strict
source priority and an exact-key Shiroha registry; model-name heuristics are
forbidden. Binding changes are CAS-protected and fail closed for stale,
missing, unavailable, unknown, or explicitly unsupported models, except that
migrated `legacyPreserved` bindings may retain unknown claims.

See `docs/architecture/ai-config-provider-model-registry.md`.

## 10. Supplemental-answer matching boundary (P6)

P6-P0 froze the focused canonical contract in
`docs/architecture/p6-supplemental-answer-matching.md`; P6-P0 is docs-only
and COMPLETE, and P6-D0 through P6-V0 implemented the frozen contract and are
COMPLETE. The following durable boundary applies to the P6 implementation:

Current product availability: file-based supplemental answering (P6) is
shelved. The ordinary Answer Completion queue/detail exposes only
single-question AI answering (P7), with no source-picker or P6 review launch.
P6 services, dependency wiring, diagnostic entrypoint and offline tests remain
retained but are not ordinary product entries. This does not remove File
Library, normal document import, committed data, or shared Candidate/Review
and typed-answer persistence authority. Reopening P6 requires separately
authorized implementation and acceptance under its retained contracts.

- P6 consumes the current F1 `ParsedArtifact` explicitly through the
  Application lifecycle seam (`getCurrentArtifact(fileId)`), never sidecars,
  SQLite rows, or managed paths directly, and never an implicit
  ensure/reparse/OCR.
- The target scope is explicit: `QuestionBankScope(bankName)` |
  `ProjectScope(projectId)` | `ExplicitQuestionScope(ordered storageIds)`,
  paired with exactly one explicitly selected supplemental `LibraryFile`.
- Matching is deterministic only: no LLM, embedding, semantic model,
  edit-distance auto-write, filename inference, sequence-only match, or
  automatic pairing of files.
- `AnswerCandidate` is transient and binds `artifactId` + artifact
  `revision` + expected `QuestionDraftV2`; explanation and supplemental
  `SourceRef` remain Preview/Review-only.
- Any write happens only after explicit user confirmation and reuses the
  existing typed answer mutation authority (`TypedAnswerCommand` /
  `TypedAnswerPersistencePort` / `TypedAnswerPersistenceKernel`); P6 creates
  no second answer write protocol.
- Confirm revalidates the artifact generation and the full typed target in
  one caller-owned transaction (artifact + target stale CAS); any drift means
  `staleTarget` with zero mutation, and the atomic boundary may not be
  degraded to a non-atomic double check.
- P6 adds no schema change and no persisted candidate/provenance/explanation.
- The old paired/combined/automatic two-PDF merge remains permanently dead;
  `reference_answer_merger` and `multi_file_question_merge_service` are not
  P6 seams.

## 11. AI answer candidate boundary (P7-P0)

P7-P0 froze the focused canonical contract in
`docs/architecture/p7-ai-answer-candidates.md`; P7-P0 (docs-only), P7-D0a
(producer-neutral Candidate/origin), P7-D0b (generic review-decision core),
P7-D1 (bounded AI answer provider port + strict HTTP adapter / typed
output validation), P7-I0 (AI generation Application use case), P7-C0
(confirmation + transactional answer-only persistence), P7-U0
(minimal typed-question Presentation integration), P7-V0 (focused
validation / privacy / concurrency / acceptance), and P7-CL (canonical
closure) are COMPLETE; P7 v0 is CLOSED / FROZEN. The following durable
boundary remains frozen and applies to any future P7 extension:

- P7 adds exactly one capability: AI -> typed `AnswerCandidate` producer
  through `explicit action on one typed question -> safe-content admission
  -> bounded provider request -> strict normalization / typed validation ->
  unified transient AnswerCandidate -> shared fill/noOp/replace review
  semantics -> explicit confirmation -> existing
  TypedAnswerPersistenceKernel`. AI never owns direct formal answer write
  authority.
- P7 and P6 share one producer-neutral `AnswerCandidate` concept with a
  typed/sealed producer origin; no `AiAnswerCandidate`, AI-specific review
  entity, AI candidate/job table, or second review/confirmation system.
  The Supplemental origin keeps every P6 invariant
  (`supplementalFileId`, `artifactId`, positive `artifactRevision`,
  non-empty ordered bound `SourceRefs`, match evidence).
- P7 v0 is text/math only: provider input admission happens before any
  network request and admits only `TextNode` / `InlineMathNode` /
  `BlockMathNode`. Questions containing `RawFallbackNode`, depending on
  assets/images unavailable to P7 v0, or requiring silent content deletion
  yield `unsupportedQuestionContent` with zero provider calls and zero
  mutation.
- `singleChoice` AI Candidates contain exactly one existing option ID
  (singular provider schema); zero/multiple/duplicate/unknown options are
  `validationFailed`. `fillBlank` / `shortAnswer` use structurally non-empty
  `ContentAnswer`. No new question kind and no per-blank schema.
- P7 is answer-only: explanation is never requested as Candidate data, and
  provider-internal reasoning, if any, is outside the Application contract
  and must never be surfaced, persisted, logged, or used as formal answer
  authority (`reviewOnlyExplanation` stays `null`).
- Provider access flows Presentation -> Application use case -> bounded AI
  Answer provider port -> provider adapter; Presentation never calls the
  provider SDK, Domain never imports provider DTOs, and Repository never
  calls the provider. Raw provider responses are transient, strictly
  bounded, never logged/persisted/returned raw, and never placed into a
  Candidate.
- Any write happens only after explicit user confirmation and reuses the
  existing typed answer mutation authority; confirm revalidates the captured
  target (`storageId` + `bankName` + complete `QuestionDraftV2`) in one
  transactional CAS boundary; any drift means `staleTarget` with zero
  mutation, and late results of cancelled/superseded generations are
  discarded.
- fill/noOp/replace follow the frozen P6 semantics; P6 F1 artifact stale
  checking, complete target snapshot binding, review/session semantics,
  transactional CAS, and `TypedAnswerPersistenceKernel` authority are not
  weakened.
- P7 v0 never calls RAG, never reads File Library / Conversation
  attachments / Learning Space files, never reuses `RetrievalEgressGrant`,
  and never calls `retrieve_file_content`; MCP v0 stays exactly six
  READ_ONLY tools, A0 stays exactly six tools, and W0 is not a P7 workflow.
- P7 adds no schema change and no persisted candidate/generation state/
  provenance/provider request/result/review state; runtime schema was v21 at
  P7 closure. The current runtime is v34.

## 12. UI Finalization Presentation boundary

The user-authorized 2026-10-25 workspace exception in
`docs/product/shiroha-appearance.md` adds selectable mobile/computer-tablet layout.
Computer/tablet navigation exposes Home, Library, Learning Spaces, Today Training,
Banks, Assistant and Settings through existing capability owners. Its reference-led
Home restores a review-entry calendar and a separately labelled current-week
StudyActivity summary. Mobile retains the three-destination Home below. The
workspace exception supersedes only the global three-only/calendar-retirement
presentation clauses, not training, timing, persistence, Agent approval or MockExam
retirement. The new read-only dashboard projection composes existing queries.

The global Paper/Grayscale/Colorful styles with independent Light/Dark/System
display modes, legacy-preset compatibility and shared visual tokens are governed by
`docs/product/shiroha-appearance.md`. They share page structure and behavior;
no schema, application semantics or navigation hierarchy changes are implied.

The final Presentation / Navigation IA authority is
`docs/product/ui-finalization-ia-freeze.md`. The final primary navigation
is Today / Assistant / Profile (user-facing labels 今日 / 助手 / 我的),
and the original 普通 / 特训 / 考试 organization remains historical UI
Finalization v0 truth. The current unified Today dashboard and lightweight
single-plan detail are governed by `docs/product/today-home-refresh-freeze.md`:
ordinary new/due entries prepare separate typed-aware pools through an
Application launch port before opening normal Practice; plan selection/CAS
semantics remain unchanged. The 2026-10-06 amendment in
`docs/product/home-training-v3.md` §1.6 retires the Home calendar/duration
display and user-visible MockExam entry, retaining Activity timing, exam
implementation and historical data. The focused UI Finalization contract
governs only those Presentation decisions and does not alter any domain,
application, persistence, provider, or schema boundary recorded in this
document.

The current Practice presentation is governed by
`docs/product/practice-ui-refresh-freeze.md`: reading cards and fixed actions
preserve the existing typed/legacy, attempt, FSRS and preview boundaries.

## 13. StudyPlan boundary (SPL-1)

StudyPlan is a strategy/selection layer above the existing review/FSRS
semantics; it never schedules, never mutates review state, and never
deactivates itself. The Built-in Agent may stage a bounded plan draft through
the separate `propose_study_plan` capability; only explicit user adoption
through an Application command with a durable transaction-level
  compare-and-set may persist the single global `ActiveStudyPlan`. MCP v0
  remains exactly six READ_ONLY tools and the A0 read catalog remains exactly
  six tools. SPL-1-D1 introduced the v22 `study_plans` table; runtime schema
  was v24 at SPL-1 closure. ActiveStudyPlan durable singleton persistence exists;
  formal adoption
  remains Application-controlled; Agent planning and Assistant draft/adoption
  Presentation are implemented; Today / 当前计划 consumes the adopted plan through
  the deterministic `StudyPlanSelectionService` (live candidate pools,
  priority selection, dailyTarget cap, advisory states only), and 开始特训
  materializes the exact ordered selected storage IDs through the narrow
  non-preview Practice seam (never `PracticePage.initialQuestions`, which
  remains preview-only). SPL-1 StudyPlan Agent Tool v0 is CLOSED / FROZEN
  (P0–D0–D1–I0–U0–V0–CL COMPLETE; stage schema v22, v24 at closure;
  current runtime v34).

  The focused SPL-1 authority is
`docs/product/SPL-1 StudyPlan Agent Tool v0.md`.

## 14. Application data path boundary (DATA-PATH P1)

Durable runtime paths are owned by the application-support-based
`AppDataPaths` authority. Normal Debug/Profile runtime uses
`<Application Support>/Shiroha/development/`; Release runtime uses
`<Application Support>/Shiroha/production/`. Database, managed files, content
assets, parsed artifacts, logs, and B0 restore working state are composed from
that authority; they must not depend on `Directory.current`, repository roots,
or Git worktrees. Tests and isolated smoke entrypoints retain their existing
in-memory, temporary, explicit-file, and read-only profiles.

The focused current contract is
`docs/architecture/data-path-authority.md`. Legacy worktree-local data is not
automatically migrated by this boundary.

## 15. Review repair boundary

Review-time AI repair has two explicit strategies. Structural question issues
retain the bounded question-level JSON proposal flow. A pure
`latex_unrenderable` issue uses the fragment-level flow frozen in
`docs/architecture/review-repair-v1.md`: Application-owned snapshot alignment
identifies one exact typed math node, a dedicated bounded provider port returns
only a replacement LaTeX fragment, and local validation plus the existing
review CAS remain authoritative.

Presentation and renderers never own fragment identity. Fragment repair never
falls back to question-level rewriting, provider reasoning, retry, or expanded
context. The accepted fragment is persisted only as bounded digests and a
typed node locator; no prompt, LaTeX source, provider body, or reasoning is
stored. This boundary adds no database schema or dependency change.

## 16. Photo answer boundary

Practice fillBlank / shortAnswer photo answers use Application-owned direct
Vision judgement and explicit user confirmation before managed image ingestion
and AnswerAttempt append. Text answering remains available; question-import OCR
is unchanged. Student images are soft evidence references, not RichContent or
FSRS grading authority. See `docs/architecture/photo-answer-v1.md`.
## Answer Completion v0 — CLOSED / FROZEN

`docs/architecture/answer-completion-question-sets.md` is the canonical design authority for the Answer Completion / `ImportedQuestionSet` capability.

The design keeps Presentation behind Answer Completion Application services, preserves `PersistedQuestion.storageId` as Question identity, reuses existing P6/P7 answer mutation authority, and makes the existing task-bound `QuestionRepository` transaction the only import transaction owner. `LibraryFile`, `ParsedArtifact`, and `ImportTask` do not become QuestionSet identity.

**ANSWER-COMP-D1 implemented this relation as the additive v28 schema; the current runtime is v34.** The `imported_question_sets` / `imported_question_set_items` tables, their constraints, the bank lookup index, and the required relationship triggers exist and are strictly validated, while historical questions remain ungrouped.

Seed capture, the QuestionRepository-owned atomic set/member writer with per-document dispatch, the Answer Completion read projection, the queue/detail Presentation, and set-scoped P6 plus single-question P7 activation are implemented. ANSWER-COMP-P0, ANSWER-ENTRY-GUARD, D0/D1/B0, I0a/I0b/I0c, Q0/U0/P6/P7, V0 and CL are COMPLETE; Answer Completion v0 is CLOSED / FROZEN. These durable boundaries apply:

- The task-bound `QuestionRepository` transaction stays the only writer of Questions plus set/member rows; historical questions stay ungrouped and are never backfilled.
- The queue/detail projection is read in one short transaction. Presentation consumes that projection only, so counts, eligibility and set category are never composed from independent repository reads or re-derived in widgets.
- The retained, shelved P6 binding resolves complete set membership as a full-set `ExplicitQuestionScope` and revalidates it when the supplemental session binds; the existing P6 review and typed-commit authority is reused, and no second answer write path is added. Opening set detail currently exposes P7 only.
- Single-question AI answering reuses the existing P7 generation/review/commit boundary through a transient surface where dismissal is zero mutation.
- This stage adds no schema beyond v28, no persisted candidate or generation state, and no new provider call site.
- Source-file deletion, artifact replacement/removal, task cleanup and folder moves preserve committed set identity and membership. Answer/content edits preserve membership and review state; query counts reflect current typed answers, including explicit-empty as answered. Question deletion or bank movement removes membership, and the final removal deletes the empty set.
- B0 preserves set identity and ordered membership while treating provenance as soft evidence; strict v28 schema/trigger and relationship validation remains mandatory. V0/CL adds no production mutation path and does not activate typed-admission R1, stable bank identity, batch AI or RAG-2.

## Home Training V3 — configuration, launch, Activity and TaskCenter backend implemented

`docs/product/home-training-v3.md` freezes
`SHIROHA-HOME-TRAINING-IPF-V3` as the planned successor to the current
Today/Home and ordinary-training configuration contracts: Category-driven
TrainingContent configuration (Category → TrainingContent → ordinary
new-question pools, Category-scoped due review pools), Today/Home v2, durable
StudyActivity timing, ImportTask attempt event timestamps, and a TaskCenter
Application facade. P1a Domain values and P1b Application contracts exist;
P1c implements additive v29 TrainingContent persistence; P4b implements additive
v30 StudyActivity persistence. B1 implements additive v31 ImportTask event
timestamps and the TaskCenter Application backend.

Runtime schema is v34; the v31 event contract is retained. The three configuration tables and independent
`app_settings.current_training_category` use canonical CategoryKey encoding;
the upgrade transaction seeds only the eligible old current bank once, without
changing learning data. B0 includes configuration and validates bindings,
weights and references before restore swap, retaining invalidated bindings and
unavailable-but-existing current content. There is no bank foreign key or new
bank registry. P2a implements the read-only TrainingCatalog and TrainingContent
queries plus atomic create/update/delete, separate preference CAS, current
selection and Category Visual writes through TrainingConfigurationRepository.
Application projects usability from the captured catalog and resolves
deterministic runtime fallback without persisting it. All admission and CAS
checks run in the writing transaction and reuse the v29 ordinary-bank eligibility
adapter. Deleting configuration preserves learning data and advances a referencing
preference's independent revision while clearing only its current content.
P2b maintains persistent binding invalidation through one caller-transaction
final-state helper. Single/bank deletion, legacy/preview bank movement, folder
updates (including import/batch folder writers), and clear-all invalidate only
valid relations when the final bank is missing, ineligible or in another Category.
Each affected content revision advances once per reconciliation pass; weights,
preferences and persisted current references remain unchanged. Temporary
delete/replace with a legal final bank does not invalidate. Drift inherited from
P2a (a valid relation whose bank was already missing, ineligible or moved) is
reconciled by a narrow same-transaction preflight pass in writers that can
recreate or re-map a bank; there is no startup sweep and no schema change.
Same-name recreation,
move-back, reads, startup and migration never restore a relation. The explicit
rebind command revalidates content CAS and fresh bank admission, restores only the
target member and advances the content revision atomically. P2b added no schema change.
P3a adds read-only bounded selection through ReviewRepository and the narrow
TrainingQuestionSelection Data seam. Domain TrainingAllocation caps initial
quotas and refills shortages with original positive weights and Largest
Remainder; zero weights never count or refill. A caller-injected Random owns
both ordered ID-window offsets (at most two per positive bank) and final
distinct-ID shuffle. Counts, windows and exact typed materialization share one
read transaction. Home batches are immutable and capped at 100; Category review
independently admits all ordinary eligible real banks, sorts due state>0 IDs by
next review time then storage ID, and caps at 40 without randomness. Existing
QuestionV2PersistenceMapper remains the union decoding authority through a
shared transaction-bound exact materializer; Home requires ReviewState and
selection-predicate consistency, while StudyPlan retains its 200-ID semantics.
Missing/unsafe/corrupt selected rows fail the entire batch with no replacement.
No learning/configuration state, queue, cache or schema is written. SQL OFFSET
can scan metadata; returned-row bounds do not imply constant query cost or
uniform subset sampling, and the existing bank-name index may be absent on a
fresh DB until the historical catalog writer has created it.
P3b implements DefaultTrainingSessionApplicationService behind the existing
Application launch contract. New training admits the exact contentId/revision
through a transaction-bound configuration reader shared with configuration CRUD;
parent, members, eligibility, live NEW counts/windows and typed materialization
use one short read snapshot. Deleted/revised targets return staleConfiguration;
valid empty pools return empty; malformed/admission/storage failures return
unavailable. Category review captures one injected clock value and remains
independent of TrainingContent. Only a complete successful batch calls the
existing initPreparedStudySession seam once, after the read transaction ends,
preserving exact P3a order; every failed preparation leaves the old queue intact.
RNG is injected per new launch. No launch writes learning/configuration state or
adds a durable queue. CP2-T implementation is complete.
Legacy bank-scoped and StudyPlan launchers remain independent. Home/Today
activation is implemented by B4; TaskCenter Presentation is implemented by B5;
ordinary Practice composition uses the prepared session with normal
attribution, while StudyPlan retains focused attribution and its 200-ID bound.
P4a implements the pure StudyActivity lifecycle/time core. Application's
StudyActivityTransitionEngine proposes an immutable single-owner state,
existing lifecycle snapshot and confirmed segment drafts; publication belongs
to the caller, after atomic persistence. Four explicit scenes are
admitted; the definition-only fifth scene and runtime interruption reasons
remain rejected. Pause/resume check both owner identities, repeated pause/resume
are no-ops, and ended proposals release the owner and reject later events.
Injected coherent monotonic/wall samples and immutable local calendar mappings
own time input; confirmed duration comes only from integer monotonic deltas.
Domain splitting walks actual local-midnight/offset-transition UTC intervals,
including multi-day and 23/25-hour DST days, emitting local date and observed
offset with deterministic sequences. An explicit source mapping revision marks
observed wall/zone changes: elapsed until observation keeps the old mapping,
subsequent anchors use the new one, and no unobserved change instant is guessed.
Invalid samples/splits produce safe failures without partially advancing state.
No IANA ID/package, duration total cache, timer, queue payload or platform object
is introduced.
P4b implements StudyActivityPersistence as an Application port and
StudyActivityRepository as the Data adapter. V30 stores sessions and immutable
segment facts, with soft context references and a segment-to-session cascade;
there is no owner token, queue, cumulative-duration cache or persisted quality.
PersistentStudyActivityService serializes immutable P4a proposals, captures event
time before awaiting prior writes, and publishes owner/state only after a short
gated transaction commits. Exact checkpoint replay is idempotent; conflicting
segment facts and stale/terminal append fail without partial writes. Failed
recording stops that session's attribution and marks process-local quality partial;
exit still releases the local owner. Explicit startup recovery closes active/paused
residue at its last successful checkpoint without estimating elapsed or restoring
an owner. B0 closes only the snapshot copy as snapshotInterrupted, preserves facts,
and rejects malformed or nonterminal portable Activity before swap. Weekly reads
sum persisted local-date segment durations for seven Monday–Sunday dates, using an
injected current local date; read failure remains unavailable. P4b is merged via
PR #224, and CP2-A is PASSED after independent T3 verification and fresh review.
Runtime is v34. B3 implements Practice/MockExam Activity wiring and production
composition. A composition creates one PersistentStudyActivityService after B0
startup recovery and DB readiness, attempts Activity startup recovery before
exposing routes, and injects the same service/query through a dependency scope.
Restore recomposition creates a fresh service and disposes the old route scope.
Practice launchers supply explicit ordinaryPractice/studyPlanPractice descriptors;
the prepared Category review seam accepts categoryReview without inferring it
from AnswerAttempt attribution. Preview does not begin Activity. A shared route
binding owns opaque route tokens, bounded 30-second checkpoint scheduling,
background/temporary-cover pause and same-owner resume, plus single-shot
queueFinished/submitted/exited dispatch. Exam submitted follows durable submission
success only; failed submit resumes and permits retry. Activity failures never
gate answering, grading, navigation or background exam grading.
The system adapter supplies Stopwatch elapsed and observed system local-date /
offset boundaries as immutable calendar facts, including offset transitions.
Within a continuous mapping revision, UTC advances exactly by confirmed
monotonic elapsed; raw wall observations establish an anchor only on a new
revision. Wall/zone observations change revision without rewriting old samples;
out-of-horizon attribution fails unavailable rather than consulting changed
calendar rules. No timezone dependency or schema change is introduced.
PR #232 is merged, so B3/I1 is historical accepted delivery under the merged-PR recovery rule. Home V2 composes the
TrainingContent ports, prepared ordinary launch and this Activity query. PR #234 is
also merged, so B4/I2 is current runtime truth. B5 implements TaskCenter UI/I3
production injection, completing the CP3 composition surface; final acceptance
still requires current-target CI and independent review.
B1 delivers P5a/P5b together. ImportTask adds three nullable UTC-second columns
with no historical backfill. TaskManager owns accepted-attempt started/parsed/
failed times and retry resets; repeated running does not refresh started time.
Current-attempt transitions compare the previous durable snapshot inside one
transaction and UPDATE only; stale callbacks do not recreate a missing task or
overwrite committed review/completion. JSON formatting is not an identity change.
QuestionRepository remains the formal completedAt transaction owner.
TaskCenterFacade is an infrastructure implementation of the immutable Application
query/command/file-selection contracts, keeping mutable tasks, diagnostics and
source locations private. Commands revalidate exact nullable attempt/trace/review
identity and current eligibility. Completed cleanup uses an immutable issued
snapshot, the existing cleanup reservation/write tails/commit leases, and a
transaction-bound exact target check. It deletes only still-eligible completed
snapshot members, preserves new/changed/busy records and all learning/source data,
and removes memory projections only after durable success. The legacy UI cleanup
API remains a compatibility path, not the new completed-only command authority.
Retry emits a picker request without mutation; selected input stays ephemeral in
the ingestion adapter and revalidates again at accepted retry. Review emits only
an exact navigation target; the composition bridge retains existing review CAS.
B0 retains package v2, migrates staged schema to v34 and continues to scrub all
ImportTask rows including event times. P5a/P5b and CP2-I implementation are complete;
B1 / CP2-I has been independently accepted and merged. B5 activates TaskCenter
UI and I3 through one TaskCenterFacade shared by query, command and selected-source
retry. Home's parse entry/badge uses the same injected safe query; the screen and
controller consume immutable Application DTOs only. The controller serializes
bounded visible-route refreshes, rejects stale/disposed publication, preserves
captured command/cleanup targets and never auto-replays stale actions. Event
times use the exact event kind and system local conversion, with no legacy
timestamp substitution. Legacy `文档解析任务:` titles are corrected only in the
safe read projection, without rewriting stored titles. FilePicker input stays
ephemeral inside the picker/ingestion compatibility boundaries. TaskCenter V2
uses the Today gray palette and a separate read-only detail sheet. Its narrow
detail query whitelists a bounded current-attempt opaque Trace ID and recorded
start-to-publication duration; it never returns a command target, attempt token
or raw diagnostics. Missing/untrusted facts stay null, and only an explicit copy
tap writes the safe ID to the clipboard. Duration uses validated current-attempt
startedAt/parsedAt wall-clock events, without lifecycle/schema changes or legacy
elapsed inference; the UI labels its recorded-event basis. The review
bridge validates the exact nullable attempt/trace/review identity and eligibility
again immediately before constructing existing ImportStaging inputs and pushing
the route. The historical task_center_projection helper remains for compatibility
tests only. Global schema is v34; accepted AR-R5A owns the retained v32 Proposal schema; PlanConfigScreen retirement and CP4 remain for B6.

B2 implements injectable Training Config list, shared selector/editor and
Presentation controller through Application ports. A single read transaction
returns the complete configuration snapshot, retaining empty custom Categories
and unavailable configurations after their banks disappear. Category Visual
presets are Category-wide preference values, separate from content revisions.
Draft weights and ideal quotas reuse Domain TrainingAllocation. Cancellation
writes nothing; a separately confirmed rebind commits immediately and is clearly
identified as independent of unsaved edits. Content and visual saves use separate
CAS and report partial success without retry or fictitious rollback. Category
reorder validates the complete captured ordered content/revision set and applies
dense ranks atomically; only changed rows advance revisions, with no member or
preference writes. Stale or failed moves leave no partial ordering changes.
Controller generation/dispose guards reject late loads, and busy state prevents
overlapping UI mutations. Configuration CRUD never changes learning facts.
Home/config production composition is now wired by B4/I2; the legacy
PlanConfigScreen remains for compatibility pending B6 retirement. B2 implementation was merged by PR #230 with standing
PR CI success. PR #230 is merged, so B2 is historical accepted delivery under the current
merged-PR recovery rule. Runtime schema is v34; accepted AR-R5A owns the retained v32 Proposal schema.
TodayTrainingQueryAdapter captures one clock observation and injected local-day
boundaries, then TrainingConfigurationRepository reads catalog, configuration,
selection and counts in one read transaction. It reuses the shared eligibility,
visibility/order and Application fallback projection without preference writes,
sampling, materialization or ReviewState creation. NEW counts include only
positive-weight members; Category due review counts are independent and uncapped;
relation summaries include 0% members and distinct local-day ReviewLog Questions.
TodayController rejects old generations, separates week and training failures,
and uses exact preference CAS for settled Category selection and ordered usable
content cycling. Stale commands reload without replay. Home consumes Application
facts through Category pages and a folded corner; the 2026-10-06 Home UI
amendment retires its seven-day Activity view without removing the query or
durable recording capability.
Only ready launches open the prepared normal Practice route with explicit
ordinaryPractice/categoryReview context; the shared guard spans preparation and
the route lifetime. Home opens the existing B2 configuration page, refreshes on
return/reactivation/resume. Parse/configuration/create-import actions live in
the header; the user deferred the production Home member-bank detail entry
to a later configuration-page redesign, retaining its underlying capability.
Other secondary entries and the real singleton StudyPlan remain.
Production Home no longer consumes bank-scoped TodayContextQuery or
PlanConfigScreen; their compatibility callers are retained.
StudyPlan and TaskCenter boundaries above remain current truth. StudyPlan remains the single global ActiveStudyPlan and stays
independent of TrainingContent. Delivery order, prerequisites and durable current
state live in `docs/product/home-training-v3.md`; bounded execution packages are
temporary PR/context artifacts, and Git/PR/CI/Reviewer owns exact execution history.
