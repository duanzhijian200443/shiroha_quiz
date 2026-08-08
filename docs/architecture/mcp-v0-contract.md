# MCP v0 Read-Only Application Contract

| Field | Value |
|---|---|
| Status | Frozen contract (P0 semantics + M0 stdio server) |
| Implementation status | M0 local-stdio server implemented |
| Transport status | Local stdio only (frozen) |
| Protocol SDK dependency | `mcp_dart` 2.4.0 exact |

This document freezes the **MCP v0 read-only application-layer tool
semantics** for Shiroha Quiz. P0 froze the application-layer tool semantics;
M0 implements the local-stdio server exactly as written. M0 adds exactly one
dependency (`mcp_dart` 2.4.0), binds the SDK only inside `lib/mcp/**`, and
makes protocol behavior the authority for acceptance. v0 still has no Agent,
no database wiring beyond T0 reads, no authentication, and no write tools.
Nothing here changes the R6 migration plan, the R4 `ReviewSession` contract,
or the R5 renderer.

## 1. Scope

v0 freezes application tool semantics only:

- the six read-only tools and their inputs/outputs;
- response envelopes, cursors, and limits;
- error codes and their mappings;
- privacy and permission boundaries;
- V1/V2 read semantics at the public DTO boundary;
- the layering that any future MCP implementation must obey.

P0 froze application tool semantics only; transport, SDK binding, and server
lifecycle are frozen by the M0 contract in section 12. Still out of scope:
Agent integration, authentication, write/mutation tools, database schema,
migration execution, and any Dart public API promise beyond the M0 server
entrypoints.

## 2. Layering

```text
External MCP Client
  -> MCP Transport Adapter
  -> Application Query Services
  -> Repositories
  -> SQLite
```

The MCP Transport Adapter is the only MCP-facing layer. It converts protocol
arguments into application DTOs and converts application results back into
protocol responses.

### Forbidden boundary crossings

- Adapter -> `DatabaseHelper`: the Adapter must never hold or call
  `DatabaseHelper`.
- Tool -> raw SQL: no tool or Adapter executes SQL.
- Tool -> SQLite file: no tool opens, reads, downloads, or replaces the
  SQLite file.
- Raw Repository Map passthrough: no tool returns repository maps or DB rows
  directly.

### Responsibility split

| Layer | Owns |
|---|---|
| MCP Transport Adapter | Protocol argument parsing; validation limited to protocol shape, types, and basic input bounds; protocol-argument/application-DTO conversion |
| Application Query Service | Business semantics, business validation, permissions, output projection |
| Repository | V1/V2 reads from persistence |
| SQLite | Physical storage; its shape is **not** a public contract |

Flutter UI, the built-in Agent, and MCP are separate adapters over the same
application services. No adapter may bypass a service to reach persistence.

## 3. Tool surface

Exactly six `READ_ONLY` tools are frozen for v0. No other tool may be added to
v0, and none of these may mutate state.

### 3.1 `list_question_banks`

Input:

| Field | Constraint |
|---|---|
| `cursor` | Nullable, opaque application cursor |
| `limit` | Default `50`, range `1..100` |

Output item fields:

| Field | Notes |
|---|---|
| `bank_name` | Display name |
| `folder_name` | Folder display name |
| `question_count` | Count |
| `due_count` | Count |
| `mastered_count` | Count |

No internal IDs and no question text are returned.

Example:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "items": [
    {
      "bank_name": "Math 2022",
      "folder_name": "Math",
      "question_count": 22,
      "due_count": 4,
      "mastered_count": 12
    }
  ],
  "next_cursor": null
}
```

### 3.2 `get_study_overview`

Input:

| Field | Constraint |
|---|---|
| `bank_name` | Nullable; `null` means the global overview across banks |
| `timezone` | IANA timezone used for date boundaries |

Output fields:

| Field | Notes |
|---|---|
| `question_count` | Count |
| `mastered_count` | Count |
| `due_count` | Count |
| `today_practice_count` | Count for the timezone's current day |
| `wrong_question_count` | Count |

No raw logs, answer text, or AI evaluation are returned.

Example:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "data": {
    "question_count": 120,
    "mastered_count": 43,
    "due_count": 17,
    "today_practice_count": 6,
    "wrong_question_count": 9
  }
}
```

### 3.3 `get_due_review_summary`

Input:

| Field | Constraint |
|---|---|
| `bank_name` | Nullable |
| `timezone` | Optional IANA timezone; omitted uses the application-configured timezone |
| `from` / `to` | Offset-bearing RFC 3339 timestamps; half-open interval `[from, to)`; window max 90 days |

Output fields:

| Field | Notes |
|---|---|
| `due_now` | Count due at the current instant |
| `scheduled_count` | Count scheduled within the window |
| `buckets` | Date/count buckets within the window |

Instants are converted to the selected timezone (the provided IANA timezone,
or the application-configured timezone when omitted) and bucketed by local
calendar date over the half-open interval `[from, to)`. No per-question state
is returned and no FSRS state is mutated.

Example:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "data": {
    "due_now": 17,
    "scheduled_count": 31,
    "buckets": [
      { "date": "2026-08-05", "count": 17 },
      { "date": "2026-08-06", "count": 8 },
      { "date": "2026-08-07", "count": 6 }
    ]
  }
}
```

### 3.4 `search_questions`

Input:

| Field | Constraint |
|---|---|
| `bank_name` | Trimmed, non-empty |
| `query` | Trimmed, length `1..200` |
| `cursor` | Opaque, nullable |
| `limit` | Range `1..50` |

Search executes through an Application Query Service only; SQL is never
concatenated with user input.

Output item fields:

| Field | Notes |
|---|---|
| `question_id` | Opaque ID; see `get_question_detail` |
| `bank_name` | Bank display name |
| `kind` | Question kind |
| `stem_preview` | Normalized stem preview: consecutive whitespace collapsed to one U+0020 space and trimmed; maximum 160 Unicode grapheme clusters (over limit: first 159 clusters plus `…`); never derived from RawFallback |
| `has_answer` | Boolean |
| `has_explanation` | Boolean |
| `due` | Due state |
| `source_kind` | `typed` or `legacy` |

No full `RawFallback` payload, schema, or SQL is returned.

Example:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "items": [
    {
      "question_id": "q_8f2c",
      "bank_name": "Math 2022",
      "kind": "single_choice",
      "stem_preview": "Solve the equation …",
      "has_answer": true,
      "has_explanation": true,
      "due": true,
      "source_kind": "typed"
    }
  ],
  "next_cursor": "opaque-0001"
}
```

### 3.5 `get_question_detail`

Input:

| Field | Constraint |
|---|---|
| `question_id` | Opaque; never assume all IDs are UUIDs and never infer the source kind from ID format |

V1 may retain old IDs; future R6 typed IDs are canonical UUIDv4. Resolution
must go through the Repository's V1/V2 reads, never through format guessing.

Output:

| Field | Notes |
|---|---|
| Safe rich-content detail | Stem, options |
| `answer` / `explanation` | Nullable, safe rich content |
| `due_state` | Due state |
| `source_kind` | `typed` or `legacy` |

Resolution rules:

- Valid V2 sidecar -> typed DTO.
- Sidecar wholly absent -> legacy-safe DTO.
- Corrupt, unsafe, or unsupported V2 -> fixed `data_corrupt` error with **no**
  V1 fallback.

Never expose: `rawJson`, unknown payloads, paths, provider/OCR data, issues,
DB rows, or exceptions. Every `RawFallbackNode` projects only to
`{"type":"unsupported"}`.

Example:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "data": {
    "question_id": "q_8f2c",
    "bank_name": "Math 2022",
    "kind": "single_choice",
    "stem": [
      { "type": "text", "text": "Solve the equation " },
      { "type": "inline_math", "latex": "x^2-1=0" },
      { "type": "unsupported" }
    ],
    "options": [
      { "label": "A", "content": [{ "type": "text", "text": "1" }] }
    ],
    "answer": [{ "type": "text", "text": "A" }],
    "explanation": null,
    "due_state": { "due": true },
    "source_kind": "typed"
  }
}
```

### 3.6 `get_weak_questions`

Input:

| Field | Constraint |
|---|---|
| `bank_name` | Nullable |
| `cursor` | Opaque, nullable |
| `limit` | Range `1..50`, bounded |

Output item fields:

| Field | Notes |
|---|---|
| `question_id` | Opaque ID |
| `bank_name` | Bank name |
| `stem_preview` | Normalized stem preview: consecutive whitespace collapsed to one U+0020 space and trimmed; maximum 160 Unicode grapheme clusters (over limit: first 159 clusters plus `…`); never derived from RawFallback |
| `lapse_count` | Count |
| `difficulty` | Numeric difficulty |
| `last_lapse_at` | Timestamp |

This is analysis only: no state mutation, no complete logs, no historical
answer text, and no AI evaluation.

Example:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "items": [
    {
      "question_id": "w_3a1b",
      "bank_name": "Math 2022",
      "stem_preview": "Limit of …",
      "lapse_count": 4,
      "difficulty": 6.5,
      "last_lapse_at": "2026-08-01T10:30:00Z"
    }
  ],
  "next_cursor": null
}
```

