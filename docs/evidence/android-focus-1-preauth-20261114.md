# ANDROID-FOCUS-1 preauthentication failure settlement

Executor evidence, 2026-11-14 Asia/Shanghai. This record covers the bounded source
change and isolated Windows resources. It records no real-device recovery or
V3–V5 acceptance. Repository/global status: NOT_EVALUATED.

## Target and authority

New independent task. The user explicitly authorized fetch, safe default-branch
fast-forward, a dedicated branch and an in-repository isolation worktree. Live
origin HEAD identified master at `90a2e05828f4bf903458d075b56ba14c606b8c4d`.
Fetch and a repeated remote query confirmed it; local master was behind by one
commit and safely fast-forwarded to that exact commit before branch creation.
An intermediate read-only remote query failed with a TLS connection error; the
subsequent query succeeded before implementation. Branch:
`codex/link-preauth-failure-settlement`, worktree:
`.codex-worktrees/link-preauth-failure-settlement`.

The original dirty ANDROID-FOCUS-1 checkout, `.workbuddy/`, scratch archives and
real slots were preserved. Only existing evidence under
`scratch/preserved-20261113/build-dirs/` was read for the historical audit. No
true slot file, saved key, phone, pairing, Android installation or V3–V5 run was
opened, modified or cleaned.

## Behavior and limits

Unified access §6.2.2 owns the new local version-1 protocol. Normal success
receipts, Android link protocol, v1 address update and v2 sealed routing retain
their existing meanings.

- A: refusing a missing/invalid executable **before invoking Process.start**
  records the original no-process fact. A launch attempt returning
  ProcessException or another exception remains uncertain/DIRTY. An already
  started adapter that acquired no CNG/network resources needs its own receipt,
  exact creation identity, reserved failure exit and original three-stream join.
- B: original TCP connection failure or silent-peer TLS establishment deadline
  can produce independent failure settlement after successful original
  SslStream/TcpClient disposal, exact CNG deletion/absence verification, handle
  disposal, original marker validation/removal and all pending checks.
- C/D: any peer-certificate observation, completed TLS/HELLO/offer/proof,
  business/remote outcome uncertainty, partial CNG import, cleanup failure,
  pending, missing/mismatched/corrupt record, wrong PID/start/owner, failed exit,
  missing original event or incomplete/erroring stream remains DIRTY.

The resource receipt is never authenticated/settled success or Android Enable.
The original supervisor independently publishes its bound join only after exit
80 and every original stream completes. Normal success still requires exit 0.
The new control action requires an explicit state revision; no MCP recovery tool
or retry loop exists. Recovery preserves the original generation and historical
identity and leaves prepared/ready false. A new explicit connect and the phone's
original PREPARING/Enable remain necessary.

A per-resource immutable recovery intent retains both before/after state and
custody snapshots. State CAS precedes custody CLEAN, so failed state publication
retains original DIRTY custody. Interruption between them still blocks connect;
only explicit exact-intent completion is supported. Missing/partial pending
records are retained, never reconstructed or deleted. Publication failure latches
the current instance; validation failure, including stale revision, does not.

## Historical read-only audit

These are classifications of the retained evidence, principally recorded on
2026-11-09. They are **not a live status revalidation** and grant no recovery
authorization. Archived summaries/digests cannot substitute for absent original
run/resource/start identities or original supervisor observations.

