# Shiroha Quiz Agent Instructions

## 1. Scope and precedence

These instructions apply to all agent work in this repository.

Resolve conflicts in this order:

1. Higher-level platform instructions and explicit current-user instructions.
2. The more restrictive repository safety/privacy/Git rule.
3. This file.
4. The active role file and task-specific execution instructions.

Stop for user direction only when the conflict cannot be resolved safely.
Operate only inside this repository unless the user explicitly authorizes otherwise.
Tool-managed caches and temporary validation artifacts do not authorize access to
private application data or unrelated workspaces.

Current Git and canonical documents are authoritative for project state.
Do not use memory to infer current HEAD, branch, delivery status or capabilities.
Only stable cross-task preferences and principles belong in long-term memory;
do not duplicate Git state, test results or canonical project facts there.
Memory writes still require an explicit user request.

## 2. Context and rule routing

Before a non-trivial task, read:

- the active role entry mapped in section 3;
- the reading guide and core sections 1–3 and 7–8 of `ARCHITECTURE.md`,
  plus sections relevant to the affected capability;
- the governing task-specific canonical/frozen contract source when the task
  implements, changes or reviews behavior it owns;
- relevant implementation/tests/current diff.

Use the architecture reading guide and focused searches to identify applicable
contracts. Do not recursively load every document linked by an unrelated section.
A task-package summary or parent-attested excerpt never replaces the governing
contract itself. Do not claim a file was reviewed unless opened during this task.

| Rule file | Read when |
|---|---|
| `.agents/rules/architectural-discipline.md` | Every non-trivial repository task |
| `.agents/rules/git_work.md` | Git inspection or action is involved |
| `.agents/rules/reviewer.md` | Reviewer role is active |

Load only applicable rules. Instructions themselves may be read as task artifacts
when the user asks to inspect or optimize them; this does not activate their roles.

## 3. Roles and authorization

The first line of a user task may activate exactly one role:

| Identifier | Role file |
|---|---|
| `角色：总控` | `docs/agents/coordinator.md` |
| `角色：规划` | `docs/agents/planner.md` |
| `角色：执行` | `docs/agents/executor.md` |
| `角色：验证` | `docs/agents/verifier.md` |
| `角色：审查` | `docs/agents/reviewer.md` |
| `角色：诊断` | `docs/agents/diagnostician.md` |
| `角色：自动化` | `docs/automation/README.md` |

Read the mapped file before continuing. The active role persists through follow-up
messages for the same task until the user explicitly changes it or starts a new
task. Do not silently switch roles. Without an active explicit role, default to
read-only investigation; a pasted package alone does not grant write authority.

An Executor instruction authorizes implementation only within the requested
responsibility. Branch/worktree, staging, commit, push, PR, merge, tag and release
authority remain action-specific. Preserve already-granted authority for the same
task; do not ask for it again. Missing authority for one action does not prevent
independent authorized work.

### Explicit automation mode

Only an explicit current-user `角色：自动化` activates the isolated protocol.
Normal roles do not load `docs/automation/**` except assigned task artifacts.
The controller reads the protocol, roadmap/current capability contract and Git/PR facts; workers receive only the bounded execution handoff needed for their assigned role.

Within existing user authority, the protocol replaces only controller stops at
worker delivery, per-package handback/new-request requirements, and handling of
confirmed unrelated pre-existing verification failures. It may continue across
checkpoints and perform pre-authorized conditional merges. A dispatched Executor
package must carry any applicable bounded verification-repair exception.
Workers retain their roles, independent review and delivery stops.

No Git, runtime or scope authority is inferred from activation, an execution handoff or Automation resume state.
All other safety, privacy, canonical-contract, ownership, destructive-Git,
evidence, required-gate and repair-budget rules remain unchanged.

## 4. Architecture and scope

Preserve the dependency direction and invariants in `ARCHITECTURE.md`:

```text
Flutter UI / Built-in Agent / MCP Adapter -> Application -> Domain
Data / Infrastructure -> Application ports / Domain
```

Composition roots may wire concrete repositories, databases and providers.
UI/Agent/MCP never access SQLite or `DatabaseHelper` directly. New presentation
features stay behind Application seams. Cross-surface semantics belong in
Application, persistence in Data, and Domain stays free of Flutter, SQLite,
provider DTOs, HTTP and file-system APIs. Built-in Agent and MCP are peer adapters.

