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
is not a reusable credential. Trusted authentication maps App-registered client
credentials to ExternalPrincipal; PID, executable name and request parameters
cannot establish that identity. `clientInfo`, brand/model names and claimed
external conversation/session ids are display metadata, never identity or
permission. Missing/corrupt credential access fails closed; never consult a
plaintext fallback.

Valid mTLS proves use of the corresponding credential, not that the upstream
program is Codex. Windows P0 accepts the residual risk that another program
under the same user SID may call a paired Bridge and proxy its credential;
same-SID process identity isolation is not promised. An unpaired direct client
must still be rejected. This accepted Bridge-proxy risk is distinct from an
attacker controlling the entire user account or an administrator/kernel
attacker; no containment of those stronger attackers is claimed here. None of
these limitations bypasses current Application authorization, Scope, Egress or
explicit local COMMIT approval.

Every App runtime generation defaults to external business access disabled.
The user must actively enable one selected, paired Profile through trusted
Shiroha UI and choose a finite validity period. Enablement binds only that
Profile and current generation; it adds no Grant, Scope or Egress. Legitimate
reconnections authenticate again and recheck current authorization, but need
no repeated prompt within the same valid enablement period. Disable, expiry,
revoke, restart or Restore invalidates the applicable runtime enablement; old
connections, Contexts and sessions cannot automatically regain business access.
Duration limits, resource counts and concrete UX remain implementation and
validation choices; no numerical runtime-enable limit is frozen here. Section 3
and per-call/final-release authorization remain independently required.

Host publishes an external capability allowlist limited to READ + STAGE.
Internal local-user approval commands are not Host routes even if registered
elsewhere. No autonomous external COMMIT or DESTRUCTIVE. Client tool approval
and chat agreement do not authorize Shiroha formal writes.

ExternalProposalOrigin records clientProfileId, optional externalRequestId,
submissionKey, adapterProtocol and trusted target/scope/authorization snapshot.
Origin is historical fact, not a live authorization credential. Local owner and
all internal identities are App-generated. External request ids are untrusted,
bounded input and never used as diagnostic identity.

