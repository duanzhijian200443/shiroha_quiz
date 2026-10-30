// Test-only MCP fault producer over real stdin/stdout. No business authority.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

Future<void> main(List<String> arguments) async {
  final profile = arguments.contains('--profile=3') ? 3 : 2;
  final root = p.dirname(Platform.resolvedExecutable);
  final events = File(p.join(root, 'bridge.jsonl'));
  final first = !events.existsSync();
  final scenario = File(p.join(root, 'scenario')).readAsStringSync();
  void report(String event) =>
      events.writeAsStringSync('${jsonEncode({'event': event, 'pid': pid})}\n',
          mode: FileMode.append, flush: true);
  report('started');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final id = request['id'];
    if (id == null) continue;
    Object? result;
    switch (request['method']) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-11-25',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'relay-test', 'version': '1'}
        };
      case 'tools/list':
        result = {
          'tools':
              first && (scenario == 'inventory' || scenario == 'failed-close')
                  ? <Object?>[]
                  : VnextMcpServer.schemasFor(profile)
                      .entries
                      .map((entry) =>
                          {'name': entry.key, 'inputSchema': entry.value})
                      .toList()
        };
      case 'tools/call':
        report('call');
        if (first && scenario.startsWith('pending-peer')) {
          // Keep the original client call pending until original EOF/exit/drain.
          report('pendingCall');
          continue;
        }
        if (first && scenario == 'sdk-error') {
          stdout.writeln(jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32603, 'message': 'Synthetic protocol failure'}
          }));
          continue;
        }
        final refusal = vnextFailure('unavailable',
            profileVersion: profile,
            source: const VnextDataSource('windows', 'synthetic'));
        result = {
          'content': <Object?>[],
          'structuredContent': refusal,
          'isError': true
        };
      default:
        result = <String, Object?>{};
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    if (first &&
        scenario == 'unexpected-exit' &&
        request['method'] == 'tools/call') {
      await stdout.flush();
      report('exitArmed');
      final deadline = Stopwatch()..start();
      while (!File(p.join(root, 'exit-now')).existsSync() &&
          deadline.elapsed < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      report('spontaneousExit');
      exit(23); // Isolated original-child failure, without a client EOF.
    }
  }
  report('eof');
  final watch = Stopwatch()..start();
  final release = File(p.join(root, first ? 'allow-exit-1' : 'allow-exit-2'));
  while (!release.existsSync() && watch.elapsed < const Duration(seconds: 60)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await stdout.flush();
  await stderr.flush();
  if (first &&
      (scenario == 'failed-close' ||
          scenario == 'pending-peer-failed-close' ||
          scenario == 'adapter-reconnect-failed-close')) {
    exitCode = 23;
  }
}
