// Isolated ordinary-process regression host. No Flutter, database or credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/composition/mcp_vnext_app_owned_relay.dart';

Future<void> main() async {
  final root = p.dirname(Platform.resolvedExecutable);
  final events = File(p.join(root, 'app.jsonl'));
  void report(String event, int connection) => events.writeAsStringSync(
      '${jsonEncode({'event': event, 'connection': connection, 'pid': pid})}\n',
      mode: FileMode.append,
      flush: true);
  final scenario = File(p.join(root, 'scenario')).readAsStringSync();
  final relay = McpVnextAppOwnedRelay(
      onEvent: report,
      idleTimeout: scenario.contains('idle')
          ? const Duration(seconds: 1)
          : const Duration(seconds: 30));
  relay.start();
  report(relay.available ? 'ready' : 'unavailable', 0);
  final watch = Stopwatch()..start();
  while (!File(p.join(root, 'stop')).existsSync() &&
      watch.elapsed < const Duration(seconds: 90)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  try {
    await relay.close();
    report('appClosed', 0);
  } catch (_) {
    report('appCloseFailed', 0);
    exitCode = 23;
  }
}
