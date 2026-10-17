"""Synthetic/offline impact and scheduling regressions; no provider or OS security I/O."""

import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_impact", ROOT / "tool/ci/resolve_ci_impact.py")
impact = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = impact
SPEC.loader.exec_module(impact)
RULES, DIGEST = impact.read_rules(ROOT / "tool/ci/impact_rules.json")
ALL = set(impact.JOBS)
DART = ALL - {"windows_native"}
NATIVE = {"windows_native", "contracts"}


class ClassificationTest(unittest.TestCase):
    def test_impact_matrix(self):
        cases = [
            ("README.md", set()),
            ("docs/product/agent-refactor/README.md", ALL),
            ("windows/external_native/diagnostics/README.md", ALL),
            ("docs/product/agent-refactor/windows-host-security-readiness.md", ALL),
            ("docs/product/agent-refactor/windows-host-acceptance-plan.json", {"contracts"}),
            ("docs/product/agent-refactor/windows-host-acceptance-preparation.md", {"contracts"}),
            ("windows/external_native/native_core.cpp", NATIVE),
            ("windows/external_native/tests/l1_e4_test.cpp", NATIVE),
            ("tool/external/check_acceptance_readiness.ps1", ALL),
            ("tool/external/check_l1_windows_source.ps1", ALL),
            ("lib/application/agent/agent_runtime.dart", DART),
            ("lib/domain/content/content_node.dart", DART),
            ("lib/data/external/native/external_native_bindings.dart", ALL),
            ("tool/train_c_evidence_collector.dart", DART),
            ("pubspec.lock", ALL), ("pubspec.yaml", ALL),
            (".github/workflows/pr-contract-checks.yml", ALL),
            ("tool/ci/resolve_ci_impact.py", ALL),
            ("tool/ci/impact_rules.json", ALL),
            ("windows/external_native/CMakeLists.txt", ALL),
            ("windows/external_native/check_offline.ps1", ALL),
            ("new_unknown/README.md", ALL), ("new_unknown/fixture.bin", ALL),
            ("windows/external_native/new_unknown.xyz", ALL),
        ]
        for path, jobs in cases:
            with self.subTest(path=path):
                self.assertEqual(impact.classify([impact.Change(path)], RULES)[0], jobs)

    def test_mixed_and_shared_changes_union_requirements(self):
        changes = [impact.Change("lib/application/shared.dart"),
                   impact.Change("windows/external_native/native_core.h")]
        self.assertEqual(impact.classify(changes, RULES)[0], ALL)

    def test_source_comments_use_the_same_scope(self):
        # No content/extension-based claim that a C++ comment is harmless.
        self.assertEqual(impact.classify([impact.Change("windows/external_native/native_core.h")], RULES)[0], NATIVE)

    def test_delete_and_rename_do_not_disappear(self):
        changes = [impact.Change("README.md", "D", "100644", "000000"),
                   impact.Change("other.md", "A", "000000", "100644")]
        self.assertEqual(impact.classify(changes, RULES)[0], ALL)
        self.assertEqual(impact.classify([impact.Change("lib/removed.dart", "D", "100644", "000000")], RULES)[0], DART)

    def test_unsafe_or_ambiguous_inputs_require_full(self):
        for change in (impact.Change("README.md", "A", "000000", "100644"),
                       impact.Change("README.md", "M", "100644", "120000"),
                       impact.Change("README.md", "M", "100644", "100755"),
                       impact.Change("README.md", "T"),
                       impact.Change("../README.md"), impact.Change("/README.md"),
                       impact.Change("lib/private\nname.dart"), impact.Change("lib/未知.dart")):
            with self.subTest(change=change):
                self.assertEqual(impact.classify([change], RULES)[0], ALL)
        self.assertEqual(impact.classify([], RULES)[0], ALL)

    def test_security_document_cannot_be_overridden_by_a_route(self):
        rules = copy.deepcopy(RULES)
        rules["routes"].insert(0, {"id": "mislabelled_document", "paths": [
            "docs/product/agent-refactor/windows-host-security-readiness.md"],
            "prefixes": [], "suffixes": [], "jobs": ["static"]})
        self.assertEqual(impact.classify([impact.Change(rules["routes"][0]["paths"][0])], rules)[0], ALL)

    def test_workflow_shadow_cannot_skip_any_existing_job(self):
        workflow = (ROOT / ".github/workflows/pr-contract-checks.yml").read_text(encoding="utf-8")
        for job in impact.JOBS:
            block = re.search(rf"(?ms)^  {job}:\n.*?(?=^  [a-z_]+:|\Z)", workflow)[0]
            self.assertNotRegex(block, r"(?m)^    (?:if|needs):")
        verify = re.search(r"(?ms)^  verify:\n.*", workflow)[0]
        self.assertIn("      - impact", verify)
        self.assertIn("needs.impact.result", verify)
        self.assertIn("if: always()", verify)
        observer = re.search(r"(?ms)^  impact:\n.*?(?=^  [a-z_]+:|\Z)", workflow)[0]
        for script in ("check_l1_windows_source.ps1 -SelfTest", "check_acceptance_readiness.ps1 -SelfTest",
                       "check_bootstrap_source.ps1", "ci_contract_timings_test.ps1", "ci_impact_test.py"):
            self.assertIn(script, observer)
        self.assertNotIn("flutter-action", observer)
        self.assertIn("python3 -B tool/ci/resolve_ci_impact.py --mode shadow", observer)


