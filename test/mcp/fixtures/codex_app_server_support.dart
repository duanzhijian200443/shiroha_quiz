// Opt-in installed-client checks. No model turn, auth copy, socket or App data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String flutterDartExecutable() {
  final parts =
      p.split(File(Platform.resolvedExecutable).resolveSymbolicLinksSync());
  final cache = parts.lastIndexOf('cache');
  if (cache < 0) throw StateError('Run with the Flutter test runner.');
  return p.joinAll([
    ...parts.take(cache + 1),
    'dart-sdk',
    'bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  ]);
}

/// Minimal JSON-line driver. The installed Codex binary owns the MCP client.
final class JsonLineProcess {
  JsonLineProcess._(this.process) {
    _stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
            (line) {
              try {
                final message =
                    (jsonDecode(line) as Map).cast<String, dynamic>();
                final pending = _pending.remove(message['id']);
                if (pending != null) pending.complete(message);
              } catch (_) {
                protocolClean = false;
                _failPending('Non-protocol stdout.');
              }
            },
            onDone: () => _failPending('Protocol closed.'),
            onError: (_) {
              protocolClean = false;
              _failPending('Protocol stream failed.');
            });
    // Drain diagnostics, but never retain or print raw errors/configuration.
    _stderr = process.stderr.listen((_) {});
  }

  final Process process;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<List<int>> _stderr;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _id = 0;
  bool protocolClean = true;
  bool forcedClose = false;
  bool _closed = false;

  static Future<JsonLineProcess> start(String executable, List<String> args,
      {required String cwd, required String home}) async {
    // Deliberate allowlist: never inherit provider keys, OpenCodex configuration,
    // CODEX_HOME or auth-token variables from the developer session.
    final environment = <String, String>{
      for (final entry in Platform.environment.entries)
        if (const {
          'SYSTEMROOT',
          'WINDIR',
          'PATH',
          'PATHEXT',
          'TEMP',
          'TMP',
          'USERPROFILE',
          'APPDATA',
          'LOCALAPPDATA'
        }.contains(entry.key.toUpperCase()))
          entry.key: entry.value,
      'CODEX_HOME': home,
    };
    return JsonLineProcess._(await Process.start(executable, args,
        workingDirectory: cwd,
        environment: environment,
        includeParentEnvironment: false));
  }

  void send(Map<String, dynamic> message) =>
      process.stdin.writeln(jsonEncode(message));

  Future<Map<String, dynamic>> request(
      String method, Map<String, dynamic> params,
      {bool mcp = false}) async {
    final id = ++_id;
    final response = Completer<Map<String, dynamic>>();
    _pending[id] = response;
    send({
      if (mcp) 'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params
    });
    try {
      return await response.future.timeout(const Duration(seconds: 40));
    } finally {
      _pending.remove(id);
    }
  }

  void _failPending(String category) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError(category));
    }
    _pending.clear();
  }

  Future<int> close() async {
    if (_closed) return process.exitCode;
    _closed = true;
    await process.stdin.close();
    try {
      return await process.exitCode.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      forcedClose = true;
      process.kill();
      return await process.exitCode.timeout(const Duration(seconds: 5));
    } finally {
      await _stdout.cancel();
      await _stderr.cancel();
    }
  }
}

final class InstalledCodex {
  InstalledCodex(this.executable, this.repo, this.home);
  final String executable;
  final String repo;
  final Directory home;
  late JsonLineProcess rpc;
  String? threadId;

  Future<void> configure({String? command, String? entrypoint}) async {
    // TOML basic strings share JSON escaping for these absolute Windows paths.
    final config = '''
model = "offline-probe"
model_provider = "offline"
[model_providers.offline]
name = "Offline probe - never start a turn"
base_url = "http://127.0.0.1:1"
wire_api = "responses"
[features]
plugins = false
apps = false
shell_snapshot = false
[analytics]
enabled = false
[feedback]
enabled = false
[mcp_servers.shiroha_vnext]
command = ${jsonEncode(command ?? flutterDartExecutable())}
args = [${jsonEncode(entrypoint ?? 'test/mcp/fixtures/vnext_codex_stdio_fixture.dart')}${entrypoint == null ? ', ${jsonEncode(home.path)}' : ''}]
cwd = ${jsonEncode(repo)}
startup_timeout_sec = 10
tool_timeout_sec = 10
''';
    await File(p.join(home.path, 'config.toml')).writeAsString(config);
  }

  Future<void> start() async {
    rpc = await JsonLineProcess.start(executable, ['app-server', '--stdio'],
        cwd: home.path, home: home.path);
    final init = await rpc.request('initialize', {
      'clientInfo': {'name': 'shiroha_windows_probe', 'version': '1.0.0'},
      'capabilities': {'experimentalApi': true}
    });
    if (init.containsKey('error') ||
        p.normalize(init['result']['codexHome'] as String) !=
            p.normalize(home.path)) {
      throw StateError('Codex did not confirm the isolated home.');
    }
    rpc.send({'method': 'initialized'});
    await newThread();
  }

  Future<String> newThread() async {
    final result = await rpc.request('thread/start', {
      'cwd': home.path,
      'ephemeral': true,
      'approvalPolicy': 'never',
      'sandbox': 'read-only',
      'model': 'offline-probe',
      'modelProvider': 'offline',
    });
    if (result.containsKey('error')) throw StateError('Codex thread failed.');
    return threadId = result['result']['thread']['id'] as String;
  }

  Future<Map<String, dynamic>> inventory() =>
      rpc.request('mcpServerStatus/list', {'threadId': threadId});

  Future<Map<String, dynamic>> call(
          String tool, Map<String, dynamic> arguments) =>
      rpc.request('mcpServer/tool/call', {
        'threadId': threadId,
        'server': 'shiroha_vnext',
        'tool': tool,
        'arguments': arguments,
      });
}
