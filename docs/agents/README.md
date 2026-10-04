# Agent Workflow Guide

`AGENTS.md` owns shared permissions, safety, budgets, verification triggers and
Git policy. Role files own only their role's operations and outputs.
`ARCHITECTURE.md` and focused contracts own product/architecture semantics.

## Route

```text
Human / Coordinator
-> Planner or Diagnostician when needed
-> Executor + mechanical checks + authorized delivery -> STOP
-> optional risk-triggered Verifier
-> Independent Reviewer
-> bounded same-PR repair and targeted closure when needed
-> user-authorized merge
```

Review/verification require a frozen target and a stopped writer.
Green self-checks do not constitute independent approval.

## Roles

| Role | Responsibility | Tracked edits |
|---|---|---|
| Coordinator | Freeze, dispatch, inspect, authorized integration | Explicit Coordinator-owned integration only; no production/tests |
| Planner | Contract/design and runnable packages | No |
| Diagnostician | Failure boundary/root cause | No |
| Executor | Implementation, checks and authorized delivery | Assigned responsibility |
| Verifier | Assigned independent deterministic checks | No |
| Reviewer | Independent semantic verdict | No |

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
Execution plan: <path or none>
Expected ownership paths: <primary files/modules>
Strict path whitelist: no | yes
Frozen task semantics: <current-stage invariants>
Acceptance: <focused criteria>
Validation: <focused checks>
Git: branch-create yes|no; stage yes|no; commit yes|no; push yes|no; PR-create yes|no; merge yes|no
Review repair rounds used: <0 initially; inherited count for repair>
Stop conditions: <task-specific blockers beyond AGENTS.md>
```

Use `create` for authorized initial branch creation and `reuse` for same-task
follow-ups/repair. Missing Git actions are unauthorized.
`PR-create` covers creation only. Title/body updates, comment/review submission,
close/reopen and other PR mutations require separate explicit task/user authority
under `AGENTS.md`; do not infer them from PR creation or push authority.
Add Worktree and its authority only when isolation is needed.
Add directly necessary coupled paths under the shared ownership policy and
report why; strict whitelists require explicit authorization to expand.

## Independent checks/review packages

Verifier package: role, objective, fixed target, governing contract, exact assigned
commands and the risk trigger. Verifier never repairs.

Reviewer package: role, base/final target, original task/contract/plan,
Executor/CI evidence, optional Verifier evidence, assigned review dimensions
and inherited review-round count.

Review status and verdict are separate: a stable completed review gives
`APPROVE / REQUEST_CHANGES`; incomplete evidence gives `INCONCLUSIVE`.
Focused tasks default to global status `NOT_EVALUATED`.

## Evidence and closure

Use concise target identity, changed behavior/paths, actual checks, skipped gates,
repair counts and unresolved risks. Do not duplicate shared rules or full logs.
Each writer owns one coherent responsibility; shared paths have one owner.
Merge and later-stage work always require their own authority.
