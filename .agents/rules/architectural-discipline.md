---
activation: Always On
---

# Architectural Discipline

When modifying core code paths, inspect the upstream data flow, business logic, rendering path, and persistence boundary before editing.

Prefer root-cause fixes over terminal patching. Do not add rendering-edge cleanup when a data contract, schema, sanitizer, parser, or prompt constraint should own the invariant.

Keep business logic out of UI widgets. Preserve single responsibility, high cohesion, and low coupling.

If a requested approach introduces clear architectural debt, explain the risk and propose the safer design before implementing.

Keep cleanup scoped to the causal chain of the task. Do not expand the diff into unrelated refactors.
