---
activation: Always On
---

# Architectural Discipline

## Evidence before escalation

Understand the relevant data flow, dependency direction, and lifecycle before editing, but do not assume the bug belongs to an upstream layer merely because it appears in UI or orchestration code.

Verify the actual failure boundary first. Fix the earliest responsibility boundary that can reliably prevent the invalid state. Escalate upstream only when repository evidence proves that a downstream fix would merely hide an upstream contract violation.

## Root-cause discipline

Prefer root-cause fixes over symptom masking, but keep the fix proportional to the verified defect. Do not widen a bounded bug into a framework, migration, or architecture rewrite unless the current contract requires it.

## Architecture boundaries

Preserve the repository dependency direction and SOLID/high-cohesion principles defined by `AGENTS.md` and `ARCHITECTURE.md`. Business logic belongs outside widgets; persistence belongs behind repositories; public contracts and persisted formats require explicit authorization to change.

## Smallest defensible solution

Choose the smallest coherent, testable, maintainable solution that satisfies the frozen behavior. Do not expand scope for "enterprise-grade", generalized, future-proof, or speculative requirements.

If a proposed change would violate a frozen architecture, persistence, security, privacy, or public-contract invariant, reject that change and explain the concrete consequence. Offer the smallest compliant alternative rather than forcing a broader redesign.

## Child-agent routing

Before recommending, creating, or packaging child agents, read and follow:

```text
docs/agents/model-routing.md
```

Route by the uncertainty and blast radius of the child task, not by role name or the maximum risk of the parent stage. Use exact repository-relative paths in delegated packages.
