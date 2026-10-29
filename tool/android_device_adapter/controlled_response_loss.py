"""Explicit local validation only: withhold one selected STAGE reply from Codex.

No business implementation, credentials, content log, retry or forced process
termination. The original adapter still owns its TLS/DPAPI/CNG settlement.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import threading


class SelectedReply:
    def __init__(self, submission_key):
        self.key = submission_key
        self.request_id = None
        self.selected = False
        self.dropped = False

    def observe(self, packet):
        params = packet.get("params", {})
        if not isinstance(params, dict):
            return
        arguments = params.get("arguments", {})
        submission = arguments.get("submission", {}) if isinstance(arguments, dict) else {}
        if (not self.selected and packet.get("method") == "tools/call"
                and params.get("name") == "propose_generated_questions"
                and isinstance(submission, dict)
                and submission.get("submissionKey") == self.key
                and type(packet.get("id")) in (str, int)):
            self.selected = True
            self.request_id = packet["id"]

    def withhold(self, packet):
        if (not self.selected or self.dropped
                or type(packet.get("id")) is not type(self.request_id)
                or packet.get("id") != self.request_id):
            return False
        result = packet.get("result")
        envelope = result.get("structuredContent") if isinstance(result, dict) else None
        data = envelope.get("data") if isinstance(envelope, dict) else None
        if (not isinstance(data, dict) or envelope.get("profileVersion") != 2
                or envelope.get("error") is not None or result.get("isError") is True
                or data.get("submissionKey") != self.key
                or data.get("publication") != "STAGED"
                or data.get("formalCommit") != "NOT_REPORTED"):
            return False
        self.dropped = True
        return True


def pump(command, submission_key, evidence, source, destination):
    """Run one original child; EOF requests its own normal settlement."""
    selected = SelectedReply(submission_key)
    state = threading.Lock()
    writer = threading.Lock()
    stopped = threading.Event()
    startup = None
    if sys.platform == "win32":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=None, startupinfo=startup)

    def record(phase, **counts):
        # Never record packets, content, credentials or exception messages.
        evidence.write(json.dumps({"phase": phase, **counts}) + "\n")
        evidence.flush()

    def close_input():
        stopped.set()
        with writer:
            if not child.stdin.closed:
                try:
                    child.stdin.close()
                except BrokenPipeError:
                    pass  # The original child may already have closed input.

    def feed():
        try:
            while not stopped.is_set():
                line = source.readline(6324225)
                if not line:
                    break
                if len(line) > 6324224 or not line.endswith(b"\n"):
                    raise ValueError("bounded_input")
                packet = json.loads(line)
                if not isinstance(packet, dict):
                    raise ValueError("object_required")
                with state:
                    selected.observe(packet)
                with writer:
                    if stopped.is_set():
                        break
                    child.stdin.write(line)
                    child.stdin.flush()
        except Exception:
            # No forwarding after invalid framing or a closed original child.
            pass
        finally:
            close_input()

    threading.Thread(target=feed, daemon=True).start()
    try:
        while True:
            line = child.stdout.readline(524289)
            if not line:
                break
            if len(line) > 524288 or not line.endswith(b"\n"):
                raise ValueError("bounded_output")
            packet = json.loads(line)
            if not isinstance(packet, dict):
                raise ValueError("object_required")
            with state:
                drop = selected.withhold(packet)
            if drop:
                # The phone's original durable-publication acknowledgement was
                # received here, but zero bytes of this response go to Codex.
                record("publication_response_withheld", selectedResponses=1,
                       selectedResponseBytesForwarded=0)
                close_input()
            elif not selected.dropped:
                destination.write(line)
                destination.flush()
    finally:
        close_input()
        # Never kill an owner or release it on a timeout. Unknown settlement
        # remains visible while this same process continues waiting for it.
        try:
            code = child.wait(timeout=30)
        except subprocess.TimeoutExpired:
            record("original_adapter_settlement_pending")
            code = child.wait()
        child.stdout.close()
        record("original_adapter_exited", exitCode=code,
               selectedResponseWithheld=selected.dropped)
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-selected-android-validation", action="store_true", required=True)
    parser.add_argument("--submission-key", required=True)
    parser.add_argument("--evidence-name", required=True)
    args = parser.parse_args()
    if (not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.submission_key)
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.evidence_name)):
        return 78
    root = Path(__file__).resolve().parents[2]
    selected = root / "build" / "android_device_read"
    executable = selected / "adapter" / "AndroidDeviceAdapter.exe"
    output = root / "build" / "android_generation_validation"
    output.mkdir(exist_ok=True)
    # Append only fixed safe observations across explicit client restarts.
    with (output / (args.evidence_name + ".jsonl")).open("a", encoding="utf-8") as evidence:
        return pump([str(executable), "--business", str(selected), "--current-user-cng-import"],
                    args.submission_key, evidence, sys.stdin.buffer, sys.stdout.buffer)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        print("android_validation_unavailable", file=sys.stderr)
        sys.exit(78)
