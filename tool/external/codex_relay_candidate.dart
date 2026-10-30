import 'dart:io';

import 'package:shiroha_quiz/mcp/vnext_local_relay_port.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

/// Fixed adjacent local adapter. No credentials, data path or activation flags.
Future<void> main(List<String> arguments) async {
  final unified = arguments.length == 1 && arguments.single == '--profile=3';
  if (!unified && arguments.isNotEmpty) {
    stderr.writeln('invalidRelayArguments');
    exitCode = 64;
    return;
  }
  final profile = unified ? 3 : 2;
  await VnextMcpServer(VnextLocalRelayPort(profileVersion: profile),
          profileVersion: profile)
      .serveStdio();
}
