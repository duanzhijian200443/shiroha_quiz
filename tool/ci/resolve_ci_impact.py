"""Offline PR impact observation. Recommendations never authorize skipped jobs."""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import posixpath
import re
import subprocess
from urllib.parse import unquote


JOBS = ("static", "windows_native", "train_c_finalization_parity", "contracts")
ROOT = Path(__file__).resolve().parents[2]
ACCEPTANCE_MATERIALS = {
    "docs/product/agent-refactor/windows-host-acceptance-plan.json",
    "docs/product/agent-refactor/windows-host-acceptance-preparation.md",
}


class ImpactError(Exception):
    """Fixed diagnostic code; never expose Git stderr or input contents."""


def git(repo, *args):
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        raise ImpactError("git_unavailable") from None


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ImpactError("invalid_target")
    return value


def safe_path(value):
    return (isinstance(value, str) and bool(value)
            and re.fullmatch(r"[a-zA-Z0-9_./ -]+", value) is not None
            and not value.startswith("/")
            and not any(p in ("", ".", "..") for p in value.split("/")))


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def read_rules(path):
    raw = path.read_bytes()
    try:
        rules = json.loads(raw, object_pairs_hook=unique_fields)
        if (set(rules) != {"version", "ordinaryDocuments", "routes"}
                or type(rules["version"]) is not int or rules["version"] != 1
                or rules["ordinaryDocuments"] != ["README.md"]
                or not isinstance(rules["routes"], list) or not rules["routes"]):
            raise ValueError()
        ids = set()
        for route in rules["routes"]:
            if (set(route) != {"id", "paths", "prefixes", "suffixes", "jobs"}
                    or not re.fullmatch(r"[a-z_]+", route["id"])
                    or route["id"] in ids):
                raise ValueError()
            ids.add(route["id"])
            for key in ("paths", "prefixes", "suffixes", "jobs"):
                if (not isinstance(route[key], list)
                        or any(not isinstance(v, str) or not v for v in route[key])):
                    raise ValueError()
            if (not route["jobs"] or not set(route["jobs"]) <= set(JOBS)
                    or not (route["paths"] or route["prefixes"])
                    or any(not safe_path(p) for p in route["paths"])
                    or any(not safe_path(p.rstrip("/")) for p in route["prefixes"])
                    or any(not re.fullmatch(r"\.[a-z]+", s) for s in route["suffixes"])):
                raise ValueError()
    except (ValueError, TypeError, KeyError):
        raise ImpactError("invalid_rules") from None
    return rules, hashlib.sha256(raw).hexdigest()


@dataclass(frozen=True)
class Change:
    path: str
    status: str = "M"
    old_mode: str = "100644"
    new_mode: str = "100644"


def changes_between(repo, before, after):
    # No rename heuristic: a rename is conservatively an old-path deletion and
    # new-path addition. NUL framing retains spaces and never executes diff drivers.
    raw = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--raw",
              "--no-abbrev", "--no-renames", "-z", before, after, "--")
    fields = raw.split(b"\0")
    if fields.pop() != b"" or len(fields) % 2:
        raise ImpactError("invalid_diff")
    result = []
    try:
        for index in range(0, len(fields), 2):
            mode, new_mode, _, _, status = fields[index].decode("ascii").split()
            if not re.fullmatch(r":[0-7]{6}", mode) or not re.fullmatch(r"[0-7]{6}", new_mode):
                raise ValueError()
            result.append(Change(fields[index + 1].decode("utf-8"), status, mode[1:], new_mode))
    except (UnicodeError, ValueError):
        raise ImpactError("invalid_diff") from None
    return result


def classify(changes, rules):
    required, reasons = set(), set()
    if not changes:
        return set(JOBS), {"empty_diff"}
    for change in changes:
        path = change.path
        if (not safe_path(path) or change.status not in ("A", "M", "D")
                or change.old_mode not in ("000000", "100644")
                or change.new_mode not in ("000000", "100644")):
            required.update(JOBS)
            reasons.add("unsafe_path_or_type")
            continue
        if path in rules["ordinaryDocuments"]:
            if change.status == "M" and change.old_mode == change.new_mode == "100644":
                reasons.add("ordinary_document")
            else:
                required.update(JOBS)
                reasons.add("document_structure_changed")
            continue
        # Documentation is executable-policy input in this repository. A route
        # cannot override that floor by calling a security README ordinary prose.
        if path.endswith(".md") and path not in ACCEPTANCE_MATERIALS:
            required.update(JOBS)
            reasons.add("contract_document")
            continue
        for route in rules["routes"]:
            matches = path in route["paths"] or any(path.startswith(p) for p in route["prefixes"])
            if matches and (not route["suffixes"] or any(path.endswith(s) for s in route["suffixes"])):
                required.update(route["jobs"])
                reasons.add(route["id"])
                break
        else:
            required.update(JOBS)
            reasons.add("unknown_path")
    return required, reasons


