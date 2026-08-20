# DM-D5 Destructive Presentation and Tool Boundary

Status: **IMPLEMENTED — EXECUTOR FINAL GATE PASSED; independent review pending**

Authority: successor stage of
`dm-p0-data-lifecycle-destructive-mutation.md`. This document does not reopen
DM-D1 through DM-D4, OBS-1 v0, W0, or ADR-003.

## 1. Current-state audit

The current master already contains the DM-D1E confirmation boundary for
Question, QuestionBank, clear-all, Exam, Project, Conversation and StudyPlan
destructive actions. W0 already implements `DRAFT/STAGE -> explicit approval
-> COMMIT`. The built-in Agent already states that destructive work is never
autonomous. MCP v0 already exposes exactly six READ_ONLY tools with
`destructiveHint = false`. OBS-1 is CLOSED/FROZEN.

DM-D5 therefore adds no replacement confirmation system, Agent commit path,
MCP tool or generic mutation framework. Its bounded gaps are:

- LibraryFile has an Application delete authority but no Presentation to
  Controller to Facade entry;
- clear-all copy does not enumerate the bulk purge or recommend backup and can
  expose an exception string;
- several legacy destructive surfaces expose exception strings;
- DM-P0 destructive authorities do not share a safe operation lifecycle trace.

## 2. Presentation contract

Every destructive action remains user initiated and explicitly confirmed.
Existing compliant DM-D1E confirmations are preserved.

LibraryFile delete adds one confirmation before the existing formal
Application authority. It states that the file record and managed original are
permanently deleted, Project/Conversation/Folder relations are detached, the
current ParsedArtifact is cleaned up, the action is irreversible, and a B0
export is recommended. Cancellation executes zero mutation.

Profile clear-all keeps exactly one dialog. It states that this is a bulk
purge of Questions, ReviewState, ReviewLog and AnswerAttempt, recommends a B0
export, and states irreversibility. Failure copy is fixed and does not include
an exception string. Destructive UI errors elsewhere use the same safe-copy
rule; they never include raw exceptions, paths, storage keys or content.

## 3. Destructive operation trace

DM-D5 adds `TraceOperationKind.destructiveMutation` as a post-OBS-1 successor
extension. It was not part of the historical OBS-1 v0 taxonomy.

The Application destructive authority emits a fresh operation trace with
whitelisted records only:

```text
destructive_started
  -> destructive_completed(status = completed)
  -> destructive_completed(status = completed_with_orphan)
  -> destructive_rejected(status = rejected)
  -> destructive_failed(status = failed, failureCode = operation_failed)
```

Allowed structured fields are `event`, fixed `mutationKind`, fixed `status`,
fixed `failureCode`, and fixed `cleanupOutcome`. The trace contains no entity
id, title, file name, path, storage key, content, tool argument/output or raw
exception. Observability failure never changes the business result.

The bounded mutation kinds are Question delete, QuestionBank delete,
LibraryFile delete, Project delete, Conversation delete, ReviewState reset,
question-data clear-all, StudyPlan stop and ExamPaper delete.

LibraryFile uses the database transaction as its primary commit point. If the
primary delete succeeds but managed bytes or ParsedArtifact cleanup becomes an
orphan, the terminal event is `destructive_completed` with
`status = completed_with_orphan`; it is never `destructive_failed`. A primary
authoritative failure emits `destructive_failed` and preserves the existing
zero-cleanup/rollback semantics.

## 4. Agent and MCP boundary

- MCP v0 remains exactly six READ_ONLY tools. All retain `readOnlyHint = true`
  and `destructiveHint = false`.
- The built-in Agent and MCP remain peer adapters over Application semantics.
- W0 proposal staging remains non-authoritative. Natural-language agreement is
  not approval.
- No Agent/MCP destructive tool, dispatcher, command route or autonomous
  destructive runtime is introduced.
- A future destructive Agent/MCP capability still requires a separately frozen
  contract and a formal product approval boundary; this stage does not prebuild
  it.

## 5. Failure and concurrency invariants

- Confirmation cancellation performs zero mutation.
- Presentation reaches LibraryFile persistence only through
  `FileLibraryController -> U1WorkspaceFacade -> LibraryFileDeletionPort`.
- All destructive Application authorities retain the existing
  `BackupRestoreMutationGate` lifetime.
- Trace creation and logging are best effort and cannot bypass, duplicate,
  retry or roll back a mutation.
- Fixed failure presentation never claims rollback after an ambiguous result.
- No schema, migration, persisted trace ledger or new dependency is added.

## 6. Acceptance

DM-D5 FINAL requires focused regressions for the trace lifecycle, LibraryFile
primary failure and orphan completion, Facade delegation/fail-closed behavior,
the full LibraryFile widget/controller chain, clear-all copy and zero-mutation
cancel behavior, existing DM-D1E confirmations, the exactly-six MCP catalog,
READ_ONLY annotations, the Agent destructive policy, architecture boundaries,
analyze, format and diff checks.

The closure addendum must record implementation commits, the final matrix,
exact closure head and open P0/P1/P2 status without rewriting the provenance of
OBS-1 v0 or earlier DM-P0 stages.

## 7. Explicit non-goals

Rich Image / #115 / #116, RAG-2/3, schema/migration, GC/refcount/tombstone,
OCR/provider redesign, broad UI redesign, autonomous destructive Agent/MCP
execution, MCP tool expansion, B0 implementation changes, unrelated refactor
and incidental cleanup are out of scope.

## 8. DM-D5-FINAL closure addendum

The historical audits and contracts above remain provenance. DM-D5-FINAL used:

- frozen successor contract commit: `ca43823`;
- destructive Presentation/trace implementation commit: `0637dbc`;
- final implementation head under acceptance: `0637dbc` (the following
  evidence-only commit adds tests and this closure record without changing
  production behavior).

The executor FINAL GATE passed 594 serial focused/architecture tests across
the complete D4 HARD GATE, persisted ReviewDraft CAS, typed and legacy commit
leases, retry/restart/cleanup/retention, destructive trace lifecycle,
LibraryFile DB-first/orphan semantics, Facade and Presentation call chain,
DM-D1E confirmations, clear-all, StudyPlan stop, OBS compatibility, MCP
exactly-six READ_ONLY transport/contract/architecture, Agent destructive
policy, W0 proposal/approval authority, B0 mutation gate and repository-wide
architecture boundaries.

Focused analyze, changed-Dart analyze, changed-Dart format gate and
`git diff --check` are required again on the final evidence commit. Runtime
schema remains v23; no migration, MCP tool, autonomous destructive runtime or
new dependency was added.

Executor self-check found no open task P0/P1/P2. This is evidence, not semantic
approval: because destructive mutation and authorization are high risk, the
fixed Draft PR head still requires an independent Verifier and then an
Independent Reviewer before any user-authorized merge.
