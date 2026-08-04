# Child-Agent Model Routing and Cost Discipline

This file implements the repository-specific child-agent routing policy under
`AGENTS.md` section 15. It applies whenever a parent agent, Coordinator, or
Planner recommends or creates delegated agents.

## Goals

Reduce cost by selecting the cheapest model that safely fits the actual child
task, avoiding duplicate context and duplicate validation, and escalating only
when the work genuinely requires stronger reasoning.

This policy does **not** impose a hard monetary, token, agent-count, or total
elapsed-time budget. Scope, safety, command timeouts, and terminal stop
conditions still apply.

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

Use `gpt-5.6-sol` with reasoning selected by review difficulty:

| Difficulty | Reasoning | Typical review |
|---|---|---|
| Light | light | single-file mechanical fix, test fixture, formatting-safe documentation, frozen behavior with no public API change |
| Medium | medium | default business-logic review, several changed files, state behavior under a fully frozen contract, ordinary architecture-boundary review |
| High | high | public API or contract, CAS/revision/concurrency, persistence/schema/migration, security/privacy, cross-module compatibility, contradictory evidence, or checkpoint reopening |

Every Reviewer package must state:

```text
Review difficulty: light | medium | high
Reason: <one concrete sentence>
```

Do not select high merely because the role is Reviewer or the parent stage is
T3. A medium review is the default for meaningful semantic code review once the
contract is fully frozen.

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
Reasoning: light | medium | high | xhigh
Routing reason: <one sentence>
Fallback: <route or none>
```

For Reviewer packages, also include review difficulty. For high-capability
packages, include the escalation reason.

Terminal handoffs must report the actual provider/model and reasoning level.
When a fallback occurs, report why the preferred route could not be created.

## User overrides

An explicit user-selected model or reasoning level for the current task takes
precedence over these defaults. Safety, scope, Git authorization, privacy, and
fixed-target rules remain unchanged.
