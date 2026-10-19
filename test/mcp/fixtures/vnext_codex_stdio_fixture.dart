// Process-lifetime instrumentation only. All protocol/business behavior is the
// unchanged production entrypoint, with no synthetic App or credential option.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/mcp/vnext_mcp_entrypoint.dart' as production;

Future<void> main(List<String> arguments) async {
  // Codex can start one connection per session concurrently. Each process owns
  // a separate marker; appending to a shared Windows file loses PID records.
  await File(p.join(arguments.single, 'server-$pid.pid')).writeAsString('$pid');
  await production.main();
}