Preserve typed sidecar authority, corrupt-sidecar hard failure, explicit-empty
semantics, structural RichContent rendering, review/content separation and frozen
Application approval boundaries.

Reuse existing abstractions and verify the actual failure boundary. Make the
smallest coherent change. Preserve compatibility and unrelated user changes.
Do not refactor, rename, reformat or generalize unrelated code. Public APIs,
persisted formats, schema, dependencies, CI/release/signing and security/privacy
contracts require explicit scope.

High-risk areas include persistence/migrations, managed-file lifecycle, async
recovery/concurrency, redaction, credentials, OCR/AI, Agent/MCP write permissions,
authorization and global exception handling.

## 5. Workflow and independent verification

Default route:

```text
Planner/Diagnostician only when needed
-> Executor + required durable-document updates + mechanical checks
-> authorized PR delivery -> STOP
-> standing PR CI verification gate
-> Verifier only when required acceptance is not credibly covered by CI
-> Independent Reviewer
-> bounded same-PR repair when needed
-> final Reviewer approval
-> user-authorized merge
```

Use planning when durable contracts, architecture/root cause or high-risk
cross-layer semantics are unresolved, or when explicitly requested.

Executor owns implementation, minimum meaningful regressions, focused tests and
architecture gates, analyze, format, diff-check and final scope inspection.
Green Executor checks are mechanical evidence, not independent semantic approval.
Stop at the authorized delivery boundary, even when no PR is authorized.

For every non-trivial completion PR, the automatic `PR contract checks` run is
the default independent verification authority. It must succeed for the current
PR head and current base/merge target even when GitHub branch protection does not
mark any status as required. Results for a stale head or stale base/merge target
do not satisfy the gate.

Standing CI may fully satisfy deterministic acceptance, including high-risk
schema/migration, transaction/concurrency or security/authorization behavior,
when the required acceptance matrix is explicitly covered by hard-failing CI.
Insert an independent Verifier only when required acceptance cannot be credibly
proved by current standing CI, including:

- real-provider/device/release/runtime or manual-observation acceptance;
- OS/platform behavior not exercised by standing CI;
- flaky, timing-dependent or inconsistent Executor/CI evidence;
- a required acceptance condition with no deterministic standing-CI coverage;
- an explicit user or Reviewer request for independent checks.

When a Verifier is required, verify one fixed target and preserve its PR evidence.
An Independent Reviewer is mandatory for every non-trivial completion PR.
Reviewer approval is semantic evidence; green CI never replaces independent review.

## 6. Failure handling and budgets

A failed Executor check does not automatically end the task. Self-repair is
allowed only when the failure is caused by the authorized change, the root cause
is concrete, the repair stays within responsibility/ownership and frozen semantics,
introduces no unrelated bug fix or feature, and no verification is weakened,
removed, skipped or bypassed.

Default budgets:

- At most two semantic/implementation self-repair cycles per Executor assignment.
- At most two review-driven repair rounds for the same delivery target/task.
  A round batches compatible findings, repairs them and receives fresh review.
- Mechanical format/import/lint/trivial compile cleanup does not consume a
  semantic cycle.
- Changing agents, rewriting handoff notes or advancing the PR head does not reset
  the review-round budget. Track both counts in handoffs.
- Different limits require explicit task/user authority.

Rerun the failed check and directly affected regressions after repair.

Stop affected writes and delivery when:

- responsibility, another writer's ownership or a strict whitelist would be crossed;
- an unapproved schema/migration/public API/frozen-contract change is necessary;
- required verification exposes a separate pre-existing defect outside the
  explicitly activated Automation exception in `docs/automation/README.md`;
- root cause or privacy/authorization/concurrency/transaction/persistence semantics
  cannot be resolved through bounded investigation;
- passing would require weakening verification;
- a repair budget is exhausted or scope would materially broaden.

STOP allows bounded read-only diagnosis and preservation of safe evidence. It
does not authorize a repair, a retry loop or the next roadmap stage.
Report the failed command, first useful failure, root-cause evidence, attempts,
current diff/status and smallest proposed next scope.
Do not create a completion PR while required verification is failing.

