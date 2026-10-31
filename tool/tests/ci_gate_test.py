"""Fail-closed aggregate gate regressions: plan identity, reuse and matrix semantics."""

from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[2]
IMPACT_SPEC = importlib.util.spec_from_file_location("ci_impact", ROOT / "tool/ci/resolve_ci_impact.py")
impact = importlib.util.module_from_spec(IMPACT_SPEC)
sys.modules[IMPACT_SPEC.name] = impact
IMPACT_SPEC.loader.exec_module(impact)
REUSE_SPEC = importlib.util.spec_from_file_location("ci_reuse", ROOT / "tool/ci/resolve_ci_reuse.py")
reuse = importlib.util.module_from_spec(REUSE_SPEC)
sys.modules[REUSE_SPEC.name] = reuse
REUSE_SPEC.loader.exec_module(reuse)
GATE_SPEC = importlib.util.spec_from_file_location("ci_gate", ROOT / "tool/ci/verify_ci_plan.py")
gate = importlib.util.module_from_spec(GATE_SPEC)
sys.modules[GATE_SPEC.name] = gate
GATE_SPEC.loader.exec_module(gate)
RULES, DIGEST = impact.read_rules(ROOT / "tool/ci/impact_rules.json")
RUNNER = {"ImageOS": "ubuntu22", "ImageVersion": "20261001"}
# The gate reads the wall clock unless a test injects one. A fixture that pins a
# literal expiry date therefore starts failing on a day nobody chose, so every
# reuse fixture derives its timeline from this single injected instant.
NOW = datetime(2026, 10, 17, 12, 0, tzinfo=timezone.utc)
EVIDENCE_EXPIRES_AT = (NOW + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
WORKFLOW_TEXT = """name: fixture
jobs:
  contracts:
    steps:
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.41.9
"""
SHARDS = [f"Contract shard {index}/4" for index in range(1, 5)]


class FakeApi:
    def __init__(self, jobs=None, run=None, artifacts=None, blobs=None, runs=None):
        self.jobs = jobs or {}
        self.run = run or {"run_started_at": "2026-10-17T10:00:00Z"}
        self.artifacts = artifacts or {}
        self.blobs = blobs or {}
        self.runs = runs or []

    def list_runs(self, workflow, branch):
        return self.runs

    def list_jobs(self, run_id, attempt):
        return self.jobs.get((run_id, attempt), [])

    def get_run(self, run_id):
        for run in self.runs:
            if run.get("id") == run_id:
                return run
        return self.run or {"run_started_at": "2026-10-17T10:00:00Z"}

    def list_artifacts(self, run_id):
        return self.artifacts.get(run_id, [])

    def download_artifact(self, artifact_id):
        return self.blobs[artifact_id]


class SequenceApi(FakeApi):
    def __init__(self, responses):
        super().__init__()
        self.responses = list(responses)
        self.job_calls = 0
        self.requested_attempts = []

    def list_jobs(self, run_id, attempt):
        self.job_calls += 1
        self.requested_attempts.append((run_id, attempt))
        response = self.responses[min(self.job_calls - 1, len(self.responses) - 1)]
        if isinstance(response, Exception):
            raise response
        return response


def jobs_for(names, conclusion="success", head="a" * 40, attempt=1, run_id=2000):
    return [{"id": index, "run_id": run_id, "name": name,
             "status": "completed" if conclusion is not None else "in_progress",
             "conclusion": conclusion, "head_sha": head,
             "run_attempt": attempt, "started_at": "2026-10-17T10:00:00Z",
             "completed_at": "2026-10-17T10:01:00Z"} for index, name in enumerate(names, 1)]


class JobObservationTest(unittest.TestCase):
    def settle(self, api, attempt=1):
        self.pauses = []
        self.observations = []
        return gate._settled_jobs(api, 2000, attempt, True, self.pauses.append,
                                  "a" * 40, observe=self.observations.append)

    def test_initial_api_failure_recovers_without_changing_attempt(self):
        for code in ("api_timeout", "api_network", "api_server_error", "api_rate_limited",
                     "api_not_found", "evidence_incomplete"):
            with self.subTest(code=code):
                api = SequenceApi([gate.reuse.ReuseRefusal(code), jobs_for(SHARDS)])
                self.assertEqual(self.settle(api), jobs_for(SHARDS))
                self.assertEqual(api.requested_attempts, [(2000, 1), (2000, 1)])
                self.assertEqual(self.pauses, [gate.SHARD_POLL_INTERVAL_SECONDS])
                self.assertEqual(self.observations[0]["code"], code)

    def test_partial_rerun_waits_for_current_attempt_records(self):
        complete = jobs_for(SHARDS, attempt=2)
        api = SequenceApi([[], complete[:2], complete])
        self.assertEqual(self.settle(api, attempt=2), complete)
        self.assertEqual(api.requested_attempts, [(2000, 2)] * 3)
        self.assertEqual([entry["code"] for entry in self.observations],
                         ["shard_missing", "shard_missing", "settled"])

    def test_pending_states_wait_for_completed_success(self):
        for status in ("queued", "in_progress", "waiting", "pending", "requested", "completed"):
            with self.subTest(status=status):
                pending = jobs_for(SHARDS)
                pending[-1].update(status=status, conclusion=None)
                api = SequenceApi([pending, jobs_for(SHARDS)])
                self.assertEqual(self.settle(api), jobs_for(SHARDS))
                self.assertEqual(api.job_calls, 2)
        pending = jobs_for(SHARDS)
        pending[-1]["status"] = "in_progress"
        self.assertEqual(self.settle(SequenceApi([pending, jobs_for(SHARDS)])), jobs_for(SHARDS))

    def test_missing_pending_and_unavailable_evidence_exhaust_one_budget(self):
        for response, code in ((jobs_for(SHARDS[:3]), "shard_missing"),
                               (jobs_for(SHARDS, conclusion=None), "shard_not_success"),
                               (gate.reuse.ReuseRefusal("api_timeout"),
                                "matrix_unverifiable_api_timeout")):
            with self.subTest(code=code):
                api = SequenceApi([response])
                with self.assertRaisesRegex(gate.GateError, code):
                    self.settle(api)
                self.assertEqual(api.job_calls, gate.SHARD_POLL_ATTEMPTS)
                self.assertEqual(len(self.pauses), gate.SHARD_POLL_ATTEMPTS - 1)
        mixed = [gate.reuse.ReuseRefusal("api_network"), jobs_for(SHARDS[:3]),
                 jobs_for(SHARDS, conclusion=None)] * gate.SHARD_POLL_ATTEMPTS
        api = SequenceApi(mixed)
        with self.assertRaises(gate.GateError):
            self.settle(api)
        self.assertEqual(api.job_calls, gate.SHARD_POLL_ATTEMPTS)

    def test_duplicate_or_illegal_shard_is_never_retried(self):
        for names, code in ((SHARDS + [SHARDS[0]], "shard_duplicate"),
                            (SHARDS + ["Contract shard 5/4"], "shard_mismatch"),
                            (SHARDS + ["Contract shard 1/8"], "shard_mismatch"),
                            (SHARDS + ["Contract shardx"], "shard_mismatch")):
            with self.subTest(names=names):
                api = SequenceApi([jobs_for(names), jobs_for(SHARDS)])
                with self.assertRaisesRegex(gate.GateError, code):
                    self.settle(api)
                self.assertEqual(api.job_calls, 1)
                self.assertEqual(self.pauses, [])

    def test_separate_partial_observations_never_accumulate_a_pass(self):
        complete = jobs_for(SHARDS)
        api = SequenceApi([complete[:2], complete[2:]] * gate.SHARD_POLL_ATTEMPTS)
        with self.assertRaisesRegex(gate.GateError, "shard_missing"):
            self.settle(api)
        self.assertEqual(api.job_calls, gate.SHARD_POLL_ATTEMPTS)
        self.assertTrue(all(entry["successfulShards"] == 2 for entry in self.observations))

    def test_terminal_failure_is_never_hidden_by_retry_or_missing_shards(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", "neutral",
                           "action_required", "stale", "startup_failure"):
            for names in (SHARDS, SHARDS[:2]):
                with self.subTest(conclusion=conclusion, names=names):
                    failed = jobs_for(names)
                    failed[-1]["conclusion"] = conclusion
                    api = SequenceApi([failed, jobs_for(SHARDS)])
                    with self.assertRaisesRegex(gate.GateError, "shard_not_success"):
                        self.settle(api)
                    self.assertEqual(api.job_calls, 1)

    def test_wrong_or_missing_job_identity_is_never_retried(self):
        for field, value, code in (("run_id", 1999, "job_run_mismatch"),
                                   ("run_attempt", 1, "job_attempt_mismatch"),
                                   ("run_attempt", 3, "job_attempt_mismatch"),
                                   ("head_sha", "b" * 40, "job_head_mismatch"),
                                   ("head_sha", None, "job_head_mismatch"),
                                   ("id", None, "job_id_invalid"),
                                   ("id", 1, "job_id_duplicate")):
            with self.subTest(field=field, value=value):
                wrong = jobs_for(SHARDS, attempt=2)
                wrong[-1][field] = value
                api = SequenceApi([wrong, jobs_for(SHARDS, attempt=2)])
                with self.assertRaisesRegex(gate.GateError, code):
                    self.settle(api, attempt=2)
                self.assertEqual(api.job_calls, 1)

    def test_nonretryable_api_failure_is_classified_and_redacted(self):
        for code in ("api_unauthorized", "api_forbidden", "api_invalid_json",
                     "api_invalid_payload", "api_http_error", "api_request_invalid"):
            with self.subTest(code=code):
                api = SequenceApi([gate.reuse.ReuseRefusal(code), jobs_for(SHARDS)])
                with self.assertRaisesRegex(gate.GateError, "matrix_unverifiable_" + code):
                    self.settle(api)
                self.assertEqual(api.job_calls, 1)
        api = SequenceApi([gate.reuse.ReuseRefusal("synthetic-private-api-body")])
        with self.assertRaisesRegex(gate.GateError, "matrix_unverifiable_api_unclassified"):
            self.settle(api)
        self.assertNotIn("synthetic-private", json.dumps(self.observations))


class JobsApiTest(unittest.TestCase):
    def setUp(self):
        self.api = gate.reuse.GitHubApi("synthetic-secret-token", "owner/repo")

    def test_jobs_query_is_bound_to_requested_attempt(self):
        jobs = jobs_for(SHARDS, attempt=2)
        with patch.object(self.api, "_json", return_value={"total_count": 4, "jobs": jobs}) as read:
            self.assertEqual(self.api.list_jobs(2000, 2), jobs)
        read.assert_called_once_with("/repos/owner/repo/actions/runs/2000/attempts/2/jobs?per_page=100")

    def test_incomplete_or_malformed_job_payload_cannot_certify_matrix(self):
        for payload, code in (({"total_count": 5, "jobs": jobs_for(SHARDS)}, "evidence_incomplete"),
                              ({"total_count": 3, "jobs": jobs_for(SHARDS)}, "api_invalid_payload"),
                              ({"jobs": jobs_for(SHARDS)}, "api_invalid_payload"),
                              ({"total_count": "4", "jobs": jobs_for(SHARDS)}, "api_invalid_payload"),
                              ({"total_count": 1, "jobs": [None]}, "api_invalid_payload"),
                              ([], "api_invalid_payload")):
            with self.subTest(code=code, payload=payload):
                with patch.object(self.api, "_json", return_value=payload):
                    with self.assertRaisesRegex(gate.reuse.ReuseRefusal, code):
                        self.api.list_jobs(2000, 1)

    def test_http_errors_have_safe_distinct_categories(self):
        for status, headers, code in ((401, {}, "api_unauthorized"),
                                       (403, {}, "api_forbidden"),
                                       (403, {"X-RateLimit-Remaining": "0"}, "api_rate_limited"),
                                       (403, {"Retry-After": "10"}, "api_rate_limited"),
                                       (404, {}, "api_not_found"), (408, {}, "api_timeout"),
                                       (429, {}, "api_rate_limited"),
                                       (503, {}, "api_server_error"), (422, {}, "api_http_error")):
            with self.subTest(status=status, headers=headers):
                body = io.BytesIO(b"synthetic-private-api-body")
                error = urllib.error.HTTPError("https://example.invalid/private", status,
                                               "synthetic-private-reason", headers, body)
                with patch.object(self.api._opener, "open", side_effect=error):
                    with self.assertRaises(gate.reuse.ReuseRefusal) as caught:
                        self.api.list_jobs(2000, 1)
                self.assertEqual(str(caught.exception), code)

    def test_network_timeout_and_invalid_json_are_distinguished(self):
        for error, code in ((TimeoutError("synthetic-private"), "api_timeout"),
                            (urllib.error.URLError(TimeoutError()), "api_timeout"),
                            (urllib.error.URLError("synthetic-private"), "api_network"),
                            (OSError("synthetic-private"), "api_network"),
                            (ValueError("synthetic-private"), "api_request_invalid")):
            with self.subTest(code=code):
                with patch.object(self.api._opener, "open", side_effect=error):
                    with self.assertRaisesRegex(gate.reuse.ReuseRefusal, code):
                        self.api.list_jobs(2000, 1)
        with patch.object(self.api, "_request", return_value=b"synthetic-private-invalid-json"):
            with self.assertRaisesRegex(gate.reuse.ReuseRefusal, "api_invalid_json"):
                self.api.list_jobs(2000, 1)


class GateFixture(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".dart_tool"
        cache.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="ci-gate-test-", dir=cache)
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.run_git("init", "-q")
        self.run_git("config", "user.name", "CI Fixture")
        self.run_git("config", "user.email", "fixture@example.invalid")
        self.run_git("config", "commit.gpgsign", "false")
        hooks = self.repo / "empty-hooks"
        hooks.mkdir()
        self.run_git("config", "core.hooksPath", str(hooks))
        self.base = self.commit({
            "README.md": "Fixture\n", "lib/app.dart": "initial\n",
            ".github/workflows/pr-contract-checks.yml": WORKFLOW_TEXT,
            "tool/ci/impact_rules.json": (ROOT / "tool/ci/impact_rules.json").read_text(encoding="utf-8"),
            "pubspec.lock": "lock\n", "pubspec.yaml": "name: fixture\n",
            "analysis_options.yaml": "analyzer:\n", "tool/verify_changed.ps1": "# fixture\n",
        })
        self.main_branch = self.run_git("rev-parse", "--abbrev-ref", "HEAD")

    def run_git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode().strip()

    def commit(self, files):
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if content is None:
                path.unlink()
            else:
                path.write_text(content, encoding="utf-8", newline="\n")
            self.run_git("add", "--", name)
        self.run_git("commit", "-q", "-m", "synthetic fixture")
        return self.run_git("rev-parse", "HEAD")

    def merge(self, head, base=None):
        tree = self.run_git("rev-parse", f"{head}^{{tree}}")
        return self.run_git("commit-tree", tree, "-p", base or self.base, "-p", head, "-m", "merge")

    def build(self, head, base=None, mode="plan"):
        base = base or self.base
        merge = self.merge(head, base)
        self.run_git("checkout", "-q", "--detach", merge)
        event = {"pull_request": {"head": {"sha": head}, "base": {"sha": base}}}
        with patch.dict(os.environ, RUNNER):
            plan = impact.resolve_plan(self.repo, "pull_request", event, RULES, DIGEST,
                                       mode, tested_ref="HEAD")
        return plan, event

    def results(self, plan, overrides=None):
        values = {job: ("success" if plan["units"][job]["status"] == impact.EXECUTE else "skipped")
                  for job in impact.JOBS}
        values["impact"] = "success"
        values.update(overrides or {})
        return values

    def validate(self, plan, event, results, api=None, run_id=2000, attempt=1, now=NOW):
        return gate.validate(plan, self.repo, results, api, "pull_request", event,
                             run_id, attempt, now=now, pause=lambda _seconds: None)


class GateTest(GateFixture):
    def test_readme_only_plan_passes_with_skipped_units(self):
        head = self.commit({"README.md": "wording\n"})
        plan, event = self.build(head)
        report = self.validate(plan, event, self.results(plan), FakeApi())
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["totals"]["notApplicable"], 4)
        self.assertEqual(report["totals"]["executed"], 0)

    def test_full_dart_plan_requires_four_contract_shards(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        api = FakeApi(jobs={(2000, 1): jobs_for(
            ["Static changed-Dart checks", "TRAIN C finalization parity"] + SHARDS, head=head)})
        report = self.validate(plan, event, self.results(plan), api)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["shards"], SHARDS)
        self.assertEqual(report["totals"]["executed"], 3)
        self.assertEqual(report["runAttempt"], 1)
        self.assertEqual([job["name"] for job in report["shardJobs"]], SHARDS)
        self.assertTrue(all(job["headSha"] == head and job["runId"] == 2000
                            and job["runAttempt"] == 1 and job["status"] == "completed"
                            and job["conclusion"] == "success" for job in report["shardJobs"]))
        self.assertEqual(report["jobObservations"][-1]["code"], "settled")

    def test_impact_failure_cancellation_absence_or_skip_is_rejected(self):
        head = self.commit({"README.md": "wording\n"})
        plan, event = self.build(head)
        for value in ("failure", "cancelled", "skipped", ""):
            with self.subTest(value=value):
                with self.assertRaisesRegex(gate.GateError, "impact_not_success"):
                    self.validate(plan, event, self.results(plan, {"impact": value}), FakeApi())

    def test_every_execute_unit_must_succeed(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        api = FakeApi(jobs={(2000, 1): jobs_for(
            ["Static changed-Dart checks", "TRAIN C finalization parity"] + SHARDS)})
        for job in ("static", "train_c_finalization_parity", "contracts"):
            for value in ("failure", "cancelled", "skipped"):
                with self.subTest(job=job, value=value):
                    with self.assertRaisesRegex(gate.GateError, f"unit_{job}_execute"):
                        self.validate(plan, event, self.results(plan, {job: value}), api)

    def test_not_applicable_unit_cannot_report_success(self):
        head = self.commit({"README.md": "wording\n"})
        plan, event = self.build(head)
        with self.assertRaisesRegex(gate.GateError, "unit_windows_native_not_applicable"):
            self.validate(plan, event, self.results(plan, {"windows_native": "success"}), FakeApi())

    def test_plan_digest_and_identity_tampering_are_rejected(self):
        head = self.commit({"README.md": "wording\n"})
        plan, event = self.build(head)
        broken = dict(plan)
        broken["headSha"] = "c" * 40
        with self.assertRaisesRegex(gate.GateError, "plan_digest_mismatch"):
            self.validate(broken, event, self.results(plan), FakeApi())
        broken = dict(plan, headSha="c" * 40)
        impact.seal(broken)
        with self.assertRaisesRegex(gate.GateError, "identity_mismatch"):
            self.validate(broken, event, self.results(plan), FakeApi())

    def test_digest_and_classification_mismatch_are_rejected(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        api = FakeApi(jobs={(2000, 1): jobs_for(
            ["Static changed-Dart checks", "TRAIN C finalization parity"] + SHARDS)})
        for field, code, value in (
                ("rulesSha256", "rules_changed", "0" * 64),
                ("workflowSha256", "workflow_changed", "0" * 64),
                ("treeSha256", "inputs_changed", "0" * 64),
                ("flutterVersion", "toolchain_changed", "9.9.9")):
            with self.subTest(field=field):
                broken = dict(plan, **{field: value})
                impact.seal(broken)
                with self.assertRaisesRegex(gate.GateError, code):
                    self.validate(broken, event, self.results(plan), api)
        broken = json.loads(json.dumps(plan))
        broken["requiredJobs"]["static"] = False
        impact.seal(broken)
        with self.assertRaisesRegex(gate.GateError, "classification_mismatch"):
            self.validate(broken, event, self.results(plan), api)

    def test_matrix_membership_is_fail_closed(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        base_jobs = ["Static changed-Dart checks", "TRAIN C finalization parity"]
        for names, code in (
                (base_jobs + SHARDS[:3], "shard_missing"),
                (base_jobs + SHARDS + ["Contract shard 5/4"], "shard_mismatch"),
                (base_jobs + SHARDS, None)):
            with self.subTest(code=code):
                api = FakeApi(jobs={(2000, 1): jobs_for(names, head=head)})
                if code is None:
                    self.assertEqual(self.validate(plan, event, self.results(plan), api)["verdict"], "PASS")
                else:
                    with self.assertRaisesRegex(gate.GateError, code):
                        self.validate(plan, event, self.results(plan), api)
        failed_jobs = jobs_for(base_jobs + SHARDS, head=head)
        failed_jobs[-1]["conclusion"] = "failure"
        failed = FakeApi(jobs={(2000, 1): failed_jobs})
        with self.assertRaisesRegex(gate.GateError, "shard_not_success"):
            self.validate(plan, event, self.results(plan), failed)
        with self.assertRaisesRegex(gate.GateError, "matrix_unverifiable"):
            self.validate(plan, event, self.results(plan), None)

    def test_pending_matrix_observation_is_polled_until_settled(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        names = ["Static changed-Dart checks", "TRAIN C finalization parity"] + SHARDS
        pending = jobs_for(names, head=head)
        pending[-1]["conclusion"] = None
        api = SequenceApi([pending, jobs_for(names, head=head)])
        report = self.validate(plan, event, self.results(plan), api)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["shards"], SHARDS)
        self.assertEqual(api.job_calls, 2)

    def test_applied_reuse_is_revalidated_by_the_gate(self):
        code = self.commit({"lib/app.dart": "code\n"})
        source_plan, _ = self.build(code)
        source_artifact = io.BytesIO()
        with zipfile.ZipFile(source_artifact, "w") as archive:
            archive.writestr("plan.json", json.dumps(source_plan))
        source_run = {"id": 1001, "run_attempt": 1, "head_sha": code, "head_branch": "feature",
                      "head_repository": {"full_name": "owner/repo"}, "event": "pull_request",
                      "conclusion": "success", "pull_requests": [{"number": 7}],
                      "created_at": "2026-10-17T08:00:00Z"}
        head = self.commit({"README.md": "wording\n"})
        plan, event = self.build(head)
        api = FakeApi(
            jobs={(1001, 1): jobs_for(["Static changed-Dart checks", "TRAIN C finalization parity"] +
                                      SHARDS, head=code),
                  (2000, 1): jobs_for(SHARDS)},
            artifacts={1001: [{"id": 55, "name": "ci-impact-plan", "expired": False,
                               "expires_at": EVIDENCE_EXPIRES_AT}]},
            blobs={55: source_artifact.getvalue()}, runs=[source_run])
        plan = reuse.apply(self.repo, plan, api, repo_full_name="owner/repo",
                           base_repo_full_name="owner/repo", pr_number=7, head_ref="feature",
                           now=NOW)
        self.assertEqual(plan["reuse"]["status"], "APPLIED")
        results = self.results(plan)
        self.assertEqual(results["static"], "skipped")
        self.assertEqual(results["windows_native"], "skipped")
        self.assertEqual(self.validate(plan, event, results, api)["verdict"], "PASS")
        # The same claim must stop certifying once the source evidence expires.
        api.artifacts[1001][0]["expires_at"] = (NOW - timedelta(seconds=1)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
        with self.assertRaisesRegex(gate.GateError, "reuse_evidence_expired"):
            self.validate(plan, event, results, api)
        api.artifacts[1001][0]["expires_at"] = EVIDENCE_EXPIRES_AT
        drifted = dict(plan)
        drifted["reuse"] = json.loads(json.dumps(plan["reuse"]))
        drifted["reuse"]["source"]["evidenceSha256"] = "0" * 64
        impact.seal(drifted)
        with self.assertRaisesRegex(gate.GateError, "reuse_evidence_mismatch"):
            self.validate(drifted, event, results, api)

    def test_required_unit_cannot_be_downgraded_to_not_applicable(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        broken = json.loads(json.dumps(plan))
        broken["units"]["static"] = {"status": impact.NOT_APPLICABLE, "reason": "tampered"}
        impact.seal(broken)
        api = FakeApi(jobs={(2000, 1): jobs_for(
            ["TRAIN C finalization parity"] + SHARDS)})
        with self.assertRaisesRegex(gate.GateError, "classification_mismatch"):
            self.validate(broken, event, self.results(broken), api)

    def test_reuse_unit_must_be_recorded_in_the_reuse_block(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        broken = json.loads(json.dumps(plan))
        broken["units"]["static"] = {"status": impact.REUSE, "reason": "unrecorded"}
        broken["reuse"] = {"status": "APPLIED", "code": "reuse_applied", "source": {}, "units": []}
        impact.seal(broken)
        api = FakeApi(jobs={(2000, 1): jobs_for(SHARDS)})
        with self.assertRaisesRegex(gate.GateError, "reuse_mismatch"):
            self.validate(broken, event, self.results(broken), api)

    def test_reuse_status_without_evidence_is_rejected(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        broken = json.loads(json.dumps(plan))
        broken["units"]["static"] = {"status": impact.REUSE, "reason": "unproven"}
        impact.seal(broken)
        api = FakeApi(jobs={(2000, 1): jobs_for(
            ["TRAIN C finalization parity"] + SHARDS)})
        with self.assertRaisesRegex(gate.GateError, "reuse_mismatch"):
            self.validate(broken, event, self.results(broken, {"static": "skipped"}), api)


if __name__ == "__main__":
    unittest.main()
