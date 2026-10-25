# Contract CI timings, selective units and verified reuse

The contracts job retains the standing test list in
`.github/workflows/pr-contract-checks.yml`. Every executable entry must exist,
appear once and be assigned once by the existing `index % 4` split. Support
fixtures are not executable entries. Training/StudyActivity suites are standing
coverage even when a PR changes only production code.

The standing list also retains the AR-R6A External offline regression matrix:
every `test/application/external/` and `test/data/external/` suite, the
`generated_external_origin*` Proposal suites, the P11 authorization widget and
the repeatedly re-verified `rag_lazy`/Agent config-history suites. The contract
test requires those entries. That is offline Linux evidence for the accepted
P3-P12 behavior only; it is not Windows Credential, mTLS, ACL, Discovery or
Host acceptance and it clears no WINDOWS_PENDING item.

The App-owned relay adds standing framing/refusal, internal MCP client and App
exit/log-drain suites. These portable tests load no Windows relay DLL and do not
prove real Codex STAGE/Review or original-process settlement. The Windows native
job separately configures and compiles `windows/local_relay` with MSVC x64 and
the target's `/W4 /WX` settings; either command failing fails the job. It never
loads the DLL or opens a relay. Relay C++/headers require Native and Contracts;
its Dart FFI adapter and CMake configuration require all units. This compilation
coverage grants no runtime authentication or security admission.
The TLS source guard admits only the exact App-owned process consumer from MCP
section 17.12 and checks its imports, absent protected authority and original
closer. In-memory mutations retain rejection of protected startup, TLS imports,
authority fabrication, forced process termination, missing drain and formal AOT
business selection. Every other process-consumer restriction remains in place.

P22 adds pairing transcript, exchange payload, Discovery descriptor and source
guard suites to the same manifest. Static checks and contract shards run
independently: shards consume no Static job outputs. Each shard scans the
inactive source boundary before the stdlib-only independent Python
framing/SHA-256/P-256 vector verifier and Flutter tests. Fixed public
RFC6979/P21 vectors exercise no real Windows crypto, file publication,
Discovery directory, pairing or transport. The Python helper only reads
repository fixtures and verifies public signatures; it never signs or creates
keys. This is offline evidence, not runtime trust or G0-I acceptance.

The chained P27 source guard admits only the exact dormant
`lib/composition/bridge_ui_host.dart` from MCP section 17.8. It checks that host's
imports and rejects native acquisition, a second Pairing owner and business
authority. Every other `lib/` source, including the existing dormant startup and
acquisition roots, still rejects a Bridge UI host consumer. The Bootstrap gate
always runs the P27 guard's in-memory mutation self-tests; it never edits source
inputs or starts a host to check these boundaries.

Package 2 adds `windows_tls_transport_test`, `windows_peer_certificate_policy_test`
and `windows_tls_source_guard_test` once in those same shards. The existing
bootstrap gate chains `check_tls_source.ps1`; the Native job compiles/inspects
the optional certificate-only ABI-3 export and crypt32 imports, then runs the
pure decoded-policy Fake core without linking or loading crypt32/the helper.
P0/P8/P9/P10/P15/P20/P26/P27 direct regressions retain their existing suites,
including all ten P10 typed routes. TLS tests inject channels, clocks and
deadlines; real BoringSSL/crypt32/WinSock/resource/close behavior stays
WINDOWS_PENDING. These gates never bind or connect a Socket or start a Host.

P18 adds `windows_external_native_test.dart` and
`external_native_source_guard_test.dart` to the same standing shards. The first
uses test-only calls and a C-runtime allocator to check ABI rejection, bounded
copies, release paths and fixed failures; the second guards the actual C++/Dart
implementation, frozen DPAPI parameters and absent runtime wiring. Neither
loads the production helper or performs Windows security calls. Native x64
compilation/export inspection and the fake-only C++ core suite are local G0-L0
evidence; these Linux shards cannot establish Windows compilation or real
DPAPI/protected-object behavior. P19 also adds the hard-failing Windows native
offline job to the aggregate check: the independent helper compiles with MSVC
x64, exact exports/system imports are inspected and both fake-only core suites
run after their imports are checked for absent real security/file operations.
The production DLL is never loaded by that job. P19 extends the existing Dart
suites for protected-owner acquisition, contention, permanent denial and explicit
release. These are compilation/offline evidence; LOCAL-L1 remains PENDING.

