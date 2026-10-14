# Association publication diagnostic candidate

This directory contains a future L1 harness candidate, not an experiment grant.
It neither replaces nor modifies the untracked frozen Batch 2 harness/evidence.
The P20 publication candidate uses NtSetInformationFile. Native ABI 3 and the public
failure vocabulary remain unchanged. Real publication is not proven repaired.

## Stop and evidence contract

`association_probe.cpp` uses the original fixed synthetic association sequence.
Every unexpected status or shape stops that sequence immediately. Missing at
begin1, resourceLimit at begin2, invalidInput for the consumed ticket and the
Bridge denial are expected only in those named steps. A first commitUnknown
skips all later begin/protect/commit/abort calls. The only subsequent helper
call is one owner-close attempt through RAII; Native Core owns transaction
release and quarantines unknown closes without retry. No file cleanup occurs.
Failure, exception or budget observation failure returns nonzero. The ledger
retains the first failure, attempted-call counts and the unexecuted steps.

`runner_sequence.ps1` stops on any nonzero result or invocation exception and
records the modes not launched. `run_candidate.ps1` freezes runner, sequence,
DLL and executable hashes plus exact Git head. The additional SHA-256 source
manifest freezes every Native directory file and the exact file set, including
the authorized uncommitted harness overlay. Its own hash and the pure gate hash
are checked before parsing/dot-sourcing; unknown or missing files are rejected.
`-VerifyFreezeOnly` ends after artifact/HEAD/source checks, before any lab-object
inspection or probe launch; it is permitted in L0. Neither switch grants L1. It is dry-run by default and
does not admit any real mode in this Host A preparation. Host A (the primary
Windows computer) supersedes environment B as the Batch 3 candidate; no cloud
computer or VM is requested. Execute now fails before object inspection/DLL
loading with `host_a_runtime_binding_pending`. The native executable's shared
entry gate also rejects all four modes before any resource sampler, DLL loader
or export call, including direct invocation outside the PowerShell Runner.
There is no CLI opt-in around that gate. The non-empty-directory exception
below is a proposal, not permission to remove the gate or clean Batch 2 residue.
The separately reviewed device/SID/OS/local-fixed-NTFS/object/time/recovery
contract and new explicit grants are still required. This is not batch approval.

Successful sequence counts across four processes: ABI 3 (symbols resolves only),
App/Bridge acquire 1 each, Protect 2, App begin 5, Bridge begin 1, commit 3
(including consumed-ticket rejection), abort 2 and owner close 2: 20 exported
function calls. Failure reduces those counts; ceilings never override STOP.

Counters have separate meanings: `attempted` increments immediately before
calling an export (including a throwing fake and owner close); `returned` means
normal return; `completed` means the returned status/output checks finished,
including rejected results; `successful` means status 0 (or the ABI version
query returning the expected version), independently of shape checks; `accepted`
means expected status and valid shape. Expected Missing/resourceLimit/stale-ticket
and Bridge denials are accepted probes, not successful status-bearing calls.
Resource measurement success is separate; a measurement failure prevents PASS
without retroactively changing returned/completed Native counts. The first
failure is immutable; later close and sampling failures retain their own log
records. Unknown/throwing close consumes ownership before the one attempt.
The log also retains attempted-but-not-completed steps and every sampling
failure. stdout is unbuffered; abrupt interruption without final counters is
incomplete evidence, never an invented exact total or PASS.

First publication (`commit1` + exact ciphertext read-back at `begin3`) must pass
before Abort and the existing-target phase. `begin4` verifies that Abort left
the first ciphertext intact and transfers a positive ticket; only then may
`commit2` replace the existing target. `begin5` must return the second ciphertext
byte-for-byte with another positive ticket. Failure anywhere in first creation
makes replacement unreachable; no diagnostic read/retry follows commitUnknown.

