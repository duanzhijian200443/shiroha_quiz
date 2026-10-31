import 'dart:io';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';

/// Local installer only. Normal startup never treats a missing state as new.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('invalid_arguments');
    exitCode = 64;
    return;
  }
  try {
    final store = await LinkStateStore.open(Directory(arguments[0]),
        initializeInstance: arguments[1]);
    await store.close();
  } catch (_) {
    stderr.writeln('link_initialization_refused');
    exitCode = 78;
  }
}
