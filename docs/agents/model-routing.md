# Child-Agent Model Routing and Cost Discipline

This file defines repository-specific model routing for delegated agents. Safety, scope, Git authority, privacy, fixed-target rules, evidence inheritance, and finding/repair semantics live in `AGENTS.md` and are not repeated here.

## Principles

- Route by remaining uncertainty and blast radius, not by role name or the maximum risk of the parent stage.
- Use the cheapest model route that safely fits the child task.
- Deterministic verification belongs to local commands/CI/Verifier first; a model interprets evidence rather than replacing it.
- Do not reload the full parent conversation into every child.
- Reuse parent-attested evidence; do not duplicate topology discovery, hashes, root-cause analysis, or full validation across agents unless drift or contradictory evidence requires it.
- **DeepSeek default reasoning = MAX.** Whenever a DeepSeek route is selected, use the provider/host's highest supported reasoning setting (`max` in the current repository syntax) unless the current user explicitly overrides it.
- Risk tier and review difficulty still determine model/provider choice, role routing, escalation, allowed scope, and validation strength. They do not lower DeepSeek reasoning for deterministic, low-risk, or otherwise cheaper tasks.
- Sol, Terra, Luna, Gemini, and other providers retain their independent routing and reasoning rules.

## Default routes

### Ordinary implementation

```text
Preferred model: deepseek/deepseek-v4-flash
Reasoning: max
Fallback: same model at the highest supported reasoning setting
```

Use for bounded implementation where behavior/contracts are already frozen, including ordinary production changes, regression tests, adapters/mappers, compatibility glue, and deterministic in-contract repairs.

Task risk may select a different provider or require planning/review escalation,
but it does not downshift DeepSeek reasoning below `max`.

### Deterministic verification

Preferred order:

1. local deterministic runner or CI when available;
2. Verifier using the host's inexpensive tool-capable model;
3. `Gemini 3.6 Flash` high when a model route is needed;
4. `deepseek/deepseek-v4-flash` max when Gemini creation/quota/tools are unavailable.

Verifier packages run only exact requested commands/paths. They do not repair failures, widen tests, invoke real providers, rediscover the semantic root cause, or perform optional broad suites.

### Semantic review

Every Reviewer package states:

```text
Review difficulty: light | ordinary | high
Reason: <one concrete sentence>
```

#### Light

```text
Preferred: gpt-5.6-sol light
Fallback: Gemini 3.6 Flash high
```

Use for small docs/mechanical/test-only/frozen single-file changes with no meaningful persistence, privacy, concurrency, or public-contract risk.

#### Ordinary

```text
Preferred: deepseek/deepseek-v4-flash
Reasoning: max
Fallback: same model at the highest supported reasoning setting
```

Use for bounded business logic, mapper/projection/state behavior, compatibility work, and multi-file changes under a fully frozen contract.

Add a targeted Gemini cross-check only when one or more concrete risk signals exist:

- primary Reviewer uncertainty;
- more than one architecture layer crossed;
- fallback/rollback/corruption/exception behavior changed;
- public DTO/compatibility projection changed;
- Verifier evidence conflicts with implementation semantics;
- diff size makes an independent boundary pass materially useful.

If used, split assignments rather than asking both Reviewers to "review everything":

```text
DeepSeek primary:
- control/data flow
- state transitions
- transaction/error boundaries
- call paths
- whether tests catch defects

Gemini cross-check:
- contract mismatch
- cross-file omissions
- privacy/fallback boundaries
- edge inputs
- evidence/documentation inconsistencies
```

Do not create a third full Reviewer merely because two reports disagree. Coordinator resolves from the frozen contract/evidence; architectural conflicts become Class C.

#### High

Use high review only for unresolved or newly changed public contracts/APIs, CAS/revision/concurrency semantics, persistence/schema/migrations, security/privacy, meaningful cross-module data-loss risk, contradictory authoritative evidence, or reopening a frozen checkpoint.

