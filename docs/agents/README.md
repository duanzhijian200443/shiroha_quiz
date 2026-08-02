# Multi-Agent Development Workflow

This directory defines role-specific instructions for AI-assisted development.
All agents must also follow the repository-level `AGENTS.md`.

Repository roles describe responsibilities and permissions. The host-level
Codex configuration selects models and cost tiers; this repository does not
bind a role to a provider or model.

## Standard workflow

```text
Human
  -> Coordinator
       -> Planner / Diagnostician (bounded read-only work; may run in parallel)
       -> Shared-contract checkpoint
       -> Executor A in Worktree A
          Executor B in Worktree B (only when ownership does not overlap)
       -> Branch-level Verifier for each frozen implementation
       -> Coordinator serial integration
       -> Integration-level Verifier + Reviewer (same frozen snapshot)
  -> Human merge/push decision
```

The Coordinator is an orchestration layer around the existing specialist
roles. It does not replace their permissions or turn every task into parallel
work.

## Hard gates

1. **Shared-contract gate:** public contracts, ownership, compatibility, base
   commit, and integration order are frozen before parallel writes.
2. **Implementation-freeze gate:** an Executor stops writing before Verifier or
   Reviewer starts.
3. **Branch-validation gate:** each implementation worktree or target commit is
   validated before integration.
4. **Integration gate:** validated branches/diffs are integrated serially; the
   result is frozen before integration-level verification and review.
5. **Human gate:** merge and push require explicit user authorization.

Validation or review of a moving target is invalid.

## Permission model

| Role | Recommended permission | May edit tracked files |
|---|---|---:|
| Coordinator | Workspace write when integration is authorized | Coordinator-owned integration scope only |
| Planner | Read-only | No |
| Diagnostician | Read-only | No |
| Executor | Workspace write | Yes, assigned files only |
| Verifier | Workspace write for build caches | No |
| Reviewer | Read-only | No |

Avoid unrestricted full access for ordinary child tasks. Git branch, worktree,
commit, merge, and push operations remain separately authorization-gated by
`AGENTS.md`.

## Coordinator prompt template

```text
角色：总控

Read AGENTS.md, ARCHITECTURE.md, and docs/agents/coordinator.md.

Goal:
[describe the outcome]

Repository modification scope:
- [allowed paths]

Git authorization:
- create branches/worktrees: [yes/no, exact names and paths when yes]
- commits: [yes/no]
- integration: [yes/no, exact method when yes]
- push: no

Decide SERIAL, READ_ONLY_PARALLEL, or
WRITE_PARALLEL_AFTER_CHECKPOINT. Freeze shared contracts and ownership before
dispatching writers. Do not duplicate delegated work.
```

## Planner prompt template

```text
角色：规划

Read AGENTS.md, ARCHITECTURE.md, and docs/agents/planner.md.
Work strictly read-only.

Issue:
[describe the issue]

Return one bounded task package, including parallelization eligibility,
dependencies, shared-contract checkpoint, and file ownership. Do not create
agents or worktrees and do not implement the solution.
```

## Executor child template

```text
角色：执行

Read AGENTS.md, ARCHITECTURE.md, and docs/agents/executor.md.

Base commit: [sha]
Assigned worktree: [absolute path]
Assigned branch: [branch or detached]
Allowed files:
- [file]
Forbidden files/worktrees:
- [file or path]
Dependencies/checkpoint: [frozen checkpoint]
Commit authorized: [yes/no]
Allowed commit paths: [exact paths or none]
Push authorized: no
Acceptance criteria: [criteria]
Focused validation: [commands]
Stop conditions: [conditions]
Handoff budget: 800 tokens

Modify no other tracked file. Work silently and return only COMPLETE, BLOCKED,
or FAILED.
```

## Verifier child template

```text
角色：验证

Read AGENTS.md and docs/agents/verifier.md.
Work strictly verification-only.

Verification target:
- base commit: [sha]
- target commit: [sha], or frozen stopped worktree: [absolute path]
- allowed commands: [focused commands]

Do not start while a writer is active. If the target changes, return BLOCKED
and invalidate partial results. Do not fix failures or modify tracked files.
Handoff budget: 800 tokens.
```

## Reviewer child template

```text
角色：审查

Read AGENTS.md, ARCHITECTURE.md, and docs/agents/reviewer.md.

Review target: [base_commit..target_commit]
Fallback when commits are not authorized: [frozen stopped worktree and captured
status/diff]
Task package: [bounded package]
Verifier report: [report]

Review only the fixed target. Do not modify files. Return evidence-backed
findings and both required verdicts. Handoff budget: 1200 tokens.
```

## Worktrees and ownership

- One working directory has at most one active writer.
- Concurrent writers use separate worktrees with non-overlapping file ownership.
- A child operates only inside its assigned worktree and never reads or runs
  commands in another child's worktree.
- Shared contract/model/schema files remain Coordinator-owned until frozen.
- The Coordinator does not edit a shared working tree while a child writer is
  active there.
- Read-only agents may share a directory only when they are not verifying or
  reviewing an active writer's moving target.

When explicitly authorized, the Coordinator may prepare worktrees using exact
paths and branches, for example:

```powershell
git worktree add ..\shiroha_quiz-task-a -b codex/task-a <base-commit>
git worktree add ..\shiroha_quiz-task-b -b codex/task-b <base-commit>
```

These commands are examples, not standing authorization to create branches or
worktrees.

## Child communication

Children run silently and return only `COMPLETE`, `BLOCKED`, or `FAILED`.
Default handoff budgets are defined in `AGENTS.md`. Do not paste complete diffs,
source files, logs, or investigation transcripts. The Coordinator waits for
terminal events without frequent polling and does not repeat delegated work.

## Deterministic validation

Focused validation belongs to a Verifier, ordinary low-cost agent, local
terminal, or CI. Full validation is run only when requested or before release:

```powershell
.\scripts\verify.ps1
```

Use high-capability reasoning for architecture, uncertain root cause, security,
concurrency, database safety, shared contracts, and final integration decisions.
