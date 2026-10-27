"""Offline PR impact planning. A plan may omit a unit only through fixed rules.

The plan is bound to the event identities, the rule digest, the workflow digest
and a content digest of every tracked input outside the ordinary document
allowlist. It never contains source contents or raw Git stderr.
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import platform
import posixpath
import re
import subprocess
import sys
from urllib.parse import unquote


JOBS = ("static", "windows_native", "train_c_finalization_parity", "contracts")
EXECUTE = "EXECUTE"
NOT_APPLICABLE = "NOT_APPLICABLE"
REUSE = "REUSE"
ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ".github/workflows/pr-contract-checks.yml"
ACCEPTANCE_MATERIALS = {
    "docs/product/agent-refactor/windows-host-acceptance-plan.json",
    "docs/product/agent-refactor/windows-host-acceptance-preparation.md",
}
PINNED_INPUTS = (
    WORKFLOW,
    "tool/ci/impact_rules.json",
    "tool/ci/resolve_ci_impact.py",
    "tool/ci/resolve_ci_reuse.py",
    "tool/ci/verify_ci_plan.py",
    "tool/verify_changed.ps1",
    "pubspec.lock",
    "pubspec.yaml",
    "analysis_options.yaml",
)


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


def ordinary_document(change, rules):
    """True only for an in-place content edit of an allowlisted ordinary document."""
    return (change.path in rules["ordinaryDocuments"]
            and change.status == "M"
            and change.old_mode == change.new_mode == "100644")


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
            if ordinary_document(change, rules):
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


def local_markdown_targets(text):
    """Return inline local file targets and whether the grammar was unsupported.

    Angle-bracketed destinations may contain spaces. A plain destination ends at
    whitespace, after which only a quoted or parenthesised optional title is
    accepted. Reference-style definitions and unknown trailing tokens widen the
    recommendation instead of guessing a partial path.
    """
    unsupported = bool(re.search(r"(?m)^\s*\[[^\]]+\]:", text))
    targets = []
    title = re.compile(r"^(?:\"[^\"]*\"|'[^']*'|\([^)]*\))$")
    for match in re.finditer(r"\[[^\]\r\n]*\]\(([^)\r\n]*)\)", text):
        raw = match.group(1).strip()
        if raw.startswith("<"):
            end = raw.find(">")
            if end < 0:
                unsupported = True
                continue
            target = raw[1:end].strip()
            remainder = raw[end + 1:].strip()
        else:
            parts = raw.split(None, 1)
            target = parts[0] if parts else ""
            remainder = parts[1].strip() if len(parts) == 2 else ""
        if remainder and not title.match(remainder):
            unsupported = True
            continue
        if not target:
            unsupported = True
            continue
        if re.match(r"^(?:https?://|mailto:)", target) or target.startswith("#"):
            continue
        target = unquote(target.split("#", 1)[0])
        if not safe_path(target):
            unsupported = True
            continue
        targets.append(posixpath.normpath(target))
    return targets, unsupported


def check_readme_links(repo, tested):
    text = git(repo, "show", f"{tested}:README.md").decode("utf-8")
    # Validate local file targets only; no external network requests. Unsupported
    # Markdown reference syntax widens the recommendation rather than guessing.
    targets, unsupported = local_markdown_targets(text)
    for target in targets:
        try:
            git(repo, "cat-file", "-e", f"{tested}:{target}")
        except ImpactError:
            raise ImpactError("missing_document_reference") from None
    return unsupported


def _blob_sha(repo, ref, path):
    try:
        raw = git(repo, "rev-parse", "--verify", f"{ref}:{path}")
    except ImpactError:
        return None
    return raw.decode().strip()


def workflow_sha256(repo, ref):
    try:
        raw = git(repo, "show", f"{ref}:{WORKFLOW}")
    except ImpactError:
        return None
    return hashlib.sha256(raw).hexdigest()


def tree_sha256(repo, ref, rules):
    raw = git(repo, "ls-tree", "-r", "-z", "--full-tree", ref)
    lines = []
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, kind, obj = meta.decode("ascii").split()
        name = path.decode("utf-8")
        if kind == "blob" and name in rules["ordinaryDocuments"]:
            continue
        lines.append(f"{mode} {kind} {obj} {name}")
    lines.sort()
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def flutter_version(repo, ref):
    try:
        text = git(repo, "show", f"{ref}:{WORKFLOW}").decode("utf-8")
    except ImpactError:
        return "unknown"
    versions = sorted(set(re.findall(r"(?m)^\s+flutter-version:\s*(\S+)\s*$", text)))
    return versions[0] if len(versions) == 1 else "unknown"


def pinned_inputs(repo, ref):
    return {path: _blob_sha(repo, ref, path) for path in PINNED_INPUTS}


def runner():
    return {
        "os": platform.system(),
        "image": os.environ.get("ImageOS", ""),
        "imageVersion": os.environ.get("ImageVersion", ""),
    }


def canonical(plan):
    body = {key: value for key, value in plan.items() if key != "planSha256"}
    return hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def seal(plan):
    plan["planSha256"] = canonical(plan)
    return plan


def read_plan(path):
    try:
        plan = json.loads(Path(path).read_bytes(), object_pairs_hook=unique_fields)
    except (OSError, ValueError, TypeError):
        raise ImpactError("invalid_plan") from None
    if type(plan) is not dict or plan.get("version") != 2:
        raise ImpactError("invalid_plan")
    if plan.get("planSha256") != canonical(plan):
        raise ImpactError("plan_digest_mismatch")
    if set(plan.get("units", {})) != set(JOBS):
        raise ImpactError("invalid_plan")
    for job in JOBS:
        unit = plan["units"][job]
        if type(unit) is not dict or unit.get("status") not in (EXECUTE, NOT_APPLICABLE, REUSE):
            raise ImpactError("invalid_plan")
    return plan


def commit_sha(repo, ref):
    try:
        raw = git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}")
    except ImpactError:
        raise ImpactError("invalid_target") from None
    return sha(raw.decode().strip())


def pull_request_merge_target(repo, tested, pull, head, base, trigger_sha=None):
    """Bind ordinary or explicitly stacked GitHub merge topology to the event."""
    try:
        parents = git(repo, "rev-list", "--parents", "-n", "1", tested).decode().split()[1:]
        if len(parents) != 2 or parents[1] != head:
            raise ImpactError("target_mismatch")
        target = parents[0]
        stack = pull.get("stack")
        if stack is None:
            if target != base:
                raise ImpactError("target_mismatch")
            return target, None
        if (type(stack) is not dict
                or any(type(stack.get(key)) is not int or stack[key] < 1
                       for key in ("id", "number", "position", "size"))
                or stack["position"] > stack["size"]
                or sha(trigger_sha if trigger_sha is not None else pull.get("merge_commit_sha")) != tested):
            raise ImpactError("target_mismatch")
        stack_base = sha(stack["base"]["sha"])
        head_repo = pull["head"]["repo"]["full_name"]
        if not head_repo or head_repo != pull["base"]["repo"]["full_name"]:
            raise ImpactError("target_mismatch")
        trunk = target
        if stack["position"] == 1:
            if base != stack_base:
                raise ImpactError("target_mismatch")
        elif target != base:
            # An upper entry merges onto the lower PR's synthetic merge, whose
            # second parent must be this event's exact direct Base.
            lower = git(repo, "rev-list", "--parents", "-n", "1", target).decode().split()[1:]
            if len(lower) != 2 or lower[1] != base:
                raise ImpactError("target_mismatch")
            trunk = lower[0]
        git(repo, "merge-base", "--is-ancestor", stack_base, trunk)
        git(repo, "merge-base", "--is-ancestor", base, head)
        return target, stack_base
    except (ImpactError, KeyError, TypeError):
        # Unknown topology/metadata cannot fall back to an unbound full run.
        raise ImpactError("target_mismatch") from None


def resolve_plan(repo, event_name, event, rules, rules_hash, mode="plan", tested_ref="HEAD", trigger_sha=None):
    if mode not in ("plan", "full"):
        raise ImpactError("invalid_mode")
    if not isinstance(event, dict):
        raise ImpactError("invalid_event")
    tested = commit_sha(repo, tested_ref)
    if trigger_sha is not None and sha(trigger_sha) != tested:
        raise ImpactError("target_mismatch")
    plan = {
        "version": 2, "mode": mode, "event": event_name, "headSha": tested,
        "baseSha": None, "mergeBaseSha": None, "testedSha": tested,
        "mergeTargetSha": None, "stackBaseSha": None,
        "rulesSha256": rules_hash, "workflowSha256": workflow_sha256(repo, tested),
        "treeSha256": tree_sha256(repo, tested, rules), "flutterVersion": flutter_version(repo, tested),
        "runner": runner(), "changedFileCount": 0,
        "requiredJobs": dict.fromkeys(JOBS, True),
        "units": {job: {"status": EXECUTE, "reason": "non_pr_full"} for job in JOBS},
        "reasons": [], "reuse": {"status": "NOT_EVALUATED", "code": "reuse_not_evaluated"},
    }
    if event_name != "pull_request":
        if event_name == "push":
            if sha(event.get("after")) != tested:
                raise ImpactError("target_mismatch")
            if event.get("before") not in (None, "0" * 40):
                plan["baseSha"] = sha(event["before"])
            reason = "push_full"
        elif event_name == "schedule":
            reason = "scheduled_full"
        else:
            reason = "manual_full"
        plan["reasons"] = [reason]
        for job in JOBS:
            plan["units"][job]["reason"] = reason
        return seal(plan)
    try:
        head = sha(event["pull_request"]["head"]["sha"])
        base = sha(event["pull_request"]["base"]["sha"])
    except (KeyError, TypeError):
        raise ImpactError("invalid_target") from None
    plan.update(headSha=head, baseSha=base)
    target, stack_base = pull_request_merge_target(repo, tested, event["pull_request"], head, base, trigger_sha)
    plan.update(mergeTargetSha=target, stackBaseSha=stack_base)
    try:
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
        for job in JOBS:
            plan["units"][job]["reason"] = "diff_unavailable_full"
        return seal(plan)
    git(repo, "diff", "--no-ext-diff", "--check", merge_base, head, "--")
    git(repo, "diff", "--no-ext-diff", "--check", base, tested, "--")
    required, reasons = classify(changes, rules)
    if stack_base is not None:
        required.update(JOBS)
        reasons.add("stacked_merge_full")
    if merge_base != base:
        required.update(JOBS)
        reasons.add("base_diverged_full")
    if "ordinary_document" in reasons and check_readme_links(repo, tested):
        required.update(JOBS)
        reasons.add("unsupported_document_reference_full")
    if mode == "full":
        required.update(JOBS)
        reasons.add("forced_full")
    plan["reasons"] = sorted(reasons)
    plan["requiredJobs"] = {job: job in required for job in JOBS}
    plan["units"] = {
        job: {"status": EXECUTE if job in required else NOT_APPLICABLE,
              "reason": "changed_input_requires_unit" if job in required else "no_changed_input_requires_unit"}
        for job in JOBS
    }
    plan.update(changedFileCount=len({change.path for change in changes}))
    return seal(plan)


def write_outputs(plan, path):
    lines = [f"mode={plan['mode']}", f"planDigest={plan['planSha256']}"]
    for job in JOBS:
        key = "unit" + "".join(part.capitalize() for part in job.split("_"))
        status = plan["units"][job]["status"]
        lines.append(f"{key}={'execute' if status == EXECUTE else 'skip'}")
        lines.append(f"{key}Status={status}")
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def summary(plan):
    lines = ["## CI impact plan", f"Mode: {plan['mode']}; units drive job execution.",
             f"Head: `{plan['headSha']}`; Base: `{plan['baseSha']}`; Tested: `{plan['testedSha']}`.",
             f"Merge target: `{plan['mergeTargetSha']}`; stack base: `{plan['stackBaseSha']}`.",
             f"Changed files: {plan['changedFileCount']}; reasons: {', '.join(plan['reasons'])}.",
             f"Reuse: {plan['reuse']['status']} ({plan['reuse']['code']}).",
             "", "| Unit | Status | Reason |", "|---|---|---|"]
    for job in JOBS:
        unit = plan["units"][job]
        lines.append(f"| {job} | {unit['status']} | {unit['reason']} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-path", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME"))
    parser.add_argument("--mode", choices=("plan", "full"), default="plan")
    args = parser.parse_args()
    try:
        if not args.event_path or not args.event_name:
            raise ImpactError("missing_event")
        event = json.loads(Path(args.event_path).read_text(encoding="utf-8"), object_pairs_hook=unique_fields)
        rules, digest = read_rules(ROOT / "tool/ci/impact_rules.json")
        plan = resolve_plan(ROOT, args.event_name, event, rules, digest, args.mode,
                            trigger_sha=os.environ.get("GITHUB_SHA"))
        if args.event_name == "pull_request" and args.mode == "plan":
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import resolve_ci_reuse
            pull = event.get("pull_request") or {}
            head_event = pull.get("head") or {}
            plan = resolve_ci_reuse.apply(
                ROOT, plan, resolve_ci_reuse.GitHubApi.from_environment(os.environ),
                repo_full_name=(head_event.get("repo") or {}).get("full_name"),
                base_repo_full_name=(event.get("repository") or {}).get("full_name"),
                pr_number=pull.get("number"), head_ref=head_event.get("ref"),
            )
        write_plan(plan)
        text = summary(plan)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                stream.write(text)
        if os.environ.get("GITHUB_OUTPUT"):
            write_outputs(plan, os.environ["GITHUB_OUTPUT"])
        print(text)
        return 0
    except (ImpactError, OSError, ValueError) as error:
        code = str(error) if isinstance(error, ImpactError) else "input_or_output_invalid"
        print(f"FAIL: ci_impact:{code}")
        return 1


def write_plan(plan):
    output = ROOT / ".dart_tool/ci-impact/plan.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
