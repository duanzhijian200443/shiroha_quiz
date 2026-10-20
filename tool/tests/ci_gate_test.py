"""Fail-closed aggregate gate regressions: plan identity, reuse and matrix semantics."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
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

    def list_jobs(self, run_id, attempt):
        self.job_calls += 1
        return self.responses[min(self.job_calls - 1, len(self.responses) - 1)]


def jobs_for(names, conclusion="success", head="a" * 40, attempt=1):
    return [{"name": name, "conclusion": conclusion, "head_sha": head,
             "run_attempt": attempt, "started_at": "2026-10-17T10:00:00Z",
             "completed_at": "2026-10-17T10:01:00Z"} for name in names]


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

    def validate(self, plan, event, results, api=None, run_id=2000, attempt=1):
        return gate.validate(plan, self.repo, results, api, "pull_request", event,
                             run_id, attempt, pause=lambda _seconds: None)


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
            ["Static changed-Dart checks", "TRAIN C finalization parity"] + SHARDS)})
        report = self.validate(plan, event, self.results(plan), api)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["shards"], SHARDS)
        self.assertEqual(report["totals"]["executed"], 3)

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
                (base_jobs + SHARDS[:3], "shard_mismatch"),
                (base_jobs + SHARDS + ["Contract shard 5/4"], "shard_mismatch"),
                (base_jobs + SHARDS, None)):
            with self.subTest(code=code):
                api = FakeApi(jobs={(2000, 1): jobs_for(names)})
                if code is None:
                    self.assertEqual(self.validate(plan, event, self.results(plan), api)["verdict"], "PASS")
                else:
                    with self.assertRaisesRegex(gate.GateError, code):
                        self.validate(plan, event, self.results(plan), api)
        failed = FakeApi(jobs={(2000, 1): jobs_for(base_jobs + SHARDS[:3]) +
                               jobs_for([SHARDS[3]], conclusion="failure")})
        with self.assertRaisesRegex(gate.GateError, "shard_not_success"):
            self.validate(plan, event, self.results(plan), failed)
        with self.assertRaisesRegex(gate.GateError, "matrix_unverifiable"):
            self.validate(plan, event, self.results(plan), None)

    def test_pending_matrix_observation_is_polled_until_settled(self):
        head = self.commit({"lib/app.dart": "code\n"})
        plan, event = self.build(head)
        names = ["Static changed-Dart checks", "TRAIN C finalization parity"] + SHARDS
        pending = jobs_for(names)
        pending[-1]["conclusion"] = None
        api = SequenceApi([pending, jobs_for(names)])
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
                               "expires_at": "2026-10-24T08:00:00Z"}]},
            blobs={55: source_artifact.getvalue()}, runs=[source_run])
        plan = reuse.apply(self.repo, plan, api, repo_full_name="owner/repo",
                           base_repo_full_name="owner/repo", pr_number=7, head_ref="feature",
                           now=gate.datetime(2026, 10, 17, 12, 0, tzinfo=gate.timezone.utc))
        self.assertEqual(plan["reuse"]["status"], "APPLIED")
        results = self.results(plan)
        self.assertEqual(results["static"], "skipped")
        self.assertEqual(results["windows_native"], "skipped")
        self.assertEqual(self.validate(plan, event, results, api)["verdict"], "PASS")
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
