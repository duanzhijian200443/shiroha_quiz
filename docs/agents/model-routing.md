# Child-Agent Model Routing and Cost Discipline

This file implements the repository-specific child-agent routing policy under
`AGENTS.md` section 15. It applies whenever a parent agent, Coordinator, or
Planner recommends or creates delegated agents.

## Goals

Reduce cost by selecting the cheapest model that safely fits the actual child
task, avoiding duplicate context and duplicate validation, and escalating only
when the work genuinely requires stronger reasoning.

Review must be both complete and capable of closing routine findings without
repeated user interruptions. The process must not oscillate between two bad
extremes:

- unbounded review -> revision -> review loops;
- stopping for every local field name, bound, wording, or deterministic repair.

Scope, safety, Git authority, privacy, fixed-target rules, command timeouts, and
the bounded closure rules below always apply.

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
- deterministic repairs inside an approved contract;
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
- do not infer or add unrelated tests, OCR checks, full suites, builds, or apps;
- do not use write-mode formatting or automatic fixes;
- do not repair failures;
- accidental extra commands must be disclosed and must not count as required
  evidence;
- authoritative focused validation runs once per frozen target;
- after a repair, rerun only evidence invalidated by that repair plus the
  changed-path, staged-state, and target-identity gates.

## Semantic review routing

Route semantic review by remaining uncertainty and blast radius. Do not default
every Reviewer to `gpt-5.6-sol`.

Every Reviewer package must state:

```text
Review difficulty: light | ordinary | high
Reason: <one concrete sentence>
```

### Light review

Use one Reviewer:

```text
Preferred model: gpt-5.6-sol
Reasoning: light
Fallback: Gemini 3.6 Flash high
```

Typical light targets:

- one small documentation file;
- a single-file mechanical fix;
- test fixtures or characterization tests;
- formatting-safe changes;
- frozen behavior with no public API, persistence, privacy, or concurrency
  change.

Do not add a second Reviewer merely because another inexpensive model is
available.

### Ordinary semantic review

Primary route supported by the current host:

```text
Preferred model: deepseek/deepseek-v4-flash
Reasoning: max
Fallback: the same model at xhigh when max is unavailable
```

Typical ordinary targets:

- business logic under a fully frozen contract;
- several related changed files;
- mapper, adapter, projection, or compatibility code;
- ordinary state behavior;
- non-security-critical architecture-boundary work.

A Gemini cross-check is risk-triggered, not automatic. Add it only when one or
more of these signals exists:

- the primary Reviewer reports uncertainty;
- the change crosses more than one architecture layer;
- the change contains fallback, rollback, exception, or corruption handling;
- the change introduces or modifies a public DTO or compatibility projection;
- Verifier evidence appears inconsistent with implementation semantics;
- the diff is large enough that an independent boundary pass is materially
  useful.

Risk-triggered cross-check route:

```text
Model: Gemini 3.6 Flash
Reasoning: high
```

The two Reviewers receive different assignments:

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

Do not send both Reviewers identical “review everything” prompts. The
cross-check receives only the frozen contract summary, exact changed paths,
focused diff, Verifier result, primary findings, and its targeted checklist. It
must not reload the full parent conversation or repository.

Cross-review decision rules:

```text
Both approve
-> APPROVE

Either reports an actionable P1/P2
-> enter the finding-classification and closure process below

The two reports conflict
-> Coordinator resolves from the frozen contract and repository evidence
-> if the conflict is architectural, stop for user input
-> do not create a third full Reviewer automatically
```

### High-difficulty review

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
- deepseek/deepseek-v4-flash max
- Gemini 3.6 Flash high with a different targeted checklist

Final review after known findings are fixed:
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

Exactly one Sol-high full review is allowed per stage by default. A second
Sol-high full review requires new explicit user authorization.

Once a high-risk contract is frozen, its ordinary implementation slices return
to ordinary review routing unless the slice itself changes schema, public API,
privacy, concurrency, or migration semantics.