## 4. Response envelopes and cursors

Single-object responses use exactly:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "data": {}
}
```

Page responses use exactly:

```json
{
  "schema_version": "mcp.study.v0",
  "generated_at": "2026-08-05T00:00:00Z",
  "items": [],
  "next_cursor": null
}
```

Envelope rules:

- success envelopes always include `generated_at`, a UTC RFC 3339 timestamp
  at whole-second precision using `Z` (for example `2026-08-05T14:00:00Z`);
- success and error envelopes are mutually exclusive: a response is either a
  success envelope (`data` or `items`/`next_cursor`) or the exact error
  envelope in section 5, never both.

Cursor rules:

- cursors are opaque application tokens;
- an empty `items` array marks the end of a page sequence;
- no SQL `OFFSET` may back a cursor;
- no cursor or page ordering is guaranteed across app rebuilds or upgrades;
- no global database revision is added;
- `ReviewSession.expected_revision` is **not** a common MCP field and must not
  be exposed in v0 responses.

## 5. Error model

The complete v0 error code set is exactly:

```text
invalid_request, not_found, access_denied, data_corrupt,
temporarily_unavailable, internal_error
```

Mappings:

| Condition | Error code |
|---|---|
| Invalid arguments | `invalid_request` |
| Missing object | `not_found` |
| Forbidden data access | `access_denied` |
| Corrupt / unsupported / privacy-rejected V2 | `data_corrupt` |
| Temporary DB or resource failure | `temporarily_unavailable` |
| Unclassified internal failure | `internal_error` |

Error responses use exactly:

```json
{
  "schema_version": "mcp.study.v0",
  "error": {
    "code": "invalid_request",
    "message": "The request is invalid.",
    "retryable": false
  }
}
```

Every error includes exactly `code`, `message`, and `retryable`. An error
envelope never contains the success fields `data`, `items`, or `next_cursor`
and is mutually exclusive with success envelopes.

Error payloads carry only a fixed safe `code`, `message`, and `retryable`
flag. They never contain: SQL or SQLite text, stack traces, paths, keys,
provider URLs, question content, answers, explanations, raw fallback
payloads, raw exceptions, or schema details. `data_corrupt` never triggers a
V1 fallback.

## 6. Privacy and permissions

Every v0 tool is `READ_ONLY`.

Allowed:

- bank list;
- safe stats;
- due summary;
- search;
- safe question detail;
- weakness summary.

Forbidden:

- `execute_sql` / `run_arbitrary_query`;
- database download, replace, delete, or clear;
- review mutation (`delete`, `clear`, or any state change);
- submitting grades;
- staging or committing drafts;
- automatic commit;
- key/provider/config access;
- raw OCR, raw fallback, or path reads.

Never returned or logged: credentials, provider bodies, Base64 or raw bytes,
local or DB paths, OCR text, private Replay data, full `RawFallback`
payloads, internal exceptions, or unauthorized full answer history.

## 7. V1/V2 read semantics

- R6 persistence is an **additive sidecar**; historical V1 is never
  fabricated as V2.
- The Repository may internally handle `TypedPersistedQuestion` and
  `LegacyPersistedQuestion`, but the public DTO exposes only
  `source_kind: typed | legacy`.
- V2 is the authoritative typed detail. Legacy fallback occurs only when the
  sidecar is wholly absent; corruption never downgrades.
- A legacy-safe DTO may lack provenance, assets, and typed issues.
- `QuestionDraftV2` is never reconstructed from V1 data.
- No promise of field equivalence between V1 and V2 projections is made.

## 8. Dependencies and sequencing

```text
MCP-P0 docs only
  -> R6A0-R6D safe V2 persistence/repository
  -> after R6C/R6D: read-only Application Query Service
  -> then MCP v0 Adapter/Server
  -> only after R7: audit-style write tools may be planned
