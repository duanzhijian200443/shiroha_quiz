# Shiroha Quiz Agent Instructions

## 1. Scope and precedence

These instructions apply to all agent work in this repository.

When instructions conflict:

1. Follow higher-level platform and explicit current-user instructions.
2. Follow the more restrictive repository safety/privacy/Git rule.
3. Follow this file before role-specific workflow text.
4. Follow the active role file.
5. Stop for user direction only when the conflict cannot be resolved safely.

Operate only inside this repository unless the user explicitly authorizes otherwise.

---

## 2. Required context and rule routing

Before a non-trivial task, read:

- `ARCHITECTURE.md`;
- the active role file under `docs/agents/`;
- relevant implementation/tests/current diff;
- only the `.agents/rules/` files needed for the current task.

Do not claim a file was reviewed unless it was opened during the current task.

| Rule file | Read when |
|---|---|
| `.agents/rules/architectural-discipline.md` | Every non-trivial repository task |
| `.agents/rules/git_work.md` | Git status/diff/staging/commit/branch/history/push decisions are involved |
| `.agents/rules/reviewer.md` | Only when the first line activates `角色：审查` |

Do not enumerate or load unrelated rule files.

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

Read the mapped role file before continuing. Do not silently switch roles. Without an explicit role, do not assume write authority.

---

## 4. Architecture and change discipline

Preserve the canonical dependency direction in `ARCHITECTURE.md`:

```text
Flutter UI / Built-in Agent / MCP Adapter
                  -> Application
                  -> Domain

Data / Infrastructure -> Application ports / Domain
```

`main.dart` or another explicit composition root may wire concrete repositories, databases and providers.

Requirements:

- UI, Agent and MCP adapters do not access SQLite/`DatabaseHelper` directly.
- New presentation features do not add direct Repository dependencies when an Application seam exists.
- Cross-surface use-case semantics belong in Application services/facades.
- Persistence belongs in Repositories/data infrastructure.
- Domain code does not depend on Flutter, SQLite, provider DTOs, HTTP clients or file-system APIs.
- The built-in Agent does not call the app's own MCP transport; they are peer adapters.
- New AI/MCP mutation flows stage through Application commands and the frozen approval boundary.
- Preserve typed sidecar authority, strict corrupt-sidecar failure, typed explicit-empty semantics, RichContent structural rendering and review-state/content separation.
- Reuse existing abstractions before adding new ones.
- Verify the actual failure boundary before escalating upstream.
- Make the smallest coherent change that satisfies the frozen contract.
- Do not refactor, rename, reformat, generalize, or future-proof unrelated code.
- Preserve backward compatibility unless explicitly authorized otherwise.
- Do not change public APIs, persisted formats, schema, dependencies, CI/release/signing, or security/privacy contracts unless explicitly in scope.
- Preserve unrelated user changes. Report nearby issues instead of fixing them automatically.

High-risk areas include persistence/migrations, managed-file lifecycle, async recovery/concurrency, logging/redaction, credentials, OCR/AI boundaries, Agent/MCP write permissions, authorization, and global exception handling.

---

## 5. Default development workflow

The default workflow is now:

```text
Planner (only when needed)
  -> Executor + mechanical verification
  -> commit / push / PR when authorized
  -> STOP
  -> Independent Reviewer
  -> APPROVE or bounded repair
  -> user-authorized merge
```

A standalone Verifier is **not** a default phase.

### Planner is used only when

- a new durable contract must be frozen;
- architecture or root cause is unresolved;
- a high-risk cross-layer change needs design first;
- schema/public API/security/privacy/concurrency semantics are not already frozen;
- the user/Coordinator explicitly requests planning.

### Executor owns implementation + mechanical verification

For implementation:

1. inspect relevant code/tests/current diff;
2. verify the reported problem unless an evidence-backed root cause is already frozen;
3. freeze task-specific behavior and allowed paths;
4. add/update the minimum regression evidence;
5. make the smallest coherent change;
6. run focused tests/checks, relevant architecture gates, focused analyze, format gate and `git diff --check` as applicable;
7. inspect final changed paths/diff for scope drift;
8. when Git authority allows, commit exact paths, push the assigned branch and create the PR;
9. STOP after PR creation and hand off the fixed PR head to the Independent Reviewer.

Executor verification is self-check evidence, not semantic approval.

### Independent Reviewer

The Reviewer re-reads the final fixed PR target independently. Executor reports are evidence records, not proof of correctness. The Reviewer checks semantics, architecture, frozen contracts, privacy/authorization, concurrency/transaction/persistence boundaries when relevant, regression strength and scope discipline.

The Reviewer returns P0/P1/P2/P3 findings and `APPROVE` or `REQUEST_CHANGES`. The Reviewer does not implement repairs or merge.

---

## 6. Verification failure and bounded self-repair policy

A failed Executor check does **not** automatically require STOP.

Executor MAY self-repair only when all are true:

1. the failure is causally related to the current authorized task;
2. the root cause is identified with concrete evidence;
3. the repair stays entirely inside `Allowed paths` / `Commit paths`;
4. the repair does not alter frozen architecture/canonical semantics;
5. the repair does not weaken, skip, delete, relax, or bypass the failing verification;
6. no unrelated bug fix or new feature is introduced.

After repair, rerun the failed check and the directly affected regression set.

### Repair budget

- Up to **two bounded semantic/implementation repair cycles** are allowed by default during one Executor task.
- Mechanical cleanup such as format, import ordering, lint-only cleanup, or a trivial compile fix does not consume a semantic repair cycle.
- Do not turn this budget into permission for speculative trial-and-error.

### Mandatory STOP

STOP instead of self-repair when:

- an additional write path is required;
- schema/migration/public API/frozen contract changes become necessary;
- the failure reveals a separate pre-existing defect rather than the current task;
- root cause is uncertain;
- fixing requires weakening/removing a test or check;
- privacy, authorization, concurrency, transaction, or persistence semantics become ambiguous;
- two bounded repair cycles fail to reach clean verification;
- the repair would materially broaden the task.

On STOP, report the failing command/test, first useful failure, root-cause evidence, repairs attempted, current diff/status, and the smallest proposed next scope. Do not create a completion PR with mandatory verification still failing.

---

## 7. When to use an independent Verifier

`角色：验证` remains available but is optional/risk-triggered.

Use an independent Verifier when one or more apply:

- schema migration or data migration;
- destructive data operation;
- high-risk transaction/concurrency behavior;
- security/privacy/authorization boundary;
- Executor evidence is internally inconsistent or not credible;
- flaky/environment-dependent failure needs independent classification;
- real-provider, real-device, release/runtime acceptance;
- the Reviewer explicitly requests an independent deterministic re-check.

Then the route is:

```text
Executor + self-verification -> Independent Verifier -> Independent Reviewer
```

Otherwise use the default:

```text
Executor + self-verification -> Independent Reviewer
```

---

## 8. Git authority

Never run destructive/history-rewriting Git operations, including `git reset --hard`, destructive `git checkout`/`git restore`, `git clean -fd[x]`, force push, or history rewriting.

Git authority is action-specific. Staging does not authorize commit; commit does not authorize push; push does not authorize PR creation; PR creation does not authorize merge/tag/release. Branch/worktree creation also requires explicit authority.

Never use `git add .` or `git add -A`. Use exact paths. Do not create/update `DEVELOPMENT_LOG.md` unless explicitly in scope.

An Executor may create local commits only when its package supplies all of:

```text
Local commits authorized: yes
Branch: <assigned branch>
Commit paths: <exact allowed paths>
Push authorized: no | yes
PR creation authorized: no | yes
Merge authorized: no | yes
```

