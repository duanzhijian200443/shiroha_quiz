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
-> bounded same-PR repair + fresh CI/review when needed
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
| Reviewer | Independent semantic verdict + PR evidence | Read-only |

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
Task package: temporary; current context before PR, PR body `## Task package` after PR creation
Task-package revision: <positive integer; mandatory once persisted in a PR body>
Task-package digest: <64 lowercase hex SHA256; mandatory in a PR body>
Documentation responsibility:
- <exact path>: UPDATE | CHECK_ONLY
# or: none
Expected ownership paths: <primary files/modules>
Strict path whitelist: no | yes
Frozen task semantics: <current-stage invariants>
Acceptance: <focused criteria>
Validation: <focused checks>
Git: branch-create yes|no; stage yes|no; commit yes|no; push yes|no; PR-create yes|no; merge yes|no
PR metadata: title/body-update yes|no
Authority source: <trusted user instruction; list any bounded standing permission separately>
Review repair rounds used: <0 initially; inherited count for repair>
Stop conditions: <task-specific blockers beyond AGENTS.md>
```

Use `create` for authorized initial branch creation and `reuse` for same-task
follow-ups/repair. Missing Git/PR actions are unauthorized.
With `Strict path whitelist: yes`, list exact repository-relative paths, including
both endpoints of a rename and every deleted path; a responsibility label is not
a whitelist. A package records user authority and does not create it. Required
read-only remote comparison/post-push fetch may be stated with its Git authority.
`PR-create` covers creation only. Title/body updates, close/reopen and other PR
mutations require the corresponding explicit authority under `AGENTS.md`; do not
infer them from PR creation or push authority. Reviewer and Verifier assignments
explicitly targeting an existing PR do not need separate package flags for their
one role-evidence publication per completed pass.
Add Worktree and its authority only when isolation is needed.

`Documentation responsibility` is mandatory for a completion package:
`UPDATE` means accepted delivery changes durable truth/status and the path must be
closed before final approval; `CHECK_ONLY` means the Reviewer verifies that the
existing text is not stale or contradictory. Use explicit `none` when no durable
document can change. Repository-absolute paths are the default; inside a focused
contract directory, exact relative `./...` paths are allowed and preferred for
sibling contract/package entries that must remain valid after the directory is
renamed. Do not make agents rediscover closure paths from memory.

For durable staged work, prefer one focused canonical contract such as
`docs/product/<capability>.md`. Task packages are temporary handoff/PR-body artifacts,
not tracked sibling files or a second queue. Do not add Task-ID/Status/completion
suffixes merely to mirror execution state; merged PR + CI/review is the execution
history.

Add directly necessary coupled paths under the shared ownership policy and report
why; strict whitelists require explicit authorization to expand.

## PR task-package identity

This is the single normalization contract, implemented by the read-only
`tool/task_package_identity.ps1`. It performs no network request or input write.

1. Decode the PR body as UTF-8, remove one leading BOM if present, and convert
   CRLF and lone CR to LF.
2. Require exactly one standalone, column-zero `## Task package` ATX heading
   outside fenced code. Reject alternate spacing/closing hashes for that heading.
   The section includes that heading and ends immediately before the next ATX
   level-1/level-2 heading outside fenced code, or at the end of the body. Backtick
   and tilde fences follow the usual minimum-three delimiter/maximum-three-space
   indentation rules; heading/field examples inside fences are content, not metadata.
3. Require exactly one unfenced standalone `Task-package revision: N` line, where
   N is a positive Int64 with no leading zero, and one
   `Task-package digest: <64 lowercase hex>` line. Reject missing, duplicate or
   malformed fields and an unclosed fence in a section extending to body end.
4. Remove only that digest line. Remove trailing empty lines, then append exactly
   one LF. Preserve all other whitespace, Unicode and content, including revision.
5. SHA256 the UTF-8 bytes without BOM; output lowercase hex. This is the digest.

The first identified PR package starts at revision 1. Each normalized content
change increments revision within the same PR, including repair and factual edits;
never reset it on a new worker/head. Existing unversioned packages need a writer
to add identity and a fresh review; old head-only approvals cannot be carried over.

Writer: supply a 64-zero digest placeholder, run the helper with `-Compute`, fill
the returned digest through the authorized package-section update, then verify the
body read back from the PR with the default mode. Freeze the final section before
review/verification. Subsequent run/CI status belongs in evidence, not that section.

```powershell
pwsh -NoProfile -File ./tool/task_package_identity.ps1 -BodyPath <UTF-8-body-file> -Compute
pwsh -NoProfile -File ./tool/task_package_identity.ps1 -BodyPath <UTF-8-body-file>
```

The default mode fails on declared/computed mismatch. `-Compute` is a writer aid,
never review/verification/merge evidence. Reviewer/Verifier record and recheck
`(head, base/merge target, revision, recomputed digest)` before/after the pass.
The merge actor reads the live PR body, runs default verification and compares all
four fields to the applicable approval records. A self-consistent new digest
without matching approval still fails. No identity value grants Git/scope authority.
Any normalized package change after a pass freezes it makes that pass/approval
stale; this includes factual edits. Unrelated PR-body sections are excluded from
the hash and must not redefine the task. Canonical documents remain authoritative.

## Independent verification and review packages

Standing automatic `PR contract checks` is the default independent verification
authority for completion PRs and must cover the current head/current merge target.

Create a Verifier package only when required acceptance is not credibly covered by
standing CI. Include role, objective, fixed target, governing contract, exact
assigned commands/observations and the CI coverage gap. When the assignment targets
an existing PR, one Verifier evidence publication is a standing role permission and
does not need a separate package field. Verifier never repairs.

Reviewer package includes base/final target, governing contract, the final temporary
PR-body package and its revision/recomputed digest, Executor/CI evidence, optional Verifier evidence, assigned review
dimensions, inherited review-round count and Documentation responsibility.

Final `APPROVE` requires the reviewed candidate head to already contain every
required durable-document update, plus current-target CI and the targeted semantic
review. Final review evidence is `[REVIEW APPROVAL]`; required Verifier PASS evidence
is `[VERIFICATION APPROVAL]`.

## Evidence and merge readiness

Use concise target identity, changed behavior/paths, actual checks, skipped gates,
repair counts and unresolved risks. Do not duplicate shared rules or full logs.
Each writer owns one coherent responsibility; shared paths have one owner.

Before merge, require final-head/current-target CI success, final Reviewer PR
approval matching the live package identity, any required Verifier PR approval, closed Documentation responsibility
and explicit merge authority. Later-stage work still requires its own scope and
authority unless an explicitly activated Automation run provides that continuation.
