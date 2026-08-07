# Child-Agent Model Routing and Cost Discipline

This file defines repository-specific model routing for delegated agents. Safety, scope, Git authority, privacy, fixed-target rules, and finding/repair semantics live in `AGENTS.md` and are not repeated here.

## Principles

- Route by remaining uncertainty and blast radius, not by role name or the maximum risk of the parent stage.
- Use the cheapest model that safely fits the child task.
- Deterministic verification belongs to local commands/CI/Verifier first; a model interprets evidence rather than replacing it.
- Do not reload the full parent conversation into every child.
- Do not duplicate full validation across agents unless a repair changed the frozen target.

## Default routes

### Ordinary implementation

```text
Preferred model: deepseek/deepseek-v4-flash
Reasoning: xhigh
Fallback: same model at the nearest available high reasoning level
```

Use for bounded implementation where behavior/contracts are already frozen, including ordinary production changes, regression tests, adapters/mappers, compatibility glue, and deterministic in-contract repairs.

A T3 parent stage does not make every frozen implementation slice T3 reasoning work.

### Deterministic verification

Preferred order:

1. local deterministic runner or CI when available;
2. Verifier using the host's inexpensive tool-capable model;
3. `Gemini 3.6 Flash` high when a model route is needed;
4. `deepseek/deepseek-v4-flash` xhigh when Gemini creation/quota/tools are unavailable.

Verifier packages run only exact requested commands/paths. They do not repair failures, widen tests, invoke real providers, or perform optional broad suites.

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
Preferred: deepseek/deepseek-v4-flash max
Fallback: same model xhigh
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
-> fresh Repair Executor
-> focused Verifier
-> one targeted closure Reviewer
```

```text
Class C
-> stop for user authorization
```

P3 is non-blocking and does not launch automatic repair unless evidence promotes it under `AGENTS.md`.

A targeted closure Reviewer checks only the explicit findings, repaired lines, direct regression surface, and updated Verifier evidence. It must not restart a full review.

## Execution economy

### Executor self-check

Executor owns implementation plus a minimal immediate check:

- directly affected focused test(s);
- focused analyze when practical;
- `git diff --check`.

It may make one clearly in-scope immediate correction during that first focused check, then rerun only the failed command.

### Independent verification

Verifier owns the authoritative focused matrix, target identity, changed/staged paths, and diff gates. Do not make Executor and Verifier both run the same broad matrix without a target-changing repair.

### Diff-first reading

For handoff/verification/review:

1. target identity + status;
2. diff stat/name-only;
3. focused diff;
4. full files only when needed.

For committed targets, the commit SHA identifies tracked file contents; do not require redundant per-file hash inventories.

## Package model fields

Only include model routing fields when delegating a child or overriding defaults:

```text
Preferred model: <route>
Reasoning: <level>
Routing reason: <one sentence when non-obvious>
Fallback: <route or none>
```

High review also includes the specific escalation reason and whether it is the stage's final full review.

Repair packages additionally include only:

```text
Finding class: A | B
Findings to close: <exact list>
Frozen local decisions: <none or exact decisions>
Closure pass: <n/max>
```

Do not repeat generic Git/safety/architecture text already inherited from `AGENTS.md`.

## Model identity reporting

Report the requested route and any observed fallback. If the host exposes the actual provider/model, report it. If it does not, do not require self-attestation and do not emit boilerplate such as `MODEL IDENTITY: UNCONFIRMED`.

## User overrides

An explicit current-user choice of model, reasoning level, review limit, repair permission, or stop condition overrides these routing defaults. Safety, privacy, scope, Git authority, and fixed-target rules remain unchanged.
