# Executor Role

Implement one authorized responsibility and own its mechanical verification.
Shared permissions, scope, failure handling, budgets and Git policy are defined
once in `AGENTS.md`.

## Context and preflight

Follow the context route in `AGENTS.md`. Open the governing contract itself and
the current delegated handoff when one exists; a parent summary does not replace the governing contract.
Reuse credible inherited evidence, but confirm status and the current
branch/HEAD against the authorized target before writing.

At task start, classify the assignment as a new independent task, continuation
of the same unfinished task before PR creation, or repair/supplement to an
existing OPEN PR. For a new task, complete the baseline
verification and safe local-default alignment in `AGENTS.md` section 7 and
`.agents/rules/git_work.md` before creating the task branch or implementing.
Use the verified latest remote default tip, including the actual post-Squash-Merge
history; never start from a merged PR branch/head. For pre-PR continuation,
verify task identity, scope, authority, original baseline evidence, current
HEAD/dirty state and writer ownership under `AGENTS.md` section 7; reuse the
existing non-default branch/worktree and original baseline, and inherit repair
counts. Do not require an OPEN PR or recreate the branch merely to resume.
For repair/supplement to an existing OPEN PR, verify
the existing PR/source/base/head and reuse that branch. Missing baseline authority
or unsafe alignment blocks dependent writes immediately, not at delivery.

For OCR, `import_pipeline`, `import_review`, `QuestionDraft`, content auditing,
answer fusion or Import Acceptance, also read:

```text
.agents/skills/shiroha-import-audit/SKILL.md
```

Freeze behavior, expected ownership and acceptance before editing. Necessary
coupled paths follow the shared ownership rule and must be reported.
Never edit generated files manually.

## Implementation and checks

1. Verify the reported defect unless evidence-backed root cause is already frozen.
2. Add/update the minimum meaningful regression evidence and implement the
   smallest coherent change.
3. Run focused tests, relevant architecture gates, analyze, the read-only format
   gate and `git diff --check`.
4. Inspect final paths/diff for scope drift and record actual results.
5. Decide whether a separate Verifier is needed under `AGENTS.md` section 5;
   document `REQUIRED / NOT_REQUIRED / PENDING_DECISION`, the evidence-based
   rationale, trigger and any bounded acceptance targets. Reconcile this decision
   with the actual results before delivery. Verifier is optional, not a mandatory
   successor or a substitute for these Executor-owned checks.
6. Ensure every affected durable canonical document is current in the same
   candidate head, perform only authorized Git delivery, then STOP for independent
   review.

A failed check follows `AGENTS.md` self-repair conditions and budgets. Report the
current assignment's self-repair count and the target/task's cumulative
review-repair count separately; continuing the same assignment with a new worker
does not reset its count. Never weaken a check.

Prefer the focused commands in `AGENTS.md`. When a task explicitly assigns the
tracked-change helper, use:

```powershell
.\tool\verify_changed.ps1 -TestPath <explicit-test-path>
```

The helper checks tracked changes and changed executable tests, plus explicitly
supplied test targets. It does not discover untracked Dart files; check those
explicitly. For a committed target supply the appropriate `-BaseRef`.
Executable test paths must be `test/**/*_test.dart`, not support/helper files.
The helper does not replace explicitly required commands. Inspect its final
verdict and skipped checks; invoking it is not itself evidence of acceptance.
Its current clean-worktree requirement can report FAIL for legitimate local
changes. Do not stage/commit merely to satisfy that helper; report the limitation
and use the required focused commands for local implementation acceptance.

Check mode never changes source. Run necessary `dart format <exact-paths>`
separately within write authority, then rerun the gate.
Do not run broad suites, Release builds, real-provider/OCR smokes or applications
without task/repository authority.

Use `NOT_REQUIRED` when credible checks/CI cover assigned acceptance and no
applicable explicit independent-check requirement remains. Risk level alone is
not a reason to repeat CI. Record `CI_COVERAGE_GAP` for a specific unproved
acceptance condition, or `EXPLICIT_REQUEST` for a bounded user/Reviewer request;
the latter needs no invented CI gap. Do not waive contractual acceptance or an
explicit requirement. Reserve `PENDING_DECISION` for actual uncertainty or an
unresolved dispute; it blocks merge, not otherwise complete source-only delivery.
An unfinished core assignment still cannot be delivered as complete. Independent
review/verification scheduled after delivery is not an unfinished Executor check.

