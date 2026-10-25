// Test-only MCP fault producer over real stdin/stdout. No business authority.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

Future<void> main() async {
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
                  : VnextMcpServer.inputSchemas.entries
                      .map((entry) =>
                          {'name': entry.key, 'inputSchema': entry.value})
                      .toList()
        };
      case 'tools/call':
        report('call');
        if (first && scenario == 'sdk-error') {
          stdout.writeln(jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32603, 'message': 'Synthetic protocol failure'}
          }));
          continue;
        }
        final refusal = vnextFailure('unavailable');
        result = {
          'content': <Object?>[],
          'structuredContent': refusal,
          'isError': true
        };
      default:
        result = <String, Object?>{};
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }
  report('eof');
  final watch = Stopwatch()..start();
  final release = File(p.join(root, first ? 'allow-exit-1' : 'allow-exit-2'));
  while (!release.existsSync() && watch.elapsed < const Duration(seconds: 60)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await stdout.flush();
  await stderr.flush();
  if (first && scenario == 'failed-close') exitCode = 23;
}
