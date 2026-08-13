# S0 Secure Credential Storage — Focused Canonical Contract

Status: **Canonical S0 authority**.

This document is the authoritative contract for secure storage of AI/OCR/
Agent provider credentials: credential authority, activation semantics,
save/delete and migration state machines, failure taxonomy, and S0 stage
governance.

## 1. Problem and scope

Provider credentials were historically persisted as plaintext in SQLite
(`ai_engines.api_key`, and legacy `ai_profiles.text_api_key` /
`vision_api_key`). S0 removes plaintext as the long-term storage of
credentials: SQLite retains only non-secret engine metadata, and credentials
are obtained through a dedicated secure credential seam.

In scope: credential authority, repository/API shape, legacy migration,
CRUD semantics, and privacy guarantees for AI/OCR/Agent provider credentials.

Out of scope (frozen non-goals):

- UI redesign; Agent/MCP capability expansion;
- P6/P7/RAG; unrelated schema refactor; DatabaseHelper refactor;
- modification of the F1 parsed-artifact contract;
- physical removal of legacy `api_key` columns in this stage (runtime schema
  stays v20).

## 2. Credential authority

- The secure credential store (`EngineCredentialStore` port) is the sole
  credential authority.
- Keys are namespaced by a stable engine identity: `engine.<engineId>`.
- SQLite is metadata-only. The `ai_engines.api_key` column remains only as a
  legacy compatibility column and is never read by any runtime path.
- New metadata writes always scrub `api_key` to `''`.
- After activation, legacy plaintext may temporarily remain in SQLite only
  when migration has not yet completed; it exists solely as migrator retry
  input and is never a runtime credential fallback.
- After migration DONE, plaintext count is 0.
- No cross-store atomicity is claimed: the secure store and SQLite are
  independent persistence systems. Every operation has exactly one commit
  point plus explicit compensation and reconciliation rules (below).

## 3. Activation

S0 activates at the S0-D2 production wiring checkpoint: the composition root
injects the real secure-store adapter, the legacy migrator, and SQLite scrub
writes.

- Before activation, existing behavior is unchanged; the repository
  `credentialStore` seam is optional (`null` = not activated, transitional
  passthrough).
- After activation, `credentialStore` is required and the passthrough bridge
  is removed. Runtime hydration reads the secure store only.
- No security posture change is claimed before activation is wired and
  verified.

## 4. Runtime hydration

Post-activation, reading an engine's credential has exactly three outcomes;
they must never be folded into one:

- `missing` — no credential for the engine id: hydrated `apiKey == ''`,
  engine reported incomplete (same UX as an empty key today); no exception.
- `temporarilyUnavailable` — secure store transient failure: typed
  `EngineCredentialException(temporarilyUnavailable)` propagates.
- `dataCorrupt` — stored value invalid: typed
  `EngineCredentialException(dataCorrupt)` propagates as a hard failure.

`AiEngineProfile.apiKey` is a runtime-only, in-memory value. Persistence uses
metadata without the key (`toMetadataMap()`); SQLite writes scrub `api_key`
to `''`. UI, Agent, MCP, and providers never access the secure store directly;
all access goes through the bounded port/adapter and the repository seam.
Agent profiles continue to carry keys only inside REDACTED value types.

## 5. save state machine

```text
saveEngine(engineId, metadata, secret)

S0 validate: engineId safe; secret non-empty, bounded, no NUL.
S1 read old = credentialStore.read(engine.<engineId>)
   - temporarilyUnavailable -> FAILED(transient); zero mutation.
   - dataCorrupt -> treated as old = missing (writing a valid value heals the
     corrupt entry; compensation uses the delete-new rule below).
S2 if old == secret (present and identical): skip the credential write
   (idempotent); otherwise credentialStore.write(engine.<engineId>, secret).
   - failure -> FAILED(typed); prior credential state unchanged; DB untouched.
S3 store.saveAiEngine(metadata with api_key = '')
   - success -> DONE (credential = new secret; metadata = new metadata).
   - failure -> compensate from the S1 old state:
       old present (valid): best-effort write(engine.<engineId>, old)
         - success -> FAILED(compensated); original state restored
           (old credential + old metadata).
         - failure -> PARTIAL_FAILED(typed); mixed state
           (credential = new/unknown, metadata = old).
       old missing: best-effort delete(engine.<engineId>)
         - success -> FAILED(compensated); original state restored
           (no credential + old metadata).
         - failure -> PARTIAL_FAILED(typed); new credential becomes an
           unreachable residue; reconciled by a later same-id save
           (overwrite) or delete (idempotent cleanup).
       old corrupt: best-effort delete(engine.<engineId>)
         - success -> FAILED(normalized); the corrupt entry is normalized
           to missing (safe normalization, not original-state restoration);
           old metadata retained.
         - failure -> PARTIAL_FAILED(typed); residue rules as above.
```

Frozen semantics: updating an existing engine must preserve the old
credential state. A normal metadata failure must not silently destroy the
user's previous key: compensation restores the original state when it
succeeds, and a compensation failure returns a typed partial failure. A
pre-existing corrupt credential is not restorable; compensation normalizes
it to missing and reports `FAILED(normalized)`.

## 6. delete state machine