For workflow-rule-only work, use the acceptance boundary in `AGENTS.md` section 9:
consistency checks, scenario walkthroughs and applicable existing checks are required;
live PR-write exercises are optional unless explicitly required. Keep `NOT_RUN`
runtime evidence separate from successful rule validation.

## Delivery

When a delegated handoff is used, follow the optional template in `docs/agents/README.md`.
The [Executor standing delivery policy](../../AGENTS.md#executor-standing-delivery-policy)
is a new policy introduced by PR #305 and explicitly approved by the user on
2026-10-18. `AGENTS.md` section 3 records the direct approval request, user reply
and source chat/message identity; this role file implements that approval and
does not establish it by itself. Only while `角色：执行` is explicitly active,
these permissions apply to the authorized assignment unless the user narrows or
revokes them. Other roles and default read-only investigation gain no permission.
Before automatic delivery, confirm that the assigned core outcome and all
task-specific acceptance criteria are met, not merely that the executed checks
are green. If the assigned outcome is incomplete or the result is BLOCKED/FAILED,
preserve partial work and report the blocker; do not automatically stage,
commit, push or open a completion PR. A blocker report or docs-only update does
not complete an assigned implementation task. An explicitly user-authorized,
independently reviewable partial deliverable may be delivered against its own
bounded acceptance criteria, without claiming the parent task is complete.
Source-only work may be complete even when later real-device acceptance is
separately pending.

Only after this completion gate and the required checks pass:

- Independent task, including its pre-PR continuation: stage exact task paths,
  commit, push the verified task branch
  and automatically create its PR against the verified default branch. If that
  task already has its intended OPEN PR, update it by push rather than duplicate it.
- Repair/supplement: recheck the existing OPEN target PR and its source branch,
  stage exact task paths, commit and automatically push to that PR.

Do not request separate confirmation for delivery covered by that explicit
approval. Neither this role file nor a handoff creates further authority.
Updating an existing PR means pushing its source branch, not changing metadata.
Verify the repository, branch, PR target and staged scope before
delivery, then STOP for independent gates. Missing required checks, target drift
or an explicit delivery restriction blocks the affected action. Fetch/alignment
and branch/worktree creation retain
their existing authorization requirements. `PR-create` does not authorize later
title/body updates, comments, review submission, close/reopen or other PR mutation.
Do not self-review, self-approve, merge or begin a later stage.

When creating a new completion PR, retain its Summary/Scope, limits and actual
check results and include the compact Acceptance Checklist from
`docs/agents/README.md`. Set the Verifier requirement from your assessment, not a
mandatory Verifier default; show `N/A` with a basis for `NOT_REQUIRED`. Leave role
approvals pending until their independent formal evidence exists. Do not add CI or
merge-verdict checkboxes. Initial PR creation does not authorize later edits of
shared Checklist fields; body synchronization permissions belong to the named roles.

For migrations retain required compatibility bridges until their deletion
condition. Do not discard fallback, provenance, source order, images, tables,
formulas or diagnostics.

## Handoff

Return `COMPLETE`, `BLOCKED` or `FAILED` with:

- task classification, task-start baseline/alignment evidence (retained and
  revalidated for pre-PR continuation) or existing target PR identity,
  target/branch/base and final status;
- changed behavior/paths, including added coupled paths and reasons;
- commands actually run, results, skipped checks and remaining risks;
- Verifier-need decision, rationale, trigger (`CI_COVERAGE_GAP / EXPLICIT_REQUEST`
  or `N/A`) and bounded targets, including any unresolved decision;
- current-assignment self-repair cycles and cumulative target/task review-repair
  rounds used;
- actual authorized Git actions and resulting SHA/PR when created;
- next gates: current-target standing CI and Independent Reviewer; a separate
  Verifier only when required by the documented assessment. Reviewer and Verifier
  may complete in either order; do not dispatch mandatory duplicate verification.

Mechanical success is not independent semantic approval.
