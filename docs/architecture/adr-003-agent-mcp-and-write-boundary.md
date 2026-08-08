# ADR-003: Agent/MCP Peer Adapters and Approval Write Boundary

Status: **Accepted**

## Context

Shiroha needs both an in-app Agent and external access through MCP. Routing the built-in Agent through the app's own MCP server would appear to unify tooling, but would add transport lifecycle, protocol serialization, permission translation and debugging cost to an entirely local call path.

Future AI features also need writes (generated questions, answer repair, exam drafts), but direct autonomous database mutation would bypass the typed review/persistence guarantees established by R1–R8 and P5.

## Decision

Built-in Agent and MCP are peer adapters over shared application semantics:

```text
Built-in Agent
      |
      v
Application Tool / Query / Command Layer
      ^
      |
External MCP Client -> MCP Adapter
```

The built-in Agent does not call MCP transport.

MCP v0 remains exactly the six read-only tools frozen in `mcp-v0-contract.md`. Project/File Library protocol tools require a later MCP contract/version.

Future mutation capability follows a four-level permission model:

```text
READ        -> execute inside granted scope
DRAFT/STAGE -> create/edit proposal only
COMMIT      -> explicit user approval before formal persistence
DESTRUCTIVE -> extra approval or unavailable in early versions
```

Adapters never execute SQL or call `DatabaseHelper`. Formal writes converge on application command services and typed persistence/review semantics.

For answer completion specifically, manual input, supplemental files and AI are candidate sources; they must converge on one typed answer command instead of defining separate write protocols.

## Consequences

Positive:

- UI, Agent and MCP share behavior without sharing transports;
- external protocol changes cannot silently redefine app business rules;
- AI cannot bypass user approval or typed persistence authority;
- P6/P7 become candidate producers rather than new persistence systems.

Costs:

- application tool/query/command contracts must exist before transport/Agent integration;
- write UX must model proposal/approval explicitly.

## Rejected alternatives

### Built-in Agent calls localhost MCP

Rejected because the transport adds no business value inside the same process and introduces avoidable failure modes.

### Agent/MCP call repositories directly

Rejected because it duplicates business validation and leaks persistence semantics.

### AI writes formal data immediately

Rejected because it bypasses approval and creates an unsafe second write authority.
