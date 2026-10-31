import 'dart:io';
import 'package:shiroha_quiz/composition/mcp_vnext_development_bridge.dart';

/// Optional Windows-target package. Still requires the ORIGINAL App parent,
/// protected Bootstrap, P15/P0 and App-owned Bridge settlement.
Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('invalidBridgeArguments');
    exitCode = 64;
    return;
  }
  await serveDevelopmentWindowsBridge(profileVersion: 3);
}
