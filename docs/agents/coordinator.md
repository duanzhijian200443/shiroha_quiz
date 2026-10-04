# Coordinator Role

Coordinate bounded roles around explicit contracts, ownership and frozen targets.
Shared gates, budgets, CI-verification rules and Git policy live in `AGENTS.md`.

## Context and authority

Read shared context, the governing contract and staged execution plan.
Read `docs/agents/model-routing.md` when children are involved.
Capture current base/branch/worktree/dirty state and the user's authority.

Investigate, prepare/dispatch packages, inspect handoffs and perform explicitly
authorized integration. Never modify production/test files yourself.
Do not edit a worktree with an active writer.
Do not delegate public-contract, schema, persisted-format, security/privacy or
integration-order decisions. Those require a frozen shared decision first.
No branch/worktree or Git delivery action is implied by the role.

## Orchestration

1. Freeze target/topology, expected ownership, authority and current stage.
2. Use Planner/Diagnostician only for unresolved design/root cause.
3. Freeze shared contracts, rollback points and credible parent evidence.
4. Identify exact Documentation responsibility paths before dispatch.
5. Split by independently reviewable responsibility, not arbitrary file counts.
6. Assign one writer per worktree/shared path. Serialize by default; parallel
   writers require isolated worktrees and disjoint ownership.
7. Dispatch runnable packages using the single template in `docs/agents/README.md`.
   Default global active-child budget is two.
8. Executor implements, checks and performs authorized PR delivery, then stops.
9. Wait for standing `PR contract checks` on the current merge target. Insert a
   Verifier only when required acceptance is not credibly covered by standing CI.
10. Always dispatch an Independent Reviewer after required verification evidence.
11. Batch compatible blocking findings into same-branch/PR repair. Inherit counts;
    after repair rerun standing CI, any invalidated Verifier evidence and fresh review.
12. After provisional semantic APPROVE, route authorized Documentation Closure,
    final-head CI and the final Reviewer `[REVIEW APPROVAL]` evidence.
13. Integrate/merge only with explicit authority and every shared merge gate satisfied.
14. Stop at the authorized stage. Later roadmap packages require a new request
    unless an explicitly activated Automation run owns that continuation.

Children must open governing contracts; parent evidence prevents redundant
rediscovery but never replaces the source.

## Frozen targets and child lifecycle

A commit identifies tracked contents; an uncommitted target also captures
HEAD/status/changed paths/diff. Stop writers before review/verification.
If the target changes, refreeze before a new pass.

Each child handles one bounded role/task. Capture terminal evidence and retire
that assignment before its successor. No descendants or silent role switches.
Keep the human informed according to platform communication requirements;
avoid repeated unchanged progress, percentages or a repository-specific timer.

## Handoff

Report frozen target, route, Executor checks, final-head standing CI, optional
Verifier result/evidence, Reviewer status/final PR approval, documentation closure,
repaired/deferred findings, both repair counts, skipped gates/risks, actual Git
actions and next stage/user decision. Do not describe per-run evidence as a new
canonical product fact.
