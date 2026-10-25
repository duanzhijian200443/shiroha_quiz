// Test-only Hosted root. The mode is fixed in code, never argv/environment/MCP.
import 'package:shiroha_quiz/data/external/windows_codex_client.dart';

import 'windows_trusted_bootstrap_aot.dart';

Future<void> main(List<String> arguments) => runTrustedBootstrap(arguments,
    connectionMode: WindowsCodexConnectionMode.hosted);