| Slot | Verdict | Original identity and receipt evidence | Irreplaceable gap / condition |
| --- | --- | --- | --- |
| focusd01 | INSUFFICIENT_EVIDENCE | Retained snapshot reports LINK_OWNED/DIRTY, recoveryRequired/unknown, PID 7708; formal business receipt does not match that owner, no matching pending reported. Full owner generation/run/resource/start bytes are not present in the opened summary. | Need the exact failed original owner/resource tuple, matching trusted original settlement and original process/three-stream join. Neither the older business receipt nor later successes prove TLS/CNG closure of this failure. Cannot assign A/B or recover from these summaries. |
| focusv34501 | BLOCKED | Snapshot reports original business PID 45540, LINK_OWNED/DIRTY, recoveryRequired/unknown; formal enable-proof receipt mismatches, a business pending receipt matches the original owner. Preparation evidence also recorded the historical Link still running then. | Matching pending is an explicit incomplete publication obstacle, not a formal receipt or supervisor join. Need original published business settlement and original exit/three-stream evidence, plus explanation/closure of the prior publication failure. General business recovery is outside this change. No current liveness claim is made. |
| focusv34504 | INSUFFICIENT_EVIDENCE | Retry result reports recoveryRequired/owner_unsettled, PID 16824, no lease/pending, formal enable-proof receipt mismatching the retry owner. Earlier adoption and baseline proof were clean. Full retry owner generation/run/resource/start and complete original cleanup/join are absent from the opened result. | Need the original retry's exact tuple, pre-TLS facts, actual TLS/socket/CNG closure and original exit/three-stream join. Earlier clean adoption/proof and no pending/lease cannot fill these gaps. No retroactive version-1 receipt may be manufactured. |

No slot is RECOVERABLE on the available evidence. The new implementation does
not retroactively settle these runs or promote a pending receipt. In particular,
it does not infer the historical PID 45540 exception from a different successful
publication or later probe.

Opened source evidence (paths relative to the preserved build-dirs root):

- `android-focus-1-20261109-pr365/historical-before.json` and
  `historical-after.json`: identical bytes and parsed snapshots; SHA-256
  `6455d119d3d03621c71a1152f084244f6ecbf064be98fb17355882b517a03d9a`.
- `android-focus-1-20261109-pr365/PREPARATION.md`: SHA-256
  `38bd0441afc8c9513dd53ebee8001e5c1c3ea376a65c79c978d0dfbc49e21694`.
- `android-focus-1-20261109-pr365-focusv34504/proof-retry-result.json`: SHA-256
  `3c6383c8ae45becc5ceb646b41931b4d28644c3b684003a42545d3f27c8d79b0`.
- Same directory, `baseline-proof.json`: SHA-256
  `9466e2f6e0883a0601d5312f5ebe1ddba3e34aee6add95aa976b9aa1086aa93e`;
  `adoption-clean-check.json`: SHA-256
  `2e40409b282d87b56073d71828363fa075c911d1b5de778654dd2f02319c7774`.

## Validation and independent gates

PASS: 258 focused cases across the six suites below, including 52 new failure
settlement cases and eight explicit Windows resource/supervisor cases. Debug and
Release .NET builds and the Release synthetic boundary tests passed. Five-file
Dart format gate, focused analysis, standing-suite/timing coverage guard and
`git diff --check` passed. Logs remain in the isolated worktree's ignored build
directory (`link-preauth-acceptance-final.log`, `link-preauth-native-final.log`). Commands:

```text
dotnet build tool/android_device_adapter/AndroidDeviceAdapter.csproj --no-restore --nologo
dotnet build tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Release --no-restore --nologo
dotnet run --project tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Release --no-build -- --self-test
flutter test --no-pub --concurrency=1 --dart-define=LINK_PREAUTH_NATIVE=true test/data/external/link_preauth_failure_test.dart test/data/external/link_runtime_test.dart test/data/external/link_state_store_test.dart test/data/external/link_initialization_test.dart test/data/external/link_architecture_test.dart test/mcp/link_frontend_test.dart
dart format --output=none --set-exit-if-changed <the five changed Dart files>
flutter analyze --no-pub <the five changed Dart files>
tool/tests/ci_contract_timings_test.ps1
git diff --check
```

The explicit Windows fixture uses actual disposable current-user CNG imports,
local TCP/TLS acquisition, failure, disposal, original process identity and Link
supervision. Socket/TLS/CNG error injections occur after actual acquisition;
CNG retirement injection deletes its own generated key then reports failure,
retaining pending/unknown rather than leaking a test key. No saved credential is
loaded. The fixture command is Debug-only and absent from Release. It does not
exercise production native-parent admission/DPAPI composition or an Android
endpoint. Portable negatives do not substitute for these Windows observations.