```

This document does not modify R6-P0.1, its schema, public API, stage order,
privacy taxonomy, or migration, nor R4 `ReviewSession`, nor the R5 renderer.
R6A0 remains the next mainline task.

## 9. Future work (non-binding)

Possible future tools, listed without frozen APIs or parameters:

```text
stage_question_drafts, get_review_session, edit_review_item,
decide_review_item, commit_review_session, discard_review_session
```

These are **not** v0: parameters are not frozen, they cannot be implemented
now, and no exact API is promised. Constraints for any future version:

- all commits happen through `ReviewSession`;
- rejected/deferred items are never directly persisted;
- future R7-controlled `ReviewResult` wiring is required;
- automatic commit is forbidden.

## 10. Application Query Service

The future read-only application layer exposes query services behind the
Adapter. The pseudocode below is illustrative only and is **not** a frozen
Dart public API:

```dart
/// Illustrative only — not a frozen Dart public API.
class QuestionQueryService {
  Future<List<QuestionBankSummary>> listQuestionBanks(
      {OpaqueCursor? cursor, int limit = 50});
  Future<QuestionSearchPage> searchQuestions({
    required String bankName,
    required String query,
    OpaqueCursor? cursor,
    int limit = 50,
  });
  Future<QuestionDetail> getQuestionDetail(String questionId);
}

class StudyQueryService {
  Future<StudyOverview> getStudyOverview({String? bankName, String timezone});
  Future<DueReviewSummary> getDueReviewSummary({
    String? bankName,
    required DateTime from,
    required DateTime to,
  });
  Future<WeakQuestionPage> getWeakQuestions({
    String? bankName,
    OpaqueCursor? cursor,
    int limit = 50,
  });
}
```

## 11. Implementation gates

```text
1  R6C typed read API implemented
2  R6D synthetic persistence acceptance passed
3  safe corrupt-V2 error verified
4  Application Query Service returns typed DTO
5  Adapter does not reference DatabaseHelper
6  Adapter does not import sqflite
7  list/paginated tools have bounded limits; time-aggregation tools have bounded ranges; single-object tools return fixed bounded structures
8  every cursor opaque
9  RawFallback payload invisible
10 no write/destructive tool
```

## 12. M0 transport, SDK, and acceptance contract

M0 freezes the following four contracts. They are authoritative and carry
testable sentinels; the implementation and acceptance must match them exactly.

### 12.1 Transport: local stdio only

- M0 serves only over the process stdin/stdout stdio transport
  (`serveStdio` / `StdioServerTransport`).
- Streamable HTTP, OAuth/Authorization flows, WebSocket, and any remote or
  network server are explicitly forbidden in M0 and are not planned for v0.
- The server lifecycle is: connect to stdio -> initialize handshake ->
  `tools/list` + `tools/call` -> close; close must tear down the transport and
  clear the connection state.

### 12.2 SDK dependency: exact pin

- The dependency is exactly `mcp_dart: 2.4.0` in `pubspec.yaml`.
- No range, caret, comparison, or prerelease (`dev`/`beta`/`rc`) form is
  permitted, and no second MCP or transport package may be added.

### 12.3 SDK layering: `lib/mcp/**` only

- `package:mcp_dart` types and imports appear only under `lib/mcp/**`.
- Application (T0) and all other layers never import or know `mcp_dart`; the
  adapter converts between protocol arguments and T0 DTOs.

### 12.4 Acceptance authority: protocol behavior

Acceptance is judged by observable protocol behavior, not by SDK presence or
internal structure. The M0 suite drives the real mcp_dart protocol
(`McpClient` initialize, `listTools`, `callTool`, close) and asserts:

- exactly six `READ_ONLY` tools with read-only annotations;
- success and error request/response envelopes with the frozen shapes;
- the complete error taxonomy and mapping, including malformed requests;
- the stdio lifecycle (handshake, close, transport teardown);
- typed and legacy projections with corrupt-V2 `data_corrupt`, no fallback;
- no raw-data leakage (raw fallback payloads, SQL, paths, exceptions).

## 13. Non-goals

Explicitly not goals of this contract:

- any transport other than local stdio (Streamable HTTP, SSE, WebSocket,
  OAuth/remote server) in M0/v0;
- an Agent integration or authentication layer;
- write, destructive, or audit-style tools in v0;
- dependencies beyond the exact `mcp_dart: 2.4.0` pin;
- wire new database, schema, or migration changes;
- expose SQL, DB rows, raw fallback, OCR, provider data, or internal errors;
- add a global database revision or expose `ReviewSession` revisions;
- modify R6, R4 `ReviewSession`, or the R5 renderer.
