# Agent Workflow Guide

`AGENTS.md` owns shared permissions, safety, budgets, verification/merge gates
and Git policy. Role files own only their role's operations and outputs.
`ARCHITECTURE.md` and focused contracts own product/architecture semantics.

## Route

```text
Human / Coordinator
-> Planner or Diagnostician when needed
-> Executor + mechanical checks + authorized PR delivery -> STOP
-> standing PR CI as the default independent verification gate
-> Verifier only when required acceptance is not credibly covered by CI
-> mandatory Independent Reviewer
-> bounded same-PR repair and fresh closure when needed
-> authorized Documentation Closure
-> final-head CI + final Reviewer PR approval
-> user-authorized merge
```

Review/verification require a frozen target and a stopped writer.
Green Executor checks do not constitute independent approval. Standing CI normally
owns deterministic verification; Reviewer always owns semantic approval.

## Roles

| Role | Responsibility | Tracked edits |
|---|---|---|
| Coordinator | Freeze, dispatch, inspect, authorized integration | Explicit Coordinator-owned integration only; no production/tests |
| Planner | Contract/design and runnable packages | No |
| Diagnostician | Failure boundary/root cause | No |
| Executor | Implementation, checks and authorized delivery | Assigned responsibility |
| Verifier | Independent checks CI cannot credibly cover | No |
| Reviewer | Independent semantic verdict + authorized documentation closure | Read-only during review; listed docs only during closure |

## Writable package

Use this template for initial execution and repair; keep only task-specific facts.
Explicit user instructions may supply the same information without a formal package.

```text
角色：执行
任务：<bounded objective>

Base: <authorized base>
Branch: <assigned task branch>
Branch mode: create | reuse
Canonical contract: <governing paths or none>
Task package: <current package path or inline task>
Documentation responsibility:
- <exact path>: UPDATE | CHECK_ONLY
# or: none
Expected ownership paths: <primary files/modules>
Strict path whitelist: no | yes
Frozen task semantics: <current-stage invariants>
Acceptance: <focused criteria>
Validation: <focused checks>
Git: branch-create yes|no; stage yes|no; commit yes|no; push yes|no; PR-create yes|no; merge yes|no
PR evidence: comment yes|no; review-submit yes|no; title/body-update yes|no
Documentation closure: reviewer-update yes|no; commit yes|no; push yes|no
Review repair rounds used: <0 initially; inherited count for repair>
Stop conditions: <task-specific blockers beyond AGENTS.md>
```

Use `create` for authorized initial branch creation and `reuse` for same-task
follow-ups/repair. Missing Git/PR actions are unauthorized.
`PR-create` covers creation only. Title/body updates, comments/review submissions,
close/reopen and other PR mutations require the corresponding explicit authority
under `AGENTS.md`; do not infer them from PR creation or push authority.
Add Worktree and its authority only when isolation is needed.

`Documentation responsibility` is mandatory for a completion package:
`UPDATE` means accepted delivery changes durable truth/status and the path must be
closed before final approval; `CHECK_ONLY` means the Reviewer verifies that the
existing text is not stale or contradictory. Use explicit `none` when no durable
document can change. Do not make agents rediscover closure paths from memory.

For durable staged work, prefer `docs/product/<capability>/00-contract.md` plus
optional numerically ordered sibling task packages. Do not add `Task-ID`,
`Status`, or a separate execution-plan file just to mirror progress. The package
path/filename is sufficient scheduling identity. A tracked package is renamed with
the `-完成.md` suffix only in final Documentation Closure as defined by
`AGENTS.md`.

Add directly necessary coupled paths under the shared ownership policy and report
why; strict whitelists require explicit authorization to expand.

## Independent verification and review packages

Standing automatic `PR contract checks` is the default independent verification
authority for completion PRs and must cover the current head/current merge target.

Create a Verifier package only when required acceptance is not credibly covered by
standing CI. Include role, objective, fixed target, governing contract, exact
assigned commands/observations, the CI coverage gap and PR evidence authority.
Verifier never repairs.

Reviewer package includes base/final target, original task/contract/plan,
Executor/CI evidence, optional Verifier evidence, assigned review dimensions,
inherited review-round count, Documentation responsibility and authorized closure
actions.

A stable semantic review may reach provisional `APPROVE`. Final `APPROVE` for a
completion PR comes only after authorized documentation closure, final-head CI and
a targeted final-head check. Final review evidence is recorded on the PR as
`[REVIEW APPROVAL]`. If a Verifier was required, its PASS is recorded as
`[VERIFICATION APPROVAL]`.

## Evidence and closure

Use concise target identity, changed behavior/paths, actual checks, skipped gates,
repair counts and unresolved risks. Do not duplicate shared rules or full logs.
Each writer owns one coherent responsibility; shared paths have one owner.

Before merge, require final-head/current-target CI success, final Reviewer PR
approval, any required Verifier PR approval, closed Documentation responsibility
and explicit merge authority. Later-stage work still requires its own scope and
authority unless an explicitly activated Automation run provides that continuation.
