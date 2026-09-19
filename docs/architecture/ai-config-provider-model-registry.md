# AI Config Provider + Model Registry — Canonical Foundation Contract

Status: **Canonical authority — schema v25 model-origin and binding-policy
foundation implemented**.

This document defines the durable AI configuration authority introduced by
PR-A. It covers Provider identity, Model Registry, capability claims and
capability bindings. It does not define the Profile UI, expand Agent transport
support, or authorize real-provider calls during acceptance.

## 1. Authority and dependency boundary

```text
Presentation / Built-in Agent / AI consumers
                    -> Application services and ports
                    -> Domain contracts

SQLite + secure credential adapter + provider HTTP adapter
                    -> Application ports
```

SQLite is accessed only by data infrastructure. Provider protocol details are
confined to explicit provider adapters. Credentials cross only the bounded S0
repository/runtime seam and never enter query DTOs, logs, SQLite, backups, or
Presentation.

The Provider / Model Registry is the single model-asset authority. Capability
bindings and future Agent configuration are consumers that only reference an
existing `model_ref`; neither may create Provider or Model assets. Custom
model creation belongs to Provider management — never to a capability picker
or any other consumer screen.

## 2. Durable identities and schema v24

Schema v24 adds four tables:

- `ai_providers`: stable `provider_id`, explicit `provider_kind`, display
  metadata, endpoint, revision, readiness, and safe connection/sync status.
- `ai_models`: stable `model_ref`, owning `provider_id`, exact canonical model
  id, display metadata, availability, explicit `origin`, and discovery
  timestamps.
- `ai_model_capability_claims`: one support claim per model, capability and
  source.
- `ai_capability_bindings`: one CAS-protected binding for each of
  `textModel`, `imageUnderstanding`, and `documentRecognition`, including the
  existing parsing-side tuning values.

Provider identity is only `provider_id`. Provider kind, Base URL and display
name are not identities and never cause automatic merging. The canonical model
id is case-sensitive and is never normalized or inferred from a display name.
Empty, boundedness-violating, control-character, or surrounding-whitespace
model ids are invalid.

Provider kind is one of `deepseek`, `zhipu`, `gemini`, or
`openai_compatible`. Runtime adapter selection uses this stored kind; Base URL
is only an endpoint. URL classification exists only as the frozen one-time
legacy migration rule. In the product UI, `openai_compatible` may be
presented under the label “自定义模型提供商”: it reuses the existing
OpenAI-compatible adapter to connect a provider that Shiroha does not preset.
This is a presentation label only and implies no protocol support beyond the
existing OpenAI-compatible adapter contract; no additional
`AiProviderKind` value is introduced for it.

### 2.1 Model origin authority (v25)

`ai_models.origin` is the explicit, persisted origin authority with exactly
four values: `providerCatalog`, `curated`, `userDefined`, and the
migration-only `legacyImported`. Origin is written only by explicit events
and is never inferred at runtime from model name, prefix, display name,
provider kind, or Registry hits. Catalog presence is not capability
evidence, and capability evidence is not origin.

- `providerCatalog`: created and owned by a successful Provider `/models`
  refresh. Refresh may update it or mark it `unavailable` when the catalog
  stops returning it.
- `curated`: materialized by Shiroha for exact special models owned by an
  explicit production contract (currently `zhipu` / `glm-ocr` via
  `layout_parsing`). Provider refresh never creates, updates, or tombstones
  curated rows, and a missing catalog entry never retires them.
- `userDefined`: created by explicit user confirmation (custom model add or
  re-confirmation). Provider refresh never creates, updates, tombstones,
  deletes, or re-identifies these rows.
- `legacyImported`: the deterministic migration-only classification for v24
  rows whose origin cannot be losslessly reconstructed. It is never exposed
  as a user-facing product type and is never tombstoned by refresh. It
  converges only through explicit events: a refresh exact hit promotes it to
  `providerCatalog`, and an explicit user confirmation re-classifies it as
  `userDefined`.

## 3. Capability authority

Capabilities are `textInput`, `imageInput`, `textOutput`, `reasoning`,
`toolCalling`, `ocr`, and `embedding`. Claims are `supported` or
`unsupported`; absence is `unknown`.

