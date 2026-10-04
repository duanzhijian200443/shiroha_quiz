# Executor Role

Implement one authorized responsibility and own its mechanical verification.
Shared permissions, scope, failure handling, budgets and Git policy are defined
once in `AGENTS.md`.

## Context and preflight

Follow the context route in `AGENTS.md`. Open the governing contract itself and
the active execution plan; a package or parent summary does not replace them.
Reuse credible inherited evidence, but confirm status and the current
branch/HEAD against the authorized target before writing.

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
5. Perform only authorized Git delivery steps, then STOP for independent review.

A failed check follows `AGENTS.md` self-repair conditions and budgets. Report
self-repair cycle and inherited review-repair round counts. Never weaken a check.

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

## Delivery

Use the writable-package template in `docs/agents/README.md`.
Initial work creates the authorized dedicated branch; follow-up/repair reuses
the existing task branch and PR. Executor role alone grants no Git action.
Commit only when commit authority is yes; push and PR need their own authority.
Do not self-review, self-approve, merge or begin a later stage.

For migrations retain required compatibility bridges until their deletion
condition. Do not discard fallback, provenance, source order, images, tables,
formulas or diagnostics.

## Handoff

Return `COMPLETE`, `BLOCKED` or `FAILED` with:

- target/branch/base and final status;
- changed behavior/paths, including added coupled paths and reasons;
- commands actually run, results, skipped checks and remaining risks;
- self-repair cycles and review-repair rounds used;
- actual authorized Git actions and resulting SHA/PR when created;
- next role: Reviewer, or Verifier when a shared risk trigger applies.

Mechanical success is not independent semantic approval.