The process samples its own OS peak working set and peak commit charge plus
current handle count before helper work, after every completed helper call and
after owner close. Memory peaks include between-sample work. Handle maximum is
explicitly **sampled**, not an exact OS high-water mark. The candidate ceilings
are 64 MiB for each memory peak and 128 sampled handles, requiring explicit
inclusion in any future grant. These observations are not an asynchronous
watchdog and cannot interrupt a stuck native call. A future batch needs its own
approved timeout/recovery policy; no force termination is supplied here.

## Internal failure classification

`ProtectedObjects::association_commit` accepts an optional caller-owned internal
`CommitDiagnostic`. It records admission, prepare, old-target close, rename, published-close,
published-validation or complete; independent flags distinguish exceptions and
final transaction-release failure. The exported wrapper supplies no diagnostic
pointer. No OS code, path, identity or payload is recorded or exported.

All original failure mappings are retained. In particular, rename returning
non-success, an exception after entering rename, post-rename close/validation
failure and final release failure after entering rename remain commitUnknown.
Old-target close failure before entering rename remains unavailable and
quarantines the owner without retrying its detached handle.
Stage classification is not evidence that an ambiguous rename did or did not
publish. Core fake tests cover new/existing targets and inert leftovers.

## Publication API assessment and approved G0-L0 candidate

Official references inspected for this candidate:

- [FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)
- [SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle)
- [FILE_RENAME_INFORMATION](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information)
- [NtSetInformationFile](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntsetinformationfile)

The current Win32 documentation allows a directory handle in RootDirectory for
a relative filename. FileNameLength counts bytes and need not include a NUL.
The frozen Batch 2 source supplies the fixed name with a terminating NUL and excludes
it from FileNameLength. Its SDK x64 layout is alignment 8, size
24, offsets 8/16/20, name bytes 32, supplied buffer bytes 54 and capacity 58.
There is no demonstrated alignment, truncation or NUL overrun defect here.

The parent is the verified state directory pin. It requests READ_CONTROL,
FILE_READ_ATTRIBUTES, SYNCHRONIZE, FILE_LIST_DIRECTORY and FILE_TRAVERSE, and
shares read/write but not delete. The native rename documentation describes
traverse/read-attribute access for the root handle and a separate target open
requesting write-data/synchronize. The temp requests DELETE, write-data,
read-attribute, READ_CONTROL and SYNCHRONIZE, with no sharing. The existing
target read allows read/delete sharing. No evidence yet justifies widening
access/sharing or dropping the parent pin.

New and existing publication differ only in ReplaceIfExists derived from the
validated snapshot. Success then closes the temp and rechecks owner, target
identity and security. Batch 2 exercised only the new-file branch; its status
7 and missing target do not identify the actual GetLastError or uniquely select
API failure versus post-publication failure. Its STOP violation and absent
memory measurements must remain attached to any archived observation.

The approved P20-only G0-L0 candidate resolves NtSetInformationFile in the
already-loaded user-mode ntdll module, with the NTAPI signature and class 10.
`association_rename.h` is the actual production seam also called by fake tests.
Its fixed-name structure has x64 alignment 8, offsets 8/16/20, storage size 56
and request length 56, meeting the 24-byte base plus 32 filename-byte documented
minimum without exceeding the 56-byte allocation. FileNameLength stays 32 and
excludes NUL; the fake rejects 52 and over-capacity lengths. It keeps
the validated parent, original existence flag and synchronous DELETE-bearing
temp. Direct NTSTATUS and IO_STATUS_BLOCK.Status must both be exactly zero;
pending, missing export, warning, mismatched or untouched completion fail unknown.
There is no retry, path fallback, access/share relaxation or raw OS-code output.
The native call cannot be used with an asynchronous handle; the existing open
path supplies FILE_SYNCHRONOUS_IO_NONALERT. No asynchronous wait is introduced.

Readiness sections 9.B.4 and 12 record the narrowly approved API candidate.
This is not proof of the Batch 2 root cause or of a successful real replacement.
Real behavior requires a separately approved L1 batch and remains untested.

