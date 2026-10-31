import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/link_frontend.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('invalid_arguments');
    exitCode = 64;
    return;
  }
  final port = LinkFrontendPort();
  try {
    await VnextMcpServer(port, profileVersion: 3)
        .serveTransport(LinkFrontendTransport(StdioServerTransport(), port));
  } catch (_) {
    stderr.writeln('link_frontend_unavailable');
    exitCode = 78;
  }
}
