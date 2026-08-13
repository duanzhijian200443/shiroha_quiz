# Shiroha Quiz Agent Instructions

## 1. Scope and precedence

These instructions apply to all agent work in this repository.

When instructions conflict:

1. Follow higher-level platform and explicit current-user instructions.
2. Follow the more restrictive repository safety/privacy/Git rule.
3. Follow the active role file.
4. Stop for user direction only when the conflict cannot be resolved safely.

Operate only inside this repository unless the user explicitly authorizes otherwise.

---

## 2. Required context and rule routing

Before a non-trivial task, read:

- `ARCHITECTURE.md`;
- the active role file under `docs/agents/`;
- relevant implementation and tests;
- current Git state/diff that affects the task;
- only the `.agents/rules/` files selected below.

Do not claim a file was reviewed unless it was opened during the current task.

| Rule file | Read when |
|---|---|
| `.agents/rules/architectural-discipline.md` | Every non-trivial repository task |
| `.agents/rules/git_work.md` | Git status/diff/staging/commit/branch/history/push decisions are involved |
| `.agents/rules/reviewer.md` | Only when the first line activates `角色：审查` |

Do not enumerate or load unrelated rule files. Reading a rule file as evidence does not activate its behavioral role unless routing says so.

---

## 3. Role activation

The first line may activate exactly one role:

| Identifier | Role file |
|---|---|
| `角色：总控` | `docs/agents/coordinator.md` |
| `角色：规划` | `docs/agents/planner.md` |
| `角色：执行` | `docs/agents/executor.md` |
| `角色：验证` | `docs/agents/verifier.md` |
| `角色：审查` | `docs/agents/reviewer.md` |
| `角色：诊断` | `docs/agents/diagnostician.md` |

Read the mapped role file before continuing. Do not activate multiple roles or silently switch roles. Without an explicit role, do not assume write authority.

---

## 4. Architecture and change discipline

Preserve the canonical post-R8 dependency direction defined by `ARCHITECTURE.md`:

```text
Flutter UI / Built-in Agent / MCP Adapter
                  -> Application
                  -> Domain

Data / Infrastructure -> Application ports / Domain
```

`main.dart` or another explicit composition root may wire concrete repositories, databases and providers.

Requirements:

- UI, Agent and MCP adapters do not access SQLite/`DatabaseHelper` directly.
- New post-P5 presentation features do not add direct Repository dependencies; existing legacy UI-to-Repository calls are tolerated until the relevant capability is touched and do not justify a repository-wide cleanup.
- Cross-surface use-case semantics belong in application services/facades so UI, Agent and MCP can reuse them.
- Persistence belongs in Repositories/data infrastructure.
- Domain code does not depend on Flutter, SQLite, provider DTOs, HTTP clients or file-system APIs.
- The built-in Agent does not call the app's own MCP transport; both are peer adapters over application capabilities.
- New AI/MCP mutation flows must stage through application commands and the frozen approval boundary; adapters never write SQL directly.
- Preserve typed sidecar authority, strict corrupt-sidecar failure, typed explicit-empty semantics, RichContent structural rendering and review-state/content separation.
- Widgets do not acquire domain logic.
- Reuse existing abstractions before adding new ones.
- Verify the actual failure boundary before escalating upstream.
- Make the smallest coherent change that satisfies the frozen contract.
- Do not refactor, rename, reformat, generalize, or "future-proof" unrelated code.
- Preserve backward compatibility unless explicitly authorized otherwise.
- Do not change public APIs, persisted formats, schema, dependencies, CI/release/signing, or security/privacy contracts unless they are explicitly in scope.
- Preserve unrelated user changes. Report nearby issues instead of fixing them automatically.

High-risk areas include import pipelines, persistence/migrations, managed-file lifecycle, async recovery/concurrency, logging/redaction, credentials, OCR/AI merging, Agent/MCP write permissions, and global exception handling. High-risk changes require failure-path and concurrency evidence where applicable.

---

## 5. Normal task workflow

For implementation:

1. Inspect relevant code/tests/current diff.
2. Verify the reported problem exists unless the package supplies a frozen, evidence-backed root cause.
3. Freeze the task-specific behavior and allowed scope.
4. Add/update the minimum regression evidence needed.
5. Make the smallest coherent change.
6. Run minimal focused self-checks.
7. Stop at the Executor phase boundary and hand off to independent verification.

For read-only tasks, do not modify, format, create, rename, or delete files.

---

## 6. Git authority

Never run destructive/history-rewriting Git operations, including `git reset --hard`, destructive `git checkout`/`git restore`, `git clean -fd[x]`, force push, or history rewriting.

