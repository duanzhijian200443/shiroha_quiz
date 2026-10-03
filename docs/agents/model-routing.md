# Agent Model Routing and Cost Discipline

This file defines repository-specific model routing. Safety, scope, Git
authority, privacy, fixed-target rules, evidence inheritance and repair semantics
live in `AGENTS.md`.

## Precedence

Model routing follows this order:

1. explicit current-user instruction;
2. explicit current-task / project override;
3. this repository default.

A current explicit user choice overrides every repository fallback below.

Do not put model names in task titles. A task package may mention the active
model only when routing itself is relevant.

## Current repository default

For this project, use:

```text
GPT-6.1 Sol
```

for Planning, Execution, Diagnosis and Independent Review when available.

Reasoning level should match the task:

- light: docs/mechanical/frozen low-risk work;
- ordinary: bounded business/domain logic and multi-file changes;
- high: public contracts, persistence/schema/migrations, CAS/concurrency,
  security/privacy/authorization, or meaningful data-loss risk.

Independence means a separate review pass/context over a frozen target. It does
not require a different model family.

## Executor

The Executor owns:

- implementation;
- focused mechanical verification;
- policy-permitted bounded self-repair;
- commit/push/PR delivery when authorized.

Do not insert a separate Verifier merely to repeat the Executor's deterministic
checks.

## Optional independent Verifier

Use a Verifier only for the risk triggers in `AGENTS.md`.

Preferred order:

1. deterministic CI/local runner when sufficient;
2. GPT-6.1 Sol in a separate verification context when an agent is needed.

The Verifier runs assigned checks only and never repairs failures.

## Independent Reviewer

Final semantic review uses GPT-6.1 Sol in a separate review context unless the
user explicitly chooses another route.

The Reviewer must independently inspect the frozen PR head and may not accept
Executor self-assessment as proof.

## Repair routing

During implementation:

```text
Executor check fails
-> bounded self-repair when AGENTS.md permits
-> rerun failed/direct regression checks
-> STOP only at the actual scope/contract/risk boundary
```

After review:

```text
P0/P1/P2
-> bounded Repair Executor on the same PR
-> mechanical verification
-> push updated PR
-> STOP
-> targeted fresh Reviewer pass
```

P3 does not automatically trigger repair.

## Execution economy

Run directly affected tests, relevant architecture/boundary checks, focused
analyze, format gate and `git diff --check`. Do not run live provider/OCR,
full Release builds, or broad suites merely for reassurance.

## User overrides

An explicit current-user choice of model, reasoning level, review limit, repair
permission, stop condition or Git authority wins over repository routing
defaults. Safety, privacy, frozen contract and fixed-target rules remain
unchanged.
