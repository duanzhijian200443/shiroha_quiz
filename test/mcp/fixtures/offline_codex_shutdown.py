"""Pinned, opt-in Windows host test. No real provider, App, Link or credentials.

prepare ROOT; reference ROOT; baseline ROOT. Each case is create-new, once only.
Baseline must receive the reviewer's isolation checkpoint before invocation.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time
import tomllib
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from offline_mcp_shutdown import Windows, available_memory, digest, SCENARIO_DELAY_MS

HERE = Path(__file__).resolve().parent
CODEX = Path.home() / 'AppData/Local/OpenAI/Codex/bin/22cfb1d302613eae/codex.exe'
CODEX_HASH = '3097c909fb6d5cd63510d44aceb1d42df9f6e85722a3e447e477def1ecf60e16'
DART = Path.home() / 'flutter/bin/cache/dart-sdk/bin/dart.exe'
CANDIDATE_ROOT = HERE.parents[2] / 'build' / 'codex-gc'
CANDIDATE_BASE = 'f79b26ccbb3116b052544666a181012fb45dc49b'
SCENARIOS = ('normal', 'delayed', 'hang')
INPUTS = ('offline_codex_shutdown.py', 'offline_mcp_shutdown.py',
          'offline_shutdown_responses.dart', 'offline_codex_responses.dart')
GIB = 1024 ** 3
EXPECTED_FIXTURE_WARNING = (
    'Model metadata for `offline-shutdown` not found. Defaulting to fallback metadata; '
    'this can degrade performance and cause issues.')


def expected_isolation_warning(config_path):
    return ('Under-development features enabled: skip_host_skill_discovery. '
            'Under-development features are incomplete and may behave unpredictably. '
            'To suppress this warning, set `suppress_unstable_features_warning = true` in '
            + str(config_path) + '.')


def write_new(path, value, limit=16384):
    data = (json.dumps(value, separators=(',', ':')) + '\n').encode()
    if len(data) > limit:
        raise ValueError('record_budget')
    with Path(path).open('xb') as file:
        file.write(data)
    return value


def environment(case):
    """Replacement mapping: never merge developer keys, profiles or proxies."""
    win = os.environ.get('SYSTEMROOT', 'C:/Windows')
    home = str(case / 'home')
    return {'SYSTEMROOT': win, 'WINDIR': win, 'HOME': home,
            'USERPROFILE': home, 'APPDATA': home, 'LOCALAPPDATA': home,
            'CODEX_HOME': home, 'TEMP': str(case / 'temp'), 'TMP': str(case / 'temp'),
            'NO_PROXY': '127.0.0.1,localhost', 'PYTHONIOENCODING': 'utf-8',
            'PYTHONDONTWRITEBYTECODE': '1'}


def config(case, nonce, base, scenario=None):
    if not base.startswith('http://127.0.0.1:') or not base.endswith('/v1'):
        raise ValueError('nonlocal_provider')
    port = base[len('http://127.0.0.1:'):-3]
    if not port.isdigit() or not 0 < int(port) < 65536:
        raise ValueError('invalid_provider_port')
    q = json.dumps
    fixture_args = ['-I', '-B', str(HERE / 'offline_mcp_shutdown.py'), str(case), nonce]
    if scenario is not None:
        if scenario not in SCENARIOS:
            raise ValueError('scenario')
        fixture_args.append(scenario)
    return f'''model = "offline-shutdown"
model_provider = "offline"
approval_policy = "never"
web_search = "disabled"
project_doc_max_bytes = 0
project_doc_fallback_filenames = []
project_root_markers = []
cli_auth_credentials_store = "file"
mcp_oauth_credentials_store = "file"
check_for_update_on_startup = false
[projects.{q(str(case / 'work'))}]
trust_level = "untrusted"
[features]
plugins = false
apps = false
multi_agent = false
multi_agent_v2 = false
shell_tool = false
shell_snapshot = false
computer_use = false
browser_use = false
unbounded_connection_retries = false
skip_host_skill_discovery = true
skill_mcp_dependency_install = false
enable_request_compression = false
[analytics]
enabled = false
[feedback]
enabled = false
[history]
persistence = "none"
[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"
log_user_prompt = false
[model_providers.offline]
name = "Offline shutdown fixture"
base_url = {q(base)}
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
[mcp_servers.shiroha_vnext]
command = {q(sys.executable)}
args = {q(fixture_args)}
cwd = {q(str(case / 'work'))}
required = true
startup_timeout_sec = 10
tool_timeout_sec = 10
enabled_tools = ["probe_read"]
'''


def overrides(text):
    args = []
    def visit(value, prefix=''):
        for key, child in value.items():
            name = f'{prefix}.{key}' if prefix else key
            if not prefix and key == 'projects':
                # One top-level TOML inline table. Do not split path dots or
                # Windows separators into config-override key segments.
                entries = ','.join(json.dumps(path) + ' = {trust_level = "untrusted"}'
                                   for path in child)
                args.extend(['-c', 'projects={' + entries + '}'])
            elif isinstance(child, dict):
                visit(child, name)
            else:
                args.extend(['-c', name + '=' + json.dumps(child)])
    visit(tomllib.loads(text))
    return args


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate_manifest_key')
        value[key] = item
    return value


def load_candidate(path):
    root = CANDIDATE_ROOT.resolve()
    path = Path(path).resolve()
    if not path.is_relative_to(root):
        raise ValueError('candidate_manifest_root')
    with path.open('rb') as file:
        data = file.read(16385)
    if len(data) > 16384:
        raise ValueError('candidate_manifest_size')
    value = json.loads(data, object_pairs_hook=_unique_object)
    if not isinstance(value, dict) or set(value) != {
        'formatVersion', 'kind', 'executable', 'sha256', 'sourceBase',
        'sourceManifestPath', 'sourceManifestSha256', 'patchPath', 'patchSha256',
        'toolchain', 'shutdownGraceMs', 'shutdownBoundMs'
    }:
        raise ValueError('candidate_manifest_shape')
    if (type(value['formatVersion']) is not int or value['formatVersion'] != 1 or
        value['kind'] != 'isolated-codex-graceful-close' or value['sourceBase'] != CANDIDATE_BASE or
        type(value['shutdownGraceMs']) is not int or value['shutdownGraceMs'] != 3000 or
        type(value['shutdownBoundMs']) is not int or value['shutdownBoundMs'] != 9000):
        raise ValueError('candidate_manifest_identity')
    toolchain = value['toolchain']
    if (not isinstance(toolchain, dict) or set(toolchain) != {'rustc', 'cargo', 'target', 'profile'} or
        toolchain['target'] != 'x86_64-pc-windows-msvc' or toolchain['profile'] != 'dev-small' or
        any(not isinstance(toolchain[key], str) or not 1 <= len(toolchain[key]) <= 512
            for key in ('rustc', 'cargo'))):
        raise ValueError('candidate_toolchain')
    for key, hash_key in (('executable', 'sha256'), ('sourceManifestPath', 'sourceManifestSha256'),
                          ('patchPath', 'patchSha256')):
        if not isinstance(value[key], str) or not Path(value[key]).is_absolute():
            raise ValueError('candidate_absolute_path')
        target = Path(value[key]).resolve()
        if (not target.is_relative_to(root) or target == CODEX.resolve() or
            not target.is_file() or not isinstance(value[hash_key], str) or
            re.fullmatch('[a-f0-9]{64}', value[hash_key]) is None or digest(target) != value[hash_key]):
            raise ValueError('candidate_artifact_binding')
        if key == 'executable' and target != (root / 'target/dev-small/codex.exe').resolve():
            raise ValueError('candidate_executable_path')
    return value


def prepare(root, candidate_manifest=None):
    if os.name != 'nt' or digest(CODEX) != CODEX_HASH:
        raise ValueError('client_pin')
    candidate = load_candidate(candidate_manifest) if candidate_manifest else None
    root.mkdir(parents=True, exist_ok=False)
    manifest = {'format': 1, 'attempt': uuid.uuid4().hex,
                'clientVersionPin': '0.166.0-alpha.5.1',
                'clientCommitPin': 'f79b26ccbb3116b052544666a181012fb45dc49b',
                'clientSha256': CODEX_HASH,
                'pythonSha256': digest(sys.executable), 'dartSha256': digest(DART),
                'source': {name: digest(HERE / name) for name in INPUTS}}
    if candidate is not None:
        manifest.update(format=2, candidate=candidate,
                        candidateManifestPath=str(Path(candidate_manifest).resolve()),
                        candidateManifestSha256=digest(candidate_manifest))
    for mode in SCENARIOS if candidate is not None else ('reference', 'baseline'):
        case = root / mode
        case.mkdir()
        for directory in ('home', 'work', 'temp'):
            (case / directory).mkdir()
        nonce = uuid.uuid4().hex
        case_value = {'attempt': uuid.uuid4().hex, 'nonce': nonce}
        if candidate is not None:
            case_value['scenario'] = mode
        write_new(case / 'case.json', case_value)
        template = config(case, nonce, 'http://127.0.0.1:1/v1', mode if candidate else None)
        (case / 'config-template.toml').write_text(template, encoding='utf-8')
        manifest[mode] = {'configSha256': digest(case / 'config-template.toml'),
                          'caseSha256': digest(case / 'case.json')}
    return write_new(root / 'manifest.json', manifest)


class Drain:
    def __init__(self, process):
        self.rows = queue.Queue(maxsize=64)
        self.failed = False
        self.out_bytes = self.err_bytes = 0
        self.threads = [threading.Thread(target=self._out, args=(process.stdout,), daemon=True),
                        threading.Thread(target=self._err, args=(process.stderr,), daemon=True)]
        for thread in self.threads:
            thread.start()

    def _out(self, stream):
        try:
            while True:
                line = stream.readline(65537)
                if not line:
                    break
                self.out_bytes += len(line)
                if len(line) > 65536 or self.out_bytes > 2 * 1024 * 1024:
                    self.failed = True
                    continue
                self.rows.put_nowait(json.loads(line))
        except Exception:
            self.failed = True

    def _err(self, stream):
        try:
            while True:
                chunk = stream.read(4096)
                if not chunk:
                    break
                self.err_bytes += len(chunk)
                if self.err_bytes > 65536:
                    self.failed = True
        except Exception:
            self.failed = True

    def next(self, seconds=10):
        return self.rows.get(timeout=seconds)

    def joined(self):
        for thread in self.threads:
            thread.join(timeout=1)
        return not any(t.is_alive() for t in self.threads) and not self.failed


def spawn(command, case):
    return subprocess.Popen(command, cwd=case / 'work', env=environment(case),
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            creationflags=subprocess.CREATE_NO_WINDOW |
                            subprocess.BELOW_NORMAL_PRIORITY_CLASS)


def public_identity(native, handle):
    return {k: v for k, v in native.identity(handle).items() if k != 'image'}


def bind_child(native, header, parent, expected_hash, version=1):
    handle = native.open(header['pid'])
    try:
        child = native.identity(handle)
        if (header.get('stage') != 'start' or header.get('fixtureVersion') != version or
                child['pid'] != header['pid'] or child['started'] != header['started'] or
                child['parent'] != parent['pid'] or header.get('parent') != parent['pid'] or
                int(child['started']) < int(parent['started']) or
                os.path.normcase(child['image']) != os.path.normcase(sys.executable) or
                child['sha256'] != expected_hash or header['sha256'] != expected_hash):
            raise ValueError('original_child_binding')
        return handle
    except Exception:
        native.close(handle)
        raise


def read_records(case, final=False):
    file = case / 'fixture.jsonl'
    if not file.exists():
        return []
    data = file.read_bytes()
    if len(data) > 12 * 512:
        raise ValueError('fixture_evidence_budget')
    lines = data.splitlines(keepends=True)
    if any(len(line) > 512 for line in lines) or (final and data and not data.endswith(b'\n')):
        raise ValueError('fixture_partial_or_oversized_record')
    return [json.loads(line) for line in lines if line.endswith(b'\n')]


def complete_records(rows):
    return (len(rows) == 8 and
            [r.get('sequence') for r in rows] == list(range(1, 9)) and
            all(r.get('fixtureVersion') == 1 for r in rows) and
            [r.get('stage') for r in rows] ==
            ['start', 'initialize', 'list', 'call', 'eof', 'cleanup_begin',
             'cleanup_end', 'terminal'] and
            rows[-1].get('complete') is True and rows[-1].get('calls') == 1)


def candidate_record_shape(rows, scenario, terminal):
    stages = ['start', 'initialize', 'list', 'call', 'eof', 'cleanup_begin']
    if terminal:
        stages += ['cleanup_end', 'terminal']
    if len(rows) != len(stages):
        return False
    fields = {'start': {'pid', 'parent', 'started', 'sha256', 'scenario', 'cleanupDelayMs'},
              'initialize': {'protocol'}, 'list': {'count'}, 'call': {'count'},
              'eof': set(), 'cleanup_begin': set(), 'cleanup_end': set(),
              'terminal': {'complete', 'calls'}}
    previous = -1
    for index, (row, stage) in enumerate(zip(rows, stages), 1):
        if (not isinstance(row, dict) or
            set(row) != {'fixtureVersion', 'sequence', 'stage', 'monotonicNs'} | fields[stage] or
            type(row['fixtureVersion']) is not int or row['fixtureVersion'] != 2 or
            type(row['sequence']) is not int or row['sequence'] != index or row['stage'] != stage or
            type(row['monotonicNs']) is not int or row['monotonicNs'] < previous):
            return False
        previous = row['monotonicNs']
    return (rows[0]['scenario'] == scenario and
            type(rows[0]['cleanupDelayMs']) is int and
            rows[0]['cleanupDelayMs'] == SCENARIO_DELAY_MS[scenario] and
            rows[1]['protocol'] in ('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05') and
            type(rows[2]['count']) is int and rows[2]['count'] == 1 and
            type(rows[3]['count']) is int and rows[3]['count'] == 1 and
            (not terminal or rows[-1]['complete'] is True and
             type(rows[-1]['calls']) is int and rows[-1]['calls'] == 1))


def observe_original_process(native, handle, last_alive_ns, exit_observed_ns,
                             clock=time.monotonic_ns):
    if exit_observed_ns is not None:
        return last_alive_ns, exit_observed_ns
    before_query = clock()
    if native.exited(handle):
        return last_alive_ns, clock()
    # A timestamp taken after the query could already be later than process
    # exit. Only the pre-query timestamp is a conservative survival bound.
    return before_query, None


def candidate_outcome(result, rows, scenario, turn_done_ns, host_exit_ns, mcp_exit_ns,
                      mcp_last_alive_ns=None):
    """Same Windows monotonic clock in fixture and observer, never wall-clock inference."""
    timed = all(type(value) is int for value in (turn_done_ns, host_exit_ns, mcp_exit_ns))
    elapsed = (max(0, max(host_exit_ns, mcp_exit_ns) - turn_done_ns) / 1_000_000
               if timed else None)
    bounded = elapsed is not None and elapsed <= 9000
    completed = candidate_record_shape(rows, scenario, terminal=True)
    delay_ms = ((rows[6]['monotonicNs'] - rows[5]['monotonicNs']) / 1_000_000
                if completed else None)
    delay_ok = completed and delay_ms >= SCENARIO_DELAY_MS[scenario]
    hung = candidate_record_shape(rows, scenario, terminal=False)
    exit_upper_ms = ((mcp_exit_ns - rows[5]['monotonicNs']) / 1_000_000
                     if timed and hung else None)
    alive_lower_ms = ((mcp_last_alive_ns - rows[5]['monotonicNs']) / 1_000_000
                      if timed and hung and type(mcp_last_alive_ns) is int and
                      mcp_last_alive_ns <= mcp_exit_ns else None)
    observed = result['executionComplete'] and not result['forced'] and not result['cleanupFailed']
    graceful = (observed and bounded and completed and delay_ok and
                result['hostExit'] == 0 and result['mcpExit'] == 0 and scenario != 'hang')
    protection = (scenario == 'hang' and observed and bounded and hung and
                  result['hostExit'] == 0 and
                  result['mcpExit'] is not None and result['mcpExit'] != 0 and
                  alive_lower_ms is not None and alive_lower_ms >= 2500)
    return {'scenario': scenario, 'shutdownObservedMs': elapsed,
            'shutdownBoundMet': bounded, 'cleanupDurationMs': delay_ms,
            'mcpLastAliveMonotonicNs': mcp_last_alive_ns,
            'cleanupAliveLowerBoundMs': alive_lower_ms,
            'cleanupExitObservedUpperBoundMs': exit_upper_ms, 'fixtureComplete': completed,
            'timeoutProtectionPassed': protection, 'compatible': graceful,
            'scenarioPassed': protection if scenario == 'hang' else graceful}


def exact_result(value, nonce):
    if not isinstance(value, dict) or value.get('error') is not None:
        return False
    for flag in ('isError', 'is_error'):
        if flag in value and value[flag] is not False:
            return False
    wanted = {'data': {'ok': True, 'nonce': nonce}}
    structured = value.get('structured_content', value.get('structuredContent'))
    content = value.get('content')
    if structured is not None and structured != wanted:
        return False
    if not isinstance(content, list) or len(content) != 1:
        return False
    try:
        return content[0].get('type') == 'text' and json.loads(content[0]['text']) == wanted
    except (ValueError, KeyError, TypeError):
        return False


def call_observation(item):
    # Exact fixed-source rejection only. Never infer from substrings or retain
    # arbitrary errors, parameters, output bodies or request IDs.
    error = item.get('error')
    message = error.get('message') if isinstance(error, dict) else error
    category = ('none' if error is None else 'approval_required_never'
                if message == 'MCP tool call requires approval, but approval policy is never'
                else 'other')
    status = item.get('status')
    return {'status': status if status in ('completed', 'failed', 'in_progress') else 'other',
            'errorCategory': category, 'errorPresent': error is not None,
            'resultPresent': item.get('result') is not None}


class ClientObservation:
    """Bounded predicate evidence; unknown errors never become expected warnings."""
    def __init__(self, nonce, config_path=None):
        self.nonce = nonce
        self.isolation_warning = (expected_isolation_warning(config_path)
                                  if config_path is not None else None)
        self.calls = self.finals = self.turns = self.warnings = self.errors = 0
        self.isolation_warnings = 0
        self.invalid = False
        self.call = None
        self.predicates = {}
        self.unexpected = {}

    def accept(self, event):
        kind, item = event.get('type'), event.get('item', {})
        if kind in ('turn.failed', 'error'):
            self.errors = min(2, self.errors + 1)
            self.invalid = True
        if kind == 'turn.completed':
            self.turns = min(2, self.turns + 1)
        if kind != 'item.completed':
            return
        item_type = item.get('type')
        if item_type == 'mcp_tool_call':
            self.calls = min(2, self.calls + 1)
            checks = {'server': item.get('server') == 'shiroha_vnext',
                      'tool': item.get('tool') == 'probe_read',
                      'status': item.get('status') == 'completed',
                      'errorAbsent': item.get('error') is None,
                      'resultExact': exact_result(item.get('result'), self.nonce)}
            if self.call is None:
                self.call = call_observation(item)
                self.predicates.update(checks)
            self.invalid |= not all(checks.values())
        elif item_type == 'agent_message':
            self.finals = min(2, self.finals + 1)
            exact = item.get('text') == 'Offline probe complete: ' + self.nonce
            self.predicates['finalExact'] = self.predicates.get('finalExact', True) and exact
            self.invalid |= not exact
        elif item_type == 'error' and item.get('message') == EXPECTED_FIXTURE_WARNING:
            self.warnings = min(2, self.warnings + 1)
            self.invalid |= self.warnings > 1
        elif (item_type == 'error' and self.isolation_warning is not None and
              item.get('message') == self.isolation_warning):
            self.isolation_warnings = min(2, self.isolation_warnings + 1)
            self.invalid |= self.isolation_warnings > 1
        elif item_type != 'reasoning':
            category = item_type if item_type in (
                'error', 'command_execution', 'file_change', 'collab_tool_call',
                'web_search', 'todo_list') else 'other'
            self.unexpected[category] = min(2, self.unexpected.get(category, 0) + 1)
            self.invalid = True

    def summary(self):
        return {'calls': self.calls, 'finals': self.finals, 'turns': self.turns,
                'expectedFixtureWarnings': self.warnings, 'topLevelErrors': self.errors,
                'expectedIsolationWarnings': self.isolation_warnings,
                'isolationWarningFeature': 'skip_host_skill_discovery'
                    if self.isolation_warnings else None,
                'unexpectedItems': self.unexpected, 'predicates': self.predicates,
                'callObservation': self.call,
                'protocolPassed': not self.invalid and
                    (self.calls, self.finals, self.turns) == (1, 1, 1)}


def verify_inputs(root, manifest, mode, runtime_hash=None):
    for name, expected in manifest['source'].items():
        if digest(HERE / name) != expected:
            raise ValueError('source_drift')
    for path, expected in ((CODEX, CODEX_HASH), (DART, manifest['dartSha256']),
                           (Path(sys.executable), manifest['pythonSha256'])):
        if digest(path) != expected:
            raise ValueError('binary_drift')
    if manifest.get('format') == 2:
        candidate_path = manifest['candidateManifestPath']
        if (digest(candidate_path) != manifest['candidateManifestSha256'] or
            load_candidate(candidate_path) != manifest['candidate']):
            raise ValueError('candidate_changed')
    case = root / mode
    for name, field in (('config-template.toml', 'configSha256'), ('case.json', 'caseSha256')):
        if digest(case / name) != manifest[mode][field]:
            raise ValueError('prepared_input_drift')
    if runtime_hash is not None and digest(case / 'config-runtime.toml') != runtime_hash:
        raise ValueError('runtime_config_drift')


def cleanup(native, processes, child, result):
    """Attempt every owned handle and preserve failures; no PID-tree cleanup."""
    for process in reversed(processes):
        try:
            handle = int(process._handle)
            if not native.exited(handle):
                result['forced'] = True
                result['status'] = 'ABORTED'
                native.terminate(handle)
            process.wait(timeout=2)
        except Exception:
            result['cleanupFailed'] = True
    if child is not None:
        try:
            if not native.exited(child):
                result['forced'] = True
                result['status'] = 'ABORTED'
                native.terminate(child)
                native.k.WaitForSingleObject(child, 2000)
            result['mcpExitAfterCleanup'] = native.exit_code(child)
        except Exception:
            result['cleanupFailed'] = True
        finally:
            try:
                native.close(child)
            except Exception:
                result['cleanupFailed'] = True


def run(root, mode):
    manifest = json.loads((root / 'manifest.json').read_text())
    is_candidate = manifest.get('format') == 2
    if mode not in (SCENARIOS if is_candidate else ('reference', 'baseline')):
        raise ValueError('mode_manifest_mismatch')
    verify_inputs(root, manifest, mode)
    case = root / mode
    if any((case / 'work').iterdir()):
        raise ValueError('workspace_not_empty')
    case_input = json.loads((case / 'case.json').read_text())
    nonce = case_input['nonce']
    if is_candidate and case_input.get('scenario') != mode:
        raise ValueError('scenario_manifest_mismatch')
    write_new(case / 'started.json', {'format': 1, 'mode': mode})
    native = Windows()
    native.below_normal()
    started = time.monotonic()
    processes = []
    child = None
    runtime_hash = None
    turn_done_ns = host_exit_ns = mcp_exit_ns = mcp_last_alive_ns = None
    result = {'format': 2 if is_candidate else 1, 'mode': mode, 'status': 'ABORTED', 'forced': False,
              'executionComplete': False, 'compatible': None, 'cleanupFailed': False}
    if is_candidate:
        result.update(candidateManifestSha256=manifest['candidateManifestSha256'],
                      installedClientSha256=CODEX_HASH)
    try:
        if available_memory() < 4 * GIB:
            raise ValueError('low_memory_start')
        if mode == 'reference':
            host = spawn([sys.executable, '-I', '-B', str(HERE / 'offline_mcp_shutdown.py'),
                          str(case), nonce], case)
            processes.append(host)
            drain = Drain(host)
            child = native.open(host.pid)
            result['mcp'] = public_identity(native, child)
            for ident, method, params in (
                (1, 'initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                                   'clientInfo': {'name': 'reference', 'version': '1'}}),
                (None, 'notifications/initialized', {}),
                (2, 'tools/list', {}), (3, 'tools/call', {'name': 'probe_read', 'arguments': {}})):
                message = {'jsonrpc': '2.0', 'method': method, 'params': params}
                if ident is not None:
                    message['id'] = ident
                host.stdin.write((json.dumps(message) + '\n').encode())
                host.stdin.flush()
                if ident is not None:
                    reply = drain.next()
                    if reply.get('id') != ident or 'error' in reply or reply.get('jsonrpc') != '2.0':
                        raise ValueError('reference_protocol')
                    if ident == 1 and reply['result'].get('protocolVersion') != '2025-11-25':
                        raise ValueError('reference_protocol')
                    if ident == 2 and [t.get('name') for t in reply['result'].get('tools', [])] != ['probe_read']:
                        raise ValueError('reference_protocol')
                    if ident == 3 and not exact_result(reply['result'], nonce):
                        raise ValueError('reference_result')
                if available_memory() < 2 * GIB:
                    raise ValueError('low_memory_running')
            host.stdin.close()  # Reference only. Baseline never owns MCP stdin.
            host.wait(timeout=15)
            result['protocolPassed'] = True
        else:
            service = spawn([str(DART), str(HERE / 'offline_shutdown_responses.dart'), nonce], case)
            processes.append(service)
            service_drain = Drain(service)
            ready = service_drain.next()
            if set(ready) != {'kind', 'base'} or ready['kind'] != 'ready':
                raise ValueError('service_start')
            text = config(case, nonce, ready['base'], mode if is_candidate else None)
            with (case / 'config-runtime.toml').open('x', encoding='utf-8') as file:
                file.write(text)
            runtime_hash = digest(case / 'config-runtime.toml')
            result['runtimeConfigSha256'] = runtime_hash
            executable = manifest['candidate']['executable'] if is_candidate else str(CODEX)
            command = [executable, 'exec', '--ignore-user-config', '--ephemeral', '--json',
                       '--color', 'never', '--sandbox', 'read-only', '--skip-git-repo-check',
                       '--cd', str(case / 'work'), *overrides(text),
                       'Execute the single scripted offline MCP probe.']
            host = spawn(command, case)
            processes.append(host)
            host.stdin.close()  # Only Codex prompt input; not its MCP transport.
            drain = Drain(host)
            parent = native.identity(int(host._handle))
            expected_client_hash = manifest['candidate']['sha256'] if is_candidate else CODEX_HASH
            if (parent['sha256'] != expected_client_hash or
                Path(parent['image']).resolve() != Path(executable).resolve()):
                raise ValueError('client_handle_binding')
            result['codex'] = {k: v for k, v in parent.items() if k != 'image'}
            observed = ClientObservation(nonce, case / 'home' / 'config.toml')
            while time.monotonic() - started < 45:
                if available_memory() < 2 * GIB:
                    raise ValueError('low_memory_running')
                if child is None:
                    rows = read_records(case)
                    if rows:
                        if native.exited(int(host._handle)):
                            raise ValueError('parent_exited_before_binding')
                        child = bind_child(native, rows[0], parent, manifest['pythonSha256'],
                                           2 if is_candidate else 1)
                        result['mcp'] = public_identity(native, child)
                if is_candidate:
                    if host_exit_ns is None and native.exited(int(host._handle)):
                        host_exit_ns = time.monotonic_ns()
                    if child is not None:
                        mcp_last_alive_ns, mcp_exit_ns = observe_original_process(
                            native, child, mcp_last_alive_ns, mcp_exit_ns)
                    if (turn_done_ns is not None and time.monotonic_ns() - turn_done_ns > 9_000_000_000
                        and (host_exit_ns is None or mcp_exit_ns is None)):
                        raise ValueError('shutdown_bound')
                try:
                    event = drain.next(.025)
                except queue.Empty:
                    if host.poll() is not None and not drain.threads[0].is_alive():
                        break
                    continue
                if is_candidate and event.get('type') == 'turn.completed' and turn_done_ns is None:
                    turn_done_ns = time.monotonic_ns()
                observed.accept(event)
            if host.poll() is None:
                raise ValueError('case_wall_limit')
            result.update(observed.summary())
            service.stdin.close()
            service.wait(timeout=5)
            result['serviceExit'] = native.exit_code(int(service._handle))
            summary = service_drain.next(2)
            result['service'] = summary
            result['serviceJoined'] = service_drain.joined()
            if summary != {'kind': 'finished', 'accepted': 2, 'total': 2,
                           'outputs': 1, 'finished': True, 'failures': []}:
                result['protocolPassed'] = False
            if result['serviceExit'] != 0:
                result['protocolPassed'] = False
        result['hostExit'] = native.exit_code(int(host._handle))
        result['streamsJoined'] = drain.joined()
        if child is None:
            raise ValueError('original_mcp_not_bound')
        # Bounded observation, no stdin operation or shutdown request to MCP.
        while time.monotonic() - started < 50:
            if is_candidate:
                mcp_last_alive_ns, mcp_exit_ns = observe_original_process(
                    native, child, mcp_last_alive_ns, mcp_exit_ns)
                if mcp_exit_ns is not None:
                    break
            elif native.exited(child):
                break
            if (is_candidate and turn_done_ns is not None and
                time.monotonic_ns() - turn_done_ns >= 9_000_000_000):
                break
            time.sleep(.025)
        if is_candidate:
            mcp_last_alive_ns, mcp_exit_ns = observe_original_process(
                native, child, mcp_last_alive_ns, mcp_exit_ns)
            if host_exit_ns is None and native.exited(int(host._handle)):
                host_exit_ns = time.monotonic_ns()
        result['mcpExit'] = native.exit_code(child)
        rows = read_records(case, final=True)
        result['stages'] = [r['stage'] for r in rows]
        result['fixtureComplete'] = complete_records(rows) if not is_candidate else False
        if mode == 'reference':
            header = rows[0] if rows else {}
            if any(header.get(key) != result['mcp'][key]
                   for key in ('pid', 'parent', 'started', 'sha256')):
                result['protocolPassed'] = False
        result['executionComplete'] = (result['protocolPassed'] and
                                       result['hostExit'] is not None and
                                       result['mcpExit'] is not None and result['streamsJoined'] and
                                       result.get('serviceJoined', True))
        passed = (result['executionComplete'] and result['hostExit'] == 0 and
                  result['mcpExit'] == 0 and result['fixtureComplete'])
        if mode == 'reference':
            result['executionComplete'] = passed
            result['status'] = 'REFERENCE_PASS' if passed else 'REFERENCE_FAILED'
        else:
            result['compatible'] = passed
            result['status'] = 'BASELINE_OBSERVED' if result['executionComplete'] else 'INCOMPLETE'
        if is_candidate:
            result['finalHeaderBound'] = bool(rows) and all(
                rows[0].get(key) == result['mcp'][key]
                for key in ('pid', 'parent', 'started', 'sha256'))
            if not result['finalHeaderBound']:
                result['executionComplete'] = False
            result.update(candidate_outcome(result, rows, mode, turn_done_ns, host_exit_ns,
                                            mcp_exit_ns, mcp_last_alive_ns))
            result['status'] = 'CANDIDATE_OBSERVED' if result['executionComplete'] else 'INCOMPLETE'
    except Exception as error:
        allowed = {'low_memory_start', 'low_memory_running', 'source_drift', 'binary_drift',
                   'reference_protocol', 'reference_result', 'service_start', 'case_wall_limit',
                   'original_mcp_not_bound', 'parent_exited_before_binding', 'original_child_binding',
                   'client_handle_binding', 'shutdown_bound'}
        result['category'] = str(error) if isinstance(error, ValueError) and str(error) in allowed else 'fixture_error'
    finally:
        cleanup(native, processes, child, result)
        try:
            verify_inputs(root, manifest, mode, runtime_hash)
            result['inputsUnchanged'] = True
        except Exception:
            result['inputsUnchanged'] = False
        if result['forced'] or result['cleanupFailed'] or not result['inputsUnchanged']:
            result['status'] = 'ABORTED'
            result['executionComplete'] = False
            if mode == 'baseline' or is_candidate:
                result['compatible'] = False
            if is_candidate:
                result['scenarioPassed'] = False
                result['timeoutProtectionPassed'] = False
        result['seconds'] = round(time.monotonic() - started, 3)
        write_new(case / 'result.json', result, 8192)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('prepare', 'reference', 'baseline', *SCENARIOS))
    parser.add_argument('root', type=Path)
    parser.add_argument('--candidate-manifest', type=Path)
    args = parser.parse_args()
    try:
        if args.candidate_manifest is not None and args.mode != 'prepare':
            raise ValueError('candidate_selection_is_prepare_only')
        value = (prepare(args.root.resolve(), args.candidate_manifest)
                 if args.mode == 'prepare' else run(args.root.resolve(), args.mode))
        print(json.dumps({'mode': args.mode, 'status': value.get('status', 'PREPARED')}))
        if args.mode != 'prepare' and not value.get('scenarioPassed', value['executionComplete']):
            sys.exit(1)
    except Exception:
        print(json.dumps({'mode': args.mode, 'status': 'FAILED_BEFORE_RUN'}))
        sys.exit(1)