## 7. Git, branches and ownership

Never run destructive or history-rewriting Git operations, including hard reset,
destructive checkout/restore, clean, force push, amend, rebase or squash.
Any current-user exception must be explicit and must comply with platform rules;
a task template or role cannot grant that exception.

Each write task uses a dedicated non-default branch:
initial implementation creates the assigned branch from the authorized base;
follow-ups and review repair reuse that task's branch/PR.
Never implement directly on the default branch.
Assigned branch creation requires explicit user authority or authority inherited from the current user-approved task; a delegated handoff may record that authority but never create it.
Worktrees are optional for a single writer; use them only for parallel writers,
needed dirty-checkout isolation or an explicit Coordinator requirement, with
applicable authorization.

Expected ownership paths are not an exhaustive whitelist unless
`Strict path whitelist: yes`. Directly necessary coupled paths may be added when
they remain in the same responsibility, do not overlap another writer, and add
no unauthorized feature, dependency, migration, public contract or refactor.
Report added paths and reasons. With a strict whitelist, stop before crossing it.

Stage exact paths only; never `git add .` or `git add -A`.
Do not create/update `DEVELOPMENT_LOG.md` unless explicitly requested.
Inspect status before/after writes and preserve unrelated tracked/untracked files.

For delegated work, Planner/Coordinator may use the optional execution-handoff
template in `docs/agents/README.md` to make scope, acceptance and already-granted
authority explicit. Direct user instructions may provide the same facts without a
formal handoff. A handoff records authority; it never creates authority.
Implementation or staging never implies commit, push, PR creation, merge, tag or
release. Only perform actions actually authorized by the user/current task.

`PR-create` authorizes PR creation only. PR title/body updates, close/reopen and
other PR mutations remain separate actions requiring explicit task/user authority.
Reviewer and Verifier assignments that explicitly target an existing PR have one
narrow standing exception: each completed pass may publish exactly one role evidence
comment/submission on that PR. Reviewer evidence may report `APPROVE`,
`REQUEST_CHANGES` or `INCONCLUSIVE`; Verifier evidence may report PASS or a bounded
non-PASS result. This evidence mutation does not authorize title/body changes,
labels, close/reopen, merge, code edits or any other PR mutation. A generic `PR yes`
is not blanket authority.

## 8. Security, privacy and network

Never expose or persist secrets, private configuration or complete private file
contents. Do not log/report complete prompts, answers, raw OCR/provider bodies,
Base64, sensitive absolute paths or unsafe exception messages. Use IDs, stages,
counts, safe categories and redacted summaries.

Network authority is specific to purpose and destination:

- Git fetch/push and connected PR actions require the corresponding Git authority.
- Read-only inspection of a task's remote target is permitted when the task
  explicitly requires that comparison; it does not grant push or PR mutation.
- Public documentation lookup requires task/user authority and sends no private
  source, document or configuration content.
- Real OCR/AI/provider calls, private-document processing, saved-key loading and
  Replay writes require an explicitly authorized runtime scope.

Authority for one category never grants another. Network/provider use is
otherwise disabled by default.

## 9. Validation and evidence economy

Use focused checks appropriate to the change:

```text
dart format --output=none --set-exit-if-changed <changed-dart-files>
flutter analyze <changed-dart-files>
flutter test --concurrency=1 <focused-tests>
git diff --check
```

Check helpers must not format, fix, restore, stage or modify tracked inputs,
including on failure. Executors perform necessary format/fix actions separately,
then rerun the read-only gate. Tool-managed caches may be created.

Do not run full-repository formatting or fix historical unrelated analyze issues.
Include changed tests/helpers in focused analysis when applicable.
Run Windows Flutter tests serially unless parallel safety is established.
Full `.\scripts\verify.ps1` is for explicit global/release acceptance or user request.
Prefer one direct regression plus necessary boundary/failure/concurrency coverage.

Never claim an unrun check passed; report skipped/failed checks.
A command with no meaningful progress for three minutes is stalled. Preserve
evidence; do not silently extend timeouts or retry indefinitely.

## 10. Review, documentation responsibility and merge evidence