class GitInputTest(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".dart_tool"
        cache.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="ci-impact-test-", dir=cache)
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.run_git("init", "-q")
        self.run_git("config", "user.name", "CI Fixture")
        self.run_git("config", "user.email", "fixture@example.invalid")
        self.run_git("config", "commit.gpgsign", "false")
        hooks = self.repo / "empty-hooks"
        hooks.mkdir()
        self.run_git("config", "core.hooksPath", str(hooks))
        self.base = self.commit({"README.md": "Fixture\n", "lib/app.dart": "initial\n"})

    def run_git(self, *args):
        return impact.git(self.repo, *args).decode().strip()

    def commit(self, files):
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if content is None:
                path.unlink()
            else:
                path.write_text(content, encoding="utf-8")
            self.run_git("add", "--", name)
        self.run_git("commit", "-q", "-m", "synthetic fixture")
        return self.run_git("rev-parse", "HEAD")

    def merge_commit(self, head, base=None):
        base = base or self.base
        tree = self.run_git("rev-parse", f"{head}^{{tree}}")
        return self.run_git("commit-tree", tree, "-p", base, "-p", head, "-m", "synthetic merge")

    def plan(self, head, tested=None, base=None, **kwargs):
        event = {"pull_request": {"head": {"sha": head}, "base": {"sha": base or self.base}}}
        return impact.resolve_plan(self.repo, "pull_request", event, RULES, DIGEST,
                                   tested_ref=tested or self.merge_commit(head, base), **kwargs)

    def test_readme_only_observation_keeps_full_execution(self):
        head = self.commit({"README.md": "Fixture amended\n"})
        plan = self.plan(head)
        self.assertFalse(any(plan["recommendedJobs"].values()))
        self.assertTrue(all(plan["executionJobs"].values()))
        self.assertEqual(plan["changedFileCount"], 1)
        self.assertEqual(plan["headSha"], head)
        self.assertEqual(plan["baseSha"], self.base)

    def test_last_push_readme_does_not_hide_earlier_code_changes(self):
        self.commit({"lib/app.dart": "code change\n"})
        head = self.commit({"README.md": "wording fix\n"})
        self.assertEqual({j for j, run in self.plan(head)["recommendedJobs"].items() if run}, DART)

    def test_diff_parser_retains_spaces_deletes_and_both_rename_paths(self):
        head = self.commit({"lib/app.dart": None, "lib/renamed app.dart": "initial\n"})
        changes = impact.changes_between(self.repo, self.base, head)
        self.assertEqual({(c.path, c.status) for c in changes},
                         {("lib/app.dart", "D"), ("lib/renamed app.dart", "A")})

    def test_base_drift_and_cancelled_target_mismatch(self):
        head = self.commit({"README.md": "head\n"})
        original_merge = self.merge_commit(head)
        self.run_git("switch", "-q", "-c", "advanced-base", self.base)
        advanced = self.commit({"base.txt": "new base\n"})
        self.assertTrue(all(self.plan(head, base=advanced)["recommendedJobs"].values()))
        with self.assertRaisesRegex(impact.ImpactError, "target_mismatch"):
            self.plan(head, tested=original_merge, base=advanced)
        new_head = self.commit({"README.md": "another push\n"})
        with self.assertRaisesRegex(impact.ImpactError, "target_mismatch"):
            self.plan(new_head, tested=original_merge)

    def test_merge_result_changes_are_also_classified(self):
        head = self.commit({"README.md": "branch wording\n"})
        extra = self.commit({"lib/app.dart": "merge tree change\n"})
        tested = self.merge_commit(extra)
        # Preserve the PR head parents but use the extra tree to model the
        # merge-result input independently from cumulative branch changes.
        tree = self.run_git("rev-parse", f"{tested}^{{tree}}")
        tested = self.run_git("commit-tree", tree, "-p", self.base, "-p", head, "-m", "merge tree")
        self.assertEqual({j for j, run in self.plan(head, tested=tested)["recommendedJobs"].items() if run}, DART)

    def test_push_manual_and_forced_full_never_recommend_skipping(self):
        head = self.commit({"README.md": "wording\n"})
        self.assertTrue(all(self.plan(head, mode="full")["recommendedJobs"].values()))
        for event_name, event in (("push", {"after": head}), ("workflow_dispatch", {})):
            plan = impact.resolve_plan(self.repo, event_name, event, RULES, DIGEST)
            self.assertTrue(all(plan["recommendedJobs"].values()))
        with self.assertRaisesRegex(impact.ImpactError, "target_mismatch"):
            impact.resolve_plan(self.repo, "push", {"after": self.base}, RULES, DIGEST)

    def test_bad_target_and_missing_objects_cannot_give_selective_plan(self):
        head = self.commit({"README.md": "wording\n"})
        tested = self.merge_commit(head)
        with self.assertRaisesRegex(impact.ImpactError, "invalid_target"):
            self.plan("--invalid", tested=tested)
        # A missing parent identity is inconsistent with the checkout, so hard fail.
        with self.assertRaisesRegex(impact.ImpactError, "target_mismatch"):
            self.plan(head, base="a" * 40, tested=tested)

    def test_unavailable_diff_falls_back_to_full(self):
        head = self.commit({"README.md": "wording\n"})
        with patch.object(impact, "changes_between", side_effect=impact.ImpactError("invalid_diff")):
            plan = self.plan(head)
        self.assertEqual(plan["reasons"], ["diff_unavailable_full"])
        self.assertTrue(all(plan["recommendedJobs"].values()))

    def test_committed_whitespace_errors_are_not_hidden_by_full_mode(self):
        head = self.commit({"README.md": "trailing spaces  \n"})
        with self.assertRaises(impact.ImpactError):
            self.plan(head, mode="full")

    def test_local_references_are_checked_without_network(self):
        head = self.commit({"README.md": "[source](lib/app.dart) [web](https://example.invalid)\n"})
        self.assertFalse(any(self.plan(head)["recommendedJobs"].values()))
        head = self.commit({"README.md": "[missing](lib/missing.dart)\n"})
        with self.assertRaisesRegex(impact.ImpactError, "missing_document_reference"):
            self.plan(head)

    def test_unparsed_document_references_widen_scope(self):
        head = self.commit({"README.md": "[link][ref]\n\n[ref]: lib/app.dart\n"})
        self.assertTrue(all(self.plan(head)["recommendedJobs"].values()))

    def test_invalid_mapping_cannot_expand_the_document_allowlist(self):
        path = self.repo / "rules.json"
        bad = copy.deepcopy(RULES)
        bad["ordinaryDocuments"].append("docs/product/agent-refactor/README.md")
        path.write_text(json.dumps(bad), encoding="utf-8")
        with self.assertRaisesRegex(impact.ImpactError, "invalid_rules"):
            impact.read_rules(path)
        path.write_text('{"version":1,"version":1}', encoding="utf-8")
        with self.assertRaisesRegex(impact.ImpactError, "invalid_rules"):
            impact.read_rules(path)
        path.write_text("{invalid", encoding="utf-8")
        with self.assertRaisesRegex(impact.ImpactError, "invalid_rules"):
            impact.read_rules(path)

    def test_cli_report_redaction_and_missing_evidence_do_not_skip_execution(self):
        rules_path = self.repo / "tool/ci/impact_rules.json"
        rules_path.parent.mkdir(parents=True)
        rules_path.write_text(json.dumps(RULES), encoding="utf-8")
        event_path = self.repo / "event.json"
        event_path.write_text("{}", encoding="utf-8")
        summary_path = self.repo / "summary.md"
        output = io.StringIO()
        with patch.object(impact, "ROOT", self.repo), patch.object(sys, "argv", [
            "resolve_ci_impact.py", "--event-name", "workflow_dispatch", "--event-path", str(event_path)
        ]), patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": str(summary_path)}), redirect_stdout(output):
            self.assertEqual(impact.main(), 0)
        plan = json.loads((self.repo / ".dart_tool/ci-impact/plan.json").read_text())
        self.assertTrue(all(plan["executionJobs"].values()))
        self.assertEqual(plan["rulesSha256"], impact.read_rules(rules_path)[1])
        self.assertNotIn(str(self.repo), output.getvalue())
        self.assertNotIn("fixture@example.invalid", output.getvalue())
        self.assertTrue(summary_path.exists())
        # Corrupt input cannot produce a new success, even if an older report exists.
        event_path.write_text("[invalid", encoding="utf-8")
        output = io.StringIO()
        with patch.object(impact, "ROOT", self.repo), patch.object(sys, "argv", [
            "resolve_ci_impact.py", "--event-name", "pull_request", "--event-path", str(event_path)
        ]), redirect_stdout(output):
            self.assertEqual(impact.main(), 1)
        self.assertEqual(output.getvalue().strip(), "FAIL: ci_impact:input_or_output_invalid")


if __name__ == "__main__":
    unittest.main()