## Target handle lifecycle and race boundary

Static reference analysis of the native core: `association_begin` assigns
`lease->target`, inspects it into `target_identity` and reads ciphertext from it.
`target_current` independently reopens the fixed name, compares its full policy
and volume/file identity with that captured value, then closes the transient
handle. Commit repeats that check after Flush and validates the temp immediately
before releasing the retained old target. `finish` closes any remaining target
on preparation failure, abort or owner release. After the new pre-rename close,
the retained field is null, so neither finish nor owner close retries it.

The contract retains original identity values, not a requirement for a destination
HANDLE to remain open throughout the transaction. Class 10 publication now closes
the verified old target once, while preserving owner/lock/all parent pins. Close
failure is unavailable with quarantine and no rename. After entering rename,
uncertain publication remains commitUnknown. New-target publication skips the
old-handle close; successful publication still closes the temp and reopens and
validates the published temp identity/security and all owner pins.

```mermaid
stateDiagram-v2
    [*] --> Snapshot
    Snapshot --> Validated: read/CAS + write/Flush + owner/target/temp checks
    Snapshot --> Unavailable: preparation or identity denial
    Validated --> OldClosed: existing target / detach + successful close
    Validated --> Rename: missing target / no old handle
    Validated --> Unavailable: old close failure / no rename
    OldClosed --> Rename: fixed parent + fixed name
    Rename --> Unknown: API/exception failure
    Rename --> Published: settled dual-status success
    Published --> Unknown: temp close, post-validation or finish failure
    Published --> Complete: temp close + new identity/security/pins + finish succeed
    Unknown --> [*]: consume ticket / inert residue / no retry or cleanup
    Unavailable --> [*]: consume ticket / quarantine uncertain close
    Complete --> [*]
```

Writer-lock exclusion applies to cooperating processes following this protocol.
It supplies no exclusion against arbitrary same-SID or Administrator code. Such
code can replace/mutate/remove the target after the last check and successful
close, before rename. The candidate may fail unknown or overwrite an intervening
object; validation of the newly published temp cannot establish which object was
replaced at that instant. This is the existing accepted §9.B.5/9.D same-SID risk.
Closing the old handle does not eliminate TOCTOU, provide anti-rollback, or relax
cross-SID DACL requirements. Parent binding, access/sharing and the OS writer lock
remain unchanged. Real class 10 behavior and platform compatibility remain pending.

If a future approved diagnostic wrapper records GetLastError, it must capture
it immediately after the failed API call, before any other call; emit only the
numeric code and fixed stage through the separately approved test channel.
Never add it to the production C ABI, Dart failure or MCP response.

## Offline checks

`check_offline.ps1` builds the production DLL, checks ABI/hardening/imports, then
checks the four fake-only executables for forbidden imports before running
CTest. The probe test compiles the same sequence with the entire DLL loader,
process sampler and real entry point excluded. Runner tests inject a process-free
callback and reject invocation exceptions and malformed results at each mode.
Pure source-freeze tests reject hash/path drift, duplicates and traversal. The rename executable calls the production packing/status seam with synthetic
handles and a fake NTAPI function, including new/existing and inconsistent
completion cases. Core fakes reject an open destination and exercise successful
old-target close, close failure/quarantine, existing identity drift and uncertain
post-publication results. Probe fakes also inject exceptions at every post-acquire
call boundary and assert zero subsequent operations except one owner close.
These tests do not resolve or invoke a native export.

`SHIROHA_L1_CANDIDATE_BUILD=ON` compiles the real candidate separately; it is
never a CTest entry. Compilation and static inspection do not authorize loading
the DLL or executing any candidate mode, including symbols/abi.

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED.

## Host A preparation candidate

This is a bounded Batch 3 contract proposal. It changes no production store
authority, §9.D recipe, leftover cap, acceptance matrix or AF_UNIX halt.

### No accidental initialization