```text
deleteEngine(engineId)

D0 read old = credentialStore.read(engine.<engineId>)
   - temporarilyUnavailable -> FAILED(transient); zero mutation.
   - dataCorrupt -> proceed (deletion is safe for a corrupt value); the
     restore rule degrades to the "old missing" rule below.
D1 credentialStore.delete(engine.<engineId>)
   - failure -> FAILED(typed); metadata untouched; never reported as success.
D2 store.deleteAiEngine(engineId)
   - success -> DONE. Invariant: metadata absent AND credential absent.
   - failure -> compensate from the D0 old state:
       old present (valid): best-effort write(engine.<engineId>, old)
         - success -> FAILED(compensated); original state restored
           (row present + old credential).
         - failure -> PARTIAL_FAILED(typed); row remains, credential absent
           -> engine incomplete; reconciled by a later delete (idempotent)
           or re-save.
       old missing: best-effort delete(engine.<engineId>)
         (ensure credential stays absent)
         - success -> FAILED(compensated); row present, no credential.
         - failure -> PARTIAL_FAILED(typed).
       old corrupt: best-effort delete(engine.<engineId>)
         (ensure credential stays absent)
         - success -> FAILED(normalized); corrupt entry normalized to
           missing (safe normalization, not restoration); row present.
         - failure -> PARTIAL_FAILED(typed).
```

Frozen semantics: delete is security-favoring. Success guarantees both
metadata and credential are absent. A credential deletion failure is FAILED,
never DONE. Repeated delete with no row and no credential is an idempotent
DONE.

## 7. Legacy migration state machine

```text
Runs only after activation (S0-D2 wiring). Runtime never reads SQLite
plaintext, before, during, or after this machine.

IDLE -> SCAN: ai_engines rows with non-empty api_key; legacy ai_profiles
        key columns are handled separately (below).

per engine row:
  R1 read secure = credentialStore.read(engine.<engineId>)
     - present (valid) -> SECURE-WINS: never overwrite; scrub the SQLite
       value directly (api_key = '').
     - missing -> write legacy plaintext to the secure store, then verify
       (read-back equals the written value):
         success -> scrub api_key = ''.
         failure -> PARTIAL_FAILED(verificationFailed); no scrub; plaintext
         remains as retry input only.
     - temporarilyUnavailable -> STOP for this batch; no scrub; plaintext
       remains as retry input only; PARTIAL_FAILED(storeUnavailable).
     - dataCorrupt -> STOP; no scrub; PARTIAL_FAILED(secureCorrupt). A legacy
       value must never overwrite an existing secure credential, even a
       corrupt one.

legacy ai_profiles: no production reader; scrub text_api_key and
vision_api_key directly; no secure entries are created for orphan legacy rows.

terminal: DONE = SQLite has no plaintext (plaintext count 0) and the secure
store is the sole credential authority.

Hard invariant: a legacy SQLite value must never overwrite an existing secure
credential.
```

## 8. Failure taxonomy

```text
EngineCredentialFailure { missing, dataCorrupt, temporarilyUnavailable }
EngineCredentialException(failure)          - toString contains no key,
                                              no raw cause, no path.
EngineCredentialPartialException(failure)   - typed partial failure after a
                                              failed compensation.

Operation outcomes (save/delete):
  DONE                  - both stores reached the target state.
  FAILED(unchanged)     - failed before mutation; state identical to before.
  FAILED(compensated)   - primary write failed, compensation succeeded;
                          state restored to before.
  FAILED(normalized)    - pre-existing credential was corrupt; compensation
                          succeeded and normalized it to missing (safe
                          normalization, not restoration); the state is not
                          the original state.
  PARTIAL_FAILED        - primary write failed and compensation failed;
                          mixed state is reported explicitly with its
                          reconciliation path.

LegacyMigrationFailure { storeUnavailable, verificationFailed, secureCorrupt }
  - processed rows are scrubbed; unprocessed plaintext remains only as retry
    input and is never a runtime authority or fallback.
```

## 9. Stage graph and governance

```text
S0-P0 -> S0-D0 -> S0-D1 -> S0-D2 -> S0-CL
```

- `S0-P0`: canonical contract — COMPLETE.
- `S0-D0`: core seam (port, metadata mapping, repository split with optional
  seam, fakes/tests) — NOT STARTED.
- `S0-D1`: real secure adapter (dependency authorization required, Class C;
  e.g. flutter_secure_storage or a platform DPAPI/Keystore adapter) —
  NOT STARTED.
- `S0-D2`: legacy migration + production wiring (migrator, bounded DB
  helpers, composition root, removal of the pre-activation bridge) —
  NOT STARTED.
- `S0-CL`: focused verification, final full semantic review, canonical
  closure — NOT STARTED.

All S0 stages are `SERIAL`; a checkpoint must complete and freeze before the
next stage starts, and later stages never auto-activate.

## 10. Deferred

- Key rotation UI; multi-device sync.
- Physical removal of legacy `api_key` columns (v21 candidate).
- GC of unreachable credential residue (bounded; reconciled by later same-id
  write/delete; no scheduler in v0).
- Moving the engine-settings "test connection" direct HTTP call behind an
  application seam (existing presentation-layer debt, follow-up).
- B0 backup interplay: any future `.shiroha`/export package must exclude
  credentials (frozen requirement; B0 itself remains DEFERRED).

## 11. Documentation authority

- `ARCHITECTURE.md` — repository-wide boundary contract.
- This document — focused S0 authority.
- `docs/architecture/n0-post-p5-roadmap.md` — stage ordering and current
  status.
