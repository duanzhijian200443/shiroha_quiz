// A test-only loopback service. Stdout carries bounded control summaries only.
import 'dart:convert';
import 'dart:io';
import 'offline_codex_responses.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || !RegExp(r'^[a-f0-9]{32}$').hasMatch(args.single)) {
    exitCode = 64;
    return;
  }
  final nonce = args.single;
  final service = OfflineCodexResponses([
    ScriptedMcpCall('probe_read', (_) => {}),
  ],
      validateOutput: (_, output) =>
          output.length == 1 &&
          output['data'] is Map &&
          (output['data'] as Map).length == 2 &&
          output['data']['ok'] == true &&
          output['data']['nonce'] == nonce,
      finalMessage: 'Offline probe complete: $nonce');
  await service.start();
  stdout
      .writeln(jsonEncode({'kind': 'ready', 'base': service.base.toString()}));
  try {
    await stdin.first.timeout(const Duration(seconds: 65));
  } catch (_) {
    // Closed driver input or timeout only stops this owned HTTP fixture.
  } finally {
    await service.close();
  }
  stdout.writeln(jsonEncode({
    'kind': 'finished',
    'accepted': service.requests,
    'total': service.totalRequests,
    'outputs': service.outputs.length,
    'finished': service.finished,
    'failures': service.failures
  }));
}