Standing CI registers the portable suite; its opt-in Windows resource cases are
not Linux-CI evidence. Verifier requirement: **REQUIRED / CI_COVERAGE_GAP**.
Bounded targets: independently rerun the current-head isolated Windows resource
and supervisor matrix, check generation/revision and interruption refusal, and
confirm the historical conclusions remain evidence-limited. No real historical
slot, saved credential or phone is authorized by that target. Independent semantic
Reviewer and current-head/current-base PR contract checks remain required.

The initial fixture expected immediate TCP refusal; the Windows run observed a
pre-TLS TCP deadline, so the fixture now checks the actual TCP boundary. An added
repeat/stale-revision regression exposed an overbroad publication-failure latch;
it was repaired by a dedicated publication-failure result, preserving stale
validation refusal without blocking a subsequent explicit connect. Launch
exceptions were conservatively excluded from no-acquisition authority. The
existing prohibition on generic recover remains intact through the specific
recoverPreauth API. Final diff inspection also caught a recovery control frame
carrying a routing-only field; the command encoder and its protocol regression
now keep recovery revision separate from refresh-address input. No acceptance check was weakened. Semantic self-repair cycles:
4/4 (conservatively including the fixture/boundary and control-frame corrections); review repair
rounds: 0/4.

## Conditions before V3–V5

This change prevents missing failure-settlement authority from permanently
blocking future A/B failures **when all original evidence is captured**. C/D,
missing supervision and the historical gaps above intentionally continue to
block. It promises no universal TLS-timeout recovery.

1. Complete current-target CI, independent Reviewer and required bounded Windows
   verification; merge only with explicit merge authority.
2. Separately authorize a specific existing installation/slot and real-device
   operations. This assignment grants none. Any historical recovery needs
   sufficient original evidence and its own explicit authorization; otherwise
   keep those slots preserved and blocked.
3. Before new connection, obtain a legitimately CLEAN selected slot under the
   original owner, matching required records and no unresolved pending; never
   clear a historical slot or create a replacement owner to satisfy this step.
4. Explicit phone PREPARING, successful original proof/settlement and finite
   Enable; then a fresh real Codex READ baseline, matching business receipt,
   original output/process/three-stream joins and final CLEAN.
5. Only then execute the separately authorized V3 notification/split-screen,
   V4 new-session READ and V5 background/lock matrix with unchanged expiry,
   original identities and bounded evidence. Isolated PASS proves none of these.

## Round-1 review repair amendment (2026-11-14)

Post-delivery amendment; the original record above is preserved unchanged as
the pre-repair historical evidence. Round-1 independent review
(`[REVIEW REQUEST_CHANGES]` on head `6cefb8b224b8f67fe7093e87ddd41a1972680995`)
reported one P2: the recovery publication-failure latch was consumed by a
skipped journal callback, allowing a later disconnect diagnostic to rewrite
custody/state revisions and permanently mismatch the immutable recovery intent.

Repair commit `1d1f3e8a4c87fbca5c538bfc9f71d7c217c61f0f` adds a durable
`_preauthPublicationFailed` instance flag checked before any runtime record, so
no state/custody write follows a recovery publication failure and the preserved
scene stays exactly completable by a new instance. It adds one portable
regression (publication failure -> refused attach/disconnect activity -> exact
scene preserved -> fresh instance completes the retained intent). No acceptance
check was weakened; no C# or contract change was needed.

Superseding counts and status:

- Focused suite total is now 259 cases with 53 new failure settlement cases
  (the original 258/52 plus this regression); the eight opt-in Windows
  resource/supervisor cases are unchanged.
- Portable rerun at the repair head: 251 passed, 8 skipped (the opt-in Windows
  group), six suites, serial. The opt-in Windows matrix was not rerun by the
  Executor at this head; it remains the required bounded Verifier target.
