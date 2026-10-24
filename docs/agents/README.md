# Agent Workflow Guide

`AGENTS.md` owns shared permissions, safety, budgets, verification/merge gates
and Git policy. Role files own only their role's operations and outputs.
`ARCHITECTURE.md` and focused contracts own product/architecture semantics.

## Normal route

```text
Human / Coordinator
-> Planner or Diagnostician when needed
-> Executor + mechanical checks + Verifier-need decision + authorized PR delivery -> STOP
-> standing PR CI as the default independent verification gate
-> mandatory Independent Reviewer; Verifier only when required (either order)
-> bounded same-PR repair + fresh CI/review when needed
-> user-authorized merge
```

Normal review identity is the Git target: final PR head + current base/merge
target. PR-body notes are not part of review identity or merge readiness.

Before implementing a new independent task, verify the latest remote default
branch, safely align the local default with existing authority and create the
authorized task branch from that verified commit. Never inherit a merged PR's
branch/head as the new baseline, including after Squash Merge. Perform this check
at task start; `AGENTS.md` section 7 and `.agents/rules/git_work.md` own the gate.
Continuation of the same unfinished authorized task before PR creation reuses
its verified non-default branch/worktree and original baseline under `AGENTS.md`
section 7. Recheck task identity, scope, authority, baseline evidence, current
HEAD/dirty state and writer ownership, and retain repair counts; do not require
an OPEN PR or restart new-task alignment solely to resume. Explicit delivery
restrictions still apply. Repairs/supplements to an existing PR reuse its verified
OPEN target instead.

## Roles

| Role | Responsibility | Tracked edits |
|---|---|---|
| Coordinator | Freeze, dispatch, inspect, authorized integration | Explicit Coordinator-owned integration only; no production/tests |
| Planner | Contract/design and bounded execution handoffs | No |
| Diagnostician | Failure boundary/root cause | No |
| Executor | Implementation, checks and authorized delivery | Assigned responsibility |
| Verifier | Optional bounded independent checks when required | No |
| Reviewer | Independent semantic verdict + PR evidence | Read-only |

## Optional delegated execution handoff

Use a compact handoff only when delegation benefits from explicit task facts.
Direct user instructions may supply the same information; a normal task does not
need a formal execution handoff. The Acceptance Checklist below summarizes the
delivery; do not copy a resumable execution package into the PR Body.

```text
角色：执行
任务：<bounded objective>

Task kind: independent | continuation-before-PR | repair/supplement
Base: <verified latest remote default commit for new work; original baseline for continuation; existing PR base for repair>
Baseline evidence: <task-start remote/default/tip/local alignment; revalidated original task/branch/baseline for continuation; or OPEN target PR identity>
Branch: <assigned branch>
Branch mode: create | reuse
Canonical contract: <governing paths or none>
Documentation responsibility: <affected durable docs or none>
Expected ownership paths: <primary files/modules>
Strict path whitelist: no | yes
Frozen task semantics: <current-stage invariants>
Acceptance: <focused criteria>
Validation: <focused checks>
Authorized Git/PR actions: <user/task authority and applicable active-role permissions; explicit restrictions>
Authority source: <trusted user instruction or inherited user-approved task>
Self-repair cycles used: <current Executor assignment count; zero only for a genuinely new assignment>
Review repair rounds used: <cumulative count for the same delivery target/task across assignments>
Stop conditions: <task-specific blockers beyond AGENTS.md>
```

The handoff is disposable context. It records authority but never creates it.
With `Strict path whitelist: yes`, list exact repository-relative paths and stop
before any unlisted path; do not add coupled paths without explicit authorization
to expand the whitelist. Only with `Strict path whitelist: no` may directly
necessary coupled paths be added under the shared ownership/authority rules and
reported in handoff. Do not persist handoffs as sibling task Markdown, completion
markers or a second queue.