Reviewers inspect the frozen diff, task contract, changed files, and Verifier
evidence. They do not rerun deterministic validation unless a command result is
explicitly the review target.

## Complete-review requirement

A Reviewer must continue through every assigned review dimension even after
finding a P1. It returns one terminal report containing all non-duplicate P1,
P2, and P3 findings. It must not stop after the first blocker or intentionally
split one target into incremental reports.

A full Reviewer assesses the whole assigned target. A later targeted closure
check verifies only explicit findings and their direct regression surface; it
is not another full review.

## Finding classification

The Coordinator classifies every actionable finding before deciding whether to
repair, re-review, or stop.

### Class A: deterministic mechanical correction

A finding is Class A only when it has one unique, semantics-preserving fix.
Examples:

- wrong field name where the canonical field is already frozen;
- typo, stale path, duplicated word, broken Markdown, or inconsistent example;
- omitted occurrence of an already-approved rename;
- formatting or terminology drift;
- a test expectation that mechanically lags the frozen behavior;
- an exact Reviewer instruction such as `id -> question_id` where no design
  choice remains.

Class A must not change behavior, public meaning, permissions, schema, tool
set, stage dependency, error taxonomy, or allowed-file scope.

Closure lane:

```text
one terminal correction
-> focused Verifier evidence
-> commit when all gates pass
```

No new Reviewer is required. The Coordinator must search the full allowed
scope for the same stale pattern so the correction closes every occurrence.

### Class B: bounded in-scope semantic completion

A finding is Class B when it requires a local decision but does not change the
approved goal or architecture. Examples:

- choosing an interval convention such as `[from, to)`;
- setting a bounded list limit, preview length, or deterministic truncation
  rule;
- selecting a timezone source already implied by the application boundary;
- clarifying which layer owns protocol-shape validation versus business
  validation;
- completing a safe response envelope;
- resolving a contradiction entirely within the existing tool set, permission
  model, stage dependency, and allowed files.

The Coordinator may freeze a reasonable local default without interrupting the
user when all of these are true:

- no tool, endpoint, public capability, or permission is added or removed;
- READ/WRITE or security posture does not change;
- no database schema, migration, frozen public API, or cross-stage dependency
  changes;
- no new dependency, transport, provider, or file scope is introduced;
- the decision is recorded explicitly in the task handoff or decision ledger;
- one clearly defensible default exists and no authoritative contract conflicts
  with it.

Closure lane:

```text
fresh Repair Executor
-> focused Verifier
-> one targeted closure Reviewer
```

The targeted closure Reviewer receives only the findings, frozen decisions,
focused diff, and updated Verifier evidence. It must not restart a full review.

If the targeted closure Reviewer finds only Class A defects, use the Class A
terminal-correction lane and finish without another Reviewer.

If it finds another Class B defect directly caused by the repair, the
Coordinator may perform one final bounded closure repair, rerun focused
verification, and request one targeted confirmation. This is the last semantic
repair pass for the task.

### Class C: material design change

Stop and request user authorization when a finding would:

- add, remove, or substantially redefine a public tool or API;
- change READ_ONLY to WRITE or expand destructive capability;
- expose previously forbidden data;
- alter database schema, migration, concurrency, CAS, or privacy policy;
- modify a frozen cross-stage dependency or authoritative fallback rule;
- add a dependency, transport, provider, or new allowed file;
- require choosing among materially different product behaviors;
- conflict with another authoritative contract without a clear precedence rule.

Class C is the only finding class that is automatically `BLOCKED` pending user
input.

## Bounded automatic closure

The normal automatic lifecycle is:

```text
Executor
-> Verifier
-> complete Reviewer
-> classify all findings together
-> repair through Class A or Class B lane when authorized by this policy
-> final focused evidence
-> commit or stop
```

Hard limits per task:

- at most one initial full semantic Reviewer;
- at most one risk-triggered cross-check;
- at most two Class B semantic repair passes total;
- at most one Class A terminal-correction pass after the final semantic check;
- at most one Sol-high full review per stage without new user authorization;
- no third full Reviewer;
- no automatic Revision 2/3 loop that reloads the entire contract each time.

