import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/link_frontend.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'package:shiroha_quiz/data/external/link/link_call_capture.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('invalid_arguments');
    exitCode = 64;
    return;
  }
  const verify = bool.fromEnvironment('SHIROHA_LINK_VERIFY_SUPERVISION');
  LinkCallCapture? capture;
  if (verify) {
    final config = await LinkCaptureConfig.load();
    if (config != null) {
      capture = LinkCallCapture(config, frontend: true);
      await capture.start();
    }
  }
  final port = LinkFrontendPort(
      diagnostics: capture == null
          ? null
          : LinkFrontendDiagnostics(capture.diagnostics,
              lifecycleObserver: capture.lifecycle));
  var originalClosed = false;
  try {
    await VnextMcpServer(port, profileVersion: 3)
        .serveTransport(LinkFrontendTransport(StdioServerTransport(), port));
    originalClosed = true;
  } catch (_) {
    stderr.writeln('link_frontend_unavailable');
    exitCode = 78;
  } finally {
    // No client wait protocol: hard termination can omit this footer. Such a
    // capture remains incomplete, even when the last tool response succeeded.
    if (capture != null &&
        !await capture.finish(originalClosed: originalClosed)) {
      stderr.writeln('link_call_capture_incomplete');
      exitCode = capture.exitCodeAfterFinish(exitCode, complete: false);
    }
  }
}
