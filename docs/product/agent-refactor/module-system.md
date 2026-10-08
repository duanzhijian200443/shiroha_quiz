# Source-level Module System

Status: **FROZEN contract; AR-R4 COMPLETE / CLOSED.**

AR-R4 was accepted and merged in [PR #243](https://github.com/duanzhijian200443/shiroha_quiz/pull/243)
after final-head standing CI and independent repair-review closure.

Authority/activation: [index](README.md). This contract applies repository-wide
to the source-level modular monolith, not just Assistant modules.

## 1. Core versus features

Core contains typed Question/answer/option/PersistedQuestion semantics,
RichContent/codec/admission, capability/permission/effect foundation,
persistence transaction/schema/recovery compatibility infrastructure,
safe diagnostics, minimal settings/config and App Shell composition lifecycle.

Core does not collect all repositories, controllers, prompts or Proposal kinds.
Conversation belongs to Assistant; Question query UI belongs to Question.
Study, Retrieval, StudyPlan, GeneratedQuestion and MCP are feature/adapter
modules. Required dependencies must be explicit; not every feature is removable
while a registered dependent still requires it.

## 2. Minimal contribution contract

ModuleContribution identifies the module and requiredModuleIds and has four
optional registration callbacks: capabilities, UI, Agent projection and MCP
projection. Each receives only its finite typed registrar. Services/ports are
explicit module constructor inputs captured during composition.

The descriptor is composition-only. It must not become a runtime module-to-module
API (`otherModule.service`), global AppContext, service locator, reflection
discovery, DI container or hook DSL. Registrars cannot resolve arbitrary services.
Module is not Tool; capability is not MCP Tool.

UI contributions use finite shell slots and module-owned artifact presenters.
Default registration preserves current IA and behavior; a source fork can
explicitly change the enabled contributions rather than editing scattered UI
flags. MCP SDK conversion stays under `lib/mcp/**`.

## 3. Deterministic registration

Use an explicit module list. Validate IDs/dependencies, topologically order
modules with id-sorted ties, register all capabilities, build projections and
then freeze. Missing dependency, cycle, duplicate module/capability/projection/UI
key or a projection referencing an absent capability fails before UI/Host/MCP
publication. There is no automatic repair or module download.

Only requiredModuleIds is needed; no semver dependency solver. Runtime
hot-loading, DLL/ZIP plugins, script evaluation and binary sandbox are excluded.
Compiled module code is user-trusted code. External Agent input remains
untrusted and gains no permission from that compile-time trust.

## 4. Feature contribution and storage compatibility

**Running a feature is optional; supporting its published stored data cannot
disappear with the feature switch.**

Unregistered features contribute no UI, Agent tools/guidance or MCP surface.
Disabling/removing them does not DROP tables or delete user data. Remove required
consumers explicitly or fail composition; do not silently repair the graph.

Storage compatibility is separate retained source code: migration history,
strict codecs/readers, schema/relationship validators and backup classification.
It remains available during feature disable and source removal. A source fork
may remove the runtime contribution while retaining this small compatibility
package. Removing compatibility itself requires a separately designed storage
support transition; unknown published data cannot be skipped or treated as valid.

Storage initialization/recovery precedes module runtime publication. Feature
enablement cannot decide whether a published global migration or validator runs.
One SQLite database and its upgrade authority remain; no database-per-module or
runtime module migration discovery is introduced.

## 5. Directory migration

Start with existing layer directories and module composition/contributions.
New feature code has explicit feature ownership and can gradually use vertical
domain/application/data/UI subdirectories. No whole-repository feature-first
move is required. Directory symmetry cannot relax dependency gates, especially
MCP SDK confinement. Modules do not call a composition root for services.

## 6. Hard acceptance and rollback

AR-R4 must prove missing/cycle/duplicate failure, deterministic registration,
disabled UI/Agent/MCP/prompt absence and no changes to the generic loop/Provider
when adding a fixture module. Adding/removing a module and declared consumers
changes the explicit composition list, not scattered tool/prompt/UI switches.

Existing data -> disable -> restart -> backup/restore -> re-enable must retain
valid data under storage validation. Disabled features cannot bypass schema or
corrupt-payload failure. GeneratedQuestion/MCP additions in AR-R5/AR-R6 exercise
this with real feature boundaries. Rollback hides contributions, retains storage
compatibility, and never loads an incompatible older binary after schema upgrade.

## 7. AR-R4 implementation boundary

`application/modules/module_composition.dart` implements `ModuleId`,
`ModuleContribution`, four finite registrars, `ModuleComposer`,
`ModuleComposition` and safe typed `ModuleCompositionException` failures.
Module IDs and projection/UI keys are explicit lowercase source tokens of
1..64 characters (`[a-z][a-z0-9_]*`). Required dependencies are immutable;
duplicates within the dependency list are invalid contributions.

Composition validates the entire graph before invoking callbacks. It consumes
each complete eligible topology layer in ModuleId order, registers all
capabilities into the retained `ApplicationCapabilityRegistry`, freezes that
phase, builds projections against its one executor, and returns one immutable
composition only after every phase succeeds. Registrars close on both success
and failure and cannot mutate the frozen result when retained by a callback.
Callback exceptions become `invalid_module_contribution` without exception text.
Agent/MCP bindings match both capability identity and input/output types.

The fixed failure codes are `duplicate_module`, `missing_dependency`,
`dependency_cycle`, `duplicate_capability`, `duplicate_agent_projection`,
`duplicate_mcp_projection`, `duplicate_ui_key`,
`projection_missing_capability` and `invalid_module_contribution`.
There is no partially returned UI/Agent/MCP surface on failure.

`production_modules.dart` owns the explicit production list: `study`,
`retrieval`, `missing_answer`, `study_plan`. They capture already constructed
Application services/ports. They currently require no other runtime module:
their service dependencies are explicit constructor inputs, not fake Core
contributions. Composition order is `missing_answer`, `retrieval`, `study`,
`study_plan`; each registry preserves that deterministic registration order.

The Agent adapter separately retains the accepted Provider catalog order:
six Study reads, W0, StudyPlan, then granted Retrieval. Explicit projection
`exposureOrder` values preserve that wire-facing order; ties preserve registration
order. Guidance remains in deterministic registration order at finite prompt
slots, preserving the accepted prompt byte for byte with the default list.
Retrieval exposure/guidance additionally requires its existing per-turn grant.
Its narrow effective-file callback and serialization gate retain recipient,
current-file, source-turn and cancellation checks. Only the current single file
egress projection is supported; multiple egress projections fail composition.
Neither registration nor visibility grants Application permission.

The Runtime facade accepts a frozen `AgentSurface`; its old Dispatcher constructor
arguments remain a compatibility bridge. A surface and legacy Dispatchers cannot
be combined. Built-in Agent projections are limited to READ and STAGE: composing
any other projection permission fails with `invalid_module_contribution`, and the
Runtime independently rejects such a surface. Module registration or projection
visibility never grants COMMIT/DESTRUCTIVE authority; that authority remains
exclusive to explicit formal-approval contexts. Adding a synthetic read changes
only its contribution/list, and
the same generic loop executes it with typed receipts and one final Assistant
append. Existing W0/SPL presentation events remain the retained bridge; their
lifecycle, approval commands and fallback barriers do not change. AR-R8 owns
any later artifact/controller decomposition.

MCP contributions are typed capability/key descriptors. The v0 converter under
`lib/mcp/` accepts exactly the six retained Study bindings or no surface; an
absent Study MCP contribution produces no server. SDK schemas, annotations,
stdio and result encoding stay in their existing adapter owners. Other feature
modules contribute no MCP tools. Future profiles need their own adapter contract.

UI registration is limited to `workspaceAction` and `assistantArtifact` shell
descriptors with explicit unique keys. The production list currently contributes
no UI descriptors and keeps existing hardened IA/presenters. Synthetic fixtures
exercise registration/removal and duplicate-key failure; this stage introduces
no Widget registry, route DSL or navigation rewrite.

Global storage and B0 recovery initialize before module publication. No module
has a migration callback. StudyPlan's published durable data is the storage
compatibility fixture: enabled -> disabled -> close/reopen -> strict reader/schema
validation -> real B0 export/restore -> re-enabled retains its data and schema.
The same B0 admission rejects corrupt StudyPlan data with the runtime contribution
absent. AR-R4 retained schema v31, package v2, credential exclusion and storage owners.
The new contract tests run as hard-failing standing PR suites alongside existing
Runtime, fallback, capability, MCP and B0 regressions. No AR-R5/R6/R7/R8 feature
was activated by AR-R4.

AR-R5A is an implementation candidate at schema v32. Production composition
explicitly supplies GeneratedQuestionService after global database readiness;
the optional source contribution has one internal typed READ and no Agent, MCP
or UI descriptors. Its dedicated stage/review/approval commands do not grant
external access. Removing/ disabling the contribution retains the five Proposal
tables, strict codec/shape/data validators, historical readers and B0 INCLUDE
classification. Migration and validation remain mandatory without the module.
Pending working edits and terminal receipts survive restart/export/restore and
re-enable; corrupt retained data fails admission with the contribution absent.