Keep the two repair counters separate under `AGENTS.md` section 6: self-repair
belongs to the current bounded Executor assignment; review-repair rounds belong
to the same delivery target/task across assignments. A genuinely new authorized
assignment starts only its own self-repair count at zero. Worker replacement,
resumption, handoff rewrites and PR-head changes do not reset applicable counts.

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

Executor decides whether a separate Verifier is needed and records the rationale
under `AGENTS.md` section 5. It is not a mandatory successor. A credible
`NOT_REQUIRED` needs no Verifier run or synthetic approval. For `REQUIRED`, the
bounded assignment includes the objective, fixed head/base target, governing
contract, exact commands/observations and trigger: `CI_COVERAGE_GAP` or
`EXPLICIT_REQUEST` from the user/Reviewer. Explicit requests need no invented CI
gap and do not expand runtime authority. `PENDING_DECISION` is reserved for actual
uncertainty, not a compulsory initial gate. Verifier never repairs.

Reviewer reads the original user task/current handoff when relevant, governing
contract, Executor/CI evidence, optional Verifier evidence, changed paths and
focused diff. Semantic approval requires current-target CI, sufficient semantic
evidence, durable-doc consistency and zero open P0/P1/P2; it does not wait for
Verifier merely because verification is pending. The role's own evidence must
still be sufficient. Reviewer audits Executor's assessment within normal review,
not as a separate mandatory approval step. Unresolved verification need or scope
blocks merge even when semantic review is approved. Either role may finish first.

## Acceptance Checklist

Executor includes a compact Checklist in new completion PRs, preserving Summary,
Scope, limits and actual check results. The task and governing contract define
acceptance; the Checklist only summarizes it. Review focus never limits mandatory
review dimensions. Use each role's own target and comment link, not a global
Checklist target or dynamic CI/merge checkboxes. Adapt this template to the change:

```markdown
## Acceptance Checklist

### Executor
- [x] Implementation and required documentation complete
- [x] Focused checks complete

### Reviewer
Review focus:
- <change-specific review priorities>

- [ ] REVIEW APPROVAL
  - Head: PENDING
  - Base/merge target: PENDING
  - Covered scope: PENDING
  - Evidence: PENDING

### Verifier
Requirement (Executor assessment): <REQUIRED | NOT_REQUIRED | PENDING_DECISION>
Trigger: <CI_COVERAGE_GAP | EXPLICIT_REQUEST | N/A>
Basis: <actual coverage or explicit requirement and its source>
Verification targets:
- V1: <full meaning from the authorized task/contract, or N/A>

- [ ] VERIFICATION APPROVAL
  - Head: PENDING
  - Base/merge target: PENDING
  - Covered scope: PENDING
  - Evidence: PENDING

## Evidence policy
Task/contract, actual Git/CI and formal role evidence govern acceptance.
This Checklist is a non-authoritative summary.
```

Select the requirement from the completed Executor assessment; do not leave three
alternatives or default every task to pending. For `NOT_REQUIRED`, replace the
Verifier approval checkbox and pending snapshot with `Verification: N/A` and its
basis. Do not run a Verifier just to fill that section. Check only completed work.
V1/V2 IDs aid reference; comments also state actual item meanings and coverage.

| Field | Maintenance authority |
|---|---|
| Executor summary, requirement assessment, shared targets | Executor at PR creation; later edits need explicit Body-edit authority |
| Reviewer verdict/approval, own Head/Base/scope summary/link | Assigned Reviewer under the narrow standing permission |
| Verifier verdict/approval, own Head/Base/scope summary/link | Assigned Verifier under the narrow standing permission |
| Automation state | Only explicitly activated Automation with existing authority |
| CI results | Actual GitHub Checks; no Body status checkbox |
| Merge readiness | Authorized merge actor aggregates evidence; no new role or Body checkbox |

Follow `AGENTS.md` section 10 for comment-first publication, safe exclusive or
atomic conditional Body updates, history and failure closure. Each completed pass
publishes only its one role-evidence record. Updating UI does not require another
review pass or comment. Do not create/rebuild a missing or ambiguous Checklist
under role-only permission. Author status is not permission to edit shared fields.
Formal evidence stays usable when an unauthorized or unsafe display update is
deferred. Report `CHECKLIST_SYNC_DEFERRED` or `CHECKLIST_SYNC_FAILED` separately.

