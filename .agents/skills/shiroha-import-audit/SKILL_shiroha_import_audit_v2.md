---
name: shiroha-import-audit
description: Run bounded, redacted, deterministic offline audits for Shiroha Quiz import-path changes, including OCR/text import, typedV2 admission and finalization, ImportTask/Review lifecycle, answer fusion, supplemental-answer integration boundaries, and Answer Completion import metadata. Use only when task-specific acceptance can be proven without live providers, private source documents, application startup, or uncontrolled side effects.
---

# Shiroha Import Audit

## Purpose

Use this skill to collect **bounded deterministic evidence** for Shiroha Quiz import-path behavior.

This skill is an audit helper, not a replacement for repository architecture, task-specific canonical contracts, role instructions, CI, Independent Verifier, or Independent Reviewer.

Authority order:

```text
explicit current task / user instruction
-> AGENTS.md
-> active role instructions
-> task-specific canonical architecture/product contract
-> this Skill
```

When a task-specific canonical contract defines stronger or more specific acceptance, follow that contract.

Do not weaken, reinterpret, or replace frozen acceptance with this Skill's generic checklist.

---

## Applicable scope

Use this skill for focused changes involving one or more of:

- OCR question import;
- text/document import;
- `import_pipeline`;
- import parsing / regionization / assembly;
- reference-answer attachment or answer fusion;
- `QuestionDraft` / `QuestionDraftV2`;
- RichContent import auditing;
- typed candidate admission;
- `typedV2` / `legacyV1` route decisions;
- `TypedReviewSnapshot`;
- import finalization;
- ImportTask / attempt / Review lifecycle;
- import restart/reload behavior;
- import persistence gates;
- Supplemental Answer import-side adapters when the task remains offline;
- Answer Completion import metadata such as `document_v4` and `_questionSetCaptureV1`;
- deterministic import acceptance tooling.

Do **not** use this skill as the primary acceptance authority for unrelated:

- backup / restore;
- database migration;
- general QuestionSet persistence;
- retrieval / RAG;
- Agent runtime;
- MCP;
- unrelated UI;
- release/build/signing;
- real-device acceptance.

If the task crosses into one of those domains, follow its own canonical contract and verification path.

---

## Safe inputs only

Prefer only:

- synthetic fixtures;
- in-memory or temporary test databases;
- existing redacted read-only Replay cases;
- focused import tests;
- deterministic acceptance fixtures;
- the offline Replay path of `tool/import_acceptance.dart` or its current repository wrapper;
- provider call-count assertions;
- aggregate redacted statistics;
- temporary files created specifically by tests and containing no private source content.

Do not:

- call a real OCR, LLM, Vision, or other network Provider;
- use live Web/API access as import evidence;
- read a saved API key, credential, token, or secure-store value;
- open a private PDF/document unless the current task explicitly authorizes that exact evidence source;
- create, refresh, replace, or mutate Replay data;
- use OCR-smoke refresh paths;
- mutate production/user application data;
- run destructive filesystem or database operations outside isolated test state;
- print complete question text, answers, explanations, OCR content, provider bodies, credentials, private filenames, or absolute paths.

If required evidence cannot be collected without one of these side effects, stop and report the missing evidence instead of silently broadening the audit.

Mark the result `NOT VERIFIED` where appropriate.

---

## Runtime / UI boundary

This skill defaults to offline deterministic validation.

Do not start the production application, Windows build, real device, or live Flutter runtime merely to satisfy this skill.

Application startup, runtime inspection, widget interaction, real-provider testing, and device acceptance require explicit task authority.

If the current task explicitly requires Flutter/UI/runtime acceptance, use the appropriate task contract and Flutter/Dart tooling rather than treating this skill's offline restriction as the whole acceptance plan.

---

## Audit procedure

### 1. Freeze the target

Before running evidence:

- identify the exact task;
- identify the relevant canonical contract;
- identify the exact branch / commit / PR head when applicable;
- inspect the current diff;
- identify the smallest relevant production paths and tests.

Do not audit a stale head while reporting results for a newer one.

---

### 2. Identify the actual failure boundary

Do not assume every import defect belongs to OCR.

Trace the smallest relevant chain, for example:

```text
source adapter
-> parser / OCR document
-> regionization
-> answer attachment / assembly
-> finalization / audit
-> typed admission
-> Review snapshot
-> ImportTask persistence/reload
-> commit authority
```

Only validate stages relevant to the current task.

Do not broaden a local failure into a repository-wide import rewrite.

---

### 3. Select deterministic evidence

Choose the smallest useful combination of:

- unit test;
- focused integration test;
- temporary SQLite acceptance;
- synthetic vertical-chain acceptance;
- existing read-only Replay;
- offline `import_acceptance`;
- source/contract assertion where execution is intentionally impossible.

Prefer real behavior tests over source-text assertions when the repository exposes an executable seam.

Do not run the entire test suite unless the task or repository gate explicitly requires it.

---

### 4. Preserve zero-provider behavior

For offline audits, Provider calls must remain at the expected count.

Normally:

```text
Provider calls = 0
```

If a test uses a fake/injected Provider, distinguish:

```text
fake provider invocations
```

from:

```text
real network Provider calls
```

A fake deterministic test double is allowed when required by the focused contract.

A real network call during an offline audit is a failure.

---

### 5. Validate the correct persistence route

When the task touches storage/finalization, verify the current route explicitly.

Possible examples include:

```text
legacyV1
typedV2
```

For typed flows, validate task-specific requirements such as:

- valid typed payload remains authoritative;
- corrupt typed state does not silently fall back to legacy;
- expected storage metadata/reason is preserved;
- whole-batch admission semantics remain unchanged unless the task explicitly changes them;
- finalization produces the expected route;
- restart/reload does not silently rewrite authoritative state.

Do not infer route correctness only from UI state.

---

### 6. Validate ImportTask lifecycle when relevant

When the task touches task metadata, Review, retry, restart, or commit:

verify only the relevant states, such as:

- task identity remains stable where required;
- attempt state transitions are valid;
- persisted state survives close/reopen when required;
- restart normalization follows the current contract;
- authoritative diagnostics/metadata survive replacement paths;
- reserved metadata cannot be synthesized or overwritten by parser/provider diagnostics;
- stale or invalid state fails closed.

Do not invent a universal retry contract.

Follow the current task-specific lifecycle authority.

---

### 7. Validate atomicity when persistence is in scope

For writer/finalization tasks, explicitly test required rollback behavior.

A failed write must not leave a partially accepted import when the canonical transaction contract requires atomicity.

Potential evidence may include:

```text
Question rows
typed sidecars
review state
folder/relation state
ImportTask completion
QuestionSet membership
```

Only assert components actually owned by the current transaction contract.

Use isolated SQLite failures or rollback-only synthetic triggers where appropriate.

Do not weaken production constraints to make an atomicity test pass.

---

## Answer Completion additions

When the current task belongs to the `ANSWER-COMP-*` chain, first read:

```text
docs/architecture/answer-completion-question-sets.md
```

Only validate Answer Completion behavior that has reached the current implemented stage.

Do not test future-stage behavior as though it already exists.

When relevant, validate:

### Seed / metadata

```text
document_v3
document_v4
_questionSetCaptureV1
```

Check task-specific requirements for:

- key presence versus null;
- strict envelope shape;
- unknown/missing/extra fields;
- schema version;
- displayName preservation;
- sourceFileId preservation;
- restart/reload preservation;
- diagnostics replacement preservation;
- OCR retry preservation;
- parser/provider inability to overwrite the reserved field.

### Commit-stage QuestionSet behavior

Only once the corresponding writer stage is implemented, validate:

- one successful source-document commit creates the expected set;
- actual persisted Question storage IDs are used;
- ordered membership matches commit order;
- set/member writes share the frozen transaction owner;
- failure rolls back the entire owned transaction;
- no second writer or post-commit append path appears.

Do not create synthetic expectations for stages not yet implemented.

---

## Recommended evidence fields

Report only metrics relevant to the active task.

### Generic import quality

When available:

- `Questions`
- `Question numbers`
- `Hard issues`
- `Review issues`
- `Missing answers`
- `Repair candidates`
- `Reference answer attachments`

### Execution / safety

When available:

- `Provider calls`
- `Source mode`
- `Storage route`
- `Admission result`
- `Admission reason`
- `Finalization result`
- `ImportTask state`
- `Attempt state`
- `Reload/restart result`
- `Commit result`
- `Rollback result`

### Typed path

When relevant:

- `typedV2 / legacyV1`
- typed candidate accepted/rejected
- TypedReviewSnapshot present/valid
- typed storage metadata valid
- corrupt-sidecar behavior
- explicit-empty handling when relevant to the contract

### Answer Completion

When relevant:

- entry version (`document_v3` / `document_v4`);
- seed present/valid;
- reserved seed preserved after persistence/reload;
- QuestionSet capture result;
- member count;
- transaction outcome.

An unavailable field must be reported as:

```text
NOT VERIFIED
```

Do not infer or fabricate it.

Do not print private content in order to justify a metric.

---

## Verdict

The verdict is scoped only to the task being audited.

### PASS

Use `PASS` when:

- every task-specific required deterministic acceptance passes;
- no unexpected real Provider/network call occurs;
- required persistence/lifecycle invariants hold;
- required safety/privacy constraints hold;
- no merge-blocking deterministic defect was found.

### REVIEW

Use `REVIEW` only when:

- the canonical task explicitly permits a safe manual-review state;
- imported data remains safe and non-corrupt;
- the remaining condition is expected human review rather than implementation failure.

Do not convert an explicitly permitted Review state into a code failure.

### FAIL

Use `FAIL` when a task-specific required invariant fails, including examples such as:

- missing or duplicate questions when prohibited;
- incorrect answer attachment;
- unexpected Hard issue;
- unexpected real Provider/network call;
- broken privacy/safety contract;
- malformed typed route or metadata;
- corrupt typed state silently falling back;
- authoritative metadata lost across persistence/restart;
- invalid task lifecycle;
- unexpected partial commit;
- required rollback failure;
- stale/CAS/ownership invariant broken;
- reserved Answer Completion seed lost or overwritten;
- a task-required deterministic acceptance test fails.

### NOT VERIFIED

Use `NOT VERIFIED` for any required evidence that cannot be collected under current authorization or environment.

Do not reinterpret `NOT VERIFIED` as PASS.

---

## Evidence report format

Use a concise report:

```text
Target:
- task:
- head/ref:

Scope:
- production paths inspected:
- tests/evidence executed:

Results:
- <metric>: <value>
- <metric>: <value>

Provider/network:
- real Provider calls:
- fake Provider calls:
- network used:

Failures:
- first deterministic failure:
- classification:

Tests not run:
- ...

Runtime risks:
- ...

Task verdict:
PASS | REVIEW | FAIL | NOT VERIFIED

Repository/global status:
NOT_EVALUATED
```

Do not claim repository-wide correctness from a focused import audit.

---

## Role integration

This skill does not grant write, commit, push, PR, approval, or merge authority.

### Executor

May use the skill for bounded self-verification after implementation.

Executor evidence is not semantic approval.

### Independent Verifier

May use the skill for deterministic re-execution when the repository/task requires a standalone Verifier.

Freeze the exact target and do not modify production code.

### Independent Reviewer

May use existing audit evidence, but independently evaluates semantics, architecture, frozen contracts, regression strength, and scope.

Do not treat a PASS from this skill as automatic Reviewer approval.

---

## Stop conditions

Stop instead of broadening the audit when:

- real Provider/private-document evidence becomes necessary;
- required evidence would mutate Replay data;
- production/user data would need to be touched;
- task scope changes from import auditing into another subsystem;
- schema/public contract changes become necessary but are not authorized;
- transaction/ownership semantics are ambiguous;
- a canonical contract conflicts with assumptions in this skill;
- the exact PR/head changes during fixed-target verification;
- the requested result cannot be proven deterministically.

Report the smallest missing authorization, unresolved contract, or next verification scope.

---

## Core principle

Prefer:

```text
smallest relevant deterministic evidence
+ real repository contract
+ zero unnecessary side effects
+ redacted reporting
```

over:

```text
broad test execution
+ live Provider calls
+ private source inspection
+ inferred success
```

The goal is not to prove that “the whole import system works.”

The goal is to prove the **specific authorized import invariant** with the smallest trustworthy evidence.
