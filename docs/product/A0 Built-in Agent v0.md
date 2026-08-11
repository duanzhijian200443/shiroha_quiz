# A0 Built-in Agent v0

Status: **Canonical A0 product/runtime contract. A0 is COMPLETE.**

## 1. Authority and scope

This document records the bounded Built-in Agent behavior delivered by A0.
It describes current product and cross-layer truth, not a promise that current
provider parameters, limits, protocol details, or UI copy will never change.

A0 adds a real Shiroha response turn over the C0 Conversation foundation. It
does not add an Agent write path, retrieval system, file-content reader, or a
generic multi-Agent framework.

The repository-wide dependency and permission boundaries remain authoritative
in `ARCHITECTURE.md` and
`docs/architecture/adr-003-agent-mcp-and-write-boundary.md`.

## 2. Adapter and permission boundary

Built-in Agent and external MCP are peer adapters over shared Application
semantics. The Built-in Agent invokes the Application Agent runtime and local
study-tool dispatcher directly; it does not call the app's MCP transport.

A0 is `READ_ONLY`:

- the Agent does not execute SQL or access SQLite / `DatabaseHelper` directly;
- local study access is limited to the same exactly-six read-tool surface
  frozen by MCP v0;
- no tool may create, edit, delete, stage, approve, or formally persist learning
  data;
- tool and provider results do not override the system permission boundary.

The six local study tools are:

- `list_question_banks`;
- `get_study_overview`;
- `get_due_review_summary`;
- `search_questions`;
- `get_question_detail`;
- `get_weak_questions`.

Sharing these Application semantics does not merge the Built-in Agent and MCP
transports. MCP v0 remains exactly six `READ_ONLY` tools; A0 neither expands
the `mcp.study.v0` contract nor changes its transport/runtime.

## 3. Configuration boundary

Parsing AI configuration and Agent configuration are independent product
contracts. Changing Shiroha Agent tuning must not change exam-parsing model
configuration, and changing parsing configuration must not select or retune the
Agent.

The Agent settings select an existing complete main text-model profile and own
Agent-specific Web and tuning choices. Agent configuration references that
profile; it does not copy provider credentials into the Agent configuration.

A0 currently includes a DeepSeek Responses provider adapter. The concrete
provider/model allowlist, endpoint mapping, tuning defaults and ranges are
current implementation support, not frozen long-term product or architecture
contracts.

## 4. Conversation turn lifecycle

An A0 turn is bound to an already-persisted User Message:

```text
persist User Message
        |
        v
start Agent turn for conversationId + userMessageId
        |
        v
transient text / Web / local-tool progress
        |
        v
persist one final Assistant Message
```

- A new Conversation remains transient until its first valid User Message.
- First persistence still atomically creates the Conversation, sequence-1 User
  Message, and selected Conversation/File relations.
- The Agent turn starts only after the target User Message has been persisted.
- The target must be the latest valid User turn and must not already have a
  later persisted Assistant reply.
- At most one Agent turn may be active for the same Conversation.
- Retrying targets the same persisted User Message and must not append a
  duplicate User Message.
- If a persisted Assistant reply for that target already exists, retry returns
  that reply rather than regenerating or duplicating it.

Text deltas and progress events are transient Presentation state. Partial text
from a cancelled, timed-out, malformed, or otherwise failed turn does not enter
Conversation history. Only the final Assistant Message returned from successful
persistence becomes durable history.

The product invariant is one persisted final Assistant reply for a completed
turn. The in-memory pending-text and ambiguous-append recovery mechanism used
to preserve that invariant is not itself a canonical contract.

## 5. Context, files and Web

Conversation scope is supplied to the Agent. A Conversation whose Learning
Space has become unavailable remains readable history but cannot accept a new
Agent reply.

Conversation File attachments provide metadata only, such as safe display
name, MIME type and size. A0 does not provide file bytes, extracted text, PDF
pages, images, OCR output, or vision input. Shiroha must not claim that an
attached file was read.

Web capability is optional and provider-native. It is used only when the user
has enabled it and the selected provider supports it. A0 does not promise Web
availability for every provider/model and does not introduce an app-managed
search, browsing, retrieval, or RAG subsystem.

## 6. Persistence and transient state

The database remains schema v19. A0 uses the additive Assistant-message seam
provided by C0 and introduces no schema or migration.

Conversation and completed User/Assistant Messages are durable. In-flight turn
state, streamed text, Web/tool progress, provider continuation state, the
runtime system prompt, and generated text awaiting persistence are transient
and are not Conversation Messages. A0 does not resume an in-flight turn after a
process restart.

## 7. Safety and failure behavior

Only bounded, safe failure categories cross the Agent runtime seam. Provider
bodies, API keys, authorization data, stack traces, sensitive paths, raw
internal exceptions, and hidden reasoning must not be exposed to Presentation
or persisted as Conversation history.

Cancellation and runtime/resource bounds prevent an Agent turn from running
indefinitely. Their exact timeout, message, byte, token, tool-round and
local-call values remain adjustable implementation parameters.

## 8. Accepted A0 v0 limitations

A0 intentionally does not implement:

- Agent, MCP, or autonomous writes;
- `DRAFT/STAGE`, `COMMIT`, or destructive permission flows;
- durable turn-state persistence or automatic turn resumption;
- attached-file content, PDF/image reading, OCR or vision supplementation;
- File/Project Agent tools or MCP v0 expansion;
- RAG or another retrieval/indexing subsystem;
- multiple Agent identities or role selectors;
- W0, F1, P6, P7, or their write/candidate workflows.

Provider-native Web and the currently supported provider/model surface are
bounded capabilities, not universal availability promises.

## 9. Non-canonical implementation parameters

The following remain implementation details unless a later authorized contract
explicitly freezes them:

- exact provider/model whitelists and HTTP endpoint construction;
- request/SSE payload and continuation-state representation;
- config codec version, storage keys and serialized field names;
- tuning defaults, ranges and available reasoning values;
- history, byte, token, timeout, tool-round and local-call limits;
- internal concurrency/recovery data structures;
- exact system-prompt wording, failure enum names, UI status text and widget
  layout.

W0 mutation behavior is specified separately in
`docs/product/W0 Safe Agent Write.md`. W0 may add a distinct Built-in
Agent-only DRAFT/STAGE proposal capability while preserving the exactly-six A0
read-tool catalog and the exactly-six MCP v0 contract. This does not
retroactively change the bounded READ_ONLY behavior delivered by A0; approval,
COMMIT and typed-write semantics belong to W0.
