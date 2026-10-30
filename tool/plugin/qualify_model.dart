// Test-only scripted model for installed-Codex lifecycle qualification.
// No provider credentials, external requests or business data are used.
import 'dart:convert';
import 'dart:io';

import '../../test/mcp/fixtures/offline_codex_responses.dart';

Future<void> main() async {
  final model = OfflineCodexResponses([
    ScriptedMcpCall(
        'propose_generated_questions',
        (_) => {
              'contextRef': List.filled(43, 'A').join(),
              'submission': {
                'schemaVersion': 1,
                'submissionKey': 'host-qualification',
                'requestedCount': 1,
                'items': [<String, Object?>{}],
              },
            }),
  ]);
  try {
    await model.start();
    stdout.writeln(jsonEncode({'base': model.base.toString()}));
    await stdout.flush();
    await stdin.drain<void>();
  } finally {
    await model.close();
    stdout.writeln(jsonEncode({
      'requests': model.requests,
      'issued': model.issued.length,
      'outputs': model.outputs.length,
      'finished': model.finished,
      'failures': model.failures,
    }));
    await stdout.flush();
  }
}