Creation audit: the Known Folder handle uses FILE_OPEN; normal App acquisition
may FILE_CREATE Shiroha/external/app/trust/state/discovery/exchange, Bridge may
FILE_CREATE bridge, and either lock may FILE_OPEN_IF. These branches are valid
only under the original initialization authority. `ProtectedObjects::OpenMode`
defaults to that unchanged production behavior. The separate compile-only
`shiroha_batch3_existing_only.dll` clamps every child acquisition to existing
only: directories use FILE_OPEN and existing files retain the no-sharing lock
recipe. Absence, contention and invalid metadata fail closed, without creating
a replacement object or requesting a security descriptor. Acquisition never
creates associations.bin; association temporary creation remains CREATE_NEW,
with no collision retry. The unactivated source variant is not a replacement
for the production DLL and does not supply the missing runtime identity bridge.

### Exact read-only preflight scope

`host_a_preflight.ps1` is dry-run by default. `-Inspect` is real Windows work and
requires separate user authority; a command-line switch/hash is not authority.
It verifies scope/reader-source/policy/compiled-reader SHA-256 before loading
the frozen standalone managed reader in a fresh separately approved worker;
it never compiles reader source implicitly at inspection time. The
example scope is intentionally invalid (History empty). Historical expectations
must come only from archived sanitized Batch 2 logs/metadata with their SHA-256;
those records never establish current IDs, sizes, timestamps, security or streams.
Unavailable fields stay PENDING. This preparation accesses no live lab objects.

The approved scope must name exactly two distinct lowercase
`~tmp-<16 hex>-<8 hex>` files and their recorded positive sizes, each <=65536.
Do not use synthetic test names or infer that historical sizes are current.
All names below are relative to the OS-resolved LocalAppData; no caller-supplied
root, environment path override or recursive scan of personal directories exists.

| Object | Quantity / allowed role |
|---|---|
| OS LocalAppData (`.`) | One accepted OS ancestor; metadata only, NEVER enumerate its unrelated children |
| Shiroha, Shiroha/external | Two existing directories |
| external/app, app/trust, app/state | Three existing directories under Shiroha |
| external/discovery, external/exchange, external/bridge | Three existing directories under Shiroha |
| external/runtime.lock, external/bridge/client.lock | Two existing zero-length files; metadata read is NOT lock acquisition/liveness evidence |
| external/app/state/<two exact historical names> | Two historical files; attributes/security only |

The eight controlled directories must have exactly the children implied by this
table. State must contain exactly the two named historical files, which proves
associations.bin absent for this observation. Unknown names (including an
unexpected associations.bin), missing names, duplicate identities, enumeration
failure and any mismatch deny immediately. No unknown object is opened.

Allowed fields: relative name, volume serial, 64-bit File ID, filesystem and
fixed-drive classification, object type/attributes, reparse tag, link count,
size, unnamed data-stream name/length/allocation, Owner SID, DACL including protection/ACE flags/mask/SID, creation time,
last-write time and change time. Last-access time is not compared or exported.
Current SID is queried with token-query rights only. OS ancestor is accepted
as-is; Shiroha requires directory/current owner/no reparse; the remaining
controlled objects retain §9.D's exact protected single-ACE recipe. The report
contains no absolute paths or file content, ciphertext hash, stream content,
DPAPI or secret. One bounded `NtQueryInformationFile(FileStreamInformation, 22)`
query uses each already pinned controlled handle, twice across the two snapshots.
The accepted NTFS directory result has no data streams; each file must have exactly
one `::$DATA` entry whose length equals its file length. Any named ADS, unknown
stream type/name, duplicate, malformed/truncated response, overflow, unsupported
query or access denial stops. No stream is opened. OS LocalAppData is an accepted
ancestor and is neither child-enumerated nor stream-enumerated. There is no content
hash or claim to inspect filesystem-internal attributes/streams.

