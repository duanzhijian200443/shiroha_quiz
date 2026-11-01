"""Pure stdio MCP shutdown fixture; no production graph, device or credentials."""
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time

SCENARIO_DELAY_MS = {'normal': 0, 'delayed': 750, 'hang': 30000}


def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class FileTime(c.Structure):
    _fields_ = [('low', w.DWORD), ('high', w.DWORD)]


class ProcessInfo(c.Structure):
    _fields_ = [('status', w.LONG), ('peb', c.c_void_p),
                ('affinity', c.c_size_t), ('priority', w.LONG),
                ('pid', c.c_size_t), ('parent', c.c_size_t)]


class Windows:
    """All lifecycle actions use retained original handles, never a recycled PID."""
    def __init__(self):
        self.k = c.WinDLL('kernel32', use_last_error=True)
        self.n = c.WinDLL('ntdll')
        signatures = {
            'OpenProcess': ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            'CloseHandle': ([w.HANDLE], w.BOOL),
            'WaitForSingleObject': ([w.HANDLE, w.DWORD], w.DWORD),
            'TerminateProcess': ([w.HANDLE, w.UINT], w.BOOL),
            'GetCurrentProcess': ([], w.HANDLE),
            'SetPriorityClass': ([w.HANDLE, w.DWORD], w.BOOL),
            'GetProcessTimes': ([w.HANDLE] + [c.POINTER(FileTime)] * 4, w.BOOL),
            'GetExitCodeProcess': ([w.HANDLE, c.POINTER(w.DWORD)], w.BOOL),
            'QueryFullProcessImageNameW':
                ([w.HANDLE, w.DWORD, w.LPWSTR, c.POINTER(w.DWORD)], w.BOOL),
        }
        for name, (args, result) in signatures.items():
            getattr(self.k, name).argtypes = args
            getattr(self.k, name).restype = result
        self.n.NtQueryInformationProcess.argtypes = [
            w.HANDLE, w.ULONG, c.c_void_p, w.ULONG, c.POINTER(w.ULONG)]
        self.n.NtQueryInformationProcess.restype = w.LONG

    def below_normal(self):
        if not self.k.SetPriorityClass(self.k.GetCurrentProcess(), 0x4000):
            raise ValueError('priority_unavailable')

    def open(self, pid):
        handle = self.k.OpenProcess(0x100000 | 0x1000 | 1, False, pid)
        if not handle:
            raise ValueError('handle_unavailable')
        return handle

    def identity(self, handle):
        values = [FileTime() for _ in range(4)]
        if not self.k.GetProcessTimes(handle, *[c.byref(v) for v in values]):
            raise ValueError('creation_time_unavailable')
        info, size = ProcessInfo(), w.ULONG()
        if self.n.NtQueryInformationProcess(handle, 0, c.byref(info),
                                           c.sizeof(info), c.byref(size)):
            raise ValueError('parent_unavailable')
        image, length = c.create_unicode_buffer(32768), w.DWORD(32768)
        if not self.k.QueryFullProcessImageNameW(handle, 0, image, c.byref(length)):
            raise ValueError('image_unavailable')
        return {'pid': info.pid, 'parent': info.parent,
                'started': str((values[0].high << 32) | values[0].low),
                'image': image.value, 'sha256': digest(image.value)}

    def exited(self, handle):
        result = self.k.WaitForSingleObject(handle, 0)
        if result not in (0, 258):
            raise ValueError('wait_failed')
        return result == 0

    def exit_code(self, handle):
        if not self.exited(handle):
            return None
        code = w.DWORD()
        if not self.k.GetExitCodeProcess(handle, c.byref(code)):
            raise ValueError('exit_unavailable')
        return code.value

    def terminate(self, handle):
        if not self.exited(handle) and not self.k.TerminateProcess(handle, 91):
            raise ValueError('cleanup_failed')

    def close(self, handle):
        if not self.k.CloseHandle(handle):
            raise ValueError('handle_close_failed')


def available_memory():
    class Memory(c.Structure):
        _fields_ = [('length', w.DWORD), ('load', w.DWORD)] + [
            (name, c.c_ulonglong) for name in
            ('total', 'available', 'page_total', 'page_available',
             'virtual_total', 'virtual_available', 'extended')]
    value = Memory()
    value.length = c.sizeof(value)
    if not c.windll.kernel32.GlobalMemoryStatusEx(c.byref(value)):
        raise ValueError('memory_unknown')
    return value.available


