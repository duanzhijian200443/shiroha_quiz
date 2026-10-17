"""Offline cross-head reuse regressions with real Git objects and a fake API."""

import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_impact", ROOT / "tool/ci/resolve_ci_impact.py")
impact = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = impact
SPEC.loader.exec_module(impact)
REUSE_SPEC = importlib.util.spec_from_file_location("ci_reuse", ROOT / "tool/ci/resolve_ci_reuse.py")
reuse = importlib.util.module_from_spec(REUSE_SPEC)
sys.modules[REUSE_SPEC.name] = reuse
REUSE_SPEC.loader.exec_module(reuse)
RULES, DIGEST = impact.read_rules(ROOT / "tool/ci/impact_rules.json")
RUNNER = {"ImageOS": "ubuntu22", "ImageVersion": "20261001"}
NOW = datetime(2026, 10, 17, 12, 0, tzinfo=timezone.utc)
WORKFLOW_TEXT = """name: fixture
jobs:
  contracts:
    steps:
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.41.9
"""


class FakeApi:
    def __init__(self, runs=(), jobs=None, artifacts=None, blobs=None, run=None):
        self.runs = list(runs)
        self.jobs = jobs or {}
        self.artifacts = artifacts or {}
        self.blobs = blobs or {}
        self.run = run

    def list_runs(self, workflow, branch):
        return self.runs

    def get_run(self, run_id):
        if self.run is None:
            raise reuse.ReuseRefusal("api_unavailable")
        return self.run

    def list_jobs(self, run_id, attempt):
        return self.jobs.get((run_id, attempt), [])

    def list_artifacts(self, run_id):
        return self.artifacts.get(run_id, [])

    def download_artifact(self, artifact_id):
        return self.blobs[artifact_id]


def artifact_bytes(plan):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("plan.json", json.dumps(plan))
    return buffer.getvalue()


def shard_jobs(head, attempt=1, conclusion="success"):
    return [
        {"name": "Static changed-Dart checks", "conclusion": conclusion, "run_attempt": attempt, "head_sha": head},
        {"name": "TRAIN C finalization parity", "conclusion": conclusion, "run_attempt": attempt, "head_sha": head},
    ] + [
        {"name": f"Contract shard {index}/4", "conclusion": conclusion, "run_attempt": attempt, "head_sha": head}
        for index in range(1, 5)
    ]


class ReuseFixture(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".dart_tool"
        cache.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="ci-reuse-test-", dir=cache)
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
            "README.md": "Fixture\n",
            "lib/app.dart": "initial\n",
            ".github/workflows/pr-contract-checks.yml": WORKFLOW_TEXT,
            "tool/ci/impact_rules.json": (ROOT / "tool/ci/impact_rules.json").read_text(encoding="utf-8"),
            "pubspec.lock": "lock\n",
            "pubspec.yaml": "name: fixture\n",
            "analysis_options.yaml": "analyzer:\n",
            "tool/verify_changed.ps1": "# fixture\n",
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

    def make_plan(self, head, base=None, env=None, mode="plan"):
        base = base or self.base
        event = {"pull_request": {"head": {"sha": head}, "base": {"sha": base}}}
        with patch.dict(os.environ, env or RUNNER):
            return impact.resolve_plan(self.repo, "pull_request", event, RULES, DIGEST,
                                       tested_ref=self.merge(head, base), mode=mode)

    def source_setup(self, code_commit, pr=7, base=None, run_id=1001):
        base = base or self.base
        source = self.make_plan(code_commit, base)
        artifact = artifact_bytes(source)
        run = {"id": run_id, "run_attempt": 1, "head_sha": code_commit, "head_branch": "feature",
               "head_repository": {"full_name": "owner/repo"}, "event": "pull_request",
               "conclusion": "success", "pull_requests": [],
               "created_at": "2026-10-17T08:00:00Z"}
        api = FakeApi(
            runs=[run], jobs={(run_id, 1): shard_jobs(code_commit)},
            artifacts={run_id: [{"id": 55, "name": "ci-impact-plan", "expired": False,
                                 "expires_at": "2026-10-24T08:00:00Z"}]},
            blobs={55: artifact}, run=run)
        return api, source, artifact

    def apply(self, plan, api, head_ref="feature", pr=7):
        return reuse.apply(self.repo, plan, api, repo_full_name="owner/repo",
                           base_repo_full_name="owner/repo", pr_number=pr,
                           head_ref=head_ref, now=NOW)