- Review repair rounds: 1/4. Round-2 closure review recorded `[REVIEW APPROVAL]`
  on head `1d1f3e8a4c87fbca5c538bfc9f71d7c217c61f0f` with zero open P0/P1/P2;
  `PR contract checks` run 43575226400 succeeded on that head and base
  `90a2e05828f4bf903458d075b56ba14c606b8c4d`.
- The candidate SHA in the PR summary predates this repair; formal role evidence
  comments carry the actual reviewed heads. Verifier requirement remains
  REQUIRED / CI_COVERAGE_GAP on the current head.

## Round-2 owner-identity timing repair amendment (2026-11-14)

Post-delivery amendment; the records above are preserved unchanged. A bounded
verification task examined the race between `LinkAdapterProcess._event(owner)`
and native `shiroha_link_process_current`: when the adapter exits 80 before the
supervisor processes the owner event, `OpenProcess` on the retired PID fails
(`ERROR_INVALID_PARAMETER` -> 0) or `WaitForSingleObject` returns `WAIT_OBJECT_0`
-> 0, so `_processIdentityVerified` stays false and a valid supervisor join is
refused. The original Windows fixture hid this with an explicit mid-run stdin
wait; the production adapter had no such barrier.

Repair (no admission relaxation): the enable-proof adapter now drains stdin to
EOF before every exit (`Program.ProofExit`, fixture included), and the proof
supervisor withholds EOF until owner-identity capture or observed exit
(`_ownerCaptured` barrier in `_closeInput`). Creation identity is therefore
always checked against the live original process; strict PID, creation, exit-80
and three-stream checks are unchanged. The fixture's artificial mid-run wait was
removed in favor of the production barrier. Contract §6.2.2 and tool/link/README
record the EOF barrier.

New deterministic Windows regression `delayed-supervisor`: stderr is withheld
until a fixed interval after launch (exit-gated delivery would deadlock the
barrier), and identity is queried only via live-process `OpenProcess`/
`GetProcessTimes`. Without the barrier the no-acquisition adapter exits first
and the join must be refused; with it, identity capture precedes EOF and exit,
and recovery completes. The scenario was first observed failing on the receipt
classification branch (fixture acquired resources incorrectly), repaired within
this assignment, then passing.

Executed at this amendment's candidate head:

- PASS: Debug and Release .NET builds; Release synthetic self-test (38 checks).
- PASS: portable six-suite serial run, 251 passed / 9 skipped (the opt-in
  Windows group).
- PASS: opt-in Windows native matrix (`LINK_PREAUTH_NATIVE=true`), all nine
  resource/supervisor scenarios including `delayed-supervisor`, 54 passed.
- PASS: read-only two-file Dart format gate, focused analysis, `git diff --check`.

Superseding counts: 260 focused cases with 54 new failure settlement cases and
nine opt-in Windows scenarios. Review repair rounds: 2/4 before this round.
The Executor ran the isolated Windows matrix at this head; the independent
Verifier requirement (REQUIRED / CI_COVERAGE_GAP) is unchanged and still needs
its own bounded pass on the final head. No real slot, saved credential or phone
was accessed.

## Round-3 rejected/missing owner EOF repair amendment (2026-11-14)

Same-PR bounded repair of the user-supplied latest review on
`a1e1c53f01128805238d597ee72cc6bf08119d95`; prior evidence is preserved.
Task-start remote inspection confirmed PR #368 OPEN, source
`codex/link-preauth-failure-settlement`, base
`90a2e05828f4bf903458d075b56ba14c606b8c4d`, and that exact local/remote head.
The existing task worktree was clean and reused; the original dirty checkout
was left untouched. No fetch, default alignment or branch creation was needed
for this same-PR repair.

The reported P2 is reproducible: a fake original proof process emits an invalid
owner then waits for stdin EOF before exit, matching production `ProofExit`.
Before the fix, the new regression failed with a two-second TimeoutException
instead of the required `owner_unsettled` rejection. The supervisor waited for
owner capture/exit while the adapter waited for the supervisor's EOF.

