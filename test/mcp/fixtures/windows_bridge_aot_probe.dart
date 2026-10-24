// Test executable placed beside the original candidate. No fake I/O: exercises
// the private fixed-adjacent launcher and SDK wrapper, or only the Native ABI
// loader. Never acquires protected objects, credentials or TLS resources.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';

final class _RejectOutput implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {
      throw StateError('testOutputFailure');
    }
  }

  @override
  Future<void> close() async {}
}

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.single == 'loader') {
      WindowsExternalNative.open();
      stdout.writeln('abiLoaded');
      return;
    }
    if (arguments.single.startsWith('stdio')) {
      final mode = arguments.single;
      final output =
          mode.startsWith('stdio-output-') ? IOSink(_RejectOutput()) : stdout;
      if (mode == 'stdio-output-closed') await output.close();
      final generated = StreamController<List<int>>();
      if (mode == 'stdio-output-error') {
        generated.add(utf8.encode('${jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': {
                'protocolVersion': '2025-11-25',
                'capabilities': {},
                'clientInfo': {'name': 'output-failure-probe', 'version': '1'}
              }
            })}\n'));
      }
      final input = mode == 'stdio-input-error'
          ? Stream<List<int>>.error(StateError('testInputFailure'))
          : mode == 'stdio-output-error'
              ? generated.stream
              : stdin;
      final owner = WindowsBridgeProcess.stdio(input: input, output: output);
      try {
        await owner.start();
        if (mode == 'stdio-close') await owner.stopAndWait();
        await owner.exited;
      } finally {
        final closing = owner.stopAndWait();
        if (!identical(closing, owner.stopAndWait())) {
          throw StateError('closeIdentity');
        }
        await closing;
      }
      return; // stdout belongs exclusively to the original child protocol.
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