A targeted closure Reviewer is allowed within these limits because it verifies
specific findings rather than performing another whole-target review.

The process must not stop merely because a local default was previously
unstated. It stops only for Class C, exhausted closure limits, environment or
permission failure, target drift, or an unresolved authoritative conflict.

## High-difficulty closure

Use this maximum sequence:

```text
bounded inexpensive pre-review
-> consolidate findings
-> one main repair/revision
-> one Sol-high full final review
-> optional Class A terminal correction
-> focused Verifier
-> stop
```

If the Sol-high final review reports a Class B issue that is narrow and caused
by the final candidate, one bounded closure repair plus one inexpensive targeted
confirmation is allowed. Do not launch another Sol-high full review.

If the Sol-high final review reports Class C, stop for user authorization.

## Execution and repair economy

### Executor self-check

The ordinary Executor owns implementation plus a minimal focused self-check.
It should run only tests and analysis directly needed to catch an immediate
mistake in its changed behavior.

During the first focused validation, the Executor may make one deterministic,
in-scope correction and rerun only the failed focused command. This remains
part of the original Executor task and does not require a separate Repair
agent.

Create a fresh Repair Executor after the original writer reaches a terminal
handoff and an independent Verifier or Reviewer identifies a Class B defect, or
when writer isolation is otherwise required by repository rules.

A Class A terminal correction may be performed by a narrowly scoped fresh
Repair Executor or by the Coordinator only when repository role rules explicitly
allow the Coordinator to write. The default is a fresh Repair Executor.

### Avoid duplicate validation

Use this division:

```text
Executor:
- directly affected focused tests
- focused analyze when practical
- git diff --check

Verifier:
- complete authoritative focused matrix for the current frozen target
- changed-path, staged-state, target-identity, and diff gates

Targeted closure Reviewer:
- explicit findings
- repaired lines and direct regression surface
- updated Verifier evidence
```

Do not make multiple agents run the same complete matrix unless a repair changed
the frozen target and invalidated the old evidence.

### Diff-first reading

For implementation handoff, verification, and review, inspect in this order:

1. exact target identity and `git status --short`;
2. `git diff --stat` and `git diff --name-only`;
3. the focused diff for exact paths;
4. full files only when the diff and nearby context are insufficient.

Do not repeatedly load the entire parent conversation, entire repository, or
large unchanged files into every child package.

For cross-review and closure review, send focused context instead of a second
copy of the complete planning history.

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

Reviewer packages also include review difficulty. High-capability packages
include the escalation reason. Sol-high Reviewer packages additionally include
the stage high-review count and whether the dispatch is the final full review.

Repair packages must include:

```text
Finding class: A | B
Findings to close: <exact list>
Frozen local decisions: <none or exact decisions>
Forbidden semantic changes: <exact boundaries>
Closure pass: <number>/<maximum>
```

Terminal handoffs report the actual provider/model and reasoning level. When a
fallback occurs, report why the preferred route could not be created. For a
cross-review, report both actual models and their distinct checklists.

## Commit gate after review

A task may be staged and committed when one of these is true:

- the complete Reviewer or required cross-review returns `APPROVE`, and
  Verifier gates pass;
- all remaining findings were Class A, the terminal correction is complete,
  and focused Verifier gates pass;
- the final targeted closure Reviewer approves all Class B repairs, any
  remaining Class A correction is complete, and focused Verifier gates pass.

A commit is forbidden when:

- any Class B or Class C finding remains open;
- target identity drifted;
- changed or staged paths exceed authority;
- required verification failed or was not run;
- Git authority was not explicitly granted.

## User overrides

An explicit user-selected model, reasoning level, review-cycle limit, repair
permission, or stop condition for the current task takes precedence over these
defaults. Safety, scope, Git authorization, privacy, and fixed-target rules
remain unchanged.