When authorized, append-only commits required by the current task and policy-permitted bounded self-repair are allowed within the same branch/path limits. Commit count is not a safety boundary.

The following remain forbidden unless separately authorized:

- amend/rebase/squash/history rewrite;
- paths outside `Commit paths`;
- repair passes beyond the closure limits;
- push, PR, merge, tag, or release when not separately authorized.

Before and after write work, inspect `git status --short`. Preserve unrelated tracked/untracked files.

---

## 9. Security and privacy

Never expose, copy, persist, test-log, or report secrets such as API keys, tokens, authorization headers, signing material, passwords, credentials, private configuration, or complete private file contents.

Avoid logs/reports containing complete prompts, answers/explanations, raw OCR text, provider bodies, Base64 payloads, sensitive absolute paths, or raw exception messages that may contain private data. Prefer counts, IDs, stages, statuses, safe error categories, runtime types, and redacted metrics.

Network/provider use is disabled by default unless the task explicitly requires it.

---

## 10. Validation and evidence economy

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
- Regression tests prove behaviors/invariants, not implementation lines.
- Prefer one direct regression plus only materially necessary boundary/failure/concurrency coverage.
- Test volume is not evidence quality.

A command with no meaningful progress for 3 minutes is stalled. Preserve evidence; do not silently raise timeouts or retry indefinitely.

---

## 11. Findings and review-driven repair

Severity:

- **P0 Critical**: secret exposure, destructive corruption, catastrophic security/privacy failure.
- **P1 Blocking**: data loss, crash, broken core behavior, violated frozen invariant, serious compatibility/concurrency failure.
- **P2 Merge-blocking correctness**: bounded but meaningful correctness/compatibility/concurrency/required-acceptance gap that should be fixed before merge.
- **P3 Non-blocking**: maintainability, documentation drift, optional/extra coverage, cleanup, low-impact hardening.

P3 does not automatically trigger repair.

After the Independent Reviewer:

```text
P0/P1/P2 finding
  -> bounded Repair Executor on the same PR when scope remains valid
  -> Executor mechanical verification + bounded self-repair policy
  -> push updated PR
  -> STOP
  -> fresh targeted Reviewer pass
```

Repeat only within the task's repair limits. If repair changes architecture/public contract/schema/security/concurrency semantics or invalidates the original review scope, stop and re-plan/review at the appropriate level.

Merge is acceptable only when open task P0/P1/P2 findings are zero and required CI/gates are satisfied.

---

## 12. Multi-agent orchestration

Repository-wide orchestration uses `角色：总控`.

Coordinator responsibilities:

- freeze base/branch/worktree/dirty state and shared contracts once before dispatch;
- serialize by default; parallel writers require isolated worktrees and non-overlapping ownership;
- delegate bounded tasks with exact file ownership and parent-attested evidence;
- never edit production/test files itself;
- stop writers before reviewing/verifying a frozen target;
- route ordinary completed implementation directly to Independent Reviewer;
- insert a standalone Verifier only under the risk triggers in section 7;
- integrate only when explicitly authorized;
- never automatically push/merge unless explicitly authorized.

A child has one bounded role/task, may not create descendants, switch roles, expand scope, or decide public architecture/contracts.

---

## 13. Canonical contract discipline

A canonical document records durable current truth, not a development log, review-findings dump, test report, or substitute for Git history.

Before planning a stage that may change durable truth, identify only the relevant canonical documents.

Role responsibilities:

- **Planner:** states whether the task preserves or changes durable contract truth and which canonical docs would be affected.
- **Executor:** updates canonical docs only when an authorized implementation changes durable truth; ordinary bug fixes do not edit docs merely for completeness.
- **Reviewer:** checks both directions of implementation/contract drift.
- **Verifier:** when explicitly used, checks conformance to already-frozen contract and does not redesign it.

Preserve historical truth through amendments/status updates/superseding docs rather than rewriting history as though later decisions always existed.
