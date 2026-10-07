# External Agent Capability Boundary

Status: **FROZEN target contract; not implemented by AR-R0.**

Authority/activation: [index](README.md). This owns client-neutral external
identity, grants, context, egress and local Application Host. MCP wire schemas
belong to [MCP](mcp-vnext-contract.md); Proposal business lifecycle belongs to
[GeneratedQuestion](generated-question-proposals.md).

## 1. Trust and process boundary

```text
External Agent -> protocol adapter / stdio bridge
               -> authenticated local IPC -> App LocalCapabilityHost
               -> Application CapabilityExecutor -> business services
Built-in Agent ---------------------------> Application directly
```

App is the sole business writer. Bridge never opens SQLite, holds repositories,
executes migrations or starts an alternate writer when App is absent. Composition
roots wire implementations; adapters do not bypass Application ports.

Any authorized client can use this boundary. No brand-specific Proposal/origin
types or business `if client == ...` branches. A different protocol may add an
adapter without changing Question or Proposal Domain. Local compiled modules
are trusted source; external requests and metadata remain untrusted.

## 2. Profile, principal and grants

ExternalClientProfile has App-generated identity, display name, adapter/protocol,
explicit permissions, allowed Learning Spaces/banks/files, category/recipient
egress policy, grant revision, createdAt and revokedAt. Credential material is
separate from durable non-secret metadata; not in SQLite, backups, manifest,
CLI arguments, Proposal, query DTO or log.

Shiroha UI owns pairing and scope/egress approval. One-time pairing information
is not a reusable credential. Credential validation establishes principal;
`clientInfo`, brand/model names and claimed external conversation/session ids
are display metadata, never identity or permission. Missing/corrupt credential
access fails closed; never consult a plaintext fallback.

Host publishes an external capability allowlist limited to READ + STAGE.
Internal local-user approval commands are not Host routes even if registered
elsewhere. No autonomous external COMMIT or DESTRUCTIVE. Client tool approval
and chat agreement do not authorize Shiroha formal writes.

ExternalProposalOrigin records clientProfileId, optional externalRequestId,
submissionKey, adapterProtocol and trusted target/scope/authorization snapshot.
Origin is historical fact, not a live authorization credential. Local owner and
all internal identities are App-generated. External request ids are untrusted,
bounded input and never used as diagnostic identity.

Scope admission precedes content lookup; unauthorized/nonexistent targets share
safe non-enumerating errors. Aggregates operate inside authorized scope, not
global query followed by filtering. Revalidate current grants on every call and
egress release. Recipient is the authenticated external principal unless a
stronger verified recipient contract exists; a model name supplied by the client
does not establish its actual downstream recipient.

UI must explain which content will leave Shiroha to the external client. App
cannot revoke already released data or promise control over client retention.

## 3. Opaque context handle

open_generation_context mints a transient opaque handle binding principal,
grant revision, READ/STAGE permission, one authorized target bank/scope,
approved file snapshot, category/recipient egress, source/target generations,
App runtime generation and expiration. Client chooses safe references minted
by App, not trusted raw database identities, permissions or authority fields.

Handle is not persisted and not MCP-session-scoped. Copying it to a different
principal fails. Restart, revoke, restore and expiry invalidate it. Scope/source
changes yield a fixed stale failure; never silently expand files or substitute
targets. Relevant bindings are revalidated at invocation and stage/egress gates.

TTL must be finite and bounded. **15 minutes is an implementation candidate,
not a frozen product constant.** AR-R6A must choose/document the default and
upper bound after measuring realistic read/generate/stage duration; safety does
not depend on TTL replacing per-call authorization.

Expired clients may open a new context after current authorization. A new handle
does not renew old authority or silently accept old source generations. It does
not change a submission key or create a second Proposal. Already staged data
does not expire with its handle; outcome query uses current principal and
Proposal authorization, not a live generation handle.

## 4. Stage reconciliation, cancellation and revoke

Use [typed execution receipts](application-capabilities.md). A timeout or lost
connection after handler entry is not evidence of zero effect. STAGE's durable
reconciliation key survives request ids and handle replacement. Query receipt
before restaging an uncertain request; if context is stale, reconcile first and
open a newly validated context only for a new stage attempt.

Before transaction start, cancellation can stop with known zero effect. Past
durable stage commit, cancellation cannot remove the Proposal or report that
stage was undone. Unknown bridge outcome is reconciled by submission key.
Revoke blocks new invocations and unreleased egress; stage transactions validate
current grants before their publish point. An already committed stage remains
local Review data after revoke. Local user's current approval authority decides
future formal commit, not the revoked external grant.

App unavailable/not ready/recovering returns safe unavailable/busy; it does not
trigger alternate database access. Host starts only after B0 recovery, database
validation and complete module/route validation.

## 5. Local IPC decision checkpoint

Architecture freezes authenticated local-only transport, protected endpoint
discovery, App/bridge peer validation, bounded framing/payload/concurrency,
deadline/cancellation, versioning, reconciliation, restart/revoke behavior and
safe logs. It does **not** select TCP, named pipe, AF_UNIX or localhost HTTP.

AR-R6A is NEEDS IMPLEMENTATION-SPIKE. First screen candidates against Dart/AOT,
supported Windows environments and packaging. Record why any candidate fails;
implement minimal comparable proof only for viable candidates. Evaluate ACL /
user isolation, authenticated endpoint discovery and impersonation, cancellation,
orphan cleanup, restart/races, multi-client calls and bridge launch. Loopback is
not authentication; named-pipe ACL alone is not all application authorization.

Choose the least complex candidate passing every hard property. Spike must be
allowed to overturn preferences or reject all candidates. If none passes, keep
Host unpublished; no unauthenticated fallback. HTTP is not preferred without a
specific benefit. No shell, generic arbitrary RPC dispatch or remote listener.
Wire envelope belongs to infrastructure; Application remains typed/protocol-free.

## 6. Persistence, backup and acceptance

Profile/grant non-secret metadata needs additive storage in AR-R6A; numbering,
constraints and compatibility validators are frozen with that implementation.
No existing schema is changed at AR-R0. Credentials use a dedicated secure seam,
not the Provider credential namespace.

Portable B0 snapshot scrubs active external profiles/grants, excludes credentials
and has no handles/sessions. Restore keeps historical Proposal origin as a soft
profile reference, invalidates running contexts and requires fresh pairing.
Restore never reads/writes secure credentials or reactivates a restored grant.
Rollback baselines retain original live metadata under existing B0 authority.

Tests require principal isolation, forged clientInfo, direct-call rejection,
handle copy/expiry/reopen, stale scope/source, non-enumeration, egress revoke,
stage response loss/restart and restore-no-reauthorization. Windows proof covers
chosen transport ACL/auth, process/endpoint races, cancellation/orphans, Unicode
and spaced paths, multiple clients and clean bridge launch. Linux proof alone
does not establish Windows safety. Disable Host/routes while retaining data
compatibility; do not delete Proposal state to roll back an external feature.
