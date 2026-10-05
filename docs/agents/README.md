# Agent Workflow Guide

`AGENTS.md` owns shared permissions, safety, budgets, verification/merge gates
and Git policy. Role files own only their role's operations and outputs.
`ARCHITECTURE.md` and focused contracts own product/architecture semantics.

## Normal route

```text
Human / Coordinator
-> Planner or Diagnostician when needed
-> Executor + mechanical checks + authorized PR delivery -> STOP
-> standing PR CI as the default independent verification gate
-> Verifier only when required acceptance is not credibly covered by CI
-> mandatory Independent Reviewer
-> bounded same-PR repair + fresh CI/review when needed
-> user-authorized merge
```

Normal review identity is the Git target: final PR head + current base/merge
target. PR-body notes are not part of review identity or merge readiness.

## Roles

| Role | Responsibility | Tracked edits |
|---|---|---|
| Coordinator | Freeze, dispatch, inspect, authorized integration | Explicit Coordinator-owned integration only; no production/tests |
| Planner | Contract/design and bounded execution handoffs | No |
| Diagnostician | Failure boundary/root cause | No |
| Executor | Implementation, checks and authorized delivery | Assigned responsibility |
| Verifier | Independent checks CI cannot credibly cover | No |
| Reviewer | Independent semantic verdict + PR evidence | Read-only |

## Optional delegated execution handoff

Use a compact handoff only when delegation benefits from explicit task facts.
Direct user instructions may supply the same information; a normal task does not
need a formal handoff and nothing here must be copied into the PR body.

```text
角色：执行
任务：<bounded objective>

Base: <authorized base>
Branch: <assigned branch>
Branch mode: create | reuse
Canonical contract: <governing paths or none>
Documentation responsibility: <affected durable docs or none>
Expected ownership paths: <primary files/modules>
Strict path whitelist: no | yes
Frozen task semantics: <current-stage invariants>
Acceptance: <focused criteria>
Validation: <focused checks>
Authorized Git/PR actions: <only actions already granted by the user/current task>
Authority source: <trusted user instruction or inherited user-approved task>
Review repair rounds used: <inherited count>
Stop conditions: <task-specific blockers beyond AGENTS.md>
```

The handoff is disposable context. It records authority but never creates it.
With `Strict path whitelist: yes`, list exact repository-relative paths. Directly
necessary coupled paths may be added only under the shared ownership/authority
rules. Do not persist handoffs as sibling task Markdown, completion markers or a
second queue.

## Durable documentation

When accepted behavior changes durable product/architecture truth, update the
governing canonical docs in the same candidate head. A handoff may list expected
documentation paths, but Reviewer still checks contract/diff agreement
independently and may find stale docs that were not listed.

For durable staged work, prefer one focused canonical capability contract such as
`docs/product/<capability>.md`. Git/PR/CI/review evidence owns exact execution
history.

## Independent verification and review

Standing automatic `PR contract checks` is the default independent deterministic
verification authority and must cover the current head/current merge target.

Create a Verifier assignment only when required acceptance is not credibly covered
by standing CI. Include the objective, fixed head/base target, governing contract,
exact assigned commands/observations and the concrete CI coverage gap. Verifier
never repairs.

Reviewer reads the original user task/current handoff when relevant, governing
contract, Executor/CI evidence, optional Verifier evidence, changed paths and
focused diff. Final approval requires current-target CI, durable-doc consistency,
zero open P0/P1/P2 and any required Verifier evidence.

## Automation separation

Only explicit `角色：自动化` uses `docs/automation/README.md`. Automation may
maintain non-authoritative resumable PR-body state as a convenience. Normal roles
do not require, hash, freeze or validate that state, and it never participates in
Reviewer/Verifier approval identity or the merge gate.

## Evidence and merge readiness

Before merge require:
- final-head/current-target standing CI success;
- final Reviewer `[REVIEW APPROVAL]` for that head/base;
- any required Verifier `[VERIFICATION APPROVAL]` for that head/base;
- canonical/durable docs consistent with the accepted change;
- explicit merge authority.

Later-stage work still requires its own user scope/authority unless explicit
Automation continuation already covers it.