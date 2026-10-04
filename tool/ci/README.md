# Contract CI timings and coverage

The contracts job retains the standing test list in
`.github/workflows/pr-contract-checks.yml`. Every executable entry must exist,
appear once and be assigned once by the existing `index % 4` split. Support
fixtures are not executable entries. Training/StudyActivity suites are standing
coverage even when a PR changes only production code.

The four shards keep `--concurrency=1`. Flutter's additional JSON reporter
collects timing in the same test invocation, without running tests twice. The
summary script retains only repository-relative test paths, integer durations,
completion counts and success status. Raw events may include test messages and
remain runner-local; only the sanitized per-shard summaries are uploaded, for
seven days. Suite spans include loading/setup/teardown and are not CPU profiles.

Use recent Linux summaries to reorder the array for comparable shard loads;
keep its membership, modulo split, job names, test semantics and failure gate.
Predicted totals are estimates; verify actual shard times after the change.
Windows fixture timing is useful locally but does not replace Linux evidence.

Prefer one automatic PR run for normal delivery. Manual dispatch is for explicit
calibration/debugging, not a mandatory run before creating every PR. PR and
manual runs on the same repository/branch now share a concurrency group;
fork repositories stay separate. Automatic runs can cancel stale work, while a
manual dispatch queues instead of canceling a required PR run (whose merge ref
may differ from the branch head). Cancellation prevents overlapping stale runs,
not a second run started after the first has completed. Required PR checks still
run normally, including after merges on master.
