# Multi-Agent Development Workflow

This directory defines role-specific instructions for AI-assisted development.

All Agents must also follow the repository-level `AGENTS.md`.

## Recommended workflow

```text
Planner
  -> Task package
Executor
  -> Implementation and focused tests
Verifier
  -> Full validation report
Reviewer
  -> Read-only diff review
Human
  -> Final merge decision
```

## Permission model

| Role | Recommended permission | May edit source |
|---|---|---:|
| Planner | Read-only | No |
| Executor | Workspace write | Yes, within scope |
| Verifier | Workspace write for build caches | No |
| Reviewer | Read-only | No |

Avoid using unrestricted full access for normal development.

## Planner prompt template

```text
角色：规划

Read AGENTS.md, ARCHITECTURE.md, and docs/agents/planner.md.

Work strictly as a read-only Planner.

Analyze only the following issue and produce one bounded task package.
Do not modify files and do not provide a complete implementation.

Issue:
[describe the issue]
```

## Executor prompt template

```text
角色：执行

Read AGENTS.md, ARCHITECTURE.md, and docs/agents/executor.md.

Execute the task package below.

Allowed files:
- [file]
- [file]

No other tracked file may be modified.
If another file is required, stop and request approval.

Task package:
[paste task package]
```

## Verifier prompt template

```text
角色：验证

Read AGENTS.md and docs/agents/verifier.md.

Work strictly as a verification-only Agent.
Do not fix failures and do not modify tracked files.

Run:

1. dart format --output=none --set-exit-if-changed .
2. flutter analyze
3. flutter test --reporter expanded

Return a concise validation report with exit status and failure classification.
```

## Reviewer prompt template

```text
角色：审查

Read AGENTS.md, ARCHITECTURE.md, and docs/agents/reviewer.md.

Review only:

- the supplied task package;
- the current uncommitted Git diff;
- changed tests;
- the Verifier report.

Do not modify files.
Report only evidence-backed findings.
If no blocking findings exist, state that the patch is acceptable to merge.
```

## Full validation

Run:

```powershell
.\scripts\verify.ps1
```

Full validation is deterministic work and should normally be performed by a
script, CI, or a low-cost Verifier Agent.

Use a high-capability Agent primarily for:

- uncertain root-cause analysis;
- security-sensitive changes;
- concurrency;
- database migrations;
- global exception handling;
- architecture decisions;
- final diff review.

## Parallel work

Do not allow multiple write-enabled Agents to operate in the same working tree
at the same time.

Use separate Git worktrees for parallel implementations.

Example:

```powershell
git worktree add ..\shiroha_quiz-task-a -b agent/task-a
git worktree add ..\shiroha_quiz-task-b -b agent/task-b
```

Each Agent must operate only inside its assigned worktree.
