# Multi-Agent Development Workflow

This directory defines role-specific instructions for AI-assisted development. All agents also follow repository-level `AGENTS.md`.

## Default workflow

```text
Human / Coordinator
  -> Planner or Diagnostician only when needed
  -> Executor
       - implement
       - add/update regressions
       - focused tests / architecture checks
       - analyze / format / diff-check
       - bounded self-repair when permitted
       - commit / push / create PR when authorized
       - STOP
  -> Independent Reviewer
       - read final PR independently
       - semantic / architecture / contract review
       - P0/P1/P2/P3
  -> Human-authorized merge
```

A standalone Verifier is no longer a default phase. Use it only for risk-triggered independent verification defined in `AGENTS.md`.

## Hard gates

1. **Scope/contract gate:** behavior, allowed paths and relevant durable contract are frozen before writing.
2. **Executor verification gate:** required focused mechanical checks must pass before completion PR delivery.
3. **Independent review gate:** the Reviewer evaluates the fixed final PR head independently; green Executor checks do not equal semantic approval.
4. **Repair gate:** open P0/P1/P2 findings require bounded repair + fresh Reviewer closure before merge.
5. **Human Git gate:** branch/commit/push/PR/merge remain separately authorization-gated.

Validation or review of a moving target is invalid.

## Roles

| Role | Default use | May edit tracked files |
|---|---|---:|
| Coordinator | Orchestration/integration | Coordinator-owned integration only |
| Planner | Contract/architecture planning when needed | No |
| Diagnostician | Uncertain root cause | No |
| Executor | Implementation + mechanical verification + PR delivery | Yes, assigned paths only |
| Verifier | Optional independent deterministic verification | No |
| Reviewer | Independent final semantic review | No |

## Executor package template

```text
角色：执行
目标：<bounded objective>

Base/Branch: <target identity>
Allowed paths: <exact paths>
Parent-attested evidence: <frozen facts>
Task-specific invariant/constraints: <only current semantics>
Acceptance: <criteria>
Validation: <focused tests/checks/timeouts>
Local commits authorized: yes | no
Branch: <assigned branch>
Commit paths: <exact paths>
Push authorized: yes | no
PR creation authorized: yes | no
Merge authorized: yes | no
Stop only if: <scope/contract/environment/repair-budget conditions>
```

Executor may self-repair verification failures only under `AGENTS.md` bounded policy. After PR creation it stops for independent review.

## Optional Verifier package

```text
角色：验证
目标：<independent verification objective>

Verification target: <fixed PR head/commit>
Allowed commands: <exact deterministic checks>
Reason for independent verification: <risk trigger>
```

Verifier never fixes failures.

## Reviewer package template

```text
角色：审查
目标：最终独立语义审查

Review target: <base..final PR head>
Frozen contract: <task/contract refs>
Executor verification evidence: <summary>
Optional Verifier evidence: <summary or none>
Review difficulty: light | ordinary | high
Reason: <one concrete sentence>
```

Reviewer does not modify or merge. It returns `APPROVE` or `REQUEST_CHANGES` plus P0/P1/P2/P3.

## Repair flow

```text
Reviewer P0/P1/P2
-> bounded Repair Executor on same PR
-> Executor verification
-> push
-> STOP
-> targeted fresh Reviewer pass
```

P3 is deferred by default.

## Worktrees and ownership

- one active writer per working directory;
- concurrent writers require separate worktrees and non-overlapping ownership;
- shared contract/model/schema files remain frozen/Coordinator-owned until explicitly assigned;
- read-only agents do not review a writer's moving target.

## Deterministic validation

Focused deterministic validation normally belongs to the Executor. CI can repeat repository-required gates. Full validation (`.\scripts\verify.ps1`) is only for explicit release/global acceptance or user request.