Resolution priority is strict:

```text
providerOfficial
> exact-key shirohaRegistry
> userDeclaration
> capabilityProbe
> unknown
```

The Shiroha registry is keyed only by exact `(providerKind,
canonicalModelId)`. Model-name substring, prefix, suffix and display-name
heuristics are forbidden. A conflict within the same source is `dataCorrupt`,
not last-writer-wins.

Required binding capabilities are:

- text: `textInput + textOutput`;
- image understanding: `textInput + imageInput + textOutput`;
- document recognition: `ocr + textOutput`;
- Agent: `textInput + textOutput + toolCalling`, followed by a separate Agent
  transport compatibility decision. `reasoning` is descriptive, not required.

Binding updates use expected revision/CAS. A stale confirmation, cancel,
missing model, unavailable model, missing Provider, or explicit unsupported
required capability yields zero binding mutation. Unknown required
capabilities no longer block a binding: the user may deliberately select a
model whose required capability evidence is `unknown`, and such a binding is
persisted as `userSelectedUnknown`. `verified` is written only when every
required capability has `supported` evidence. Unknown capabilities are never
rewritten to `supported`, and selection never creates synthetic
`providerOfficial`, `shirohaRegistry`, or `capabilityProbe` claims.
`legacyPreserved` is reserved for migrated legacy bindings and is never
written for new user selections. Resource-package, quota, entitlement,
authentication, and rate-limit failures are runtime invocation errors and
never produce capability claims or `unsupported` evidence.

## 4. Credentials and Provider mutation

S0 remains the credential authority. Its key is unchanged:
`engine.<providerId>`. Provider reads expose only
`present | missing | unavailable`; plaintext is a bounded runtime value only.

Create requires `replace(secret)`. Update accepts `preserve` or
`replace(secret)`. Save/delete retain the S0 credential-first, metadata-second
commit point and its compensated, normalized and partial-failure outcomes.
Deleting a Provider referenced by a capability binding or Agent main/fallback
profile fails as `providerInUse` before credential mutation.

## 5. Migration and legacy projection

The additive v23-to-v24 migration runs inside the existing DatabaseHelper open
transaction:

1. each `ai_engines` row creates one Provider with the same id; rows are never
   merged;
2. each valid non-empty legacy model id creates one Model with
   `model_ref = engineId`;
3. incomplete/invalid legacy records remain `legacy_incomplete` without an
   invalid Model;
4. active text/image/OCR choices become `legacyPreserved` bindings using the
   existing explicit-setting, matching-active, then compatible-global order;
5. `engine_type` creates no capability claim;
6. Agent main/fallback ids remain unchanged and continue to resolve because
   migrated model refs retain engine ids.

The retained `ai_engines` table is read-only migration/rollback evidence after
v24 activation. New writes use only the v24 authority. `AiEngineRepository`
remains a temporary runtime projection from binding + model + Provider + S0
credential so OCR, AI Repair, LaTeX Repair and subjective-answer consumers do
not require a simultaneous public API rewrite. The legacy settings UI also
writes through that adapter into v24; there is no dual write.

Removing `ai_engines` requires a later explicit package after legacy UI
retirement, consumer migration, independent Agent model-ref ownership, and
B0/S0 approval.

### 5.1 v24 to v25 migration

The additive v24-to-v25 migration runs in the same open transaction:

1. `ai_models` gains `origin TEXT NOT NULL DEFAULT 'legacyImported'` with a
   CHECK constraint. v24 persisted no origin and its discovery timestamps and
   claims cannot reconstruct ownership, so every pre-existing row
   deterministically becomes `legacyImported` — no classification is guessed;
2. exact curated entries are re-classified `curated`; for each `zhipu`
   Provider, `glm-ocr` is materialized `curated` + `available` with a
   deterministic `model_ref`, because the production `layout_parsing`
   contract owns it independently of `/models`;
3. `ai_capability_bindings` is rebuilt with `userSelectedUnknown` added to
   the `validation_mode` CHECK; existing rows and their stored modes are
   preserved unchanged;
4. open-time validation requires the origin column and the extended CHECK;
   Dart enum and SQLite CHECK are upgraded in the same change.

