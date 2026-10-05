# Agent Workflow Guide

`AGENTS.md` owns shared permissions, budgets, verification/merge gates and Git
policy. Role files own only role operations. Canonical contracts own durable
product/architecture semantics.

## Route

```text
Planner/Diagnostician when needed
-> temporary task package
-> Executor + required durable docs + checks + authorized PR delivery -> STOP
-> standing PR CI
-> Verifier only for credible CI coverage gaps
-> Independent Reviewer
-> bounded same-PR repair + fresh CI/review when needed
-> user-authorized merge
```

There is no mandatory post-approval documentation commit.

## Temporary writable package

```text
角色：执行
任务：<bounded objective>
Base: <authorized base>
Branch: <assigned branch>
Branch mode: create | reuse
Canonical contract: <governing paths or none>
Task package location: current context | PR body ## Task package
Documentation responsibility:
- <exact repository path>: UPDATE | CHECK_ONLY
# or: none
Expected ownership paths: <primary files/modules>
Strict path whitelist: no | yes
Frozen task semantics: <invariants>
Acceptance: <criteria>
Validation: <checks>
Git: branch-create yes|no; stage yes|no; commit yes|no; push yes|no; PR-create yes|no; merge yes|no
PR metadata outside ## Task package: title/body-update yes|no
Review repair rounds used: <count>
Stop conditions: <extra blockers>
```

The package is ephemeral. Before PR creation it stays in handoff/context; after
PR creation it is maintained in the PR body's `## Task package` section.
Updating that section within the authorized objective does not change commit SHA
and does not create new authority. Do not commit sibling task Markdown files,
task queues, status tables or completion markers.

`UPDATE` docs must already be current on the candidate head before review.
`CHECK_ONLY` docs are inspected for contradiction. Use `none` when appropriate.

For durable staged work, keep one focused canonical capability contract where
practical. Put implementation order/prerequisites there; keep execution history
in Git/PR/CI/review evidence.

Standing `PR contract checks` is the default independent deterministic verifier.
Create a Verifier assignment only for required acceptance not credibly covered by
CI. Reviewer reads the governing contract, final PR-body task package, evidence,
Documentation responsibility and focused diff. Missing required durable docs are
normal review findings routed through same-PR repair; Reviewer does not patch
tracked files.

Final approval requires exact-head/current-target CI, zero P0/P1/P2, closed
Documentation responsibility and any required Verifier evidence.