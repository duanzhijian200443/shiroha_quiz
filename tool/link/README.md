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

### Independent registration before Link adoption

For prospective independent pairing, run `configure_registration.ps1` with a
new `SlotDirectory`, explicit `RuntimeDirectory`, `SlotRef`, `PhoneAddress`,
`DeviceId` and `CertificateDigest`. It writes adjacent `pairing-registration.json`
v1 with a registrar instance/operation/generation and original run/resource,
under the empty-slot control lock. It creates no Link state or business authority.
An existing matching config retains those identities; unknown/occupied state refuses.
Launch `shiroha_link.exe --register-pairing` directly from the desktop shell.
The native guard retains the original Explorer/image/user/session admission and
opens no pipe. Compare the full original adapter fingerprint with the phone.
It is printed to stderr and written, after original offer validation, to the
fixed slot-local `registration-observation.json` (comparison-only kind, original
operation/run/resource and 64-character fingerprint). This file is not authority
or a success signal. Registrar emits `registration_sealed` only after completion.

Slot custody v2 moves REGISTERING → SEALED; it is owned by an independent
registrar, never Link UNCLAIMED. Original adapter production preserves immutable
`registration-attempt.json`, `registration-receipt.json`,
`registration-origin.json`; only the original supervising process can publish
`registration-joined.json` after actual exit and stdin/stdout/stderr join.
`registration-source.json` seals exact original-file hashes. Every source file
uses create-new staging, flush and atomic publication. Hashes provide consistency,
not authentication. Credential binding includes original association revision,
client certificate digest and protected record bytes digest. No credential
plaintext is recorded; ordinary config or model input cannot issue evidence.

After SEALED, configure a new Link state directory using the existing
`configure_installation.ps1`, selecting the same slot and omitting pairing inputs.
Launch `shiroha_link.exe --initialize` from the desktop shell. The original
credential owner verifies the sealed evidence and current protected credentials;
Link joins that inspection helper and stores `registration-adoption-joined.json`.
The short slot-control then original adapter-resource locks recheck the source
and credential bytes before the single designated Link/operation CAS to
ADOPT_PENDING. Registrar writes/re-pairing remain permanently fenced. Link
publishes its initializing state, LINK_OWNED custody, then clean state; business
requires completion and the phone's separate current Enable/Grant.

Lock order is Link lifetime (when present), slot control, adapter resource.
Neither short lock waits for TLS, process exit or user input; native credential
callbacks do not acquire slot control. Complete original pending records may
finish only their same operation/revision; missing original join never reruns
pairing. ADOPT_PENDING can finish its reserved Link state; v2 LINK_OWNED with
missing Link state refuses, preserving possible later business dirty history.
The immutable original pairing package never reads/falls back to mutable latest
`link-settlement.json`, even after proof/business replaces that receipt.

Existing v1 records retain their parser and owner path without automatic upgrade.
Unknown old pairings stay unknown. This is prospective source production, not
retroactive history reconstruction, #356 retirement or #359 migration. Supported
old entries retain their original marker/fence refusals; no claim is made about
an arbitrary unknown old binary or malicious same-user program. Synthetic fixture
production and source checks do not prove real device/client acceptance.

### Link-owned fresh initialization

Portable initialization tests cover v2 parser/preparation/refusal without issuing
synthetic success evidence. The original C# producer + actual synthetic child
process/join/adoption matrix is an explicit Windows/.NET 10 integration group;
it builds offline into `build/link-registration-tests` and is skipped on other
platforms. Existing portable standing CI does not supply that toolchain and does
not replace this independent acceptance gap. The fixture executable is test-only;
the shipped adapter exposes no synthetic source issuance command.

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

The Windows Adapter flushes the create-new pending receipt while holding the
original slot resource lock, then publishes it with a single overwrite rename
within the slot before emitting `settled`. A refused rename keeps the pending
receipt and the previous published receipt. Link preserves the original dirty
owner and reports at most one receipt I/O diagnostic per original Adapter on
local stderr with the process ID, safe category and HResult. That diagnostic
does not participate in settlement.

