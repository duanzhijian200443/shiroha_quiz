# Independent Android-only Shiroha Link

This bounded source package reuses the independent Link/MCP frontend and original
Android adapter from #359, with the merged Profile 3 business foundation. It
does not include the Windows App, Windows business bridge, a database, pairing
credentials or a legacy-host release implementation. The governing contract is
[unified access v1.4 §§4.3, 7](../../docs/product/agent-refactor/unified-access-and-content-exchange-v1.md#s04).

Source tests and package compilation are not installed-Codex/phone acceptance.
L01/L02/L09/L10 and the initialization portion of L13 need their respective
native/device evidence. Existing #359 CLAIMED/dirty slots are diagnostic-only
here; this package neither upgrades their files nor recovers their resources.

L01 may use an existing Windows account under the
[local acceptance contract](../../docs/product/agent-refactor/unified-access-and-content-exchange-v1.md#221-本地独立连接).
Use a candidate-bound independent runtime package and newly registered
installation configuration, state directory and test pairing slot. Preserve all
existing pairings and dirty owners. Record the initial state and start access
tracing before configuration/initialization; retain coverage of the actual
configuration, Link, Adapter and client process chain through real Android READ
and original-resource shutdown. Package inventory, initial-state provenance and
the complete trace jointly establish absence of Windows App startup, business
IPC relay and business database/settings access or preprepared business state.
A missing process observation alone is insufficient. Windows system libraries,
protected credential storage and CNG/TLS remain allowed dependencies. Keep raw
traces local and provide redacted evidence summaries. This does not prove L10
historical provenance or crash recovery and does not upgrade earlier evidence.

## Build and configuration

For a fresh Android pairing on a tablet that already has the READ test App,
build Debug with `-PandroidReadValidation=true`,
`-PandroidLinkIsolationValidation=true` and `SHIROHA_UNIFIED_LINK=true`.
The default `com.example.shiroha_quiz.linkvalidation` application ID uses its own
UID, private state and Keystore namespace. To preserve an earlier isolation run,
add `-PandroidLinkIsolationValidationTag=<tag>` with a new lowercase tag matching
`[a-z][a-z0-9]{0,23}`; this appends `.<tag>` to that ID and requires isolation.
Verify the built package ID is new
on the device and the installed UIDs differ before initialization. Never replace,
clear or reset the existing App or copy its credentials/state. Both Apps use
the same TLS port; only the new installation may enable access for this run.
This does not change ordinary Debug/Release admission or prove simultaneous
listener support. See the
[Android admission contract](../../docs/product/agent-refactor/android-device-access-v0.md#12-bounded-seven-tool-integration-and-remaining-admission-boundary).

Run `build_runtime.ps1` with explicit `DartExecutable`, `CmakeExecutable`, and
a new `OutputDirectory`. It builds Dart AOT entries, two Windows x64 IPC DLLs,
and the original self-contained .NET adapter. Restore uses the existing offline
10.0.7 runtime pack. Missing build dependencies fail; startup downloads nothing.

Run `configure_installation.ps1` with explicit `RuntimeDirectory`, a new private
`StateDirectory`, `SlotDirectory`, and opaque `SlotRef`. Mutable directories
remain outside the versioned runtime directory. For a genuinely new phone
pairing, supply the public `PhoneAddress`, `DeviceId`, and full
`CertificateDigest` from the phone's original first-connection panel. These
are unverified enrollment inputs, never a verified installation binding.
For an existing paired slot, omit these inputs.

The installer persists one connector and initialization operation in its adjacent
`link-installation.json` version 2. Repeating the same configuration preserves
that identity. A different configuration, corrupt journal, occupied state or
reparse directory refuses. The installer does not read pairing secrets, create
handoff records, assert clean settlement, or change an existing slot's ACL.

## Explicit initialization

Launch the installed `shiroha_link.exe --initialize` explicitly through the real
desktop shell. Native checks the original shell/process/image/user/session
before mutable-state access. Then invoke the adjacent
`shiroha_link_control.exe initialize` locally. MCP exposes no initialization,
target selection or recovery control.

The new slot first records UNCLAIMED/PREPARING, its original operationId, null
verified installation/credential reference and UNKNOWN settlement. The original
adapter creates its own DPAPI enrollment object, performs pinned TLS and the
original P15/P0 exchange, and displays the actual client fingerprint in the Link
console and local control response. `initialize` returns when this comparison
is available; `inspect` exposes the same `pairingClientFingerprint` while the
original operation stays busy. Compare that complete fingerprint with the
phone's original panel and confirm there. Then inspect the completed state;
the early comparison response does not indicate initialization success. Pairing
ends disabled. No model confirmation substitutes for this local comparison or
creates a Grant.

After original TLS/key settlement, the adapter saves the verified pairing and
its bound receipt/provenance. Link joins the original process and all three
streams and persists `initialization-joined.json` for that exact original
run/resource/process before publishing LINK_OWNED, then finishes its local state under the
same operation and short slot-control lock. An interrupted final publication
can finish the same owner; it cannot manufacture a second owner generation.

Historical paired admission requires the original adapter's independently
recorded `adapter-origin.json`, matching original pairing settlement and the
original supervising owner's process/stream join evidence, exact
slot/installation/Profile/resource bindings and readable DPAPI credentials.
This provenance is produced by the original adapter after actual pairing, never
by an installer switch or model argument. A pre-existing pairing without this
positive source and settlement evidence remains `legacy_status_unknown`; this
package does not reconstruct old evidence from ciphertext, an absent lock,
missing CNG marker, a device name or a user's recollection. The original adapter
rechecks the protected record and original process absence before admission.

## Daily READ and close

1. Explicitly start Link from the desktop shell. Its normal entry never creates
   missing initialization state.
2. On the phone, explicitly enable access and wait for PREPARING. Run the local
   `connect` control. The original enable-proof helper settles before business.
3. Configure the normal Codex STDIO MCP command to the installed `shiroha.exe`,
   with no database, credential, address or executable arguments. The real MCP
   SDK exposes the original eleven Profile 3 tools; static discovery opens no
   credential or phone connection.
4. Use fresh Contexts and only current phone-authorized READ scope. Normal
   defaults remain Profile 2; the separately admitted Android build must select
   `SHIROHA_UNIFIED_LINK=true` to accept Profile 3. No grant is broadened.
5. `disconnect` and `shutdown` join original work/output, target CLOSE, TLS,
   temporary-key retirement, process exit and streams. A receipt must match the
   current run/resource/process; an earlier enable-proof receipt cannot clear a
   business resource. EOF is not a user cancellation.

Codex's official STDIO configuration is documented in
[OpenAI's MCP guide](https://learn.chatgpt.com/docs/extend/mcp#stdio-servers).
These configuration instructions do not assert that an installed client/phone
READ or Windows file-I/O isolation has been exercised for a particular build.

### Bounded verification observations

`build_runtime.ps1 -VerificationObservations` explicitly compiles only the Link
entry with `SHIROHA_LINK_VERIFY_SUPERVISION=true`. Ordinary builds default to no
observer or log. This is build-time diagnostic instrumentation, not a model or
control request, business permission, state format, or recovery authority.
The original adapter supervisor observes successful stdin/exit/stdout/stderr/
client settlement and the bound adapter event. The original pipe owner observes
its pending output work and actual delivery status. Runtime observes the original
call join and the matching receipt/CAS publication, retaining the original owner,
lease, connection and resource identities before they are cleared.

Only fixed non-secret fields are buffered (at most 31 observations plus a
terminal record, 32 KiB total). After original Link shutdown, the entry writes a
new `verification-<runId>.jsonl` under its trusted state directory, refusing an
existing file. No observer exception changes business clean/dirty or admission;
log failure makes the verification-build exit nonzero after original cleanup.
Missing records, missing terminal marker, overflow or failed exit reject the
evidence. Nothing consumes these logs to recover or mark resources clean.

Bind a verification run to its exact source snapshot/patch, build inputs,
toolchain, defines and all artifact hashes. Before proof or business can replace
the single adapter receipt, preserve the original pairing receipt, origin,
attempt, join and state/slot bytes. Keep both sides of a repeated initialize
comparison. Preserve the business owner/lease and its corresponding receipt,
supervision observations and final state separately. A new run never reconstructs
lost historical evidence or closes L01, L10 or an unrelated client failure.

## State, interruption and diagnostics

New Link state uses `link-state-v2.json`; slot custody uses
`slot-ownership.json`. The original #359 filenames are not overwritten.
`link-owner.lock` excludes state writers; the separate short
`slot-ownership.lock` protects initialization CAS and publication. The original
adapter retains `adapter.lock` for its TLS/CNG lifetime. No slot-control lock is
held while waiting for user confirmation, network or process settlement.

Complete, matching initialization pending records can be resumed under the
original operation/revisions and writer locks. Partial/corrupt journals, live
owners, conflicting revisions, unknown resource outcomes and missing receipts
remain retained and refuse admission. After a pairing attempt that lacks its
original completion evidence, restarting is diagnostic, not permission to pair
again. An adapter TLS/key receipt plus a gone PID cannot replace the missing
supervisor join. A fully written join pending record can finish its own atomic
publication; it does not reconstruct missing process/stream evidence. Business
recovery and general crash cleanup are not implemented here.

Detection of old handoff/state files routes to `legacy_retirement_required`,
`legacy_link_recovery_required` or `legacy_status_unknown`. It never creates
PREPARED/RELEASED/CLAIMED, deletes dirty files, scans user directories, imports a
Windows database or changes the old owner. Those paths require their own scoped
implementation and acceptance.

`inspect` distinguishes preparation, business readiness and settlement. A
successful business result never proves resource cleanup. An original-resource
failure remains a failed shutdown with retained custody, and cannot be hidden
by a later diagnostic write.