P2's persisted historical representation is owned by
[GeneratedQuestion section 10](generated-question-proposals.md#10-p2-external-historical-origin-and-v34-compatibility).
It binds Profile/key/original Target once in the immutable Header, with bounded
adapter/protocol and historical authorization metadata. Decoding grants no
authentication or current Grant/Context. P2 has no external STAGE factory;
the local/synthetic entry remains closed to external contexts/historical keys.

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
Revoke blocks new invocations and unreleased egress. For STAGE, validation of the
current client profile/grant revision and durable Proposal/receipt publication
must share one transaction/CAS publication boundary; a preflight grant check
followed by an independently committing stage is insufficient. If revoke or
grant-revision change wins before publication, STAGE commits zero durable effect
and returns the bounded stale/unauthorized result. If durable stage publication
wins first, later revoke cannot retroactively erase that local Review data.
Local user's current approval authority decides future formal commit, not the
revoked external grant.

App unavailable/not ready/recovering returns safe unavailable/busy; it does not
trigger alternate database access. Host starts only after B0 recovery, database
validation and complete module/route validation.

## 5. Local IPC decision checkpoint

Architecture freezes authenticated local-only transport, protected endpoint
discovery, App/bridge peer validation, bounded framing/payload/concurrency,
deadline/cancellation, versioning, reconciliation, restart/revoke behavior and
safe logs. Windows P0 selects IPv4 Loopback TCP + mTLS as the preferred
implementation and verification candidate, with Named Pipe retained as a
fallback. Its listener may bind only explicit `127.0.0.1`, never `0.0.0.0`, a
LAN address or an IPv6 wildcard. There is no unauthenticated business fallback.

Windows P0 uses **B-class isolation**: other local SIDs may attempt TCP
connections; OS rejection by SID at TCP `connect()` is not promised. Before
protected business handling or READ/STAGE output release, trusted authentication
and current Application ExternalPrincipal/Profile/Grant/Scope/Revision/Context
checks must pass. A client under a different SID with valid credentials and
current authorization may receive business access in this model. Cross-SID
credential secrecy, trust-anchor integrity, tamper-resistant Discovery,
protected runtime objects, resource limits and rejection of unauthorized
business access remain hard requirements. Loopback is not authentication;
mTLS is not equivalent to OS ACL isolation.

TCP/TLS should use Dart standard capabilities. A minimal Windows Native Adapter
is permitted only for demonstrated platform security gaps in necessary key and
certificate generation, secure storage, or creation/checking of protected
Discovery objects. It gains no business authorization authority and cannot
access or bypass formal business database write paths. User-level DPAPI does
not isolate different processes under the same SID; no guarantee keeps TLS
leaf private keys permanently out of process memory. This decision selects no
FFI package or certificate algorithm and authorizes no Native implementation.

Only the pure-memory trust/protocol core is implemented and accepted within its
memory scope. Real TCP/mTLS and Windows protection remain **UNVERIFIED**;
Transport remains **BLOCKED** until actual Windows acceptance is complete.

AR-R6A is NEEDS IMPLEMENTATION-SPIKE. First screen candidates against Dart/AOT,
supported Windows environments and packaging. Record why any candidate fails;
implement minimal comparable proof only for viable candidates and within
section 6's explicit runtime authorization. Evaluate protected-object ACLs,
the chosen isolation model, authenticated endpoint discovery and impersonation,
cancellation, orphan cleanup, restart/races, multi-client calls and bridge launch.
Named-pipe ACL alone is not all application authorization.

AF_UNIX-specific ROOT-ACL OS-connect rejection, Socket-file movement, endpoint
lease and unlink races are not TCP candidate pass conditions. Historical
ROOT-ACL results remain **INCONCLUSIVE**, never rewritten as PASS. TCP must
separately prove mTLS identity, Principal/Grant isolation, protected Discovery,
real resource limits, lifecycle safety, revoke and abnormal recovery; removing
AF_UNIX-only tests does not remove other credential, object or input protections.

Choose the least complex candidate passing every hard property. Spike must be
allowed to overturn the TCP preference, fall back to Named Pipe or reject all
candidates if evidence requires it. If none passes, keep
Host unpublished; no unauthenticated fallback. HTTP is not preferred without a
specific benefit. No shell, generic arbitrary RPC dispatch or remote listener.
Wire envelope belongs to infrastructure; Application remains typed/protocol-free.

## 6. Persistence, backup and acceptance

Profile/grant non-secret metadata uses additive v33 storage accepted in PR #248
below, with its constraints and compatibility validators owned here.
No existing schema is changed at AR-R0. Credentials use a dedicated secure seam,
not the Provider credential namespace.

### Non-secret authorization storage (P1)

The additive v33 schema uses the existing DatabaseHelper migration/open authority:

| Table | Persisted authority and constraints |
|---|---|
| `external_client_profiles` | App-generated UUID v4 identity; display name (1–80 characters), adapter/protocol tokens (1–32), creation/revocation UTC milliseconds and grant revision (0–2147483647). Identity metadata is immutable; updates advance revision by exactly one; revoked Profiles cannot be updated. |
| `external_grants` | One current policy per Profile, explicit READ/STAGE booleans (at least one), revision, update/revocation time. Composite FK binds Profile/revision and cascades the revision update inside the transaction. No COMMIT/DESTRUCTIVE column or generic permission string exists. |
| `external_grant_scopes` | At most 128 distinct named bank/file targets per Grant, each bound to one Learning Space (`project_id`) or the explicit local context (empty stored project id). Target ids are bounded to 256 characters, project ids to 128. Empty rows deny all targets; there is no wildcard or missing-target global fallback. |
| `external_grant_egress` | Whitelisted `questionContent`, `fileContent`, `proposalMetadata`; recipient is the owning Profile, not a client-supplied provider/name. Scope/egress rows have Grant FKs and composite primary keys. |

Application's trusted first-party management entry mints Profile ids and opaque
local references. Profile creation grants no permissions, pairing, authenticated
Principal or runtime enablement. References belong to the current management
composition and cannot be constructed from RPC/JSON ids. Trusted local selection
by id is management only; it is not credential authentication. The existing
memory trust state machine is unchanged and is not durable identity authority.

Grant replacement (including expansion or narrowing), Grant revoke and Profile
revoke use the existing B0 mutation gate and a SQLite transaction with expected
Profile revision CAS. A stale revision cannot overwrite the current winner;
revoke advances revision. Regrant requires an explicit current management action,
and a revoked Profile cannot be reactivated. Current policy queries reload durable
state, compare revision, permission, exact scope, category and recipient, and
recheck target existence and Learning Space membership. Missing/unauthorized
targets share a fixed denial; deleting a target never expands scope. Persisted
bank names retain the existing compatibility identity, not a new incarnation
guarantee. Grant lookup is policy inspection and supplies neither authentication
nor runtime admission, handler execution or output release authority.

Fresh creation, normal open, staged validation and upgrade check exact owned
schema objects, relationships and typed row data; unknown permissions, malformed
metadata, inconsistent revisions and extra owned triggers/indexes fail closed.
Older versions may acquire only exact empty additive objects, never adopt
pre-existing authorization rows. No credential, pairing secret, certificate,
runtime generation, Enablement or Context is persisted in these tables. No Host,
external Origin codec or CapabilityExecutor integration is added by P1.

Portable B0 validates this authority before deleting all four tables' rows in the
snapshot copy, including revoked metadata. Incoming portable packages must have
empty authorization tables; Restore does not silently sanitize active grants.
Raw rollback baselines keep the original local authorization metadata. Existing
Proposal Profile references remain soft and have no FK to these tables. Package
v2 is unchanged. Durable STAGE/revoke publication still requires the owning
service's future shared transaction/CAS boundary; this storage does not close
the process-local journal or restart Receipt findings.

Portable B0 snapshot scrubs active external profiles/grants, excludes credentials
and has no handles/sessions. Restore keeps historical Proposal origin as a soft
profile reference, invalidates running contexts and requires fresh pairing.
Restore never reads/writes secure credentials or reactivates a restored grant.
Rollback baselines retain original live metadata under existing B0 authority.

Tests require principal isolation, forged clientInfo, direct-call rejection,
handle copy/expiry/reopen, stale scope/source, non-enumeration, egress revoke,
stage-vs-revoke/grant-revision races, stage response loss/restart and
restore-no-reauthorization. Windows proof covers
chosen transport authentication/protected-object ACLs under section 5's isolation
model, process/endpoint races, cancellation/orphans, Unicode
and spaced paths, multiple clients and clean bridge launch. Linux proof alone
does not establish Windows safety. Disable Host/routes while retaining data
compatibility; do not delete Proposal state to roll back an external feature.

**HOST_STABILITY_HALT is active for the primary Windows host.** Transport
security acceptance and system stability acceptance must complete separately.
Experiment-associated blue screens, hard hangs or kernel-driver anomalies
immediately trigger HOST_STABILITY_HALT and stop the related dynamic experiments.
The reported AF_UNIX-associated instability on 2026-10-10 is sufficient risk
basis to stop further experiments; it does not prove a complete kernel-failure
causal chain, and acceptance must not require reproducing a blue screen.

Old AF_UNIX ROOT-ACL, endpoint-lease and close/unlink dynamic experiments are
permanently halted on the primary host and must not rerun automatically. Windows
updates, replacement scripts or account changes do not lift this halt. Future
real TCP/mTLS, Windows SID, Discovery and credential-security verification needs
new explicit authorization and should prioritize a separately approved isolated
environment. An ordinary VM on the primary host is not automatically independent
of host-kernel stability risk. If any required security or stability acceptance
is missing, the formal Host remains **unpublished**. This contract amendment
authorizes no dynamic experiment or Host activation and does not unlock AR-R6B.
