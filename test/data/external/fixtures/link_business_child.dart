// Test-only Profile 3 peer. All owner events and READ data are synthetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

final class _ReadPort implements VnextMcpPort {
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (tool != 'open_context') throw StateError('unexpected fixture call');
    return {
      'profileVersion': 3,
      'data': {'contextRef': 'synthetic-read'},
      'error': null,
      'source': {'kind': 'android', 'deviceRef': 'a' * 64},
    };
  }

  @override
  Future<void> close() async {}
}

Future<void> main(List<String> args) async {
  final exitSignal = File(args[2]);
  void event(Map<String, Object?> fields) =>
      stderr.writeln('SHIROHA_LINK_EVENT ${jsonEncode({
            'runId': args[0],
            'resourceId': args[1],
            ...fields
          })}');
  void settled() => event({
        'type': 'settled',
        'mode': 'business',
        'targetClose': true,
        'tlsShutdown': true,
        'keyRetired': true
      });

  event({
    'type': 'owner',
    'processId': pid,
    'processStarted': '123456',
    'slotRef': 'phone'
  });
  event({
    'type': 'authenticated',
    'deviceIdentity': 'a' * 64,
    'installationIdentity': 'installation',
    'profileReference': 'profile'
  });
  // The parent signals only after receiving the READ response. In the normal
  // case this process stays alive until the supervisor actually sends EOF.
  final signal =
      Timer.periodic(const Duration(milliseconds: 10), (timer) async {
    if (!exitSignal.existsSync()) return;
    timer.cancel();
    if (args[3] == 'settled') settled();
    await stderr.flush();
    exit(0);
  });
  try {
    await VnextMcpServer(_ReadPort(), profileVersion: 3).serveStdio();
    settled();
    await stderr.flush();
  } finally {
    signal.cancel();
  }
}