The supervisor now latches failure and releases the owner wait immediately on
event rejection, stream error/limits or stderr EOF without an owner. A silent
owner wait expires after eight seconds and follows the same failed EOF path.
Only the additional owner barrier is bounded: original process exit and all
three actual stream joins remain mandatory; EOF release is no cleanup proof
and does not kill a process. A later valid owner or complete failure receipt
cannot clear the failure or publish normal adapterJoined/preauth supervisor
join evidence. Successful live identity capture and the existing PID, creation
identity, exit-code and stream requirements are retained.

Ten new portable cases cover missing/invalid owner, a valid owner after
rejection, stderr failure/EOF/overflow/invalid UTF-8, stdout failure, silent
stderr and a valid owner delivered after the deadline. Each requires bounded
connect/close rejection, retained DIRTY custody, prepared=false, no supervisor
join/adapterJoined, and refused recovery despite a complete adapter receipt.
Three additional Debug-only Windows fixture scenarios (missing-owner,
invalid-owner, silent-stderr) return through production `Program.ProofExit`;
the original process must exit 80 after EOF within the bound, while preserving
the same rejection invariants. The prior delayed-supervisor positive and all
original resource scenarios still pass. Production C# behavior is unchanged;
only its barrier comment and the Debug fixture change. Governing unified
access §6.2.2 and the Link README now describe failure-only EOF release.

Executed on this repair's final source:

- PASS: the six-suite serial command below, **273 passed**, no skips, including
  **12 Windows original-resource/supervisor scenarios**. The preauth suite now
  contains 67 cases. Log: ignored `build/link-preauth-round3-tests.log`.
- PASS: .NET Debug and Release builds, zero warnings/errors; Release self-test,
  38 synthetic checks.
- PASS: read-only two-file Dart format gate, focused analysis, Link architecture
  tests (included in the six-suite run), standing-suite/timing guard, diff check
  and final scope inspection.

```text
dotnet build tool/android_device_adapter/AndroidDeviceAdapter.csproj --no-restore --nologo
dotnet build tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Release --no-restore --nologo
dotnet run --project tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Release --no-build -- --self-test
flutter test --no-pub --concurrency=1 --dart-define=LINK_PREAUTH_NATIVE=true test/data/external/link_preauth_failure_test.dart test/data/external/link_runtime_test.dart test/data/external/link_state_store_test.dart test/data/external/link_initialization_test.dart test/data/external/link_architecture_test.dart test/mcp/link_frontend_test.dart
dart format --output=none --set-exit-if-changed lib/data/external/link/link_adapter_process.dart test/data/external/link_preauth_failure_test.dart
flutter analyze --no-pub lib/data/external/link/link_adapter_process.dart test/data/external/link_preauth_failure_test.dart
tool/tests/ci_contract_timings_test.ps1
git diff --check
```

This bounded assignment's semantic self-repair cycles: **0/4** (the expected
pre-fix regression failure is reproduction evidence). Cumulative review-repair
rounds for PR #368: **3/4**, retaining the two previous rounds. No check was
weakened. Coupled paths are the existing Debug Windows fixture, barrier comment,
governing contract, usage documentation and this execution evidence.

Verifier requirement remains **REQUIRED / CI_COVERAGE_GAP**: standing Linux CI
covers portable rejection but cannot exercise original Windows process/EOF,
CNG and stream behavior. The independent bounded target must include the
current-head twelve-scenario matrix (especially missing/invalid owner and silent
stderr, alongside delayed-supervisor) and the existing revision/interruption
refusals. These Executor results are not independent verification. Production
native-parent/DPAPI and real-device/V3–V5 acceptance are NOT_RUN; no historical
slot, saved credential or phone was accessed. Current-target standing CI and
fresh independent semantic review remain pending after authorized push; no
merge or PR metadata/evidence-comment mutation is part of this repair.