The A0-specific conservative stream parser consumes the actual valid byte count
from a successful, completed `NtQueryInformationFile` response's
`IO_STATUS_BLOCK.Information`, bounded to 64 KiB; allocated capacity is not a
returned length. Unknown/unreliable counts, truncation and failed/incomplete
responses deny, without inferring a count or using a length-less stream-query
fallback. Nonterminal `NextEntryOffset` alignment/offset checks are unchanged;
inter-record alignment bytes are not reclassified as terminal padding. A final
record may end exactly or have at most seven trailing bytes, each explicitly
checked to be zero. Every nonzero terminal byte and eight or more terminal bytes
deny. This is an A0 admission policy, not a claim that Windows guarantees zero
terminal padding or that all legal Windows output shapes are compatible.
Compatibility remains **PENDING**; a denied real shape requires STOP, not a retry,
permission change or silent parser relaxation. This stream rule does not add an
actual-length claim to the separate unchanged directory-enumeration API.

The metadata-only access masks stay `0x120080` for files and `0x1200a1` for
directories. The [Microsoft query contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntqueryinformationfile)
describes file/directory stream metadata. L0 proves only this candidate's source,
parser and fake behavior; actual support at those masks is PENDING. If the approved
one-shot observation cannot obtain complete metadata at the existing rights, STOP
for the smallest contract ruling. Never add READ_DATA, a path-based stream scan,
permission fallback or a second real attempt.

The reader uses parent-bound FILE_OPEN, attributes/READ_CONTROL/SYNCHRONIZE
only for files, LIST_DIRECTORY/TRAVERSE additionally for directories. It never
requests file READ_DATA, WRITE, DELETE, WRITE_DAC or WRITE_OWNER. All pins deny
delete sharing; history pins additionally deny write sharing during capture.
It preallocates all 13 ownership slots and the close delegate before OS access,
then reserves a slot before every open. A post-open allocation/inspection failure
therefore leaves its handle owned by the reverse-order, single-attempt cleanup;
unknown/throwing closes retain the first failure and are never retried. The
fake-only C# executables compile the shared owner plus the complete reader state
machine and bounded directory/stream parsers. The concrete Windows API adapter and
every P/Invoke declaration are excluded. Failure emits only fixed first-stage
and counters; partial facts are cleared. Later close failure cannot replace the
first stage; an unknown close is never retried.
It pins at most 13 file/directory objects, enumerates each controlled directory
twice (<=3 calls per enumeration, <=16 entries per page), and checks pinned
metadata a second time. Every owned handle gets one close attempt, with no
retry after uncertainty. Failed capture yields only a fixed stage/non-PASS;
there is no complete report or invented exact count on interruption.

The 30-second in-reader elapsed checks cannot interrupt a stuck syscall. The
separate supervisor candidate observes one independent Worker with a bounded deadline. Even
that cannot guarantee recovery from a system hang. Capture closes all pins and
reports CAPTURED_NOT_RUNTIME_APPROVAL; it cannot attest state after release.
Metadata queries may have OS auditing/access-time side effects; no forensic
promise that every OS metadata bit is untouched is made, and no timestamps are
written back to conceal observation.

### Runtime identity handoff design — BLOCKED pending implementation

1. A separately approved capture establishes observed IDs/security, checked
   against historical name/size expectations. Freeze and review that report;
   it is not automatic admission. Any new source/artifact/report invalidates
   the corresponding freeze/review until rechecked.
2. The later diagnostic runtime must consume a reviewed immutable identity
   map, open every pre-existing object without create, obtain the real exclusive
   writer lock, then compare its actual pinned identities before any store
   operation. Metadata lock handles held by an observer must first close once;
   compare the lock File ID again after native acquisition to detect substitution.
   Missing/unverifiable information denies, without a fallback to initialization.
3. Recheck before first mutation, between commits and before success. Freeze
   identities/security for parents/locks/history and all historical sizes/times.
   Model only the new runtime's two CREATE_NEW temporaries and associations.bin
   publication as allowed transitions; never broadly ignore new files or all
   directory timestamp changes. A read-back concerns only newly published
   synthetic ciphertext, never either historical file. Historical files continue
   to count against unchanged leftover/enumeration budgets.
