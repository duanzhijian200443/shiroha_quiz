# AI Config Provider + Model Registry — Canonical Foundation Contract

Status: **Canonical authority — schema v24 foundation implemented**.

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

## 2. Durable identities and schema v24

Schema v24 adds four tables:

- `ai_providers`: stable `provider_id`, explicit `provider_kind`, display
  metadata, endpoint, revision, readiness, and safe connection/sync status.
- `ai_models`: stable `model_ref`, owning `provider_id`, exact canonical model
  id, display metadata, availability, and discovery timestamps.
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
legacy migration rule.

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

Verified binding updates use expected revision/CAS. A stale confirmation,
cancel, missing model, unavailable model, missing Provider, explicit
unsupported capability, or unknown capability yields zero binding mutation.
Only migrated `legacyPreserved` bindings may continue across unknown claims;
explicit unsupported and missing/unavailable references still fail closed.

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

## 6. Discovery, tombstones and Agent compatibility

A successful sync transactionally upserts the returned exact model ids and
official claims, then marks previously seen missing models `unavailable`.
Failure leaves the model snapshot unchanged and records only a safe failure
classification. A bound unavailable model retains its reference but runtime
resolution returns `modelUnavailable`.

Agent configuration evaluates registry capabilities and the explicit
DeepSeek Responses transport contract before save/runtime provider creation.
`deepseek-flash` is therefore rejected at configuration resolution. The
runtime allowlist remains an independent defense and is not expanded;
`deepseek-v4-flash` remains the only currently supported exact id.

## 7. Backup and rollback

All four v24 tables are authoritative B0 INCLUDE state. None contains a
credential column. Legacy credential columns continue to be scrubbed. A v23
package migrates only through DatabaseHelper on the staged database; v24
packages fail closed on an older app. Restore never creates, copies, deletes,
or remaps secure-store entries.

Migration failure rolls back the SQLite open transaction. In-place downgrade
after a successful v24 launch is unsupported; recovery is a forward fix or a
pre-migration backup restore.
