# Contract CI timings and coverage

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

P22 adds pairing transcript, exchange payload, Discovery descriptor and source
guard suites to the same manifest. Static checks and contract shards run
independently: shards consume no Static job outputs. Each shard scans the
inactive source boundary before the stdlib-only independent Python
framing/SHA-256/P-256 vector verifier and Flutter tests. The final
`Changed Dart and focused contracts` job still requires Static, every contract
shard, TRAIN C parity and Windows Native success; failed, cancelled or skipped
checks cannot satisfy that gate. Fixed public RFC6979/P21 vectors exercise no
real Windows crypto, file publication, Discovery directory, pairing or
transport. The Python helper only
reads repository fixtures and verifies public signatures; it never signs or
creates keys. This is offline evidence, not runtime trust or G0-I acceptance.

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

Use recent Linux summaries to reorder the array for comparable shard loads;
keep its membership, modulo split, job names, test semantics and failure gate.
Predicted totals are estimates; verify actual shard times after the change.
Windows fixture timing is useful locally but does not replace Linux evidence.

Prefer one automatic PR run for normal delivery. Manual dispatch is for explicit
calibration/debugging, not a mandatory run before creating every PR. Pull request
and manual runs on the same repository/branch share one `review` concurrency
namespace, while `push` runs use a separate `push` namespace: a push checks the
branch head and a pull request checks the merge ref, yet both can carry the same
branch name, so one shared group would let a branch push cancel a required PR run
or queue behind it. Fork repositories stay separate. Automatic runs can cancel
stale work inside their own namespace, while a manual dispatch queues instead of
canceling a required PR run. Cancellation prevents overlapping stale runs,
not a second run started after the first has completed. Required PR checks still
run normally, including after merges on master.
