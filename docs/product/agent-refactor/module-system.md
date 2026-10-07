# Source-level Module System

Status: **FROZEN target contract; not implemented by AR-R0.**

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