Codex's official STDIO configuration is documented in
[OpenAI's MCP guide](https://learn.chatgpt.com/docs/extend/mcp#stdio-servers).
These configuration instructions do not assert that an installed client/phone
READ or Windows file-I/O isolation has been exercised for a particular build.

Graceful-close compatibility applies to the client executable and configuration
bound by the acceptance evidence. An explicitly selected isolated Codex candidate
does not establish compatibility for the installed client, another release or a
PATH-selected executable. Retain its source/patch/toolchain and executable-hash
binding, isolated client configuration and matching Link/Android artifact
identities; see the [candidate manifest](#offline-client-shutdown-fixture).
Offline shutdown fixtures alone do not prove real Android READ or production
close capture. [Per-call close-capture acceptance](#optional-per-call-verification-capture)
requires both complete production footers, matching call/resource identities and
independently retained original-process exit evidence. Missing or mismatched
evidence remains INCOMPLETE; later success does not repair earlier failed or
incomplete attempts. Ordinary builds do not acquire a capture requirement.

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
lost historical evidence. It does not by itself close full L01 acceptance, the
original historical L10 provenance gap or an unrelated client failure.

### Optional per-call verification capture

`-VerificationObservations` compiles the opt-in observer in both Link and the
frontend. With no capture configuration the existing supervision-only Link log
remains unchanged, including initialization. Normal builds ignore the capture
configuration and allocate no capture writer.

For one bounded READ attempt, the trusted local harness may place the separate
`link-verification-capture.json` next to the runtime, with exactly these fields:

```json
{"formatVersion":2,"attemptId":"12345678-1234-1234-1234-123456789abc","evidenceDirectory":"<absolute normalized existing directory>"}
```

Use a new, empty evidence directory and bind this non-secret configuration to the
source/artifact manifest. Frontend never loads `LinkInstallation` to find it and
does not inspect state, custody or credentials. The config supplies no admission
authority. Registration/initialization can finish before the harness creates it.
The normal Link invocation then chooses this capture explicitly; initialization
continues to use the original supervision log.

Configuration version 1 retains the original eight-call diagnostic format and
does not acquire new closure meaning. Version 2 selects the five-call closure
capture below. All call/header/footer/collision records carry the selected `v`;
the original resource observations retain their independent formatVersion 1.
Never mix versions in one attempt or reinterpret an old v1 file as v2 evidence.

Fixed new-only files are `frontend-calls.jsonl` and `link-verification.jsonl`.
The frontend reserves its output once, asynchronously appends at most five (v2)
finalized summaries, and joins its diagnostic I/O only after original close.
Link buffers and publishes after original close. Any writer collision attempts
one fixed `capture-collision.json`; existing files are never replaced. A
collision invalidates the whole capture, even if an earlier writer has a footer.
An I/O or observer failure affects evidence only, never business output or
settlement. Codex stderr is not a guaranteed child-stderr capture channel. A
client that terminates its frontend before close may leave partial records and
no footer; this remains INCOMPLETE and is not repaired or backfilled.

The v2 aggregate allocation, including every LF, is at most 27 records / 31936
bytes. It reserves the external original-process witness and client summary,
even though the source producers do not write those two records:

| Allocation | Maximum records | Bytes per record |
|---|---:|---:|
| Frontend calls | 5 | 960 |
| Link calls | 5 | 1152 |
| Original resource observations | 7 | 2048 |
| Frontend header | 1 | 256 |
| Producer footers | 2 | 512 |
| Collision marker | 1 | 128 |
| Frontend lifecycle checkpoints | 4 | 256 |
| External original-process witness | 1 | 512 |
| External normal-client summary | 1 | 4096 |

The external harness must enforce both external limits and the aggregate,
counting LF and UTF-8 bytes. The fifth call is the last recorded v2 call;
subsequent business calls are not blocked but make capture INCOMPLETE. The old
v1 allocation remains 27 records / 32640 bytes for its eight-call producers and
original resource/header/footer/collision records; it did not reserve these v2
checkpoints or external witnesses. No per-spawn/resource filenames can enlarge
either allocation. Tests use maximum legal 128-character IDs, maximum integer
identities/revisions and FILETIME, all stages/known shapes, and UTF-8 encoding.
Identities are never truncated to fit.

Call records share a compact projection, explicitly discriminated by `v`:

| Key | Meaning |
|---|---|
| `v,e,p,s,n,t` | version 1 or 2, `call`, producer `f`/`l`, producer sequence, local ordinal, tool index |
| `r,c,i,l` | original run, frontend connection, IPC call ID, lease ID; null before available |
| `g,q` | original route generation and selection revision; null in frontend |
| `o` | original `[resourceId, processId, processStarted, slotRef]`; null in frontend, run is `r` |
| `a,at,u` | frontend-only parameter shape rows, top-level JSON type, unknown-key count |
| `x` | eight stage `[outcome,cause]` pairs in the order below |

`a` rows are `[fieldIndex,present,type,length,overflow]`. Length/count saturate at
256; no values, unknown names or nested data are retained. Type indices are
0 absent, 1 null, 2 string, 3 bool, 4 int, 5 number, 6 array, 7 object, 8 other.
Field order is `contextRef,targetRef,pageSize,cursor,fileRefs,scope,query,
questionRef,timezone,from,to,limit,passageRef,submissionKey`; only each tool's
fixed schema fields are projected. No external request identity is serialized
or hashed. Tool order is `unknown,open_context,list_question_banks,
get_study_overview,get_due_review_summary,get_weak_questions,search_questions,
get_question_detail,retrieve_file_content,get_file_passage,get_question_proposal`.

Stage order is admission, attach, ipcSend, ipcReceive, backendCall,
resultValidate, outputSend, deliveryAck. Outcome order is unseen, entered,
succeeded, rejected, failed, unknown. Cause order is none, unknown, unavailable,
busy, invalidFrame, invalidResult, deviceMismatch, timeout, clientFailure,
prePortRejected, invalidParams, invalidRequest, methodNotFound, internalError,
eof, sendFailed, receiveFailed, resultMissing, resultShape, resultProfile,
resultSource, resultData, resultErrorType, resultErrorFlag. These enum indices
are diagnostic format fields, never new public error codes. Known refusals are
observed at their original branch; unknown exception text is never inspected.

Frontend observes SDK-handler refusals before port admission. A client failure
before its request reaches this transport has no strong per-call association.
Unbound transport errors are counted, not assigned by timing. Frontend `ipcSend`
and Link `ipcReceive` join only by the exact non-null `(r,c,i)` key; Link supplies
the original lease/route/owner. Frontend `deliveryAck=succeeded` means its existing
ack frame send completed; the Link record separately proves the original receipt.
Stages outside a producer's boundary remain unseen; a terminal resource record
does not fill in a missing call stage.

The frontend starts with `capture-start` containing attempt ID and PID. Each
producer ends with `capture-finished` containing attempt ID, sequence, preceding
record/byte counts, observed/finalized calls, resource count, unassociated count,
`complete` and `originalClosed`. Original resource observations keep their own
schema and meaning. A validator requires both complete footers, contiguous
sequences/counts, no conflict marker, exact call joins and independently valid
original resource/exit evidence. A successful footer alone is never sufficient;
new failure diagnostics never confer clean authority or explain historical
failures whose original details were not captured.

For v2 only, `capture-start` also contains `processStarted`: the same process's
actual Windows GetProcessTimes creation FILETIME as a decimal string. It is read
only by the opt-in v2 frontend through a small kernel32 FFI call, without a new
dependency, native ABI, subprocess or credential/configuration owner. Failure or
non-Windows execution records null and makes capture INCOMPLETE; wall-clock time
is never substituted. The external retained original-process handle must match
both PID and creation time before its exit witness can be used.

Four fixed lifecycle records have exactly `{v:2,e:"lifecycle",p:"f",s,k,o}`:

| `k` | Original observation | `o` on normal EOF |
|---:|---|---:|
| 0 | Original transport onclose callback entered | 0 (observed) |
| 1 | First original port.close future entered | 0 (observed) |
| 2 | That same close future completed or failed | 1 (completed); 2 means failed |
| 3 | capture.finish entered after original serving/close settles | 0 (observed) |

Repeated close calls return the same original future and do not emit extra
checkpoints. There is no additional business wait, delay, timeout, retry,
cancellation or shutdown protocol. The normal EOF success sequence is naturally
`k=[0,1,2,3], o=[0,0,1,0]`; other paths retain their actual order and cannot be
made successful by rearranging observations. A missing checkpoint does not prove
its phase was never executed. v2 footers add `lifecycle` (frontend 4, Link 0);
complete v2 frontend evidence requires all four and successful original close.
Observer or writer failure stays INCOMPLETE. Interruption before flush/finish may
leave partial records, never an inferred footer. Automatic real-SDK EOF tests
after attachment/calling cover delayed/failed original close and diagnostic
failures without manually calling server.close to advance the lifecycle.

In v2 validation builds, capture failure after original closure changes an
otherwise zero process exit to diagnostic exit 80, preserving every original
nonzero exit. This includes a final flush or file-close failure after a true
footer was already written. Both producers require their independently retained
original-process exit witness as well as their footer; the footer alone cannot
prove diagnostic IO completion. v1 and normal builds keep their original exit
policy. Diagnostic exit 80 does not change business results or clean/dirty state.

## State, interruption and diagnostics

### Explicit address refresh and v2 run-only routing

From the existing trusted local control console, after the phone's independent
access action has entered PREPARING:

```text
shiroha_link_control refresh-address <private-ipv4>
```

This is the original connect/proof operation with one explicit routing hint.
The same entry accepts a clean, unprepared v1 or v2 LINK_OWNED slot with no
lease/owner or pending resources. The original TLS client credential and server
pin must prove the same device, installation, Profile and association revision
before any address persistence or routing hint. It retains the credential owner
and pairing origin; it grants no business scope or Enable renewal, never
re-pairs and never bypasses DIRTY. After success, business uses the persisted
v1 address or the v2 run-only hint through the original adapter.

For v1 this persists the verified address. v2 sealed registration refuses the
persistent update with `address_update_unsupported` and never modifies
credentials/source digests; instead the same command supplies a run-only routing
hint. The adapter verifies the sealed provenance, completes the original
pinned-TLS offer/proof and settlement against the candidate, and writes no
protected or registration byte. Link binds the hint in memory to the authenticated
identity and owner/selection/route generations and passes it only to the next
same-target business adapter, which still authenticates independently. Exit,
generation/owner/identity change, withdrawal or DIRTY invalidates it. Dirty v1 also
refuses; this command cannot repair an historical failure or bypass DIRTY. The
exact persistence, interruption and v2 run-only routing boundary are owned by the
[canonical address boundary](../../docs/product/agent-refactor/unified-access-and-content-exchange-v1.md#link-address-refresh).

Each original Adapter may forward one fixed whitelisted failure as
`<label> pid=<pid> stage=<stage> category=<code>`. A business process before its
actual authenticated event uses `android_adapter_preauthentication_failed`;
after that event no preauthentication diagnostic is emitted. An enable-proof or
address-refresh process never emits an authenticated event, so it always uses
the neutral `android_adapter_stage_failed`, including post-proof
settlement-receipt or protected-configuration failures. Only existing
whitelisted stage/code values are accepted; raw stderr is discarded.
For example, `stage=tls category=deadline` is distinct from the existing
settlement-receipt publication diagnostic. Neither observation proves clean.

The Windows case in `link_initialization_test.dart` also runs real mTLS 1.3
over isolated duplex pipes with generated identities, original proof/EOF and
CNG retirement, plus DPAPI CAS/interruption, sealed-v2 refusal and run-only
route-admission checks.
It uses no TCP connection, phone, installed Link or historical slot. The portable
orchestration tests do not substitute synthetic TLS success for this check.

### Offline client shutdown fixture

`test/mcp/fixtures/offline_codex_shutdown.py` is a separate, opt-in host test.
It pins one installed Codex executable and uses a loopback-only scripted
Responses service plus a pure test MCP server with one `probe_read` tool. Its
`prepare`, `reference` and `baseline` entries use create-new evidence directories.
The reference explicitly closes its own MCP input; the baseline runs normal
`codex exec` and observes the client-owned MCP process without closing its stdin
or injecting a terminal record. Baseline execution follows review of its frozen
inputs and isolated configuration. No actual model, device, Link or App is used.

Only an exact original nonce/success result allows the scripted final response.
The first unexpected HTTP request stops the service; retries cannot accumulate
failures or manufacture completion. Both original process handles, creation
times and image hashes remain independently observed. Fixture records use their
own `fixtureVersion` schema; they are not production Link footers or evidence of
Android access. Missing EOF/cleanup/terminal records remain incomplete even if
the tool result and client exit succeeded. Bounded timeout cleanup terminates
only retained, verified fixture handles and marks the attempt ABORTED. It never
establishes graceful compatibility or repairs an earlier missing footer.

The pinned client emits a metadata-fallback warning for the deliberately local
`offline-shutdown` model. Only that exact fixed-source message, at most once, is
classified separately as an expected fixture warning. Other error events,
similar text and duplicates still fail closed. Bounded booleans/counts identify
which call, final-message or event-shape condition failed without retaining
original output or error text.

The skill-discovery isolation switch also has a fixed development-stage warning
in that client. Its only accepted form names `skip_host_skill_discovery` alone
and the exact current isolated `home/config.toml` path, at most once. The path
is compared in memory; evidence retains only the fixed category/feature and
count. Neither warning classification changes production Link footer checks.

An isolated graceful-close candidate can be selected only at preparation:

The pinned candidate's [source patch and reproduction instructions](../external/isolated_codex/f79b26cc/README.md)
are retained separately from the local binary and execution evidence. Selecting
it never updates the installed client or transfers an earlier run's approval.
The host fixture resolves its pinned installed-client path and `flutter` SDK
checkout under the current user's home; it does not persist another user's
absolute path. The fixed installed-client hash check remains mandatory.

```text
python -I -B test/mcp/fixtures/offline_codex_shutdown.py prepare <new-root> --candidate-manifest <absolute-manifest>
python -I -B test/mcp/fixtures/offline_codex_shutdown.py normal <new-root>
python -I -B test/mcp/fixtures/offline_codex_shutdown.py delayed <new-root>
python -I -B test/mcp/fixtures/offline_codex_shutdown.py hang <new-root>
```

The exact-key candidate manifest is limited to 16 KiB. It uses `formatVersion:1`,
`kind:"isolated-codex-graceful-close"`, `executable`, `sha256`, `sourceBase`,
`sourceManifestPath`, `sourceManifestSha256`, `patchPath`, `patchSha256`,
`toolchain:{rustc,cargo,target,profile}`, `shutdownGraceMs:3000` and
`shutdownBoundMs:9000`. The source base must be
`f79b26ccbb3116b052544666a181012fb45dc49b`;
target/profile must be `x86_64-pc-windows-msvc` / `dev-small`. All resolved paths
must remain in `build/codex-gc`; the executable must be its
`target/dev-small/codex.exe`. Candidate manifest/artifacts and the untouched
installed-client hash are checked before and after every case. Omitting this
option preserves the original fixed-client preparation and reference/baseline
entries. No candidate is auto-selected from PATH.

Candidate cases use separate `fixtureVersion:2` records, adding a fixed scenario,
cleanup delay and same-Windows-monotonic-clock observations. Normal and delayed
cases require complete original cleanup and exit0; the delayed fixture holds
its resource for at least 750ms after `cleanup_begin`. The hang fixture holds
for 30 seconds unless the candidate terminates it. Timeout protection requires
observed EOF/cleanup entry, a zero Codex exit, a nonzero original MCP exit and no terminal record,
with both original exits observed within 9000ms of turn completion. The observed
cleanup survival lower bound must be at least 2500ms to reject immediate killing.
An abnormal Codex exit cannot establish timeout protection, since a client crash
could instead cause its Job to terminate the MCP process.
That bound uses the monotonic timestamp taken before the last original-handle
query that explicitly observed the process still alive. A late exit observation
is only an upper bound and cannot establish survival. This tolerance does not
replace the candidate's exact three-second Rust timer regression.
`timeoutProtectionPassed` and `scenarioPassed` may be true for hang while
`compatible` remains false. Any harness termination is still ABORTED. The
record limit remains 12 records, 512 bytes each, including LF.

Concurrent/repeated shutdown and Job descendant containment require the fixed
candidate's Rust regression evidence. A normal exec run does not pretend to
exercise a second shutdown, and the harness adds no synthetic MCP shutdown tool.

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

## Explicit preauthentication failure recovery

Unified access §6.2.2 defines the version-1 preauth-failure receipt, independent
original-supervisor join and exact recovery intent. A failed enable-proof remains
failed/DIRTY until `shiroha_link_control recover-preauth <state-revision>` is
explicitly requested locally. Obtain the current revision with `inspect`.
Recovery returns clean/SELECTED with prepared=false; a new explicit connect and
the phone's original PREPARING/Enable remain necessary. MCP has no recovery tool.

Only no-acquisition or completely released pre-TLS resources qualify. An observed
peer certificate, established TLS/offer/proof, unknown CNG/socket/TLS cleanup,
nonmatching receipt, pending publication or incomplete original process/stream
join refuse. The proof adapter waits for stdin EOF before exiting, and the
supervisor sends that EOF only after owner-identity capture (or observed exit),
so creation identity is always checked against the live original process even
when stderr event processing is delayed. The separate per-resource files never
replace normal receipts or registration provenance. A gone PID, no pending/lease,
successful later run or old receipt cannot repair historical DIRTY. General
business recovery remains outside this source slice.

Portable regressions run in the standing Link suite. For explicit isolated
Windows resource acceptance, build the current .NET adapter and run:

```powershell
dotnet build tool/android_device_adapter/AndroidDeviceAdapter.csproj --nologo
flutter test --no-pub --concurrency=1 --dart-define=LINK_PREAUTH_NATIVE=true test/data/external/link_preauth_failure_test.dart
```

The test-only native fixture is confined to fresh directories under this
checkout's build/link-preauth-native. It imports disposable current-user CNG keys,
connects only to an endpoint bound on this computer, and executes original
transport/disposal, receipt publication and Link supervisor paths. Failure
injections occur after actual acquisition; no saved key or device is accessed.
Production native parent admission/DPAPI composition and Android behavior remain
separate acceptance; these isolated tests cannot establish historical recovery
or ANDROID-FOCUS-1 V3–V5.
