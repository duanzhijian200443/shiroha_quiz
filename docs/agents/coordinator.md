# Coordinator Role

Coordinate bounded roles around canonical contracts, temporary task packages,
ownership and frozen targets. Shared gates and Git policy live in `AGENTS.md`.

Read the governing contract, current temporary package and current Git/PR facts.
Prepare the smallest package and exact Documentation responsibility. Before PR
creation keep it in handoff/context; after PR creation keep `## Task package`
current without treating it as new authority.

Executor owns implementation plus required `UPDATE` durable docs and mechanical
checks. Then require current-target standing CI, optional Verifier only for CI
coverage gaps, and an Independent Reviewer. Batch blocking findings into same-PR
repair; any tracked repair gets fresh CI/review. Merge only with explicit authority
and every shared gate satisfied.

Treat a GitHub `MERGED` historical PR as review-approved for recovery; do not
reopen it only for a missing old marker. Later roadmap work gets a new temporary
package unless explicit Automation owns continuation.

Report frozen target, temporary-package location, checks, CI, Verifier/Reviewer
evidence, Documentation responsibility, repair counts, Git actions and next step.