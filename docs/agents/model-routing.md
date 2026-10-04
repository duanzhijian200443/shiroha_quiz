# Agent Model Routing

This file owns model selection and reasoning effort only.
Shared safety, ownership, budgets, role workflow and Git authority live in
`AGENTS.md`; package templates live in `docs/agents/README.md`.

## Selection

Follow platform-supported routing, then:

1. Explicit current-user model/reasoning choice.
2. Explicit current-task/project override.
3. Repository default: GPT-6.1 Sol when available.

Use the default for Planning, Execution, Diagnosis and Independent Review.
Do not assume an unavailable model or silently override an explicit user choice.
Do not put model names in task titles; include them in packages only when relevant.

## Reasoning effort

Route by uncertainty and the child task's blast radius, not role name or the
parent stage's maximum risk:

- light: documents/mechanical/frozen low-risk work;
- ordinary: bounded business/domain logic or coherent multi-file changes;
- high: public contracts, persistence/schema/migrations, CAS/concurrency,
  security/privacy/authorization or meaningful data-loss risk.

Map these task descriptions to the actual supported reasoning settings.
Use deterministic CI/local checks when sufficient; use an independent Verifier
only when shared risk triggers apply.

## Independence

Independent review requires a separate review context/pass over the frozen
target, not a different model family. The reviewer reads the target itself.
User model choices do not change product contracts, role restrictions or Git
authority.
