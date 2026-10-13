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
