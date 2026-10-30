"""Explicit isolated installed-Codex / original relay lifecycle qualification.

Only synthetic fixtures are launched. Every output stays in the supplied run
directory. A failure preserves evidence and never authorizes later plan stages.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time


PLUGIN = "shiroha-host-probe"
MARKETPLACE = "shiroha-qualification"
PLUGIN_ID = f"{PLUGIN}@{MARKETPLACE}"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def events(path: Path) -> list[dict]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line]


def wait_event(path: Path, event: str, count: int = 1, timeout: float = 15) -> dict:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        found = [v for v in events(path) if v["event"] == event]
        if len(found) >= count:
            return found[count - 1]
        time.sleep(0.05)
    raise AssertionError(f"missing_event:{path.name}:{event}:{count}")


class PinnedProcess:
    """Keep the original process handle, checking the exact fixture executable."""

    def __init__(self, pid: int, expected: Path):
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenProcess.restype = wintypes.HANDLE
        self.api.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
        self.api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.api.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.api.OpenProcess(0x00100000 | 0x1000, False, pid)
        if not self.handle:
            raise AssertionError("fixture_process_unavailable")
        name, size = ctypes.create_unicode_buffer(32768), wintypes.DWORD(32768)
        if not self.api.QueryFullProcessImageNameW(self.handle, 0, name, ctypes.byref(size)):
            self.close()
            raise AssertionError("fixture_process_image_unavailable")
        if os.path.normcase(name.value) != os.path.normcase(str(expected.resolve())):
            self.close()
            raise AssertionError("fixture_process_image_mismatch")

    def running(self) -> bool:
        return self.api.WaitForSingleObject(self.handle, 0) == 258

    def join(self, timeout: float = 15) -> None:
        if self.api.WaitForSingleObject(self.handle, int(timeout * 1000)) != 0:
            raise AssertionError("fixture_original_process_unsettled")
        code = wintypes.DWORD()
        if not self.api.GetExitCodeProcess(self.handle, ctypes.byref(code)) or code.value != 0:
            raise AssertionError("fixture_original_process_failed")

    def close(self) -> None:
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def isolated_environment(home: Path) -> dict[str, str]:
    allowed = {"SYSTEMROOT", "WINDIR", "PATH", "PATHEXT", "TEMP", "TMP", "COMSPEC"}
    result = {key: value for key, value in os.environ.items() if key.upper() in allowed}
    # Portable plugin commands are bare names or package-contained paths. The
    # fixture resolves the original adjacent adapter through this private PATH.
    path_key = next((key for key in result if key.upper() == "PATH"), "PATH")
    result[path_key] = str(home.parent / "app") + os.pathsep + result.get(path_key, "")
    result.update({key: str(home) for key in ("CODEX_HOME", "HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA")})
    result.update({"HTTP_PROXY": "http://127.0.0.1:9", "HTTPS_PROXY": "http://127.0.0.1:9", "NO_PROXY": "127.0.0.1,localhost"})
    return result


class Rpc:
    def __init__(self, executable: Path, home: Path):
        self.home = home
        self.started = time.monotonic()
        self.trace: list[dict] = []
        self.process = subprocess.Popen([str(executable), "app-server", "--stdio"], cwd=home,
                                        env=isolated_environment(home), stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
        self.pending: dict[int, queue.Queue] = {}
        self.next_id = 0
        self.lock = threading.Lock()
        self.clean = True
        self.notifications: list[str] = []
        self.stdout_thread = threading.Thread(target=self._read, daemon=True)
        self.stderr_thread = threading.Thread(target=self._drain, daemon=True)
        self.stdout_thread.start()
        self.stderr_thread.start()
        initialized = self.request("initialize", {
            "clientInfo": {"name": "shiroha_plugin_qualification", "version": "1.0.0"},
            "capabilities": {"experimentalApi": True},
        })
        if Path(initialized["result"]["codexHome"]).resolve() != home.resolve():
            raise AssertionError("codex_home_not_isolated")
        self.send({"method": "initialized"})

    def _read(self) -> None:
        for line in self.process.stdout:
            try:
                msg = json.loads(line)
                if "method" in msg:
                    self.notifications.append(msg["method"])
                with self.lock:
                    target = self.pending.get(msg.get("id"))
                if target:
                    target.put(msg)
            except (ValueError, TypeError):
                self.clean = False

    def _drain(self) -> None:
        # Do not persist arbitrary client diagnostic/configuration bodies.
        for _ in self.process.stderr:
            pass

    def send(self, value: dict) -> None:
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def request(self, method: str, params: object, timeout: float = 30) -> dict:
        response = queue.Queue()
        with self.lock:
            self.next_id += 1
            request_id = self.next_id
            self.pending[request_id] = response
            self.send({"id": request_id, "method": method, "params": params})
            self.trace.append({"event": "sent", "method": method, "id": request_id,
                               "elapsedMs": round((time.monotonic() - self.started) * 1000)})
        try:
            value = response.get(timeout=timeout)
            self.trace.append({"event": "response", "method": method, "id": request_id,
                               "error": "error" in value,
                               "elapsedMs": round((time.monotonic() - self.started) * 1000)})
            return value
        except queue.Empty:
            raise AssertionError(f"rpc_timeout:{method}") from None
        finally:
            with self.lock:
                self.pending.pop(request_id, None)

    def checked(self, method: str, params: object) -> dict:
        value = self.request(method, params)
        if "error" in value:
            # The isolated error is bounded and contains no user data.
            raise AssertionError(f"rpc_error:{method}:{value['error'].get('code')}")
        return value["result"]

    def thread(self) -> str:
        return self.checked("thread/start", {
            "cwd": str(self.home), "ephemeral": True, "approvalPolicy": "never",
            "sandbox": "read-only", "model": "offline-probe", "modelProvider": "offline",
        })["thread"]["id"]

    def inventory(self, thread: str) -> list[dict]:
        return self.checked("mcpServerStatus/list", {"threadId": thread})["data"]

    def toggle(self, enabled: bool) -> dict:
        result = self.checked("config/batchWrite", {
            "edits": [{"keyPath": f"plugins.{PLUGIN_ID}.enabled", "value": enabled, "mergeStrategy": "upsert"}],
            "reloadUserConfig": True,
        })
        # These are the installed desktop plugin toggle's backend operations.
        self.checked("skills/list", {"cwds": [str(self.home)], "forceReload": True})
        return result

    def close(self) -> None:
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            code = self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            raise AssertionError("codex_original_process_unsettled") from None
        self.stdout_thread.join(3)
        self.stderr_thread.join(3)
        if code != 0 or not self.clean or self.stdout_thread.is_alive() or self.stderr_thread.is_alive():
            raise AssertionError("codex_exit_or_protocol_failed")


def prepare(case: Path, binaries: Path, scenario: str, unified: bool) -> tuple[Path, Path, Path]:
    app = case / "app"
    app.mkdir(parents=True)
    for file in binaries.iterdir():
        shutil.copy2(file, app / file.name)
    (app / "scenario").write_text("pending-peer-plugin" if scenario.startswith("pending-") else "plugin-host", encoding="utf-8")
    if not scenario.startswith("pending-"):
        (app / "allow-exit-1").touch()
    (app / "allow-exit-2").touch()
    if unified:
        (app / "unified").touch()
    home = case / "isolated-home"
    home.mkdir()
    (home / ".git").mkdir()  # Stop project-config discovery at the synthetic root.
    (home / "config.toml").write_text('''model = "offline-probe"
model_provider = "offline"
web_search = "disabled"
[model_providers.offline]
name = "Offline qualification (no model calls)"
base_url = "http://127.0.0.1:1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
[features]
plugins = true
apps = false
shell_snapshot = false
[analytics]
enabled = false
[feedback]
enabled = false
''', encoding="utf-8")
    market = case / "marketplace"
    plugin = market / "plugins" / PLUGIN
    write_json(plugin / "plugin.json", {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name": PLUGIN, "version": "0.1.0", "description": "Isolated synthetic host lifecycle qualification",
    })
    write_json(plugin / "mcp.json", {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers": {"shiroha_vnext": {"type": "stdio", "command": "shiroha_codex.exe", "args": ["--profile=3"] if unified else []}},
    })
    write_json(market / ".agents" / "plugins" / "marketplace.json", {
        "name": MARKETPLACE,
        "interface": {"displayName": "Isolated Shiroha qualification"},
        "plugins": [{"name": PLUGIN, "source": {"source": "local", "path": f"./plugins/{PLUGIN}"},
                     "policy": {"installation": "AVAILABLE", "authentication": "ON_USE"}, "category": "Productivity"}],
    })
    return app, home, market


def cli(executable: Path, home: Path, arguments: list[str], out: Path) -> dict:
    value = subprocess.run([str(executable), *arguments], cwd=home, env=isolated_environment(home),
                           capture_output=True, text=True, encoding="utf-8", timeout=40,
                           creationflags=subprocess.CREATE_NO_WINDOW)
    write_json(out, {"exitCode": value.returncode, "stdout": value.stdout, "stderr": value.stderr})
    if value.returncode != 0:
        raise AssertionError(f"isolated_cli_failed:{out.name}")
    return json.loads(value.stdout)


def qualify(executable: Path, run: Path, scenario: str, unified: bool = False) -> dict:
    case = run / scenario
    app, home, market = prepare(case, run / "bin", scenario, unified)
    cli(executable, home, ["plugin", "marketplace", "add", str(market), "--json"], case / "marketplace.json")
    cli(executable, home, ["plugin", "add", PLUGIN_ID, "--json"], case / "install.json")
    subprocess.run(["pwsh", "-NoProfile", "-File", str(Path(__file__).with_name("start_fixture_app.ps1")),
                    "-Directory", str(app)], check=True, timeout=15, capture_output=True,
                   creationflags=subprocess.CREATE_NO_WINDOW)
    app_handle = bridge_handle = None
    rpc = None
    model = None
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
    result = {"scenario": scenario, "evidenceClass": "synthetic fixture", "passed": False}
    try:
        ready = wait_event(app / "app.jsonl", "ready")
        app_handle = PinnedProcess(ready["pid"], app / "shiroha_quiz.exe")
        scripted_turn = scenario.startswith("pending-turn-")
        stop_before_change = scenario.startswith("pending-turn-stop-")
        if scripted_turn:
            model = subprocess.Popen([str(app / "qualify_model.exe")], cwd=home,
                env=isolated_environment(home), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
                creationflags=subprocess.CREATE_NO_WINDOW)
            base = json.loads(model.stdout.readline())["base"]
            config = home / "config.toml"
            config.write_text(config.read_text(encoding="utf-8").replace("http://127.0.0.1:1", base), encoding="utf-8")
        rpc = Rpc(executable, home)
        thread = rpc.thread()
        inventory = rpc.inventory(thread)
        write_json(case / "inventory.json", inventory)
        servers = [server for server in inventory if server.get("pluginId") == PLUGIN_ID]
        if len(servers) != 1 or len(servers[0]["tools"]) != (11 if unified else 7):
            raise AssertionError("isolated_plugin_inventory_mismatch")
        server = servers[0]["name"]
        call_params = {"threadId": thread, "server": server, "tool": "open_context" if unified else "open_generation_context", "arguments": {}}
        if scripted_turn:
            turn = rpc.checked("turn/start", {"threadId": thread, "input": [
                {"type": "text", "text": "Execute the isolated scripted MCP probe."}]})["turn"]["id"]
            wait_event(app / "bridge.jsonl", "pendingCall")
        elif scenario == "pending-disable":
            # The original client gives synthetic STAGE 145 seconds, so a READ
            # timeout cannot masquerade as cancellation caused by disabling.
            pending_params = {**call_params, "tool": "propose_generated_questions", "arguments": {
                "contextRef": "A" * 43,
                "submission": {"schemaVersion": 1, "submissionKey": "host-qualification",
                               "requestedCount": 1, "items": [{}]},
            }}
            pending = pool.submit(rpc.request, "mcpServer/tool/call", pending_params, 40)
            wait_event(app / "bridge.jsonl", "pendingCall")
        else:
            called = rpc.checked("mcpServer/tool/call", call_params)
            if called.get("structuredContent", {}).get("error") != "unavailable":
                raise AssertionError("synthetic_call_result_mismatch")
        started = wait_event(app / "bridge.jsonl", "started")
        bridge_handle = PinnedProcess(started["pid"], app / "shiroha_bridge.exe")
        if stop_before_change:
            rpc.checked("turn/interrupt", {"threadId": thread, "turnId": turn})
            wait_event(app / "bridge.jsonl", "eof")
            if not bridge_handle.running() or any(e["event"] == "originalBridgeSettled" for e in events(app / "app.jsonl")):
                raise AssertionError("premature_original_settlement")
            (app / "allow-exit-1").touch()
            bridge_handle.join()
            wait_event(app / "app.jsonl", "originalBridgeSettled")
        if scenario in ("disable", "pending-disable", "pending-turn-disable", "pending-turn-stop-disable"):
            if scenario.startswith("pending-"):
                disabling = pool.submit(rpc.toggle, False)
            else:
                rpc.toggle(False)
                write_json(case / "disabled-inventory.json", rpc.inventory(thread))
        elif scenario == "restart":
            rpc.close()
            rpc = None
        elif scenario in ("upgrade", "pending-turn-stop-upgrade"):
            manifest = market / "plugins" / PLUGIN / "plugin.json"
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["version"] = "0.1.1"
            write_json(manifest, value)
            upgraded = rpc.checked("plugin/install", {"marketplacePath": str(market / ".agents" / "plugins" / "marketplace.json"), "pluginName": PLUGIN})
            write_json(case / "upgrade.json", upgraded)
            rpc.checked("skills/list", {"cwds": [str(home)], "forceReload": True})
        wait_event(app / "bridge.jsonl", "eof")
        if scenario.startswith("pending-") and not stop_before_change:
            if not bridge_handle.running() or any(e["event"] == "originalBridgeSettled" for e in events(app / "app.jsonl")):
                raise AssertionError("premature_original_settlement")
            (app / "allow-exit-1").touch()
            disabling.result(timeout=15)
            if scenario == "pending-disable":
                pending.result(timeout=15)
        elif scenario == "pending-turn-stop-disable":
            disabling.result(timeout=15)
        bridge_handle.join()
        wait_event(app / "app.jsonl", "originalBridgeSettled")
        if not app_handle.running():
            raise AssertionError("codex_shutdown_terminated_app_owner")
        if scenario in ("disable", "pending-turn-stop-disable"):
            denied = rpc.request("mcpServer/tool/call", call_params)
            if "error" not in denied:
                raise AssertionError("disabled_plugin_still_callable")
        if scenario in ("restart", "disable", "upgrade", "pending-turn-stop-upgrade"):
            if rpc is None:
                rpc = Rpc(executable, home)
                thread = rpc.thread()
            elif scenario == "disable":
                rpc.toggle(True)
            rpc.inventory(thread)
            rpc.checked("mcpServer/tool/call", {**call_params, "threadId": thread})
            wait_event(app / "bridge.jsonl", "started", 2)
        result["passed"] = True
    except Exception as error:
        result["failure"] = str(error) if isinstance(error, AssertionError) else type(error).__name__
    finally:
        # Preserve observations BEFORE the harness requests fixture cleanup.
        # Later EOF/settlement must never be attributed to the plugin toggle.
        result["beforeCleanup"] = {
            "appEvents": [e for e in events(app / "app.jsonl") if e["event"] != "launchCurrent"],
            "bridgeEvents": events(app / "bridge.jsonl"),
            "rpcTrace": list(rpc.trace) if rpc else [],
        }
        for marker in ("allow-exit-1", "allow-exit-2", "stop"):
            (app / marker).touch()
        if rpc is not None:
            try:
                rpc.close()
            except Exception as error:
                result["passed"] = False
                result["clientCleanupFailure"] = str(error)
        pool.shutdown(wait=True)
        if model is not None:
            model.stdin.close()
            try:
                if model.wait(timeout=10) != 0:
                    raise AssertionError("scripted_model_failed")
                result["scriptedModel"] = json.loads(model.stdout.readline())
                if result["scriptedModel"]["failures"] or result["scriptedModel"]["issued"] != 1:
                    result["passed"] = False
            except Exception as error:
                result["passed"] = False
                result["modelCleanupFailure"] = type(error).__name__
        if app_handle:
            try:
                app_handle.join()
            except Exception as error:
                result["passed"] = False
                result["ownerCleanupFailure"] = str(error)
            app_handle.close()
        if bridge_handle:
            bridge_handle.close()
        result["appEvents"] = [e for e in events(app / "app.jsonl") if e["event"] != "launchCurrent"]
        result["bridgeEvents"] = events(app / "bridge.jsonl")
        if result["passed"]:
            expected_calls = 1 if scenario.startswith("pending-") and scenario != "pending-turn-stop-upgrade" else 2
            if sum(e["event"] == "call" for e in result["bridgeEvents"]) != expected_calls:
                result["passed"] = False
                result["failure"] = "unexpected_replay_or_missing_call"
        if unified:
            result["profileVersion"] = 3
            selection = app / "selection.json"
            result["selectionClean"] = selection.is_file() and not json.loads(selection.read_text())["needsCleanup"]
            if not result["selectionClean"]:
                result["passed"] = False
        write_json(case / "result.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--unified", action="store_true")
    parser.add_argument("--scenarios", nargs="+", choices=("disable", "restart", "upgrade", "pending-disable", "pending-turn-disable", "pending-turn-stop-disable", "pending-turn-stop-upgrade"), required=True)
    args = parser.parse_args()
    allowed = Path(__file__).resolve().parents[2] / "build" / "plugin_host_qualification" / "runs"
    run = args.run.resolve()
    if os.name != "nt" or not run.is_relative_to(allowed.resolve()) or not (run / "identity.json").is_file():
        parser.error("use the qualification PowerShell wrapper and its isolated run directory")
    results = []
    for scenario in args.scenarios:
        try:
            result = qualify(args.codex.resolve(), run, scenario, args.unified)
        except Exception as error:
            result = {"scenario": scenario, "passed": False, "failure": str(error) if isinstance(error, AssertionError) else type(error).__name__}
        results.append(result)
        print(json.dumps({key: value for key, value in result.items() if key not in ("appEvents", "bridgeEvents")}), flush=True)
        if not result["passed"]:
            break
    write_json(run / "summary.json", results)
    return 0 if len(results) == len(args.scenarios) and all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
