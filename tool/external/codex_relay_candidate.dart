import 'dart:io';

import 'package:shiroha_quiz/mcp/vnext_local_relay_port.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

/// Fixed adjacent local adapter. No credentials, data path or activation flags.
Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('invalidRelayArguments');
    exitCode = 64;
    return;
  }
  await VnextMcpServer(VnextLocalRelayPort()).serveStdio();
}
