# Child-Agent Model Routing and Cost Discipline

This file implements the repository-specific child-agent routing policy under
`AGENTS.md` section 15. It applies whenever a parent agent, Coordinator, or
Planner recommends or creates delegated agents.

## Goals

Reduce cost by selecting the cheapest model that safely fits the actual child
task, avoiding duplicate context and duplicate validation, and escalating only
when the work genuinely requires stronger reasoning.

This policy does **not** impose a hard monetary, token, agent-count, or total
elapsed-time budget. Scope, safety, command timeouts, terminal stop conditions,
and the bounded review-cycle rules below still apply.

## Default model routes

### Ordinary implementation

Use:

```text
Model: deepseek/deepseek-v4-flash
Reasoning: xhigh
```

This is the default for bounded implementation when behavior and public
contracts are already frozen, including:

- ordinary production-code changes;
- focused regression tests;
- adapters, mappers, and compatibility glue;
- deterministic repairs inside an already approved contract;
- frozen implementation slices that originated from a T3 roadmap.

A task being related to a T3 feature does not by itself justify a high-capability
Executor. Route by the uncertainty remaining in the child task, not by the
highest risk of the parent stage.

### Deterministic verification

Preferred route:

```text
Model: Gemini 3.6 Flash
Reasoning: high
```

Use the host's exact available Gemini 3.6 Flash model identifier.

Fallback route, only when Gemini child creation fails, quota is unavailable,
the model is unavailable, or required tools are unsupported:

```text
Model: deepseek/deepseek-v4-flash
Reasoning: xhigh
```

The fallback is automatic and does not reopen planning. The Coordinator must
report the fallback reason and the actual provider/model used.

Verifier rules:

- run only the exact commands and exact paths listed in the package;
- do not infer or add “related” tests, OCR checks, full suites, builds, or apps;
- do not use write-mode formatting or automatic fixes;
- do not repair failures;
- accidental extra commands must be disclosed and must not count as required
  evidence;
- final authoritative focused validation should run once on the frozen target.

### Semantic review

Route semantic review by the uncertainty and blast radius of the review target.
Do not default every Reviewer to `gpt-5.6-sol`.

Every Reviewer package must state:

```text
Review difficulty: light | ordinary | high
Reason: <one concrete sentence>
```

#### Light review

Use:

```text
Model: gpt-5.6-sol
Reasoning: light
Fallback: Gemini 3.6 Flash high
```

Typical light review targets:

- one small documentation file;
- a single-file mechanical fix;
- test fixtures or characterization tests;
- formatting-safe changes;
- frozen behavior with no public API, persistence, privacy, or concurrency
  change.

Use one Reviewer only. Do not add a cross-review merely because another cheap
model is available.

#### Ordinary semantic review

Primary route:

```text
Model: deepseek/deepseek-v4-pro
Reasoning: max
```

When the host does not expose `max`, use and report its exact highest available
equivalent, such as `xhigh`.

Typical ordinary targets:

- business logic under a fully frozen contract;
- several related changed files;
- mapper, adapter, projection, or compatibility code;
- ordinary state behavior;
- non-security-critical architecture-boundary work.

A Gemini cross-check is **risk-triggered**, not automatic. Add it only when one
or more of these signals exists:

- the primary Reviewer reports uncertainty;
- the change crosses more than one architecture layer;
- the change contains fallback, rollback, exception, or corruption handling;
- the change introduces or modifies a public DTO or compatibility projection;
- Verifier evidence appears inconsistent with the implementation semantics;
- the diff is large enough that an independent boundary pass is materially
  useful.

Risk-triggered cross-check route:

```text
Model: Gemini 3.6 Flash
Reasoning: high
```

The two Reviewers must receive different assignments:

```text
DeepSeek primary:
- control flow
- data flow
- state transitions
- transaction boundaries
- error classification
- call paths
- whether tests catch implementation defects

Gemini cross-check:
- contract/implementation mismatch
- cross-file omissions
- privacy leakage
- incorrect fallback behavior
- boundary inputs
- ambiguous documentation
- inconsistencies between Verifier evidence and the claimed result
```

Do not send both Reviewers identical “review everything” prompts. The Gemini
cross-check receives only the frozen contract summary, exact changed paths,
focused diff, Verifier result, primary findings, and its targeted checklist. It
must not reload the full parent conversation or repository.

Cross-review decision rules:

```text
Both approve
-> APPROVE

Either reports an actionable P1/P2
-> REQUEST_CHANGES

The two reports conflict
-> Coordinator resolves from the frozen contract and repository evidence
-> do not create a third Reviewer automatically
```

#### High-difficulty review

High review applies to:

- public API or contract freezing;
- CAS, revision, or concurrency semantics;
- persistence, schema, or migration;
- security or privacy;
- cross-module compatibility with meaningful data-loss risk;
- contradictory authoritative evidence;
- reopening a frozen checkpoint.

Use inexpensive models to find and consolidate issues before the final
high-cost review:

```text
Optional bounded pre-review:
- deepseek/deepseek-v4-pro max
- Gemini 3.6 Flash high for a different targeted checklist

Final review after all known findings are fixed:
- gpt-5.6-sol high
```

`gpt-5.6-sol high` reviews only the final candidate. It must not review every
intermediate revision.

Each Sol-high Reviewer package must state:

```text
High Reviewer count for this stage: <number>
Final review: yes | no
Escalation reason: <specific unresolved high-risk reasoning problem>
Why cheaper review is insufficient: <one concrete sentence>
```

Exactly one Sol-high final review is allowed per stage by default. A second
Sol-high review requires new explicit user authorization.

Do not select high merely because the role is Reviewer or the parent stage is
T3. Once a contract is fully frozen, ordinary implementation slices normally
return to ordinary review routing.

Reviewers inspect the frozen diff, task contract, changed files, and Verifier
evidence. They do not rerun deterministic validation unless the package
explicitly makes a command result itself the review target.

### High-capability planning, diagnosis, or execution

Use:

```text
Model: gpt-5.6-sol
Reasoning: high
```

Only when the child task explicitly requires one or more of:

- architectural design or public-contract freezing;
- uncertain root-cause analysis across modules;
- security or privacy judgment;
- concurrency, CAS, migration, or database-safety reasoning;
- resolving conflicting authoritative contracts or evidence;
- a genuinely difficult implementation whose behavior cannot be frozen first;
- escalation after the ordinary Executor failed because of reasoning limits,
  not because of environment, quota, path, or permission errors.

Each high-capability dispatch must record:

```text
Escalation reason: <specific unresolved reasoning problem>
```

The following are not sufficient escalation reasons:

- “the task is important”;
- “the parent stage is T3”;
- “high may be safer”;
- “the role is Planner/Reviewer/Executor”.

## Review-cycle budget

Review must be complete and bounded.

### Complete-review requirement

A Reviewer must continue through every assigned review dimension even after
finding a P1. It returns one terminal report containing all non-duplicate P1,
P2, and P3 findings. It must not split one target into incremental findings
across multiple agents or stop after the first blocker.

### Light and ordinary cycles

- one primary review cycle by default;
- at most one targeted Gemini cross-check when a listed risk trigger applies;
- `REQUEST_CHANGES` ends the current cycle;
- do not automatically repair, rewrite the contract, and create another full
  Reviewer;
- a new review after repair requires an explicitly authorized package.

### High-difficulty cycles

Use this maximum sequence:

```text
bounded cheap pre-review
-> consolidate all findings
-> one repair/revision
-> one Sol-high final review
-> stop
```

The final Sol-high result ends the cycle whether it is `APPROVE` or
`REQUEST_CHANGES`.

Forbidden without new explicit user authorization:

- a second Sol-high final review;
- a third Reviewer after a primary and cross-check;
- automatic review -> revision -> review loops;
- repeatedly generating Revision 2, Revision 3, or later revisions inside one
  delegated task;
- extending the cycle merely because a new finding is “still in scope”.

## Execution and repair economy

### Executor self-check

The ordinary Executor owns implementation plus a minimal focused self-check.
It should run only tests and analysis directly needed to catch an immediate
mistake in its changed behavior.

During that first focused validation, the Executor may make one deterministic,
in-scope correction and rerun only the failed focused command. This remains
part of the original Executor task and does not require a separate Repair agent.

Create a fresh Repair Executor only after the original writer has reached a
terminal handoff and an independent Verifier or Reviewer finds an actionable
defect, or when writer isolation is otherwise required by repository rules.

### Avoid duplicate validation

Use this division:

```text
Executor:
- directly affected focused tests
- focused analyze when practical
- git diff --check

Verifier:
- the complete authoritative focused validation matrix
- changed-path, staged-state, target-identity, and diff gates
```

Do not make both agents run the same complete matrix unless a post-handoff
repair changed the frozen target and invalidated the old evidence.

### Diff-first reading

For implementation handoff, verification, and review, inspect in this order:

1. exact target identity and `git status --short`;
2. `git diff --stat` and `git diff --name-only`;
3. the focused diff for exact paths;
4. full files only when the diff and nearby context are insufficient.

Do not repeatedly load the entire parent conversation, entire repository, or
large unchanged files into every child package.

For cross-review, the second Reviewer must receive focused context instead of a
second copy of the complete planning history.

## Exact-path discipline

Every package and handoff must use complete repository-relative paths.

Correct:

```text
test/architecture_boundary_test.dart
lib/application/import_review/review_session.dart
```

Forbidden aliases:

```text
architecture
architecture test
review test
session file
```

`ARCHITECTURE.md` and `test/architecture_boundary_test.dart` are distinct
files. A parent must not infer one from an alias for the other.

Before dispatch, verify every existing allowed, forbidden, validation, and
sidecar path exactly. New-file packages must verify the exact parent directory.
If a path is absent or ambiguous, stop package creation instead of guessing.

## Package requirements

In addition to the 14 fields required by `AGENTS.md`, every delegated package
must state:

```text
Preferred model: <provider/model or named host model>
Reasoning: light | medium | high | xhigh | max
Routing reason: <one sentence>
Fallback: <route or none>
```

For Reviewer packages, also include review difficulty. For high-capability
packages, include the escalation reason. Sol-high Reviewer packages must also
include the stage high-review count and whether the dispatch is the final
review.

Terminal handoffs must report the actual provider/model and reasoning level.
When a fallback occurs, report why the preferred route could not be created.
For a cross-review, report both actual models and the distinct checklist each
one received.

## User overrides

An explicit user-selected model, reasoning level, or review-cycle limit for the
current task takes precedence over these defaults. Safety, scope, Git
authorization, privacy, and fixed-target rules remain unchanged.