Git authority is action-specific. Staging does not authorize commit; commit does not authorize push; push does not authorize merge/tag/release. Branch/worktree creation also requires explicit authority.

Never use `git add .` or `git add -A`. Use exact paths. Do not create/update `DEVELOPMENT_LOG.md` unless it is explicitly in scope.

### Local commit authorization

An Executor may create local commits only when its package supplies all of:

```text
Local commits authorized: yes
Branch: <assigned branch>
Commit paths: <exact allowed paths>
Push authorized: no | yes
```

When `Local commits authorized: yes` is present, the authorization covers the current frozen task and any policy-permitted Class A/Class B closure lane on the same assigned branch and within the same commit paths. Necessary append-only local commits are allowed; **commit count is not a safety boundary**.

The following remain forbidden unless separately authorized:

- amend/rebase/squash/history rewrite;
- paths outside `Commit paths`;
- repair passes beyond the closure limits;
- push, PR, merge, tag, or release when not separately authorized.

Without the complete authorization fields, hand off an uncommitted diff.

Before and after write work, inspect `git status --short`. Do not remove unrelated tracked or untracked files.

---

## 7. Security and privacy

Never expose, copy, persist, test-log, or report secrets such as API keys, tokens, authorization headers, signing material, passwords, credentials, private configuration, or complete private file contents.

Avoid logs/reports containing complete prompts, answers/explanations, raw OCR text, provider bodies, Base64 payloads, sensitive absolute paths, or raw exception messages that may contain private data. Prefer counts, IDs, stages, statuses, safe error categories, runtime types, and redacted metrics.

Network/provider use is disabled by default unless the task explicitly requires it.

---

## 8. Validation and evidence economy

Use focused validation during implementation. Typical checks:

```bash
dart format --output=none --set-exit-if-changed <changed-dart-files>
flutter analyze <changed-production-files>
flutter test --concurrency=1 <focused-tests>
git diff --check
```

Rules:

- Do not run full-repository formatting for a focused task.
- Do not fix unrelated historical analyze findings.
- Never claim a command passed unless it ran.
- Report skipped/failed checks.
- On Windows, run Flutter tests serially unless parallel safety is established.
- Full workflow (`.\scripts\verify.ps1`) is for explicit release/global acceptance or direct user request.

### Test evidence economy

Regression tests prove behaviors/invariants, not implementation lines.

For one bounded defect:

- prefer one direct regression reproducing the failure;
- add one boundary/failure/concurrency test only when materially necessary;
- reuse existing integration/acceptance coverage;
- do not create a separate test for every private handler unless the handlers have materially different failure modes;
- do not add optional coverage during final audit merely because it is possible.

Test volume is not evidence quality.

---

## 9. Execution boundaries and command limits

Use the lowest capability/cost route that safely covers actual uncertainty. Deterministic work belongs to a Verifier, local terminal, or CI.

Executor phase boundary: once requested behavior is implemented, syntax is complete, and at least one focused implementation check passes, stop active implementation when the remaining work is mainly verification/formatting/diff/reporting.

Unless explicitly authorized:

- no full repository test suite;
- no Windows Release build;
- no generated application launch;
- no real external API/provider smoke test;
- no indefinite waits;
- no more than one retry of the same stalled/failing command;
- no silent timeout increase.

A command with no meaningful progress for 3 minutes is stalled. Preserve evidence and hand it off; a timeout is incomplete evidence, not proof of product failure.

---

## 10. Prompt economy and delegated evidence inheritance

Task prompts inherit shared rules from this file, the active role, and `docs/agents/model-routing.md` instead of repeating them.

A normal delegated package contains only:

```text
角色：<role>
目标：<one bounded objective>

Base/Branch: <target identity>
Allowed paths: <exact paths>
Parent-attested evidence: <only facts already frozen by the parent>
Task-specific invariant/constraints: <only deviations or frozen semantics>
Acceptance: <task-specific criteria>
Validation: <exact focused commands/timeouts>
Git authority: <local commit/push fields>
Model: <preferred route and fallback if overridden>
Stop only if: <scope/class-C/environment/target-drift conditions>
```

Only include explicit forbidden paths when there is a realistic ambiguity. Do not restate general repository rules, full parent history, generic safety text, or unchanged architecture in every package.

### Parent-attested evidence

A child inherits explicit parent-attested facts and must not recompute them solely for reassurance. Inheritable evidence includes:

- base/target commit SHA;
- assigned branch/worktree identity and ownership;
- clean/dirty state captured immediately before dispatch;
- allowed changed paths;
- frozen diff/changed-path identity;
- completed topology checks;
- an evidence-backed root cause or finding already frozen by Diagnostician/Reviewer/Coordinator.

Recheck inherited evidence only when:

- the role requires independent target verification;
- a command contradicts the package;
- target/ownership drift is observed;
- security/privacy correctness depends on current state;
- the package explicitly marks the fact unresolved.

Do not rescan sibling worktrees, re-derive the architecture baseline, recalculate per-file hashes, or rediscover a frozen root cause merely to confirm the parent. A commit SHA identifies the complete tracked tree.

---

## 11. Frozen-target rules

Do not verify or review a moving implementation.

### Committed target

A commit SHA already identifies the complete tracked tree. Freeze only:

```text
Target commit: <SHA>
git status --short: <expected state of the verification worktree>
```

Do **not** repeat per-file blob hashes for a committed target unless an external sidecar outside that commit can materially change evidence.

### Uncommitted target

Freeze:

- current `HEAD`;
- branch/detached state;
- `git status --short`;
- exact changed/staged paths;
- focused diff or one bounded diff identity when needed.

Any target drift invalidates verification/review evidence for the old target.

---

## 12. Findings and bounded repair policy

Use one severity scale:

- **P0 Critical**: secret exposure, destructive corruption, catastrophic security/privacy failure.
- **P1 Blocking**: data loss, crash, broken core behavior, violated frozen invariant, serious compatibility/concurrency failure.
- **P2 Merge-blocking correctness**: bounded but meaningful correctness/compatibility/concurrency/required-acceptance gap that should be fixed before merge.
- **P3 Non-blocking**: maintainability, documentation drift, optional/extra coverage, cleanup, low-impact hardening.

P3 **must not automatically trigger a repair**. Promote it only when concrete evidence proves that it violates an explicit acceptance criterion, frozen invariant, security/privacy boundary, or release gate.

Finding classes:

- **Class A**: one deterministic semantics-preserving correction. Lane: fresh narrow correction -> focused Verifier -> finish; no semantic closure Reviewer.
- **Class B**: bounded in-scope semantic completion that does not change approved architecture/schema/public API/security posture/file scope. Lane: batch all known in-scope Class B findings -> fresh Repair Executor -> focused Verifier -> one targeted closure Reviewer.
- **Class C**: material design/scope/security/schema/API/dependency/provider/permission change. Stop for user authorization.

### Review/repair ordering

- Do not run a targeted closure Reviewer before the stage/feature has received its initial full semantic Review.
- A deterministic Verifier failure may receive a Class A correction before that full Review.
- The initial full Reviewer must finish all assigned dimensions and return all non-duplicate P0/P1/P2 findings together before Class B repair begins whenever the target remains reviewable.
- Do not repair findings one-by-one when they are compatible, in-scope, and can be closed in one bounded pass.
- Do not restart a full Review after repair merely because the target SHA changed. Use targeted closure review unless the repair changed architecture/public contract/schema/security/concurrency semantics or invalidated the original review scope.

Default closure limits per frozen task/feature:

- one initial full semantic Reviewer;
- at most one risk-triggered cross-check;
- at most two Class B repair passes total;
- at most one Class A terminal correction after the final semantic check;
- at most one targeted closure Reviewer per Class B pass;
- at most one Sol-high full review per stage without new user authorization.

P3 is recorded/deferred and does not reopen the lane.

---

## 13. Multi-agent orchestration

Repository-wide orchestration uses `角色：总控`.

Coordinator responsibilities:

- freeze base/branch/worktree/dirty state and shared contracts once before dispatch;
- serialize by default and allow parallel writers only with non-overlapping production ownership and isolated worktrees;
- delegate bounded tasks with exact file ownership and parent-attested evidence;
- never edit production/test files itself;
- stop all writers before Verifier/Reviewer work on the same target;
- integrate only when Git integration is explicitly authorized;
- never automatically push/merge unless explicitly authorized.

Each child activates one role, may not create descendants, switch roles, expand its scope, or decide public architecture/contracts. One active writer per worktree.

### Child lifecycle and slot discipline

A child exists for one bounded role/task only. Terminal states are `COMPLETE`, `BLOCKED`, or `FAILED`.

When a child becomes terminal, the Coordinator must in the same orchestration turn:

1. capture the concise handoff and durable evidence;
2. record role, target/commit, verdict/findings, validation result and remaining risk;
3. close/release the terminal child before spawning its successor.

Do not keep terminal children alive for reference, logs, possible reuse, or while waiting on another feature. The handoff is durable evidence; the child session is not. Never resume a terminal writer for repair; use a fresh bounded child.

Before creating a child, reconcile the roster and release terminal children. Default active-child budget is two globally for parallel feature work unless the current user/package explicitly authorizes more. If capacity remains full after cleanup, wait for an active child to reach terminal state rather than spawning duplicates.

### Wait discipline

