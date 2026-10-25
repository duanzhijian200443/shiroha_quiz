// Opt-in isolated-client checks. No auth copy or private App data.
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
        .listen((line) {
      try {
        final message = (jsonDecode(line) as Map).cast<String, dynamic>();
        if (message['method'] != null) _events.add(message);
        final pending = _pending.remove(message['id']);
        if (pending != null) pending.complete(message);
      } catch (_) {
        protocolClean = false;
        _failPending('Non-protocol stdout.');
      }
    }, onDone: () {
      _failPending('Protocol closed.');
      unawaited(_events.close());
      if (!_stdoutDone.isCompleted) _stdoutDone.complete();
    }, onError: (_) {
      protocolClean = false;
      _failPending('Protocol stream failed.');
    });
    // Drain diagnostics, but never retain or print raw errors/configuration.
    _stderr = process.stderr.listen((_) {}, onDone: () {
      if (!_stderrDone.isCompleted) _stderrDone.complete();
    }, onError: (Object error, StackTrace stack) {
      if (!_stderrDone.isCompleted) _stderrDone.completeError(error, stack);
    });
    unawaited(
        _stderrDone.future.then((_) {}, onError: (Object _, StackTrace __) {}));
  }

  final Process process;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<List<int>> _stderr;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Stream<Map<String, dynamic>> get events => _events.stream;
  final _stdoutDone = Completer<void>(), _stderrDone = Completer<void>();
  Future<int>? _closing;
  int _id = 0;
  bool protocolClean = true;
  bool forcedClose = false;

  static Future<JsonLineProcess> start(String executable, List<String> args,
      {required String cwd,
      required String home,
      bool isolateProfile = false}) async {
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
      if (isolateProfile) ...{
        'HOME': home,
        'USERPROFILE': home,
        'APPDATA': home,
        'LOCALAPPDATA': home,
        'NO_PROXY': '127.0.0.1,localhost',
      },
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

  Future<int> close() => _closing ??= _close();

  Future<int> _close() async {
    await process.stdin.close();
    final settlement = Future.wait<int>([
      process.exitCode,
      _stdoutDone.future.then((_) => 0),
      _stderrDone.future.then((_) => 0),
    ]).then((values) => values.first);
    try {
      return await settlement.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      forcedClose = true;
      process.kill();
      return await settlement.timeout(const Duration(seconds: 5));
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
  bool _modelTurns = false;

  Future<void> configure(
      {String? command,
      List<String>? commandArguments,
      String? entrypoint,
      List<String>? entrypointArguments,
      Uri? responsesBase}) async {
    if (responsesBase != null &&
        (responsesBase.scheme != 'http' ||
            responsesBase.host != '127.0.0.1' ||
            responsesBase.userInfo.isNotEmpty ||
            responsesBase.hasQuery ||
            responsesBase.hasFragment)) {
      throw ArgumentError(
          'Only the test loopback Responses service is allowed.');
    }
    _modelTurns = responsesBase != null;
    // TOML basic strings share JSON escaping for these absolute Windows paths.
    final config = '''
model = "offline-probe"
model_provider = "offline"
[model_providers.offline]
name = "Offline scripted probe"
base_url = ${jsonEncode(responsesBase?.toString() ?? 'http://127.0.0.1:1')}
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
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
args = ${jsonEncode(commandArguments ?? [
              entrypoint ?? 'test/mcp/fixtures/vnext_codex_stdio_fixture.dart',
              ...?entrypointArguments,
              if (entrypoint == null) home.path
            ])}
cwd = ${jsonEncode(repo)}
startup_timeout_sec = 10
tool_timeout_sec = 10
''';
    await File(p.join(home.path, 'config.toml')).writeAsString(config);
  }

  Future<void> start({bool createThread = true}) async {
    rpc = await JsonLineProcess.start(executable, ['app-server', '--stdio'],
        cwd: home.path, home: home.path, isolateProfile: _modelTurns);
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
    if (createThread) await newThread();
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
      String tool, Map<String, dynamic> arguments) {
    if (_modelTurns) {
      throw StateError('Direct calls cannot prove a model turn.');
    }
    return rpc.request('mcpServer/tool/call', {
      'threadId': threadId,
      'server': 'shiroha_vnext',
      'tool': tool,
      'arguments': arguments,
    });
  }

  /// Observe only original app-server events. Never inject tool results/items.
  Future<CodexTurnObservation> turn() async {
    if (!_modelTurns) throw StateError('Offline model service not configured.');
    final observed = CodexTurnObservation(threadId!);
    final subscription =
        rpc.events.listen(observed.receive, onDone: observed.closed);
    try {
      final response = await rpc.request('turn/start', {
        'threadId': threadId,
        'input': [
          {'type': 'text', 'text': 'Execute the isolated scripted MCP probe.'}
        ],
      });
      if (response.containsKey('error')) throw StateError('Turn start failed.');
      final id = response['result']['turn']['id'] as String;
      observed.turnId = id;
      await observed.done.future.timeout(const Duration(seconds: 40));
      if (observed.completedId != id || observed.foreignTurn) {
        throw StateError('Turn evidence correlation failed.');
      }
      return observed;
    } finally {
      await subscription.cancel();
    }
  }
}

final class CodexTurnObservation {
  CodexTurnObservation(this.threadId) {
    unawaited(done.future.then((_) {}, onError: (Object _, StackTrace __) {}));
  }
  final String threadId;
  String? turnId, completedId, status;
  Object? errorCode;
  List<String> errorCategories = [];
  bool foreignTurn = false;
  final done = Completer<void>();
  final items = <Map<String, dynamic>>[];
  final eventTurnIds = <String>{};
  void receive(Map<String, dynamic> event) {
    final params = event['params'];
    if (params is! Map || params['threadId'] != threadId) return;
    if (params['turnId'] is String) {
      eventTurnIds.add(params['turnId'] as String);
    }
    if (event['method'] == 'item/completed') {
      items.add((params['item'] as Map).cast<String, dynamic>());
    }
    if (event['method'] == 'turn/completed') {
      completedId = params['turn']['id'] as String;
      status = params['turn']['status'] as String;
      final error = params['turn']['error'];
      if (error is Map) {
        final info = error['codexErrorInfo'];
        errorCode = info is Map ? info.keys.toList() : info;
        final message = (error['message'] as String? ?? '').toLowerCase();
        errorCategories = [
          for (final word in const [
            'sandbox',
            'auth',
            'api key',
            'model',
            'network',
            'connection',
            'decode',
            'stream',
            'not found',
            'access',
            'proxy',
            'http',
            '401',
            '403',
            'timeout',
            'credential',
            'login'
          ])
            if (message.contains(word)) word
        ];
      }
      foreignTurn = eventTurnIds.any((id) => id != completedId);
      if (!done.isCompleted) done.complete();
    }
  }

  void closed() {
    if (!done.isCompleted) {
      done.completeError(StateError('Client closed during turn.'));
    }
  }
}
