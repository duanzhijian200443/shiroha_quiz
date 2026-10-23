// Test executable placed beside the original candidate. No fake I/O: exercises
// the private fixed-adjacent launcher and SDK wrapper, or only the Native ABI
// loader. Never acquires protected objects, credentials or TLS resources.
import 'dart:io';
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.single == 'loader') {
      WindowsExternalNative.open();
      stdout.writeln('abiLoaded');
      return;
    }
    final owner = WindowsBridgeProcess();
    try {
      final starting = owner.start();
      if (arguments.single == 'interrupted') {
        final closing = owner.stopAndWait();
        try {
          await starting;
        } on StateError {
          // Inspection interrupted before creation; still join real settlement.
        }
        await closing;
      } else {
        await starting;
        if (!owner.isCurrent) throw StateError('unexpectedExit');
        final closing = owner.stopAndWait();
        if (!identical(closing, owner.stopAndWait())) {
          throw StateError('closeIdentity');
        }
        await closing;
        await owner.exited;
      }
      if (owner.isCurrent) throw StateError('stillCurrent');
    } finally {
      // Even a failed assertion must join the original child before returning.
      await owner.stopAndWait();
    }
    stdout.writeln('settled');
  } catch (_) {
    stderr.writeln('probeFailed');
    exitCode = 1;
  }
}