def check_readme_links(repo, tested):
    text = git(repo, "show", f"{tested}:README.md").decode("utf-8")
    # Validate local file targets only; no external network requests. Unsupported
    # Markdown reference syntax widens the recommendation rather than guessing.
    unsupported = bool(re.search(r"(?m)^\s*\[[^\]]+\]:", text))
    for match in re.finditer(r"\[[^\]\r\n]*\]\(([^)\r\n]+)\)", text):
        target = match[1].strip().split()[0].strip("<>")
        if re.match(r"^(?:https?://|mailto:)", target) or target.startswith("#"):
            continue
        target = unquote(target.split("#", 1)[0])
        if not safe_path(target):
            unsupported = True
            continue
        try:
            git(repo, "cat-file", "-e", f"{tested}:{posixpath.normpath(target)}")
        except ImpactError:
            raise ImpactError("missing_document_reference") from None
    return unsupported


def resolve_plan(repo, event_name, event, rules, rules_hash, mode="shadow", tested_ref="HEAD"):
    if mode not in ("shadow", "full"):
        raise ImpactError("invalid_mode")
    if not isinstance(event, dict):
        raise ImpactError("invalid_event")
    tested = sha(git(repo, "rev-parse", "--verify", f"{tested_ref}^{{commit}}").decode().strip())
    plan = {
        "version": 1, "mode": mode, "event": event_name, "headSha": tested,
        "baseSha": None, "mergeBaseSha": None, "testedSha": tested,
        "rulesSha256": rules_hash, "changedFileCount": 0,
        "recommendedJobs": dict.fromkeys(JOBS, True),
        "executionJobs": dict.fromkeys(JOBS, True), "reasons": [],
    }
    if event_name != "pull_request":
        if event_name == "push" and sha(event.get("after")) != tested:
            raise ImpactError("target_mismatch")
        if event_name == "push" and event.get("before") not in (None, "0" * 40):
            plan["baseSha"] = sha(event["before"])
        plan["reasons"] = ["non_pr_full"]
        return plan
    try:
        head = sha(event["pull_request"]["head"]["sha"])
        base = sha(event["pull_request"]["base"]["sha"])
    except (KeyError, TypeError):
        raise ImpactError("invalid_target") from None
    plan.update(headSha=head, baseSha=base)
    try:
        parents = git(repo, "rev-list", "--parents", "-n", "1", tested).decode().split()[1:]
        if len(parents) != 2 or parents != [base, head]:
            raise ImpactError("target_mismatch")
        merge_bases = git(repo, "merge-base", "--all", base, head).decode().split()
        if len(merge_bases) != 1:
            raise ImpactError("ambiguous_diff")
        merge_base = sha(merge_bases[0])
        plan["mergeBaseSha"] = merge_base
        # Union cumulative PR changes and actual merge-result changes, rather
        # than inspecting only the most recent push or only one diff view.
        changes = list(set(changes_between(repo, merge_base, head)
                           + changes_between(repo, base, tested)))
    except ImpactError as error:
        if str(error) == "target_mismatch":
            raise
        plan["reasons"] = ["diff_unavailable_full"]
        return plan
    git(repo, "diff", "--no-ext-diff", "--check", merge_base, head, "--")
    git(repo, "diff", "--no-ext-diff", "--check", base, tested, "--")
    required, reasons = classify(changes, rules)
    if merge_base != base:
        required.update(JOBS)
        reasons.add("base_diverged_full")
    if "ordinary_document" in reasons and check_readme_links(repo, tested):
        required.update(JOBS)
        reasons.add("unsupported_document_reference_full")
    if mode == "full":
        required.update(JOBS)
        reasons.add("forced_full")
    plan.update(changedFileCount=len({change.path for change in changes}), reasons=sorted(reasons),
                recommendedJobs={job: job in required for job in JOBS})
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-path", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME"))
    parser.add_argument("--mode", choices=("shadow", "full"), default="shadow")
    args = parser.parse_args()
    try:
        if not args.event_path or not args.event_name:
            raise ImpactError("missing_event")
        event = json.loads(Path(args.event_path).read_text(encoding="utf-8"), object_pairs_hook=unique_fields)
        rules, digest = read_rules(ROOT / "tool/ci/impact_rules.json")
        plan = resolve_plan(ROOT, args.event_name, event, rules, digest, args.mode)
        output = ROOT / ".dart_tool/ci-impact/plan.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
        lines = ["## CI impact observation", f"Mode: {plan['mode']}; all validation jobs execute.",
                 f"Head: `{plan['headSha']}`; Base: `{plan['baseSha']}`; Tested: `{plan['testedSha']}`.",
                 f"Changed files: {plan['changedFileCount']}; reasons: {', '.join(plan['reasons'])}.",
                 "", "| Job | Recommended | Actual policy |", "|---|---|---|"]
        for job in JOBS:
            lines.append(f"| {job} | {'execute' if plan['recommendedJobs'][job] else 'not applicable'} | execute |")
        summary = "\n".join(lines) + "\n"
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                stream.write(summary)
        print(summary)
        return 0
    except (ImpactError, OSError, ValueError) as error:
        code = str(error) if isinstance(error, ImpactError) else "input_or_output_invalid"
        print(f"FAIL: ci_impact:{code}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