An H1 record can stay checked after an H2 push, but only as an explicitly H1
snapshot. Each role updates its own record after its applicable new pass; it never
resets another role's history or claims old approval applies to H2. An outdated
Body `PENDING_DECISION` suggestion is not an unresolved authoritative decision
when actual requirements/evidence have resolved it, and a Body `NOT_REQUIRED`
alone cannot erase a real requirement. Shared corrections require an authorized
maintainer; display synchronization is not an extra merge gate.

Existing OPEN PRs need not retrofit the template, but still satisfy all current
applicable evidence/merge gates. Adding it needs explicit Body-edit authority.
Keep historical comments; do not backfill fabricated approvals.

## Workflow-rule acceptance

Use the boundary in `AGENTS.md` section 9: scenario walkthroughs, cross-document
consistency and applicable existing checks prove a rule-only assignment. Live
PR writes are optional unless explicitly required; report `NOT_RUN` with reasons
without presenting rule walkthroughs as runtime tests. No approval database,
background scheduler, lock service or fixed model is required.

The following cases are the semantic walkthrough matrix, not claims of executed
runtime tests or a stored task queue:

| Case | Required outcome |
|---|---|
| Executor finds credible coverage and no explicit independent requirement | `NOT_REQUIRED`; no mandatory Verifier dispatch |
| Reviewer approves; required Verifier has not run | Review stays valid; merge waits for required verification |
| Verifier passes; Reviewer has not run | Verification stays valid; merge waits for review |
| Both pass with all other gates satisfied | Merge-ready only with current-target evidence and explicit merge authority |
| Verification need or scope is genuinely unresolved | Merge blocked, without automatically invalidating sufficient semantic review |
| Evidenced `NOT_REQUIRED` without conflict | Verifier display N/A; no fabricated verification marker |
| User/Reviewer explicitly requests bounded verification despite credible CI | Record `EXPLICIT_REQUEST`; no fabricated gap or extra runtime authority |
| Reviewer lacks its own essential semantic evidence | `INCONCLUSIVE`, never approval |
| Reviewer finds a blocking defect / Verifier returns non-PASS | Corresponding approval remains unchecked; publish its non-approval marker |
| H1 approvals followed by H2; only Reviewer checks H2 | Verifier H1 snapshot remains historical; it does not approve H2 |
| Base/merge target changes without a head change | Require applicable current-target CI and fresh role evidence |
| Same-target PASS followed by unresolved material FAIL | Merge blocked; preserve history and assess any overturned review conclusion |
| FAIL followed by one successful retry | No automatic closure; require sufficient explanation/evidence |
| Partial re-verification succeeds | Close only supported items; remaining required gaps/failures still block |
| New acceptance item without Git changes | Existing approval does not automatically cover the new item |
| Checklist omits a required review/verification dimension | Task/contract still governs; omission grants no waiver |
| Concurrent Body writers without safe exclusivity/conditional update | Publish formal evidence; defer display writes without overwriting others |
| Comment succeeds, Body synchronization fails | Keep evidence; report failure; do not repeat valid review/verification |
| Existing OPEN PR lacks Checklist | No retrofit gate; current applicable merge conditions still hold |
| Only Checklist is stale while authoritative evidence is complete | Do not invalidate approval; report display issue separately, normally P3 |

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
- a resolved evidence-based Verifier-need decision and full credible coverage of
  required acceptance, with no open blockers or unexplained material evidence conflicts;
- canonical/durable docs consistent with the accepted change;
- current PR mergeability;
- explicit merge authority.

Role completion order is irrelevant. Aggregation follows `AGENTS.md` section 10,
not a latest-PASS-wins rule or a test for whether both checkboxes are ticked.

Later-stage work still requires its own user scope/authority unless explicit
Automation continuation already covers it.
