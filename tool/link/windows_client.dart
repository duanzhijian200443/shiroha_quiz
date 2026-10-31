import 'dart:convert';
import 'dart:io';
import 'package:shiroha_quiz/mcp/link_windows_client.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3 || arguments.first != '--link') {
    stderr.writeln('invalid_arguments');
    exitCode = 64;
    return;
  }
  final run = linkToken(arguments[1]), resource = linkToken(arguments[2]);
  void event(Map<String, Object?> fields) =>
      stderr.writeln('SHIROHA_LINK_EVENT ${jsonEncode({
            'runId': run,
            'resourceId': resource,
            ...fields
          })}');
  final port = LinkWindowsClient();
  try {
    event({
      'type': 'owner',
      'processId': pid,
      'processStarted': 'original-app-owned',
      'slotRef': 'windows'
    });
    final target = await port.connect();
    event({'type': 'authenticated', ...target.toJson()});
    await VnextMcpServer(port, profileVersion: 3).serveStdio();
    await port.close();
    event({
      'type': 'settled',
      'mode': 'business',
      'targetClose': true,
      'tlsShutdown': true,
      'keyRetired': true
    });
  } catch (_) {
    stderr.writeln('windows_target_unavailable');
    exitCode = 79;
  }
}