## 6. Discovery, tombstones and Agent compatibility

A successful sync transactionally owns only `providerCatalog` rows: it
upserts the returned exact model ids (stamping `origin = providerCatalog`,
which promotes exact-hit `legacyImported` rows), refreshes their
`providerOfficial` claims, and marks only `providerCatalog` rows that the
catalog stopped returning as `unavailable`. `curated`, `userDefined`, and
`legacyImported` rows are never tombstoned, deleted, or re-identified by
refresh, and refresh never overwrites their identity or display name.
Failure leaves the model snapshot unchanged, records only a safe failure
classification, and writes no capability claims. A bound model that the
catalog no longer returns keeps its binding; Presentation explains it as
“当前模型目录未返回此模型” — retirement wording (“Provider 已下架”) is
reserved for explicit retirement evidence.

### 6.1 Provider-owned model management

The Provider management surface (“API 提供商与模型”) is the model-asset
entry point. Each provider editor exposes the provider's currently manageable
models through a bounded Application projection
(`listModelsForProvider(providerId)`): the available rows of that exact
provider across `providerCatalog`, `curated`, and `userDefined`, plus any
still-valid `legacyImported` rows under the existing compatibility strategy.
Historical `providerCatalog` tombstones stay out of this projection and are
never deleted by it, so existing bindings are not disturbed. Capability
queue entries never materialize provider-manageable models, and model counts
count only these manageable rows — the queue is not the registry. Weak
origin labels are presentation-only: `providerCatalog` → “官方目录”,
`curated` → “内置”, `userDefined` → “手动添加”; `legacyImported` is never
exposed as a user-facing product label.

Custom model creation lives here and only here: from a provider's own editor
the user adds a model with `origin = userDefined` bound to that exact
`providerId` through the existing `addCustomModel` authority, including for
preset providers and without any virtual “custom provider”. Creating an
`openai_compatible` provider presented as “自定义模型提供商” requires an
explicit first model id (such endpoints cannot be assumed to implement
reliable `/models` discovery); preset providers may create with or without
one. When provider creation succeeds but the first model add fails, the
provider and its credential persist — no destructive rollback — and the UI
clearly reports the partial success and returns the user to that provider's
editor to retry.

The capability model picker is selection-only. It continues to read
`listModelsForSlot(slot)` for slot eligibility (unknown stays selectable as
“能力未标注”, only explicit `unsupported` is disabled) but never calls
`createProvider`, `addCustomModel`, or `syncModels`, and offers no custom
model entry. When no model exists it directs users to
“API 提供商与模型” to add or refresh models instead of creating anything
in place. A currently bound tombstoned model keeps summary visibility.
Custom models remain first-class Model Registry citizens created through the
Application seam — never the legacy engine screen — and carry no credential
input. The Agent transport compatibility gate is unchanged and stays
independent of these selection semantics.

Agent configuration evaluates registry capabilities and the explicit
DeepSeek Responses transport contract before save/runtime provider creation.
The frozen transport allowlist still contains the single exact id
`deepseek-v4-flash`, so `deepseek-flash` is rejected at configuration
resolution. Officially, DeepSeek retired `deepseek-v4-flash` on 2026-09-10
(requests are served by DeepSeek-V4.1-Flash, which documents Responses API
support) and has documented native Responses API support for
`deepseek-v4-pro` since 2026-08-13; the runtime allowlist remains an
independent defense and widening it to the current official ids requires a
separate explicitly authorized package. Capability truth for DeepSeek model
ids is maintained in `docs/architecture/ai-model-capability-registry.md`.

## 7. Backup and rollback

All AI-config tables (`ai_providers`, `ai_models`,
`ai_model_capability_claims`, `ai_capability_bindings`, plus retained
`ai_engines` evidence) are authoritative B0 INCLUDE state. None contains a
credential column. Legacy credential columns continue to be scrubbed. A
backup package older than the app migrates only through DatabaseHelper on
the staged database (v23 → v24 → v25); a package newer than the app fails
closed. Restore never creates, copies, deletes, or remaps secure-store
entries.

Migration failure rolls back the SQLite open transaction. In-place downgrade
after a successful v24 launch is unsupported; recovery is a forward fix or a
pre-migration backup restore.