4. A continuously pinned historical guard would require two additional handles.
   They cannot silently exceed the existing twelve-handles-per-App-owner limit
   or be disguised as existing owner pins. No such guard/extra-process budget or
   new cross-process coordination is implemented/authorized here. If repeated
   checks plus the existing accepted same-SID threat boundary cannot meet the
   reviewed preservation criterion, remain BLOCKED and request bounded design
   work; do not widen history permissions or relax the budget.
5. The current ABI does not import a frozen object map. The new metadata report
   and pure `Assert-Batch3SameSnapshot` seam do NOT implement this bridge. No
   runnable Host A binding is claimed; the real Runner unconditionally refuses
   Execute. §9.B.5's same-SID/Admin risk and check/close/rename window remain
   explicit; no snapshot or guard claims immunity to those actors.

### Bounded time, failure evidence and manual recovery

The standalone supervisor's start/identity conflation is repaired at G0-L0:
prestart operator confirmation is enforced before any launch or lease action,
start attempt and the actual `Start()` result are recorded before any identity
getter, each identity getter runs separately with first-failure quarantine, and
observation facts stay distinct from identity facts. Whether that repair closes
the original P2-2 finding is an independent review decision. A foreground
operator-controlled Owner with a bounded two-phase handoff is implemented as a
candidate; the receipt/holding windows and the at-expiry recovery consequences
remain **contract candidates pending an explicit ruling**, so no retention
budget is approved and `-Observe` stays BLOCKED.

`host_a_supervisor.ps1` is dry-run by default; `-Observe` additionally requires
`-OperatorConfirmed` and refuses before any freeze, launch or lease action
without it. It is eligible only for separate Batch 3-A0 authorization after
those blockers close and independent review. It freezes its own source, the pure
supervisor, worker, scope, both reader sources, policy and compiled
assembly before launching one independent Windows PowerShell x64 Worker. Script
execution must already be permitted by host policy; no execution-policy override
or bypass is provided. The preflight Worker loads only the frozen managed reader,
never the Native DLL. It checks `ReadOutcome`, emits a bounded redacted record on
inherited stdout and exits nonzero on incomplete/denied capture. The supervisor
does not buffer or parse stdout and cannot turn exit zero into report approval.
After the observation is frozen it runs the bounded operator handoff below and
prints the observation plus handoff records together; it exits zero only for a
timely exit-zero observation whose receipt and holding acknowledgment both
completed inside their candidate windows.

`worker_supervision.ps1` implements the same callback-driven observation used by
process-free fakes. The consumed lease prevents a second launch/observation even
when startup fails; an unconfirmed invocation consumes nothing and returns
`prestart_unconfirmed`. Attempted counts the launch attempt; StartReturned counts
the actual `Start()` result return (never an identity getter); StartSucceeded
requires true. A false launch is never a no-worker conclusion. Handle, PID and
creation-time acquisition run as separate ordered getters inside the same window:
the first failure quarantines the identity (`identity_failed`), stops all later
getters, sampling and waits, and retains the original process reference; a late
identity result is recorded but never accepted as complete (`IdentityComplete`
requires all three getters inside the deadline). Returned counts normal
exit-code callback return; Completed requires a well-formed exit code received
inside the deadline. None of these counts implies capture/identity approval.
States distinguish prestart, start false/unknown, identity failure, normal and
abnormal exit, observation failure and timeout. Preserve first failure, last
attempted stage, sample counts and PID/start-UTC ticks when obtainable.