Prefer host-provided event/terminal-handoff waiting. Do not periodically wake a model merely to report that children are still running.

If the host lacks event-driven waiting, use the lowest-frequency bounded fallback wait the runtime supports. Silence is not evidence of a stall. Surface terminal states, permission requests, ownership drift, target drift, or safety violations immediately.

Child handoffs must be concise and include target identity, files changed, behavior, focused checks/results, skipped checks, remaining risks, commit SHA when authorized, and `git status --short`.

Model/provider selection and closure routing are defined in `docs/agents/model-routing.md`.

---

## 14. Canonical contract and review-history discipline

A canonical document is the current authoritative contract for one product or architecture domain: it records what current and future agents must believe. It is not a development log, Reviewer-findings dump, test report, substitute for Git history, or ordinary TODO list.

Before planning a new stage or work that may change a durable contract:

1. the Planner identifies the canonical documents relevant to the task boundary;
2. only those relevant canonical documents are read; a full `docs/` scan is not required;
3. the plan states whether the task preserves the current contract or changes durable contract truth and, if it changes truth, exactly which canonical documents must be updated.

Role responsibilities:

- **Executor:** when implementation preserves the durable contract, do not edit canonical documents merely for completeness. When implementation changes an authorized durable contract, update the affected canonical documents in the same change. Preserve historical truth: use an amendment, status update, or superseding document when needed rather than rewriting history as though a later decision always existed.
- **Reviewer:** check implementation against the relevant canonical contract. Report implementation/contract drift and report an authorized durable contract change whose canonical documents were not updated. Do not require a routine bug fix to create or edit a canonical document without a durable contract change.
- **Verifier:** verify code, documentation, and tests against the already-frozen contract; do not redesign or reinterpret the canonical contract.

Durable contract changes include product IA/navigation/terminology, domain ownership or lifecycle semantics, application/module dependency boundaries, persisted-schema semantics, Agent/MCP permission or public contracts, canonical roadmap/stage status, and other long-lived decisions that affect future correct implementation. Routine bug fixes, ordinary copy changes, local UI polish, behavior-preserving internal refactors, tests alone, format/lint, one-off P3 findings, and per-run verification results do not update canonical documents by default.

Reviews record what an inspection found. When a formal finding disposition is useful, use the existing review context and concise states such as `OPEN`, `FIXED`, `DEFERRED`, `NOT_ACTIONED — intentional`, or `BLOCKED`; do not create a second workflow state machine. Findings normally remain in GitHub PR review/discussion or an established repository review artifact. Do not require `docs/reviews/*.md` for each small task. Create a standalone review document only when an established stage-review convention applies or the work has durable audit value such as schema, architecture, or a major stage.

Canonical documents contain only the durable rule distilled from a decision or review. Do not copy a complete Reviewer report into them. If an intentional distinction is likely to be mistakenly changed again, record that enduring semantic distinction in the relevant canonical document and keep the inspection disposition in review history.

`docs/architecture/` describes the **current contract and invariant**, not agent execution history. Do not append commit SHAs, per-run test counts, temporary Reviewer findings, repair chronology, model identity, or handoff transcripts to architecture documents. Keep those in PR descriptions/reviews/CI evidence. When a change updates current contract truth, edit the existing relevant section or use an explicit amendment/status/superseding document when historical provenance must remain visible.

**Canonical documents record current truth; reviews record inspection history; Git records implementation history.**

---

## 15. Local private PDF test corpus

Private smoke-test PDFs live only under:

```text
scratch/test_pdfs/<subject>/single/
```

Rules:

1. Do not scan outside `scratch/test_pdfs/` for test PDFs.
2. Do not modify, rename, copy, upload, commit, or track private PDFs.
3. Do not copy real question text into fixtures/logs/diagnostics/reports.
4. Reports may include only filenames, counts, question numbers, stages, statuses, and redacted metrics.
5. One PDF is one independent smoke run/import task.
6. Do not scan/read/execute historical `paired/` directories.
7. Supplemental-answer document matching is governed by the frozen P6
   canonical contract in `docs/architecture/p6-supplemental-answer-matching.md`:
   explicit supplemental file + explicit target scope, transient
   `AnswerCandidate`, and the existing typed answer mutation authority.
   Paired/combined/automatic two-PDF merge remains permanently prohibited.

---

## 16. Reporting

Report only relevant results:

- changed files and behavior;
- commands/tests actually executed and exit/result;
- skipped/failed checks;
- remaining risks/out-of-scope findings;
- commit SHA only when created;
- `git status --short` when operating in a worktree.

Do not hide failures. If the host does not expose actual child model identity, report the requested route and any observed fallback; do not require unsupported self-attestation such as `MODEL IDENTITY: UNCONFIRMED`.