P20 adds `association_object_codec_test.dart` and
`windows_credential_association_store_test.dart` to those same hard-failing
shards. The Windows job also links the production association-file transaction
core into the existing fake-only object executable, checks twelve ABI exports,
actual ASLR/DEP/CFG flags and file-operation imports in the production DLL,
and rejects those imports in both offline executables before running them.
It never loads the production DLL or creates real protected objects. Codec/CAS/
snapshot/TOCTOU/commit-failure evidence remains G0-L0, not DPAPI/NTFS/lock or
cross-SID acceptance.

The four shards keep `--concurrency=1`. Flutter's additional JSON reporter
collects timing in the same test invocation, without running tests twice. The
summary script retains only repository-relative test paths, integer durations,
completion counts and success status. Raw events may include test messages and
remain runner-local; only the sanitized per-shard summaries are uploaded, for
seven days. Suite spans include loading/setup/teardown and are not CPU profiles.
A parser or redaction failure stays fatal, but the artifact upload itself is
advisory: an artifact-service problem cannot fail a shard whose tests passed.

## Verification units and selective execution

`resolve_ci_impact.py` and `impact_rules.json` produce one plan per run. The
plan binds the event Head/Base, the unique merge base, the actual tested merge
commit, the rule digest, the workflow digest, the pinned input blobs and a
content digest of every tracked entry except the ordinary-document allowlist.

| Unit | Job | Executes when |
|---|---|---|
| G | Change impact analysis | Every event; also plan, safety checks and reuse resolution |
| S | Static changed-Dart checks | A changed input requires Dart verification |
| N | Windows native offline contracts | Native C++/header/C# or acceptance material changed |
| T | TRAIN C finalization parity | Dart, TRAIN C tools or shared configuration changed |
| C | Contract shard 1-4 | Any unit that owns standing contract coverage is required |
| V | Changed Dart and focused contracts | Every event; fail-closed aggregate |

`acceptance_material` maps to `windows_native`, because the only consumer of the
acceptance plan and preparation guide is `check_acceptance_readiness.ps1`,
which `windows/external_native/check_offline.ps1` executes in that job. The
always-on impact job also runs the same checker's self-test. The contract shards
never read those files, so routing them there was incorrect in the shadow phase.

| Changed input | Minimum units |
|---|---|
| Only a root `README.md` content edit | G, V |
| Dart under `lib/`/`test/`, TRAIN C tools | G, S, T, C, V |
| Native C++/header/C# source or tests | G, N, C, V |
| Native Dart bindings/adapters | G, S, N, T, C, V |
| Acceptance plan or preparation guide alone | G, N, V |
| Any other Markdown, including security/diagnostic docs | Full: G, S, N, T, C, V |
| Workflow, classifier, Source Guard, lockfile, toolchain or checker configuration | Full |
| Unknown path, unsafe path/type, base divergence, unavailable diff, empty diff | Full or hard FAIL |

The ordinary-document allowlist contains only root `README.md`, and only an
in-place content edit (`M`, mode `100644` on both sides) uses it. Additions,
deletions, renames, symlinks and executable-mode changes execute everything.
Local inline Markdown references are validated against the tested Git tree
without network access. Angle-bracketed destinations may contain spaces; a bare
destination with a space is ambiguous with an optional title, so it widens to
full validation instead of guessing. Reference definitions and unknown trailing
tokens also widen. Security Markdown cannot be overridden by a permissive route,
and source contents are never used to infer harmless comment-only edits.

The workflow consumes the plan through named job outputs, but the aggregate does
not trust those booleans. `verify_ci_plan.py` re-reads the uploaded
`ci-impact-plan` artifact, checks its SHA-256, binds it to the checked-out
commit and event, recomputes classification from Git, requires every required
unit to be `EXECUTE` or recorded `REUSE` (never silently `NOT_APPLICABLE`),
revalidates every reuse claim, compares each GitHub `needs.<job>.result` with the
planned status, and, when contracts execute, requires exactly the four
`Contract shard N/4` jobs with `success`. When the workflow result for contracts
is already `success`, a shard observation that still reads back pending is
re-read for up to about one minute before the aggregate fails closed; membership
mismatches and a persistently unsettled matrix still fail. Missing or malformed
evidence fails the aggregate. GitHub `skipped` is accepted only for
`NOT_APPLICABLE` or verified `REUSE` units.

## Verified cross-head reuse

Reuse targets one narrow case: a code PR that already passed this workflow, then
received only ordinary root-`README.md` content edits, with no other input
change. Only S, T and C may be reused. N always re-executes. A reuse claim is
never a cached PASS; it is a revalidated statement that the two heads have the
same verification inputs.

All of the following must hold, otherwise every unit executes:

1. Source is a successful `pull_request` run of this repository, this workflow and
   this PR's head branch; the source head is in this PR's history and the recorded
   Base matches. Forks, other branches and a different Base are ignored. GitHub
   may omit the `pull_requests` array for same-repository runs; when present it
   must match.