Use inexpensive models to find/consolidate issues first when useful. The default final high-cost review is:

```text
Final Reviewer: gpt-5.6-sol high
```

Exactly one Sol-high full review is allowed per stage by default. A second full Sol-high review requires explicit user authorization.

Once high-risk contracts are frozen, ordinary implementation slices return to ordinary review unless the slice itself changes schema/API/privacy/concurrency/migration semantics.

## Finding closure routing

Finding severity/class definitions and hard repair limits come from `AGENTS.md`.

Operational routes:

```text
Class A
-> fresh narrow Repair Executor
-> focused Verifier
-> finish
```

```text
Class B
-> initial full Reviewer has already collected compatible findings
-> one fresh Repair Executor for the batch
-> focused Verifier
-> one targeted closure Reviewer
```

```text
Class C
-> stop for user authorization
```

P3 is non-blocking and does not launch automatic repair unless evidence promotes it under `AGENTS.md`.

A targeted closure Reviewer checks only the explicit findings, repaired lines, direct regression surface, and updated Verifier evidence. It must not restart a full review.

Do not use this wasteful order:

```text
repair -> closure Reviewer -> full Reviewer -> repair -> closure Reviewer
```

Normal semantic order is:

```text
implementation -> focused Verifier -> initial full Reviewer
-> batched Class B repair when needed -> focused Verifier
-> targeted closure Reviewer -> finish
```

A deterministic Verifier failure may receive a Class A correction before the initial full Reviewer.

## Execution economy

### Executor self-check

Executor owns implementation plus a minimal immediate check:

- directly affected focused test(s);
- focused analyze when practical;
- `git diff --check`.

It may make one clearly in-scope immediate correction during that first focused check, then rerun only the failed command.

Do not ask the Executor to rerun an authoritative broad matrix already available for the unchanged target.

### Independent verification

Verifier owns the authoritative focused matrix and minimal independent target-stability check. It does not need to rediscover worktree topology, root cause, architecture baseline, or per-file hashes already frozen by the parent.

For committed targets: one target-SHA check before, requested gates, one target-SHA/status check after.

For uncommitted targets: one supplied HEAD/status check before, requested gates, one stability check after.

### Diff-first review

For handoff/review:

1. inherited target identity + Verifier evidence;
2. diff stat/name-only;
3. focused diff;
4. caller/callee/full files only when a concrete question requires them.

For committed targets, the commit SHA identifies tracked file contents; do not require redundant per-file hash inventories.

### Child lifecycle

Terminal child sessions are not retained as working context. Coordinator captures the bounded handoff, closes/releases the child immediately, and spawns a fresh child only when the next role is required. Default global active-child budget is two unless the user/package explicitly authorizes more.

Prefer event/terminal-handoff waiting over periodic status polling.

## Package model fields

Only include model routing fields when delegating a child or overriding defaults:

```text
Preferred model: <route>
Reasoning: <level>
Routing reason: <one sentence when non-obvious>
Fallback: <route or none>
```

For any DeepSeek package, `Reasoning` defaults to `max`; do not derive a lower
DeepSeek reasoning level from T0/T1/T2/T3, review difficulty, determinism, or
cost. Non-DeepSeek packages continue to use their provider-specific level.

High review also includes the specific escalation reason and whether it is the stage's final full review.

Repair packages additionally include only:

```text
Finding class: A | B
Findings to close: <exact list or compatible batch>
Frozen local decisions: <none or exact decisions>
Closure pass: <n/max>
```

Do not repeat generic Git/safety/architecture text already inherited from `AGENTS.md`.

## Model identity reporting

Report the requested route and any observed fallback. If the host exposes the actual provider/model, report it. If it does not, do not require self-attestation and do not emit boilerplate such as `MODEL IDENTITY: UNCONFIRMED`.

## User overrides

An explicit current-user choice of model, reasoning level, review limit, repair permission, or stop condition overrides these routing defaults. Safety, privacy, scope, Git authority, and fixed-target rules remain unchanged.
