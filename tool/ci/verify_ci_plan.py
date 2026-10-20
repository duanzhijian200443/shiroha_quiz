"""Fail-closed aggregate verification for selective CI unit execution.

The aggregate never trusts a single boolean: it re-reads the plan digest, binds
it to the checked-out identities, recomputes classification from Git, revalidates
every recorded reuse claim against the source run, and compares GitHub's job
results and matrix membership with the plan.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))

import resolve_ci_impact as impact  # noqa: E402
import resolve_ci_reuse as reuse  # noqa: E402


RESULT_ENV = {
    "impact": "RESULT_IMPACT",
    "static": "RESULT_STATIC",
    "windows_native": "RESULT_WINDOWS_NATIVE",
    "train_c_finalization_parity": "RESULT_TRAIN_C_FINALIZATION_PARITY",
    "contracts": "RESULT_CONTRACTS",
}
SHARD_POLL_ATTEMPTS = 12
SHARD_POLL_INTERVAL_SECONDS = 5


class GateError(Exception):
    """Fixed diagnostic code; never expose raw inputs or API bodies."""


def _require(condition, code):
    if not condition:
        raise GateError(code)


def _expected(status):
    return "success" if status == impact.EXECUTE else "skipped"


def _duration(job):
    try:
        start = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
        return round((end - start).total_seconds(), 1)
    except (KeyError, TypeError, ValueError, AttributeError):
        return None


def _jobs(api, run_id, attempt):
    if api is None:
        return None
    try:
        return api.list_jobs(run_id, attempt)
    except reuse.ReuseRefusal:
        return None


def _shard_jobs(jobs):
    matching = [job for job in jobs if job.get("name", "").startswith("Contract shard ")]
    names = sorted(job.get("name") for job in matching)
    _require(names == [f"Contract shard {index}/4" for index in range(1, 5)], "shard_mismatch")
    return matching


def _settled_jobs(api, run_id, attempt, contracts_execute, pause):
    jobs = _jobs(api, run_id, attempt)
    if not contracts_execute:
        return jobs
    # needs.contracts.result is already success here. A newer matrix job can still
    # briefly read back with a pending conclusion, so poll the observation rather
    # than failing on a transient inconsistency; an unsettled matrix still fails.
    for remaining in range(SHARD_POLL_ATTEMPTS):
        _require(jobs is not None, "matrix_unverifiable")
        shard_jobs = _shard_jobs(jobs)
        if all(job.get("conclusion") == "success" for job in shard_jobs):
            return jobs
        if remaining + 1 == SHARD_POLL_ATTEMPTS:
            break
        pause(SHARD_POLL_INTERVAL_SECONDS)
        jobs = _jobs(api, run_id, attempt)
    raise GateError("shard_not_success")


def validate(plan, repo, results, api, event_name, event, run_id, attempt, now=None, pause=None):
    now = now or datetime.now(timezone.utc)
    _require(plan.get("version") == 2, "invalid_plan")
    _require(plan.get("planSha256") == impact.canonical(plan), "plan_digest_mismatch")
    tested = impact.git(repo, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    _require(plan.get("testedSha") == tested, "identity_mismatch")
    if event_name == "pull_request":
        try:
            head = event["pull_request"]["head"]["sha"]
            base = event["pull_request"]["base"]["sha"]
        except (KeyError, TypeError):
            raise GateError("identity_mismatch") from None
        _require(plan.get("headSha") == head and plan.get("baseSha") == base, "identity_mismatch")
    else:
        _require(plan.get("headSha") == tested, "identity_mismatch")

    rules, digest = impact.read_rules(Path(repo) / "tool/ci/impact_rules.json")
    _require(plan.get("rulesSha256") == digest, "rules_changed")
    _require(plan.get("workflowSha256") is not None, "workflow_changed")
    _require(plan.get("workflowSha256") == impact.workflow_sha256(repo, tested), "workflow_changed")
    _require(plan.get("treeSha256") == impact.tree_sha256(repo, tested, rules), "inputs_changed")
    _require(plan.get("flutterVersion") == impact.flutter_version(repo, tested), "toolchain_changed")

    computed = impact.resolve_plan(repo, event_name, event, rules, digest, "plan", tested_ref=tested)
    _require(computed["requiredJobs"] == plan.get("requiredJobs"), "classification_mismatch")
    _require(computed["reasons"] == plan.get("reasons"), "classification_mismatch")

    _require(results.get("impact") == "success", "impact_not_success")

    # requiredJobs is the pre-reuse rule decision and units is the post-reuse
    # dispatch. A unit cannot be downgraded to NOT_APPLICABLE (or upgraded to
    # REUSE) unless both agree, so a tampered or buggy plan cannot skip a
    # required unit while still passing the result comparison.
    for job in impact.JOBS:
        required = plan["requiredJobs"].get(job)
        status = plan["units"][job]["status"]
        if required is False:
            _require(status == impact.NOT_APPLICABLE, "classification_mismatch")
        else:
            _require(required is True and status in (impact.EXECUTE, impact.REUSE),
                     "classification_mismatch")
    reuse_units = [job for job in impact.JOBS if plan["units"][job]["status"] == impact.REUSE]
    _require(sorted(reuse_units) == sorted(plan["reuse"].get("units") or []), "reuse_mismatch")
    if reuse_units:
        try:
            reuse.validate_applied(repo, plan, api, now)
        except reuse.ReuseRefusal as refusal:
            raise GateError(f"reuse_{refusal.code}") from None
    for job in impact.JOBS:
        status = plan["units"][job]["status"]
        expected = _expected(status)
        actual = results.get(job)
        _require(actual == expected, f"unit_{job}_{status.lower()}_not_{expected}")

    contracts_execute = plan["units"]["contracts"]["status"] == impact.EXECUTE
    jobs = _settled_jobs(api, run_id, attempt, contracts_execute, pause or time.sleep)
    shards = None
    if contracts_execute:
        shards = sorted(job.get("name") for job in _shard_jobs(jobs))

    durations = {}
    if jobs is not None:
        for job in jobs:
            name = job.get("name")
            if name and name not in durations:
                durations[name] = _duration(job)
    shard_seconds = [durations.get(f"Contract shard {index}/4") for index in range(1, 5)]
    shard_seconds = [value for value in shard_seconds if value is not None]
    display = {
        "static": "Static changed-Dart checks",
        "windows_native": "Windows native offline contracts",
        "train_c_finalization_parity": "TRAIN C finalization parity",
        "contracts": "Contract shard 1/4",
    }
    started = None
    if api is not None:
        try:
            started = datetime.fromisoformat(api.get_run(run_id)["run_started_at"].replace("Z", "+00:00"))
        except (reuse.ReuseRefusal, KeyError, TypeError, ValueError):
            started = None
    return {
        "version": 1, "verdict": "PASS", "runId": run_id, "headSha": plan["headSha"],
        "baseSha": plan["baseSha"], "mergeBaseSha": plan["mergeBaseSha"],
        "units": {job: {"status": plan["units"][job]["status"], "result": results.get(job),
                        "durationSeconds": (max(shard_seconds) if job == "contracts" and shard_seconds
                                            else durations.get(display[job]))}
                  for job in impact.JOBS},
        "impact": {"result": results.get("impact"),
                   "durationSeconds": durations.get("Change impact analysis")},
        "totals": {
            "executed": sum(1 for job in impact.JOBS if plan["units"][job]["status"] == impact.EXECUTE),
            "notApplicable": sum(1 for job in impact.JOBS if plan["units"][job]["status"] == impact.NOT_APPLICABLE),
            "reused": len(reuse_units),
            "elapsedSeconds": round((now - started).total_seconds(), 1) if started else None,
        },
        "reuse": {"status": plan["reuse"]["status"], "code": plan["reuse"]["code"],
                  "sourceRunId": (plan["reuse"].get("source") or {}).get("runId"),
                  "units": plan["reuse"].get("units", [])},
        "shards": shards, "wronglySkipped": [],
    }


def summary(report):
    lines = ["## CI execution report", f"Verdict: {report['verdict']}.",
             f"Units executed {report['totals']['executed']}, not applicable "
             f"{report['totals']['notApplicable']}, reused {report['totals']['reused']}; "
             f"elapsed {report['totals']['elapsedSeconds']}s.",
             f"Reuse {report['reuse']['status']} ({report['reuse']['code']}); "
             f"source run {report['reuse']['sourceRunId']}.", "",
             "| Unit | Status | GitHub result | Seconds |", "|---|---|---|---|",
             f"| impact | - | {report['impact']['result']} | {report['impact']['durationSeconds']} |"]
    for job, unit in report["units"].items():
        lines.append(f"| {job} | {unit['status']} | {unit['result']} | {unit['durationSeconds']} |")
    if report["shards"] is not None:
        lines.append("")
        lines.append(f"Contract shards observed: {', '.join(report['shards'])}.")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--event-path", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME"))
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID"))
    parser.add_argument("--attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    parser.add_argument("--output", default=".dart_tool/ci-execution/report.json")
    args = parser.parse_args()
    try:
        plan = impact.read_plan(args.plan)
        event = json.loads(Path(args.event_path).read_text(encoding="utf-8"))
        results = {job: os.environ.get(name, "") for job, name in RESULT_ENV.items()}
        api = reuse.GitHubApi.from_environment(os.environ)
        report = validate(plan, impact.ROOT, results, api, args.event_name, event,
                          int(args.run_id or 0), int(args.attempt or 1))
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        text = summary(report)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                stream.write(text)
        print(text)
        return 0
    except (impact.ImpactError, GateError) as error:
        print(f"FAIL: ci_gate:{error}")
        return 1
    except (OSError, ValueError, TypeError, KeyError):
        print("FAIL: ci_gate:input_or_output_invalid")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