class ReuseTest(ReuseFixture):
    def test_readme_append_reuses_only_static_train_c_and_contracts(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, source, _ = self.source_setup(code)
        head = self.commit({"README.md": "wording only\n"})
        plan = self.apply(self.make_plan(head), api)
        self.assertEqual(plan["reuse"]["status"], "APPLIED")
        self.assertEqual(sorted(plan["reuse"]["units"]), ["contracts", "static", "train_c_finalization_parity"])
        self.assertEqual(plan["units"]["static"]["status"], impact.REUSE)
        self.assertEqual(plan["units"]["contracts"]["status"], impact.REUSE)
        self.assertEqual(plan["units"]["windows_native"]["status"], impact.NOT_APPLICABLE)
        self.assertEqual(plan["reuse"]["source"]["runId"], 1001)
        self.assertEqual(plan["reuse"]["source"]["headSha"], code)
        self.assertEqual(plan["reuse"]["source"]["evidenceSha256"],
                         hashlib.sha256(json.dumps(source).encode("utf-8")).hexdigest())
        self.assertEqual(plan["planSha256"], impact.canonical(plan))

    def test_native_unit_is_never_reused(self):
        code = self.commit({"windows/external_native/native_core.cpp": "int main(){}\n"})
        api, _, _ = self.source_setup(code)
        head = self.commit({"README.md": "wording only\n"})
        plan = self.apply(self.make_plan(head), api)
        self.assertEqual(plan["units"]["windows_native"]["status"], impact.EXECUTE)
        self.assertEqual(plan["units"]["contracts"]["status"], impact.REUSE)
        self.assertNotIn("windows_native", plan["reuse"]["units"])

    def test_source_head_must_be_an_ancestor(self):
        self.run_git("switch", "-q", "-c", "side", self.base)
        side = self.commit({"lib/app.dart": "side change\n"})
        api, _, _ = self.source_setup(side)
        self.run_git("switch", "-q", self.main_branch)
        self.commit({"lib/app.dart": "main code change\n"})
        head = self.commit({"README.md": "main wording\n"})
        plan = self.apply(self.make_plan(head), api)
        self.assertEqual(plan["reuse"]["status"], "REFUSED")
        self.assertEqual(plan["reuse"]["code"], "source_not_ancestor")

    def test_base_drift_prevents_reuse(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, _, _ = self.source_setup(code)
        head = self.commit({"README.md": "wording\n"})
        self.run_git("switch", "-q", "-c", "advanced", self.base)
        advanced = self.commit({"base.txt": "advanced\n"})
        plan = self.apply(self.make_plan(head, base=advanced), api)
        self.assertEqual(plan["reuse"]["status"], "REFUSED")
        self.assertIn(plan["reuse"]["code"], {"base_changed", "ci_inputs_changed"})
        self.assertEqual(plan["units"]["static"]["status"], impact.EXECUTE)

    def test_failed_cancelled_or_missing_source_is_refused(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        head = self.commit({"README.md": "wording\n"})
        for conclusion in ("failure", "cancelled", None):
            with self.subTest(conclusion=conclusion):
                api, _, _ = self.source_setup(code)
                api.runs[0]["conclusion"] = conclusion
                plan = self.apply(self.make_plan(head), api)
                self.assertEqual(plan["reuse"]["status"], "REFUSED")
                self.assertEqual(plan["reuse"]["code"], "no_source_run")
        plan = self.apply(self.make_plan(head), FakeApi())
        self.assertEqual(plan["reuse"]["code"], "no_source_run")

    def test_other_pull_request_or_branch_is_not_a_source(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, _, _ = self.source_setup(code)
        head = self.commit({"README.md": "wording\n"})
        self.assertEqual(self.apply(self.make_plan(head), api, head_ref="other")["reuse"]["code"],
                         "no_source_run")
        # When GitHub supplies the PR array, a different number cannot be reused.
        api.runs[0]["pull_requests"] = [{"number": 7}]
        self.assertEqual(self.apply(self.make_plan(head), api, pr=8)["reuse"]["code"], "no_source_run")

    def test_source_that_itself_reused_is_refused(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, source, _ = self.source_setup(code)
        source["units"]["static"] = {"status": impact.REUSE, "reason": "verified_input_equivalence"}
        api.blobs[55] = artifact_bytes(impact.seal(source))
        head = self.commit({"README.md": "wording\n"})
        plan = self.apply(self.make_plan(head), api)
        self.assertEqual(plan["reuse"]["status"], "REFUSED")
        self.assertEqual(plan["reuse"]["code"], "source_used_reuse")

    def test_non_ordinary_delta_is_refused(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, _, _ = self.source_setup(code)
        self.commit({"lib/app.dart": "second code change\n"})
        head = self.commit({"README.md": "wording\n"})
        plan = self.apply(self.make_plan(head), api)
        self.assertEqual(plan["reuse"]["code"], "delta_not_ordinary")

    def test_expired_missing_or_corrupt_evidence_falls_back(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        head = self.commit({"README.md": "wording\n"})
        for mutation, expected in (
                (lambda api: api.artifacts[1001][0].update({"expired": True}), "evidence_expired"),
                (lambda api: api.artifacts[1001][0].update({"expires_at": "2026-10-01T00:00:00Z"}), "evidence_expired"),
                (lambda api: api.artifacts.pop(1001), "evidence_missing"),
                (lambda api: api.blobs.update({55: b"not a zip"}), "evidence_mismatch")):
            with self.subTest(expected=expected):
                api, _, _ = self.source_setup(code)
                mutation(api)
                plan = self.apply(self.make_plan(head), api)
                self.assertEqual(plan["reuse"]["status"], "REFUSED")
                self.assertEqual(plan["reuse"]["code"], expected)
                self.assertEqual(plan["units"]["static"]["status"], impact.EXECUTE)

    def test_attempt_and_job_result_mismatch_are_refused(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        head = self.commit({"README.md": "wording\n"})
        api, _, _ = self.source_setup(code)
        api.jobs[(1001, 1)] = shard_jobs(code, attempt=2)
        self.assertEqual(self.apply(self.make_plan(head), api)["reuse"]["code"], "attempt_mismatch")
        api, _, _ = self.source_setup(code)
        api.jobs[(1001, 1)] = shard_jobs(code, conclusion="failure")
        self.assertEqual(self.apply(self.make_plan(head), api)["reuse"]["code"], "source_not_successful")
        api, _, _ = self.source_setup(code)
        api.jobs[(1001, 1)] = [job for job in shard_jobs(code) if job["name"] != "Contract shard 4/4"]
        self.assertEqual(self.apply(self.make_plan(head), api)["reuse"]["code"], "shard_mismatch")

    def test_toolchain_drift_invalidates_reuse(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, _, _ = self.source_setup(code)
        head = self.commit({"README.md": "wording\n"})
        plan = self.apply(self.make_plan(head, env={"ImageOS": "ubuntu22", "ImageVersion": "20261002"}), api)
        self.assertEqual(plan["reuse"]["code"], "toolchain_changed")

    def test_ci_input_changes_and_forks_never_reuse(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, _, _ = self.source_setup(code)
        head = self.commit({"README.md": "wording\n", "tool/ci/resolve_ci_impact.py": "# changed\n"})
        plan = self.apply(self.make_plan(head), api)
        self.assertEqual(plan["reuse"]["code"], "ci_inputs_changed")
        head = self.commit({"README.md": "wording again\n"})
        plan = reuse.apply(self.repo, self.make_plan(head), api, repo_full_name="fork/repo",
                           base_repo_full_name="owner/repo", pr_number=7, head_ref="feature", now=NOW)
        self.assertEqual(plan["reuse"]["code"], "fork_source")

    def test_missing_api_falls_back_to_execute(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        self.source_setup(code)
        head = self.commit({"README.md": "wording\n"})
        plan = self.apply(self.make_plan(head), None)
        self.assertEqual(plan["reuse"]["code"], "api_unavailable")
        self.assertEqual(plan["units"]["static"]["status"], impact.EXECUTE)

    def test_applied_reuse_is_revalidated_and_detects_drift(self):
        code = self.commit({"lib/app.dart": "code change\n"})
        api, source, _ = self.source_setup(code)
        head = self.commit({"README.md": "wording\n"})
        plan = self.apply(self.make_plan(head), api)
        self.assertEqual(plan["reuse"]["status"], "APPLIED")
        self.assertEqual(reuse.validate_applied(self.repo, plan, api, NOW)["runId"], 1001)
        tampered = dict(source)
        tampered["headSha"] = "b" * 40
        api.blobs[55] = artifact_bytes(impact.seal(tampered))
        with self.assertRaisesRegex(reuse.ReuseRefusal, "evidence_mismatch"):
            reuse.validate_applied(self.repo, plan, api, NOW)
        api.artifacts.pop(1001)
        with self.assertRaisesRegex(reuse.ReuseRefusal, "evidence_missing"):
            reuse.validate_applied(self.repo, plan, api, NOW)


if __name__ == "__main__":
    unittest.main()