Candidate observation deadline is 15s (maximum 30s), <=100ms wait slices and
<=301 polls. Worker and controller each have 256 MiB OS peak working-set and peak
pagefile/commit-use ceilings; sampled handle ceilings are 256 and 512 respectively.
The controller samples both processes before each wait and checks monotonic time
before/after startup, resource query, waiting and exit-code retrieval. Invalid
samples, clock anomalies or budgets stop immediately; no further wait/getter or
mode follows a detected failure. These proposed numeric ceilings require the
exact later grant. Handle counts are sampled, not OS high-water marks. Short-lived
process/sample races deny rather than invent a last measurement.

The candidate two-phase handoff adds a receipt window and a holding
acknowledgment window after the observation (candidate defaults 60s each;
candidate total owner-lifetime ceiling 150s). These numbers are candidates
pending the lifecycle ruling and approve no retention or resource budget. The
handoff phase never observes the worker again - no second wait, getter or sample -
performs no automatic action on any path (no close, dispose, retry, restart,
cleanup or termination), rejects late receipts/acknowledgments with the
monotonic clock, and therefore makes no full-lifecycle resource-budget claim for
a continued hold. A receipt without acknowledgment is not holding; a failed
handoff stays SettlementUnknown and is never reported as released or ready.

The callbacks and OS calls themselves cannot be forcibly interrupted. A blocked
launch, resource query, wait or getter may delay detection; this is not a hard OS
watchdog or system-hang recovery guarantee. At deadline/failure it stops observing,
never kills/retries/restarts/cleans/resumes. Settlement stays unknown even if a
later exit occurs. WorkerResourcesReleased is false on all uncertain results;
only timely observed OS exit and accepted exit-code retrieval can set it true
for process-owned resources. The controller's retained Process reference remains
owned; that flag is no Owner Close, capture-success or OS-stability acceptance.
The CLI keeps its script-local Process reference through the bounded handoff and
exits only with the handoff outcome recorded; PID/start time and inherited
Worker output stay locators/evidence, never ownership, and the earlier claim
that they were an operator recovery reference is withdrawn. P2-2 remains OPEN
pending the ruled lifecycle contract and independent review: the handoff
mechanics are implemented, but no post-observation holding period, operator
responsibility model, at-expiry recovery option or holding resource accounting
is approved, and an operator acknowledgment is not a cross-process ownership
transfer, a settlement or any bound on the worker's lifetime.

`bounded_wait.ps1` remains the original bounded-wait seam for probe candidates;
its clock/deadline checks include exit-code retrieval. It grants no probe launch.
The old synchronous Batch 3 probe Runner remains behind its unconditional runtime
identity gate and is not certified bounded by the metadata supervisor.

Proposed later batch ceilings: one batch <=60s, each probe <=15s, four modes
once, <=20 exported calls (3 ABI, 2 acquire, 2 Protect, 6 Begin, 3 Commit,
2 Abort, 2 Close), two temp creates/writes/flushes/publications maximum. Every
unexpected result stops earlier. Each probe retains 64MiB OS peak working set,
64MiB peak commit, 128 sampled process handles and <=12 native owner handles.
Inspector/controller memory and handles need their own separately approved
numeric budgets; do not hide their cost in the probe's figures or claim sampled
handles are an absolute OS maximum. A metadata application covers no probe call.

The supervisor never auto-kills, retries, cleans or resumes on timeout. At most
one Owner Close is attempted by a responsive owner; a stuck call cannot be
concurrently closed or claimed released. Preserve the first failure and last
attempt; missing summaries mean unknown actual totals. Block admission, retain
the owned process reference and tell the named operator that settlement is
unknown. Explicit termination authority, if later granted, applies only to that
identified candidate; OS process exit is not commit-success or manual-recovery
acceptance. Severe OS/driver/kernel instability requires the operator's approved
backup/recovery procedure, no reproducer or automatic reboot.

Before even a read-only preflight grant, name the backup-confirmation person,
recovery operator, restorable local backup/procedure, exact one-shot time window,
inspector/controller budgets and reporting destination. The agent has no backup,
restore, ciphertext-copy, termination or cleanup authority. Batch 2 files remain
preserved on every failure. A separate, later Batch 3 grant is still mandatory.
