# W0 Safe Agent Write

Status: **Canonical W0 product/application contract. W0 is CURRENT and is not
yet COMPLETE.**

## 1. Authority and bounded first capability

This document is the focused authority for W0 Safe Agent Write. Repository-wide
dependency and permission boundaries remain authoritative in `ARCHITECTURE.md`
and `docs/architecture/adr-003-agent-mcp-and-write-boundary.md`.

W0 v0 adds one Built-in Agent capability: propose filling a missing answer on
an existing typed question. The formal mutation is bounded to:

```text
current typed answer = null
proposed typed answer = structurally non-empty
```

W0 v0 does not let the Agent replace or clear an existing answer, edit another
question field, create a question, delete data, or perform a batch mutation.
It does not add a mutation tool to MCP v0.

## 2. Permission and data flow

The W0 flow is:

```text
Built-in Agent
  -> request DRAFT/STAGE proposal
  -> scope/target admission
  -> transient exact proposal + preview

User
  -> explicit Presentation approval bound to that proposal

Application command
  -> one dedicated data-layer transaction
  -> typed answer persistence authority
```

The Agent may request a proposal but cannot approve or commit it. Presentation,
the Agent adapter, and MCP never execute SQL or access `DatabaseHelper`.

## 3. Shared typed-answer authority and Agent policy

The shared typed-answer persistence authority continues to support the existing
manual-repair semantics:

- missing answer to non-null answer;
- replacement of an existing answer;
- clearing an existing answer;
- valid semantic no-op preservation.

That shared authority owns strict typed-sidecar decode, full-`QuestionDraftV2`
structural compare-and-set, answer/option validation, privacy admission, the
typed persistence mapper, atomic sidecar and V1 `standard_answer` projection
updates, and transaction rollback. It never mutates review/FSRS state, and a
corrupt or unsafe sidecar never falls back to V1 content.

W0's fill-only restriction is an Agent proposal/command policy over that shared
authority, not a restriction on manual repair. The dedicated W0 persistence
boundary must defensively recheck that the expected answer is null and the
proposed answer is non-null and structurally non-empty.

## 4. Staging admission and non-enumeration

Proposal staging MUST perform scope/target admission before loading or
returning preview-visible target content.

For Learning Space scope, staging must confirm the current Project and
`project_banks` relation before producing a proposal. This staging check is
non-authoritative for COMMIT and MUST be repeated inside the dedicated commit
transaction.

Unauthorized and nonexistent targets must use a safe non-enumerating failure
boundary. The proposal tool must not reveal out-of-scope target content or
existence through preview or error details.

Consequently:

- staging must not load a target through an unrestricted question-detail path
  and then apply scope checks afterward;
- Global scope may admit any otherwise eligible typed question available to
  the local user;
- Learning Space scope may admit only a question whose current `bank_name`
  belongs to the current Project through the current `project_banks` relation;
- the name-based relation is the current compatibility authority, not a
  permanent stable bank identity;
- preview-visible stem, options, answer state, bank name, or other target
  content is returned only after admission succeeds;
- unauthorized and nonexistent targets return the same bounded failure shape,
  without target identity or content;
- an admitted but corrupt/unsafe typed target may return a distinct bounded
  data-unavailable failure, but never its payload or content.

Staging admission protects preview confidentiality and user comprehension. It
does not reserve the target or grant COMMIT authority.

## 5. Proposal identity, payload, and preview

Every proposal has an opaque, unique, immutable identity. Its generation
scheme is an implementation detail and is not a product contract.

The exact proposal binds:

- the source Conversation and source User Message;
- the source scope kind and, when applicable, current Project identity;
- the target storage identity and typed draft identity;
- the target's admitted current `bank_name`;
- the complete expected typed draft;
- the proposed typed answer;
- the fill-missing-answer operation.

A proposed choice answer must refer only to current target option identities. A
proposed content answer may contain only supported structural content and must
not use raw fallback or an empty/whitespace-only payload.

The human-readable preview is derived by Application code from the admitted
target snapshot and proposed typed answer. It must show enough target context,
the empty-before and proposed-after answer, and that no other question field or
review state will change. LLM-authored prose is never the authoritative preview.

Proposal creation time may support ordering or display but has no approval,
authorization, or compare-and-set meaning.

## 6. Deterministic proposal fingerprint and one-active rule

Replay identity is a deterministic semantic fingerprint over:

```text
source Conversation identity
+ source User Message identity
+ operation semantics
+ source scope / Project identity
+ target storage identity
+ admitted bank_name
+ canonical expected typed draft
+ canonical proposed typed answer
```

Proposal identity, creation time, preview text/layout, provider call identity,
and internal lifecycle representation are not fingerprint inputs.

The rules are:

- the same semantic fingerprint reuses the existing proposal identity and its
  current outcome;
- a different payload produces a new proposal identity and supersedes the old
  active/pending proposal for that source User turn;
- each source User turn has at most one active/pending write proposal;
- committed or explicitly rejected proposals are not automatically reactivated
  by provider replay;
- proposals from different source turns may coexist, including proposals that
  initially target the same question;
- the first successful target mutation makes incompatible proposals stale at
  commit-time compare-and-set.

Canonical structural equality, not a digest alone, determines fingerprint
equality. The digest algorithm, encoding helpers, cache structure, and internal
state names remain implementation details.

## 7. Explicit approval

Only an explicit Presentation action bound to the exact proposal identity is
approval. The UI submits the proposal identity, not a reconstructed or editable
payload.

The following never constitute approval:

- the LLM stating that the user agreed;
- ordinary chat text such as "OK", "yes", or equivalent wording;
- an Agent/provider retry;
- a staged proposal or successful preview;
- closing or dismissing an approval surface.

### Passive dismissal and explicit rejection

Passive Presentation dismissal does not mutate proposal state. Closing the
proposal card, navigating away, switching Conversations, dismissing a dialog or
sheet, or otherwise hiding the approval surface:

- does not approve;
- does not reject;
- does not supersede;
- keeps the proposal in its existing active/pending state.

When the user returns to the source Conversation, its current active/pending
proposal may be presented again. Only an explicit Reject action bound to the
exact proposal identity transitions that proposal to the terminal rejected
outcome. A rejected proposal cannot later be approved or reactivated by
Agent/provider/tool replay.

The Agent catalog exposes no approve or commit operation. A revised proposal
uses a new identity and invalidates the older active proposal. While the source
Agent turn is still active, a preview may be visible but approval remains
disabled.

## 8. Atomic COMMIT boundary

After explicit approval, Application invokes one dedicated data-layer
persistence operation. Application must not chain independent Conversation,
Project, and Question repository calls and describe the sequence as atomic.

One SQLite transaction must revalidate and apply all of the following:

1. the source Conversation still exists;
2. the source User Message still exists, belongs to that Conversation, and has
   the User role;
3. the current Conversation scope matches the proposal scope;
4. a Learning Space scope still references the expected current Project;
5. the current `project_banks(project_id, bank_name)` relation authorizes the
   target bank for a Learning Space proposal;
6. the target question still exists and has the expected current `bank_name`;
7. the typed sidecar is complete, safe, and decodable;
8. the current complete typed draft structurally equals the proposal baseline;
9. the current answer is still null;
10. the proposed answer is non-null, structurally non-empty, and valid for the
    current question kind/options;
11. the typed sidecar and V1 answer projection each update exactly once;
12. review/FSRS state remains unchanged.

Global scope omits only the Project/relation requirement; all source, scope,
target, compare-and-set, and write checks still apply.

This contract does not assign the operation to any existing repository class.
It may use a focused data adapter that reuses the shared transaction-scoped
typed-answer persistence authority. Any failed precondition or write rolls back
the complete transaction.

## 9. Concurrency, retry, and lifecycle

- Concurrent approval of one proposal shares one in-flight operation and must
  not issue duplicate formal writes.
- Reapproval of a committed proposal reports the existing committed outcome.
- COMMIT entry and explicit Reject on the same active/pending proposal share
  one atomic lifecycle gate: the single linearization point for that proposal.
  Exactly one transition wins, either `pending -> committing` (approval wins)
  or `pending -> rejected` (reject wins); the losing attempt does not start or
  cancel a formal write and observes/reports the winner's outcome.
- Once `pending -> committing` has won, a later explicit Reject must not
  transition the proposal to rejected; it reports the existing committing or
  final committed outcome and must not cancel or interfere with the
  authoritative COMMIT that has already entered the formal write.
- Once `pending -> rejected` has won, a later Approve must not start COMMIT; it
  reports the existing rejected outcome and performs zero formal writes.
- An approval attempt on a terminal rejected proposal reports the existing
  rejected outcome and performs no write.
- Concurrent proposals for one target rely on the transaction-level structural
  compare-and-set; at most one incompatible mutation succeeds.
- Target edits, target deletion, bank changes, relation detachment, Project
  deletion, and Conversation/Message deletion invalidate COMMIT with zero
  partial writes.
- If the UI stops waiting while COMMIT continues, retry observes the same
  in-flight or terminal proposal outcome rather than starting another write.
- An ambiguous persistence outcome is reconciled through a permission-aware
  target read: exact post-image means committed, exact baseline permits an
  explicit retry, any other state is stale, and an unconfirmable outcome must
  not be retried automatically.
- Conversation switching does not itself approve, reject, or commit a proposal.
- Proposals are transient and disappear on process restart. SQLite still
  guarantees all-or-nothing formal persistence. If an earlier COMMIT succeeded,
  a later fill-only staging attempt sees a non-null answer and is ineligible.

## 10. Agent and MCP boundary

W0 may add one separate Built-in Agent DRAFT/STAGE proposal capability. It does
not alter the exactly-six A0 read-tool catalog and does not add a seventh tool
to MCP v0.

The Built-in Agent remains a peer of MCP over Application semantics and does
not call the app's MCP transport. Runtime supplies trusted source Conversation
and User Message identity; the model cannot choose or override that authority.

The runtime/system policy must state that the Agent may read and stage the
bounded proposal, but cannot approve, commit, replace, clear, delete, or claim
that formal persistence occurred.

## 11. Persistence and non-goals

W0 v0 keeps database schema v19 and adds no proposal table, revision column,
idempotency ledger, bank registry, dependency, or persisted proposal format.

W0 v0 does not include:

- destructive or batch writes;
- replacement or clearing by the Agent;
- question creation or other question-field edits;
- MCP v0 expansion;
- durable or cross-restart proposals;
- stable bank identity or bank rename;
- F1, P6, P7, RAG, File-content reading, or parsing changes;
- a generic multi-Agent or generic mutation framework;
- broad Presentation redesign or repository-wide architecture cleanup.

## 12. Stage and closure status

W0 remains CURRENT until implementation, focused independent verification, and
semantic review close all required acceptance without unresolved P0/P1/P2
findings. A final **W0-CL canonical closure checkpoint** then marks this
document and the roadmap COMPLETE. W0-CL must not rewrite this contract to
excuse an implementation deviation; a material deviation reopens contract
approval.
