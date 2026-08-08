# ADR-001: Post-R8 Layering and Adapter Boundary

Status: **Accepted**

## Context

R1–R8 introduced a real `domain`/`application` typed core, but the root architecture document still described the older `UI -> Service -> Repository -> DatabaseHelper` rule and explicitly allowed UI to call repositories. Upcoming File Library, Project, Agent and MCP work would amplify that dependency if the boundary stayed unchanged.

A repository-wide cleanup is neither necessary nor desirable: some existing screens legitimately still call repositories and are already covered by production tests.

## Decision

The canonical direction for new post-P5 work is:

```text
Flutter UI / Built-in Agent / MCP Adapter
                  -> Application
                  -> Domain

Data / Infrastructure -> Application ports / Domain
```

An explicit composition root may know concrete repositories/databases/providers to assemble dependencies.

New post-P5 presentation features must not introduce new direct repository dependencies. Existing direct UI-to-repository dependencies are migration debt, not an automatic refactor target. They should be moved behind an application service when a new cross-surface capability needs the same behavior.

Application semantics are the reuse boundary. UI, Agent and MCP adapters convert interaction/protocol data into application calls and receive safe application DTOs.

## Consequences

Positive:

- one business capability can be reused across Flutter UI, built-in Agent and MCP;
- future protocol/provider changes do not redefine business semantics;
- persistence and provider details remain outside presentation code;
- N0 does not reopen R1–R8.

Costs:

- some existing UI-to-repository calls remain temporarily inconsistent with the target direction;
- new application services/facades may be introduced gradually as shared use cases appear.

## Rejected alternatives

### Keep `UI -> Service/Repository` as the permanent rule

Rejected because Agent and MCP would either duplicate semantics or call repositories directly.

### Refactor every existing screen immediately

Rejected because it creates a new large-scale architecture migration without product value and contradicts the closed R1–R8 boundary.
