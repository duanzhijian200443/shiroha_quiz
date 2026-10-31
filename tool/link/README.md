# Independent Shiroha Link candidate

This package contains the standalone Dart AOT Link, the real MCP SDK frontend,
the local control program, and the original .NET Android adapter. It contains
no Windows Shiroha App, Flutter engine, database, pairing record or credentials.
Windows client/Bridge binaries are an explicitly optional build output. The
current source is a candidate: its bounded normal-client/phone observations are
listed below; complete installation, native lifecycle and handoff acceptance
remain required and are not implied by a build.

The governing contracts are [MCP §19](../../docs/product/agent-refactor/mcp-vnext-contract.md#unified-access-successor),
[local access §§4–7](../../docs/product/agent-refactor/unified-access-and-content-exchange-v1.md#s04)
and the [Android focused contract](../../docs/product/agent-refactor/android-device-access-v0.md).

## Build and install

`build_runtime.ps1` takes explicit `DartExecutable`, `CmakeExecutable` and a
NEW `OutputDirectory`. It compiles the AOT entries and native peer libraries,
then publishes the existing .NET adapter using the cached 10.0.7 runtime pack.
Restore is offline; missing packs fail rather than silently downloading or
changing dependencies. `-IncludeWindowsClient` additionally builds the original
App-owned Windows bridge/client. Android-only builds never build or search for
`shiroha_quiz.exe` or `pubspec.yaml`.

`configure_installation.ps1` takes the explicit runtime, a new private state
directory, an existing paired slot directory and its opaque `SlotRef`. An
optional `WindowsClientExecutable` must name the client beside its Windows App.
The script restricts directory ACLs to the current user and SYSTEM, creates one
connector instance, and writes the installation's adjacent non-secret
`link-installation.json`. Its exact fields are version=1, stateDirectory,
slotDirectory, slotRef, connectorInstanceId, adapterExecutable and nullable
windowsClientExecutable. Configuration is trusted local installer input; no
MCP argument or local protocol message can supply these paths.

Keep mutable state outside the runtime version directory and plugin cache.
Existing state/configuration is never overwritten by the initializer. A version
update must first settle the original lease, preserve the same external state
and connector identity, then deliberately map the new runtime directory. Keep
the prior directory while any original owner uses it. No startup download,
automatic replacement, pairing reset or grant update occurs.

The optional Windows package keeps `shiroha_quiz.exe`, its normal dependencies,
`shiroha_codex.exe`, `shiroha_bridge.exe` and the original relay/native libraries
adjacent. Build that target App with `SHIROHA_UNIFIED_LINK=true`; ordinary builds
keep Profile 2. The original App/Explorer provenance and fixed pipe-peer checks
remain mandatory. Do not rename a different process or spoof its parent.

## Existing candidate-host migration

A known/uncertain old hosted slot requires the old App's explicit local handoff;
missing state or a missing fence is not proof of a new slot. Do not manually
write a RELEASED/CLAIMED JSON file. The supported migration set must use the
updated adapter, whose legacy credential/key acquisitions check the persistent
slot fence. Old unfenced binaries/registrations must be disabled and excluded
before migration; mere adapter.lock availability does not establish this.

The migration-capable Windows App reads its OWN database through
`LegacyLinkHandoffRepository`. Its local “将旧手机连接交给 Shiroha Link” action
joins original owners and requires an exact clean legacy selection. It uses the
original protected pairing record through the App-parent-verified adapter to
obtain the device/installation/Profile binding. It then writes PREPARED, commits
the exact release/tombstone transaction, and only then publishes RELEASED.
The v1 legacy selection has no separate row-revision field: its generation plus
the exact raw-state SHA-256 is the CAS identity; no historical process identity
or cleanup evidence is invented. The original database's durable local owner
identifies that old App instance. Dirty, absent, changed or incompatible records
refuse migration and must be resolved by their original owner.

On the separately launched Link, `shiroha_link_control claim` persists
CLAIM_PENDING before exclusively consuming RELEASED. Both the shared CLAIMED
record and the final local record must agree. Repeating a completed claim is an
idempotent check, not another ownership transfer. Partial writes remain fenced.
This one-time old-App operation is distinct from subsequent Android daily use,
which opens neither the Windows App nor its database.

The current installer accepts an existing paired slot only. A new, never-hosted
Android-only installation still needs positive provisioning ownership; the
current candidate does not yet implement that path. An absent legacy record
must not be worked around by creating a fake RELEASED record, resetting pairing
or launching Windows solely to fabricate a prior owner. This is an open product
acceptance requirement, in addition to the real lifecycle/client checks below.

## Daily operation

Start `shiroha_link.exe` explicitly from the real desktop File Explorer as an
ordinary user process. The native role verifies that exact desktop shell parent,
its creation time, fixed image, user and session. Any-Job membership cannot
identify a Codex-owned Job: the real shell may itself belong to a system Job.
This provenance check still needs real client-termination qualification; it is
neither arbitrary-Job attestation nor permission to spoof a parent. The Link
business and control pipes have separate endpoints and fixed adjacent peers.

1. Use `shiroha_link_control inspect` to inspect safe state/revisions.
2. Use `select <registered-target> <selection-revision>` only after original
   settlement. Windows is selectable only when its client is configured.
3. On the phone, explicitly enable access and wait for PREPARING. Run
   `shiroha_link_control connect`; Link joins the original enable-proof helper.
4. In a normal Codex configuration, register `shiroha` with `command` equal to
   the exact installed `shiroha.exe`, with no device/path arguments. The SDK
   exposes the existing eleven-tool Profile 3 even while Link is unavailable.
   Tool discovery creates no target connection, grant or credential acquisition.
5. Use fresh contexts. Unknown generated results are queried only on the original
   device/Profile/submissionKey; neither Link nor the frontend stores or replays
   requests. No new generation is needed merely to verify this transport.
6. `disconnect`/`shutdown` withdraw new work and join original work/output,
   target close, TLS, keys, child exit and streams before clearing the exact
   dirty revision. Busy sessions are never preempted.

`prepared` in diagnostics means the local connection action completed; `ready`
requires the current authenticated business lease. Idle adapter loss withdraws
ready immediately. `businessResult=returned` only records an App response; it
does not infer that STAGED committed. Delivery acknowledges the frontend's
actual MCP output write, not a user's observation. Settlement is independent.

The local control client also acknowledges its exact run/ticket after reading
and printing the management result, then waits for server disconnect. The
server never drops an unread reply merely because the kernel accepted a write.
Lost delivery is resolved by inspecting current state/revision, not blindly
repeating a management mutation. Diagnostic messages contain only fixed phase
names and closed native stage numbers, with no path or credential/body content.

## Recovery and diagnostics

Normal startup never creates missing state or clears dirty state. The owner lock,
32 KiB strict field-whitelisted state, expected revision and atomic same-directory
publication protect ordinary concurrent/colliding operations. A retained pending
file or malformed state fails closed. These controls do not claim containment
of an arbitrary malicious process running as the same Windows user.

`recover <state-revision>` is an explicit local action. It requires the original
run/resource-bound adapter settlement receipt, matching claimed target/owner,
the original process identity to be gone, and the slot lock with no retained
key marker. Missing key/PID alone is insufficient. It does not delete markers,
enumerate/delete CNG objects, change pairing, or replay business input. A missing
receipt, partial receipt or unresolved key keeps recovery required. Windows
resources continue to belong to the original App, not to this Android receipt.

MCP EOF is distinct from a real cancellation notification. Link remains the sole
output consumer until original work finishes, and does not keep undelivered
bodies for a future client. Repeated shutdown preserves the first failure.
The control plane admits one bounded request per authenticated connection and
at most ten actions per second; business has one slot and no request queue.
Control frames are at most 16 KiB; Link business envelopes at most 6,324,224 bytes
before allocation/JSON decode. Original business/Submission/output limits remain.

Native/normal-client acceptance must separately cover independent survival,
abnormal frontend loss, Link crash, source/selection invalidation, every handoff
write interruption, phone withdrawal/lock/expiry and unaffected local study.
The deterministic tests and standalone builds do not close those gates.

## Bounded observation and current limits

The candidate has real migrated-slot Codex READ and eleven-tool discovery, a
busy second model session without takeover, normal client exit, and abnormal
client exit after completed READ with original adapter settlement. Windows App
was absent during those calls. The retained slot's old-App release and Link
CLAIMED records matched. See [MCP §19.5.1](../../docs/product/agent-refactor/mcp-vnext-contract.md#1951-bounded-local-candidate-observations).

A later Link crash preserved the original active/dirty snapshot. Its available
receipt was from an earlier enable-proof, not the current business owner;
recovery refused without changing the snapshot. The exact failure order is
not established, and a later phone observation was outside the App foreground.
Do not clear this state or call that result clean recovery. The package remains
incomplete: new/ambiguous initial ownership, complete native recovery/handoff,
Windows target and remaining device lifecycle/switch/local-study gates are open.

On the phone the actual control is **允许 Codex 访问**. If Wi-Fi/LAN eligibility
is absent, identity may not load and the existing panel can show **首次连接电脑**.
Reconnect the original LAN and reopen the panel before interpreting pairing;
never re-pair merely to remove that display. Finite access must be explicitly
enabled for each proof exercise, never renewed automatically by the runtime.
