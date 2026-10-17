"""Bounded cross-head reuse for changed-Dart verification units.

Only the static, TRAIN C parity and contract-shard units may be reused. Windows
native compilation always re-executes. Reuse is a claim about input equivalence
between two heads, never a cached test PASS: every condition below must hold on
the real Git tree, the source run and its uploaded plan artifact.
"""

from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))

import resolve_ci_impact as impact  # noqa: E402


REUSABLE = ("static", "train_c_finalization_parity", "contracts")
WORKFLOW_FILE = "pr-contract-checks.yml"
PLAN_ARTIFACT = "ci-impact-plan"
# A change to any of these route families means the validation machinery itself
# is under review; no earlier run can certify the new machinery.
BLOCKING_REASONS = {
    "shared_configuration", "unknown_path", "unsafe_path_or_type", "contract_document",
    "document_structure_changed", "base_diverged_full", "diff_unavailable_full",
    "forced_full", "unsupported_document_reference_full", "empty_diff",
}
UNIT_JOBS = {
    "static": ("Static changed-Dart checks", 1),
    "train_c_finalization_parity": ("TRAIN C finalization parity", 1),
    "contracts": ("Contract shard", 4),
}


class ReuseRefusal(Exception):
    """Fixed diagnostic code; never expose API bodies or input contents."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _require(condition, code):
    if not condition:
        raise ReuseRefusal(code)


def _is_ancestor(repo, ancestor, descendant):
    result = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, descendant],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    return result.returncode == 0


def _parse_time(value):
    if not isinstance(value, str):
        raise ReuseRefusal("evidence_missing")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ReuseRefusal("evidence_missing") from None


class GitHubApi:
    """Minimal read-only Actions API; no writes and no privileged token."""

    def __init__(self, token, repo, base="https://api.github.com"):
        self.token = token
        self.repo = repo
        self.base = base
        self._opener = urllib.request.build_opener(_DropAuthorizationOnRedirect())

    @classmethod
    def from_environment(cls, env, repo=None):
        token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
        name = repo or env.get("GITHUB_REPOSITORY")
        if not token or not name:
            return None
        return cls(token, name)

    def _request(self, path):
        request = urllib.request.Request(
            self.base + path,
            headers={"Authorization": f"Bearer {self.token}",
                     "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28",
                     "User-Agent": "shiroha-ci-impact"})
        try:
            with self._opener.open(request, timeout=30) as response:
                return response.read()
        except (urllib.error.URLError, OSError, ValueError):
            raise ReuseRefusal("api_unavailable") from None

    def _json(self, path):
        try:
            return json.loads(self._request(path))
        except (ValueError, TypeError):
            raise ReuseRefusal("api_unavailable") from None

    def list_runs(self, workflow, branch):
        if not branch:
            raise ReuseRefusal("no_source_run")
        query = urllib.parse.urlencode(
            {"event": "pull_request", "branch": branch, "per_page": 30})
        payload = self._json(f"/repos/{self.repo}/actions/workflows/{workflow}/runs?{query}")
        runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
        if not isinstance(runs, list):
            raise ReuseRefusal("api_unavailable")
        return runs

    def get_run(self, run_id):
        return self._json(f"/repos/{self.repo}/actions/runs/{int(run_id)}")

    def list_jobs(self, run_id, attempt):
        payload = self._json(
            f"/repos/{self.repo}/actions/runs/{int(run_id)}/attempts/{int(attempt)}/jobs?per_page=100")
        jobs = payload.get("jobs") if isinstance(payload, dict) else None
        if not isinstance(jobs, list):
            raise ReuseRefusal("api_unavailable")
        if payload.get("total_count", len(jobs)) > len(jobs):
            raise ReuseRefusal("evidence_incomplete")
        return jobs

    def list_artifacts(self, run_id):
        payload = self._json(
            f"/repos/{self.repo}/actions/runs/{int(run_id)}/artifacts?per_page=100")
        artifacts = payload.get("artifacts") if isinstance(payload, dict) else None
        if not isinstance(artifacts, list):
            raise ReuseRefusal("api_unavailable")
        return artifacts

    def download_artifact(self, artifact_id):
        return self._request(f"/repos/{self.repo}/actions/artifacts/{int(artifact_id)}/zip")


class _DropAuthorizationOnRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            if urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
                redirected.remove_header("Authorization")
        return redirected


def _read_evidence(api, run_id):
    artifacts = [a for a in api.list_artifacts(run_id) if a.get("name") == PLAN_ARTIFACT]
    _require(len(artifacts) == 1, "evidence_missing")
    artifact = artifacts[0]
    _require(not artifact.get("expired"), "evidence_expired")
    _require(artifact.get("expires_at") is not None, "evidence_missing")
    blob = api.download_artifact(artifact["id"])
    try:
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            names = [name for name in archive.namelist() if name.endswith("plan.json")]
            _require(len(names) == 1, "evidence_mismatch")
            raw = archive.read(names[0])
        evidence = json.loads(raw, object_pairs_hook=impact.unique_fields)
    except (zipfile.BadZipFile, ValueError, KeyError, TypeError, OSError):
        raise ReuseRefusal("evidence_mismatch") from None
    _require(type(evidence) is dict and evidence.get("version") == 2, "evidence_mismatch")
    _require(evidence.get("planSha256") == impact.canonical(evidence), "evidence_mismatch")
    return artifact, evidence, hashlib.sha256(raw).hexdigest()


def _unit_jobs(jobs, unit, attempt, head):
    prefix, count = UNIT_JOBS[unit]
    if count == 1:
        matching = [job for job in jobs if job.get("name") == prefix]
    else:
        matching = [job for job in jobs if re.fullmatch(rf"{re.escape(prefix)} (\d)/{count}", job.get("name", ""))]
        names = sorted(job.get("name") for job in matching)
        _require(names == [f"{prefix} {index}/{count}" for index in range(1, count + 1)], "shard_mismatch")
    _require(len(matching) == count, "job_missing")
    for job in matching:
        _require(job.get("conclusion") == "success", "source_not_successful")
        _require(job.get("run_attempt") == attempt, "attempt_mismatch")
        _require(job.get("head_sha") == head, "evidence_mismatch")
    return matching


def _validate_candidate(repo, plan, api, run, units, now):
    head = impact.sha(run.get("head_sha"))
    _require(plan.get("workflowSha256") is not None, "inputs_changed")
    _require(head != plan["headSha"], "source_is_current_head")
    _require(_is_ancestor(repo, head, plan["headSha"]), "source_not_ancestor")
    rules, _digest = impact.read_rules(Path(repo) / "tool/ci/impact_rules.json")
    delta = impact.changes_between(repo, head, plan["headSha"])
    _require(bool(delta), "delta_empty")
    _require(all(impact.ordinary_document(change, rules) for change in delta), "delta_not_ordinary")
    _require(impact.tree_sha256(repo, head, rules) == plan["treeSha256"], "inputs_changed")
    _require(impact.workflow_sha256(repo, head) == plan["workflowSha256"], "inputs_changed")
    _require(impact.pinned_inputs(repo, head) == impact.pinned_inputs(repo, plan["headSha"]),
             "inputs_changed")

    attempt = int(run.get("run_attempt") or 0)
    _require(attempt >= 1, "attempt_mismatch")
    artifact, evidence, evidence_sha = _read_evidence(api, run["id"])
    _require(evidence.get("event") == "pull_request" and evidence.get("mode") == "plan", "evidence_mismatch")
    _require(evidence.get("headSha") == head, "evidence_mismatch")
    _require(evidence.get("baseSha") == plan["baseSha"], "base_changed")
    _require(evidence.get("mergeBaseSha") == plan["mergeBaseSha"], "base_changed")
    _require(evidence.get("testedSha") is not None, "evidence_mismatch")
    _require(evidence.get("rulesSha256") == plan["rulesSha256"], "inputs_changed")
    _require(evidence.get("workflowSha256") == plan["workflowSha256"], "inputs_changed")
    _require(evidence.get("treeSha256") == plan["treeSha256"], "inputs_changed")
    _require(evidence.get("flutterVersion") == plan["flutterVersion"] != "unknown", "toolchain_changed")
    current_runner, source_runner = plan["runner"], evidence.get("runner") or {}
    _require(bool(current_runner.get("imageVersion")) and bool(source_runner.get("imageVersion")),
             "toolchain_unverified")
    _require(current_runner.get("image") == source_runner.get("image")
             and current_runner.get("imageVersion") == source_runner.get("imageVersion"),
             "toolchain_changed")
    for unit in units:
        unit_evidence = (evidence.get("units") or {}).get(unit) or {}
        _require(unit_evidence.get("status") == impact.EXECUTE, "source_used_reuse")
        _require((evidence.get("requiredJobs") or {}).get(unit) is True, "evidence_mismatch")
    expires = _parse_time(artifact.get("expires_at"))
    _require(expires > now, "evidence_expired")
    jobs = api.list_jobs(run["id"], attempt)
    for unit in units:
        _unit_jobs(jobs, unit, attempt, head)
    return {
        "runId": int(run["id"]), "runAttempt": attempt, "headSha": head,
        "baseSha": plan["baseSha"], "mergeBaseSha": plan["mergeBaseSha"],
        "artifactId": int(artifact["id"]), "artifactName": PLAN_ARTIFACT,
        "evidenceSha256": evidence_sha, "treeSha256": plan["treeSha256"],
        "workflowSha256": plan["workflowSha256"], "rulesSha256": plan["rulesSha256"],
        "flutterVersion": plan["flutterVersion"],
        "runnerImage": current_runner.get("image"),
        "runnerImageVersion": current_runner.get("imageVersion"),
        "units": list(units), "createdAt": run.get("created_at"),
    }


def _belongs_to_pr(run, pr_number):
    entries = run.get("pull_requests") or []
    if entries:
        return any(pr.get("number") == pr_number for pr in entries)
    # GitHub omits this array for many same-repository pull_request runs (verified
    # against this repository's own runs). Identity is then bound by the repository,
    # workflow, head branch, ancestor head and the identical Base recorded in the
    # source plan, so a run can only belong to this PR's own history.
    return pr_number is not None


def apply(repo, plan, api, repo_full_name, base_repo_full_name, pr_number, head_ref, now=None):
    plan["reuse"] = {"status": "REFUSED", "code": "reuse_not_applicable", "source": None, "units": []}
    if plan["event"] != "pull_request" or plan["mode"] != "plan":
        return impact.seal(plan)
    if not repo_full_name or repo_full_name != base_repo_full_name:
        plan["reuse"]["code"] = "fork_source"
        return impact.seal(plan)
    blocked = sorted(set(plan["reasons"]) & BLOCKING_REASONS)
    if blocked:
        plan["reuse"]["code"] = "ci_inputs_changed"
        plan["reuse"]["blockedReasons"] = blocked
        return impact.seal(plan)
    units = [unit for unit in REUSABLE if plan["units"][unit]["status"] == impact.EXECUTE]
    if not units:
        return impact.seal(plan)
    if api is None:
        plan["reuse"]["code"] = "api_unavailable"
        return impact.seal(plan)
    now = now or datetime.now(timezone.utc)
    reason = "no_source_run"
    try:
        runs = api.list_runs(WORKFLOW_FILE, head_ref)
    except ReuseRefusal as refusal:
        plan["reuse"]["code"] = refusal.code
        return impact.seal(plan)
    ordered = sorted(runs, key=lambda run: (run.get("created_at") or "", run.get("id") or 0), reverse=True)
    for run in ordered[:20]:
        if run.get("event") != "pull_request" or run.get("conclusion") != "success":
            continue
        if run.get("head_branch") != head_ref or not _belongs_to_pr(run, pr_number):
            continue
        if (run.get("head_repository") or {}).get("full_name") != base_repo_full_name:
            continue
        try:
            source = _validate_candidate(repo, plan, api, run, units, now)
        except ReuseRefusal as refusal:
            reason = refusal.code
            continue
        except impact.ImpactError:
            reason = "evidence_mismatch"
            continue
        for unit in units:
            plan["units"][unit] = {
                "status": impact.REUSE, "reason": "verified_input_equivalence",
                "sourceRunId": source["runId"], "sourceHeadSha": source["headSha"],
            }
        plan["reuse"] = {"status": "APPLIED", "code": "reuse_applied",
                         "source": source, "units": list(units)}
        return impact.seal(plan)
    plan["reuse"]["code"] = reason
    return impact.seal(plan)


def validate_applied(repo, plan, api, now=None):
    """Re-validate a recorded REUSE claim; any drift is a hard gate failure."""
    reuse = plan.get("reuse") or {}
    _require(reuse.get("status") == "APPLIED", "reuse_mismatch")
    source = reuse.get("source") or {}
    _require(isinstance(api, GitHubApi) or hasattr(api, "get_run"), "api_unavailable")
    _require(bool(source.get("units")), "reuse_mismatch")
    _require(sorted(source["units"]) == sorted(reuse.get("units") or []), "reuse_mismatch")
    for unit in source["units"]:
        _require(plan["units"][unit]["status"] == impact.REUSE, "reuse_mismatch")
    run = api.get_run(source["runId"])
    _require(run.get("conclusion") == "success", "source_not_successful")
    _require(int(source["runAttempt"]) >= 1, "attempt_mismatch")
    now = now or datetime.now(timezone.utc)
    try:
        validated = _validate_candidate(repo, plan, api, run, list(source["units"]), now)
    except impact.ImpactError:
        raise ReuseRefusal("evidence_mismatch") from None
    for key in ("runId", "runAttempt", "headSha", "baseSha", "mergeBaseSha",
                "artifactId", "evidenceSha256", "treeSha256", "workflowSha256",
                "rulesSha256", "flutterVersion", "runnerImage", "runnerImageVersion"):
        _require(validated[key] == source.get(key), "evidence_mismatch")
    return validated