class Records:
    def __init__(self, path, version=1):
        self.file = Path(path).open('xb', buffering=0)
        self.count = 0
        self.version = version

    def add(self, stage, **fields):
        row = {'fixtureVersion': self.version, 'sequence': self.count + 1,
               'stage': stage, **fields}
        if self.version == 2:
            row['monotonicNs'] = time.monotonic_ns()
        data = (json.dumps(row, separators=(',', ':')) + '\n').encode()
        if self.count >= 12 or len(data) > 512:
            raise ValueError('fixture_evidence_limit')
        self.file.write(data)
        os.fsync(self.file.fileno())
        self.count += 1


class Protocol:
    """A deliberately static test protocol, not the Shiroha business protocol."""
    def __init__(self, nonce, record):
        if not re.fullmatch('[a-f0-9]{32}', nonce):
            raise ValueError('invalid_public_nonce')
        self.nonce, self.record = nonce, record
        self.initialized = False
        self.calls = self.lists = 0

    def receive(self, message):
        method, ident = message.get('method'), message.get('id')
        if message.get('jsonrpc') != '2.0':
            raise ValueError('invalid_protocol')
        if method == 'initialize' and not self.initialized:
            params = message.get('params', {})
            requested = params.get('protocolVersion')
            supported = ('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05')
            negotiated = requested if requested in supported else supported[0]
            self.initialized = True
            self.record('initialize', protocol=negotiated)
            result = {'protocolVersion': negotiated, 'capabilities': {'tools': {}},
                      'serverInfo': {'name': 'offline-shutdown', 'version': '1'}}
        elif method == 'notifications/initialized' and self.initialized:
            return None
        elif method == 'tools/list' and self.initialized and self.lists == 0:
            self.lists += 1
            self.record('list', count=1)
            result = {'tools': [{'name': 'probe_read',
                       'description': 'Return the public fixture nonce.',
                       'annotations': {'readOnlyHint': True,
                                       'destructiveHint': False,
                                       'openWorldHint': False},
                       'inputSchema': {'type': 'object', 'properties': {},
                                       'additionalProperties': False}}]}
        elif method == 'tools/call' and self.initialized and self.calls == 0:
            params = message.get('params', {})
            if params.get('name') != 'probe_read' or params.get('arguments') != {}:
                raise ValueError('unexpected_call')
            self.calls += 1
            self.record('call', count=1)
            data = {'data': {'ok': True, 'nonce': self.nonce}}
            result = {'content': [{'type': 'text', 'text': json.dumps(data)}],
                      'structuredContent': data, 'isError': False}
        elif method == 'ping' and self.initialized:
            result = {}
        else:
            raise ValueError('unexpected_method')
        if type(ident) not in (str, int):
            raise ValueError('invalid_request_id')
        return {'jsonrpc': '2.0', 'id': ident, 'result': result}


def close_resource(resource, record, scenario=None, sleep=time.sleep):
    record('cleanup_begin')
    if scenario is not None and SCENARIO_DELAY_MS[scenario]:
        sleep(SCENARIO_DELAY_MS[scenario] / 1000)
    resource.close()
    record('cleanup_end')


def fixture(directory, nonce, scenario=None):
    if scenario is not None and scenario not in SCENARIO_DELAY_MS:
        raise ValueError('scenario')
    records = Records(Path(directory) / 'fixture.jsonl', 2 if scenario else 1)
    native = Windows()
    handle = native.open(os.getpid())
    try:
        identity = native.identity(handle)
    finally:
        native.close(handle)
    fields = {k: identity[k] for k in ('pid', 'parent', 'started', 'sha256')}
    if scenario is not None:
        fields.update(scenario=scenario, cleanupDelayMs=SCENARIO_DELAY_MS[scenario])
    records.add('start', **fields)
    # An actual fixture-owned local resource. No production cleanup is claimed.
    resource = (Path(directory) / 'fixture-resource').open('xb')
    protocol = Protocol(nonce, records.add)
    ended = False
    status = 0
    try:
        for _ in range(16):
            line = sys.stdin.buffer.readline(16385)
            if not line:
                records.add('eof')
                ended = True
                break
            if len(line) > 16384 or not line.endswith(b'\n'):
                raise ValueError('input_limit')
            reply = protocol.receive(json.loads(line))
            if reply is not None:
                sys.stdout.write(json.dumps(reply, separators=(',', ':')) + '\n')
                sys.stdout.flush()
        if not ended:
            raise ValueError('message_count_limit')
    except Exception:
        status = 78
        records.add('protocol_failed')
    finally:
        close_resource(resource, records.add, scenario)
        records.add('terminal', complete=ended and status == 0, calls=protocol.calls)
        records.file.close()
    return status


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4) or os.name != 'nt':
        sys.exit(64)
    try:
        sys.exit(fixture(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None))
    except Exception:
        # No raw exception text, command line, environment or parameters.
        sys.exit(79)
