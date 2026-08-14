# Agent Model Routing and Cost Discipline

This file defines repository-specific model routing. Safety, scope, Git authority, privacy, fixed-target rules, evidence inheritance and repair semantics live in `AGENTS.md`.

## Principles

- Route by remaining uncertainty and blast radius.
- Use the cheapest route that safely fits implementation, but keep final semantic review independent.
- Reuse parent-attested evidence and avoid duplicate topology/hash/root-cause work.
- DeepSeek default reasoning = MAX whenever a DeepSeek route is selected unless the user overrides it.
- A green Executor verification lane is not semantic approval.

## Ordinary implementation + mechanical verification

```text
Preferred model: deepseek/deepseek-v4-flash
Reasoning: max
Fallback: same model at the highest supported reasoning setting
```

Use for bounded implementation where behavior/contracts are frozen, including production changes, regressions, adapters/mappers, compatibility glue and deterministic in-contract repairs.

The Executor owns focused mechanical verification and bounded self-repair by default. A standalone Verifier is not inserted merely to rerun the same checks.

## Optional independent verification

Preferred order when `AGENTS.md` risk triggers require a Verifier:

1. local deterministic runner/CI when sufficient;
2. inexpensive tool-capable Verifier;
3. Gemini Flash high;
4. DeepSeek V4 Flash max when other routes are unavailable.

Verifier runs exact assigned checks and never repairs failures.

## Independent final semantic review

The current project workflow assigns the final semantic review to **GPT-5.6 Sol** independently from the Executor.

Every review states:

```text
Review difficulty: light | ordinary | high
Reason: <one concrete sentence>
```

Recommended reasoning:

- light: small docs/mechanical/test-only/frozen low-risk changes;
- ordinary: bounded business/domain logic and multi-file changes under a frozen contract;
- high: public contract/API changes, CAS/revision/concurrency semantics, persistence/schema/migrations, security/privacy/authorization, or meaningful cross-module data-loss risk.

Preferred final Reviewer:

```text
Model: gpt-5.6-sol
Reasoning: match review difficulty; use high for high-risk review
```

Reviewer reads the final PR independently and does not accept Executor self-assessment as proof.

## Repair routing

During implementation/verification:

```text
Executor check fails
-> bounded self-repair when AGENTS.md conditions are satisfied
-> rerun failed/direct regression checks
-> up to two bounded semantic repair cycles
-> mandatory STOP when limits/boundaries are crossed
```

After Reviewer findings:

```text
P0/P1/P2
-> bounded Repair Executor on same PR when in scope
-> mechanical verification
-> push updated PR
-> STOP
-> GPT-5.6 Sol targeted fresh review
```

P3 does not automatically trigger repair.

A second full review is exceptional; use targeted closure unless the repair changed architecture/public contract/schema/security/concurrency semantics or invalidated the original review scope.

## Execution economy

Executor should run:

- directly affected focused tests;
- relevant architecture/boundary checks;
- focused analyze;
- format gate;
- `git diff --check`;
- only broader checks explicitly required by the task/repository.

Do not run live provider/OCR, generated apps, full Release builds, or broad suites merely for reassurance.

## User overrides

An explicit current-user choice of model, reasoning level, review limit, repair permission, stop condition, or Git authority overrides these routing defaults. Safety, privacy, scope and fixed-target rules remain unchanged.