2. The source head is an ancestor of the current head.
3. Source Base and merge base equal the current ones; base divergence executes
   everything.
4. Each reused unit really executed in the source attempt with conclusion
   `success`; a unit whose source status was itself `REUSE` is rejected.
5. Apart from the ordinary README allowlist, the tracked tree, contents, modes
   and pinned-input blobs are identical; the whole source-head-to-head delta must
   consist of ordinary README edits.
6. Workflow, classifier, verification scripts, lockfile and dependency
   configuration digests are identical.
7. Linux runner image/version and the pinned Flutter revision are identical and
   both recorded; an empty toolchain identity is unverifiable and executes.
8. The source run/attempt, job identities and the uploaded plan artifact are
   cross-checked, and the artifact SHA-256 matches.
9. The artifact is unexpired and independently re-readable at gate time.
10. The source is not a fork.

Any other condition, including a change to CI inputs in the cumulative PR,
refuses reuse with a fixed code (`no_source_run`, `source_not_ancestor`,
`base_changed`, `delta_not_ordinary`, `inputs_changed`, `toolchain_changed`,
`toolchain_unverified`, `evidence_missing`, `evidence_expired`,
`evidence_mismatch`, `source_used_reuse`, `source_not_successful`,
`attempt_mismatch`, `shard_mismatch`, `fork_source`, `ci_inputs_changed`,
`api_unavailable`) and executes the affected units. Ambiguous evidence (for
example a re-run that leaves more than one plan artifact) is treated as missing
evidence. A PR that modifies the workflow or classifier therefore never reuses,
because the new machinery has not itself been accepted. `reuse.status` and its
source run/attempt, artifact and evidence digests are recorded in the plan and
re-checked by the aggregate.

## Full regression, concurrency and observability

Full validation runs unconditionally for `master` branch pushes, manual
`workflow_dispatch`, the weekly `schedule` (Monday 04:00 Asia/Shanghai, Sunday
20:00 UTC), workflow/classifier/checker/lockfile/toolchain changes, base
divergence, unknown inputs, unsafe paths and unavailable diff evidence. There is
no workflow-level `paths-ignore`.

Pull request, push, manual and scheduled runs keep separate concurrency
namespaces: `review` for PR/manual, `push` for branch pushes and `schedule` for
the weekly run. Only pull requests and pushes cancel superseded work; manual and
scheduled runs queue instead of cancelling a required PR run. A branch push and
an equivalent PR run can share the same branch name, so they must not share a
group.

The aggregate writes `ci-execution-report.json` with each unit's planned status,
GitHub result and duration, the contracts shard membership, the reuse source and
the executed/not-applicable/reused counts, plus elapsed run time when the API is
available. It is uploaded for seven days. The job summary repeats the same
facts. The report never contains source contents, prompts, raw API bodies or
absolute paths.

`resolve_ci_impact.py` and `resolve_ci_reuse.py` use only the Python standard
library and read-only Git/API calls. The plan and evidence artifacts contain
target SHAs, digests, counts and fixed codes. Missing observation artifacts never
authorize skipping; the aggregate fails when the plan is absent.

Shard ordering is calibrated from sanitized Linux timings. Five comparable runs
(39022713883, 39022413882, 39020919476, 39020883651, 39019297482) gave per-suite
medians and five cross-shard swaps: median shard sums moved from
234.8/245.5/266.6/184.6 s to 232.9 s each (slowest shard -12.6%), and the
slowest shard improved in every run under that run's own per-suite times
(3-29 s). Membership, the modulo split, `--concurrency=1`, job names and the
failure gate are unchanged. The section comments in the list describe coverage
groups, not contiguous ranges. Windows fixture timing is useful locally but does
not replace Linux evidence.

Post-change runs measured 315.6/190.5/244.7/224.1 s (run 39028083483); recomputing
that run's per-suite times under the previous order gives
318.1/202.8/255.5/198.5 s. The median balance is stable, but a single suite
deviating from its median (99 s against a 65 s median) dominates that run, so
end-to-end gains vary and the contracts job remains the critical path.

Prefer one automatic PR run for normal delivery. Manual dispatch is for explicit
calibration/debugging, not a mandatory run before creating every PR. Required PR
checks still run normally, including after merges on master.

The impact job additionally executes Bootstrap and both Windows Source Guard /
Acceptance Readiness SelfTests on every event. Their existing Native-job calls
and each shard's source/vector checks remain in place. No G0-L1/L2 experiment,
production DLL loading or Host activation is added.
