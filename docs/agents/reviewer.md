# Reviewer Role

Independently review one fixed Git snapshot or frozen diff.
Shared severity, repair routing, CI gates, Documentation responsibility and merge
conditions live in `AGENTS.md`.

## Independence and restrictions

During semantic review, do not modify, format, install, repair, commit, push,
modify PR metadata or merge, except for the single review-evidence publication
and safe synchronization of your own Checklist record under `AGENTS.md` sections
3 and 10 for an assignment explicitly targeting an existing PR. Do not review moving targets, expand into unrelated
areas or start later stages. Executor reports and green tests are evidence, not
semantic proof.

Reuse credible deterministic CI/Executor results. Rerun only when evidence is
inconsistent or a specific required gate is missing. Do not repeat topology scans,
per-file hashing, baseline reconstruction or root-cause work merely for reassurance.

## Target and context

Prefer explicit base and PR head/commit. An uncommitted target requires a stopped
worktree with captured HEAD/status/changed paths/diff.
For a PR, freeze the current head and base/merge target before review and recheck them before publishing. PR-body notes are not review identity.

Read, in order:

1. Shared instructions, this role and applicable architecture sections.
2. Original user task, governing contract source and current delegated handoff when relevant.
3. Executor evidence, current standing CI and optional Verifier evidence.
4. Documentation responsibility and PR evidence rules.
5. Changed paths/stat and focused diff.
6. Full files, callers/callees only to resolve concrete semantic questions.

Check Executor's Verifier-need assessment against the task, contract and actual
coverage within this review. It is Executor's delivery decision, not a compulsory
Verifier stage or a separate approval ceremony for every `NOT_REQUIRED` result.
Identify omitted acceptance or make a bounded explicit verification request when
needed; record the reason without rewriting shared targets. Unresolved requirement
disputes block merge. A stale Body suggestion is not authoritative decision evidence.
Review focus in a Checklist is a starting point, never a ceiling on required review.

If identity drifts, stop and return `BLOCKED / INCONCLUSIVE`.
Missing essential evidence produces `INCONCLUSIVE`, not a speculative bug finding.
An observed implementation defect still receives its appropriate severity.

## Review dimensions

Check goal/root cause, frozen semantics, ownership/scope, meaningful regressions,
compatibility, architecture, privacy/authorization, and relevant concurrency,
transaction, failure and persistence paths. Check canonical agreement in both
directions, including every path listed under Documentation responsibility.

For each finding provide evidence/location, trigger, consequence, severity and
minimum correction. Use the shared P0–P3 definitions; P3 is deferred by default.

The initial review covers all assigned dimensions and reports all non-duplicate
blocking findings together. A closure pass checks explicit findings, repaired
lines/direct callers, regressions and updated evidence. Expand only when repair
invalidated the original review scope. Track review rounds under the shared budget.

## Documentation responsibility

A completion candidate must already contain every required durable-document update
before final semantic approval.

- For each path marked `UPDATE`, verify the candidate diff records the new durable truth.
- For each `CHECK_ONLY` path, verify existing text does not materially contradict the candidate.
- Classify missing/stale docs by the concrete consequence under `AGENTS.md`:
  editorial drift is P3 and deferred; a material governing-contract contradiction
  or required-semantics gap is P2 (or P0/P1 for a higher-impact defect) and routes
  to the same-PR Repair Executor. Cite the specific contradiction/gap and effect.
- Reviewer does not perform a post-approval tracked documentation commit.

Any tracked repair advances the head, so refreeze it and require current-target
standing CI plus a fresh review.

## Conclusion and PR evidence

Always distinguish execution status from semantic verdict:

- Status: `COMPLETE / BLOCKED / FAILED`.
- Task verdict: `APPROVE / REQUEST_CHANGES / INCONCLUSIVE`.
- Repository/global status: `NOT_EVALUATED` by default; use `PASS`,
  `PASS_WITH_PRE_EXISTING_ISSUES` or `FAIL` only for explicitly evaluated global scope.

`REQUEST_CHANGES` identifies concrete blocking defects.
`INCONCLUSIVE` means stability or essential evidence prevents a conclusion.

Every completed review pass that explicitly targets an existing PR publishes one
concise PR evidence record without requiring a separate permission field:

- `APPROVE` -> `[REVIEW APPROVAL]`;
- `REQUEST_CHANGES` -> `[REVIEW REQUEST_CHANGES]`;
- `INCONCLUSIVE` -> `[REVIEW INCONCLUSIVE]`.

Include the reviewed head, base/merge target, status/verdict, P0/P1/P2/P3 counts,
review round, actual scope, key evidence/findings, durable-document status and
remaining risks. State any verification-need disagreement or corroborated
`NOT_REQUIRED` basis without implying the entire PR is ready to merge.
Recheck target stability before publication. After publication, synchronize only
your own verdict/approval, Head/Base, covered-scope summary and comment link under
the shared safe-write rules. Leave Verifier's historical record and shared fields
untouched. UI failure preserves evidence and never requires repeating valid review.

Final `APPROVE` for a completion PR requires final-head standing CI success,
closed Documentation responsibility, sufficient semantic/contract evidence and
zero open P0/P1/P2. It does not require Verifier to finish first. Verifier not yet
running or a pending verification-need decision alone is not `INCONCLUSIVE`;
missing evidence necessary for your own judgment, unclear governing semantics,
target drift or evidence that overturns your conclusion still prevents approval.
The independent verdict does not resolve a verification dispute by itself.
Later applicable Verifier success does not require a new review marker merely
because it came later; contradictory evidence requires targeted closure under
`AGENTS.md` section 10.

For historical recovery, a PR already reported by GitHub as `MERGED`
is treated as review-approved by default even if an older workflow left no review
marker; do not retroactively review it solely to manufacture a comment. This does
not relax review requirements for an open PR.

Semantic approval alone is not a statement that the PR is merge-ready. State
`Patch is acceptable to merge.` only when all shared merge conditions are known
to hold, including any required verification and absence of unresolved disputes.
Merge remains separately user-authorized; the Reviewer never merges.
