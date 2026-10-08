# Agent Runtime v1 / External Agent / MCP vNext Contract Index

Status: **FROZEN target architecture; AR-R1/AR-R2/AR-R3 COMPLETE / CLOSED;
AR-R4 module contribution kernel COMPLETE / CLOSED; AR-R5A IMPLEMENTATION CANDIDATE.**

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
as an implementation candidate at schema v32 with B0 package v2. External
Host/IPC, MCP vNext and READ fallback continuation remain unimplemented targets. Current product behavior
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

Only these bounded implementation choices remain open: context TTL value
(15 minutes is a candidate, not a frozen product limit), actual local IPC
transport and platform packaging/minimum supported Codex version. AR-R6A/AR-R9B
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
