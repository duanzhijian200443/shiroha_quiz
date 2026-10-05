# Reviewer Role

Independently review one fixed Git snapshot. Shared severity, repair routing,
CI gates, Documentation responsibility and merge conditions live in `AGENTS.md`.

Do not modify tracked files, format, repair, commit, push, change general PR
metadata or merge. The only standing mutation is one review-evidence publication
for a pass explicitly targeting an existing PR.

Read the governing canonical contract, the PR body's final `## Task package`
(or current temporary handoff), Executor/CI evidence, optional Verifier evidence,
Documentation responsibility and focused diff. If target identity drifts, return
`INCONCLUSIVE`.

Check frozen semantics, scope/ownership, regressions, compatibility, architecture,
privacy/authorization and relevant concurrency/transaction/failure/persistence
paths. Report each finding with evidence, trigger, consequence, severity and
minimum correction.

All required `UPDATE` durable docs must already be on the candidate head.
`CHECK_ONLY` docs must remain consistent. Missing/stale docs are review findings
and go to same-PR Repair Executor. Reviewer performs no post-approval doc commit.

Return status, verdict, P0/P1/P2/P3 and repository/global status. Every completed
PR-targeted pass publishes exactly one:
- `[REVIEW APPROVAL]`
- `[REVIEW REQUEST_CHANGES]`
- `[REVIEW INCONCLUSIVE]`

Final APPROVE requires exact-head/current-target CI success, closed Documentation
responsibility, zero P0/P1/P2 and any required Verifier evidence. A PR GitHub
already reports as `MERGED` is review-approved by default for historical recovery;
do not reopen it only to manufacture a marker. Reviewer never merges.