| Severity | Meaning |
|---|---|
| P0 | Secret exposure, destructive corruption or catastrophic security/privacy failure |
| P1 | Data loss, crash, broken core behavior, violated frozen invariant or serious compatibility/concurrency failure |
| P2 | Meaningful correctness/compatibility/concurrency/required-acceptance gap blocking merge |
| P3 | Non-blocking maintenance, documentation drift, optional coverage or cleanup |

P3 is deferred by default. Completed reviews return all non-duplicate blocking
findings together. Incomplete/unstable targets return `INCONCLUSIVE`, never approval.

P0/P1/P2 -> bounded Repair Executor on the same branch/PR -> mechanical checks
-> authorized push -> STOP -> standing CI -> required Verifier when CI is
insufficient -> fresh targeted Reviewer closure. Targeted review expands only if
the repair invalidated the original scope.

When a change alters durable product/architecture truth, the Executor must update
the governing canonical documents in the same candidate head. Planner/Coordinator
handoffs should list known affected docs, but that list is a convenience rather
than a second authority. Reviewer independently checks contract/diff agreement and
may report missing or stale durable documentation as a blocking finding.

There is no mandatory post-approval Documentation Closure. Durable docs required
for the delivery belong in the implementation/repair head before CI and review.
If review finds a missing/stale durable document, route it through the same-PR
repair flow. Any tracked documentation repair advances the head and therefore
requires standing CI and fresh review. Reviewer remains read-only apart from its
single PR-evidence publication.

A completion PR is merge-ready only when:
- final-head/current-target `PR contract checks` succeeded;
- the Independent Reviewer recorded `[REVIEW APPROVAL]` matching the final head and current base/merge target,
  with zero open P0/P1/P2;
- required Verifier `[VERIFICATION APPROVAL]` evidence matches the applicable
  verified head/base target when required;
- every declared Documentation responsibility is closed on that candidate head;
- explicit user merge authority exists.

Reviewer/Verifier assignments explicitly targeting an existing PR may publish one
role-evidence record per completed pass without a separate package flag. Reviewer
uses `[REVIEW APPROVAL]` / `[REVIEW REQUEST_CHANGES]` /
`[REVIEW INCONCLUSIVE]`; Verifier uses `[VERIFICATION APPROVAL]` on PASS and
`[VERIFICATION RESULT]` on non-PASS.

For historical reconstruction, a PR GitHub reports as `MERGED` is treated as
having satisfied its review gate even when an older workflow left no approval
marker. Do not reopen/re-review solely to manufacture one. A later revert,
explicit unresolved blocker or current user instruction may create new bounded
work. This rule never lets an open PR bypass the current review gate.

Repository/global status defaults to `NOT_EVALUATED` for focused tasks.

## 11. Orchestration

Normal repository orchestration uses `角色：总控`. The Coordinator freezes
base/branch/worktree/dirty state, contracts and ownership before dispatch.
Serialize by default. Parallel writers require isolated worktrees and
non-overlapping ownership. Stop writers before review/verification.

Coordinator never edits production/tests itself or automatically pushes/merges.
Delegated children have one bounded role/task; they may not create descendants,
switch roles, expand scope or decide public architecture/contracts.
Read `docs/agents/model-routing.md` when routing children.

## 12. Canonical documents and execution handoffs

Canonical contracts record durable product/architecture truth; Git/PR/CI/Reviewer
evidence owns exact execution facts.

For staged product work, prefer one focused canonical contract per capability,
normally `docs/product/<capability>.md`. Do not persist implementation task
packages beside a contract merely to track order, NEXT, status or completion.

Normal roles do not require PR-body task packages. Planner/Coordinator may create a
bounded temporary handoff in the active conversation when delegation benefits from
explicit scope, ownership, acceptance or authority. That handoff is disposable,
does not become merge identity, and never overrides the user, canonical contracts
or Git facts.

Only explicit Automation mode may maintain resumable PR-body scratch state under
the rules in `docs/automation/README.md`. That state is non-authoritative and is
ignored by normal Reviewer/Verifier merge identity.

Completion is represented by merged PR + CI/review evidence. Durable capability
state belongs in the canonical contract and, when stage-level truth changes, the
roadmap. Do not make filenames or PR-body metadata imitate an execution database.

Preserve historical truth through amendments, explicit historical labeling and
superseding references.

