// Ordinary test children only. No Bridge executable, Native loader or secrets.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';

import 'codex_app_server_support.dart' show flutterDartExecutable;
import 'windows_resource_process_cases.dart' show FakeBridgeProcessIo;

const readyBytes = [82, 69, 65, 68, 89, 0, 255, 13];
const eofBytes = [69, 79, 70, 0, 254];
const payloadLength = 256 * 1024;

List<int> expectedProcessOutput(
        {required bool stderr, bool waitsForEof = true}) =>
    [
      if (!stderr) ...readyBytes,
      if (stderr && waitsForEof) ...eofBytes,
      for (var i = 0; i < payloadLength; i++)
        stderr ? 255 - (i % 256) : i % 256,
    ];

// The file is only a test-side exit gate, never a product startup protocol.
// A deadman ensures a failed test runner cannot leave a cooperating child alive;
// 79 is always a test failure, never successful lifecycle settlement.
const _childScript = r'''
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final deadman = Timer(const Duration(seconds: 30), () => exit(79));
  if (Platform.environment.length != 1 ||
      Platform.environment['SHIROHA_PROCESS_ENV_PAD'] != '') {
    exit(80);
  }
  stdout.add([82, 69, 65, 68, 89, 0, 255, 13]);
  await stdout.flush();
  if (args[2] == 'eof') {
    await stdin.drain<void>();
    stderr.add([69, 79, 70, 0, 254]);
    await stderr.flush();
  }
  final release = File(args[0]);
  while (!await release.exists()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  for (var chunk = 0; chunk < 64; chunk++) {
    stdout.add(Uint8List.fromList(List.generate(4096, (i) => i % 256)));
    stderr.add(Uint8List.fromList(List.generate(4096, (i) => 255 - i % 256)));
    await Future.wait([stdout.flush(), stderr.flush()]);
  }
  await Future.wait([stdout.close(), stderr.close()]);
  deadman.cancel();
  exit(int.parse(args[1]));
}
''';

/// Injects only ordinary Dart creation into the existing process-custody owner.
/// Package inspection remains the existing synthetic PE fixture. This does not
/// execute the private fixed-adjacent production launcher/AOT/Loader path.
final class WindowsProcessLifecycleFixture implements WindowsBridgeProcessIo {
  WindowsProcessLifecycleFixture._(this.root,
      {required this.code,
      required this.waitsForEof,
      required this.hideExit,
      required this.failInput,
      required this.failDrain,
      required bool holdCreate,
      required bool holdDrains}) {
    if (!holdCreate) transfer.complete();
    if (!holdDrains) {
      stdoutReceipt.complete();
      stderrReceipt.complete();
    }
    custody = WindowsBridgeProcess(io: this);
  }

  static Future<WindowsProcessLifecycleFixture> open({
    int code = 0,
    bool waitsForEof = true,
    bool holdCreate = false,
    bool holdDrains = false,
    bool hideExit = false,
    bool failInput = false,
    bool failDrain = false,
  }) async {
    final cache = Directory(p.join(Directory.current.path, '.dart_tool'));
    final root = await cache.createTemp('windows_process_lifecycle_');
    final fixture = WindowsProcessLifecycleFixture._(root,
        code: code,
        waitsForEof: waitsForEof,
        hideExit: hideExit,
        failInput: failInput,
        failDrain: failDrain,
        holdCreate: holdCreate,
        holdDrains: holdDrains);
    addTearDown(fixture.dispose);
    await File(p.join(root.path, 'child.dart')).writeAsString(_childScript);
    return fixture;
  }

  final Directory root;
  final int code;
  final bool waitsForEof, hideExit, failInput, failDrain;
  final inventory = FakeBridgeProcessIo();
  final transfer = Completer<void>();
  final created = Completer<ObservedWindowsTestChild>();
  final stdoutReceipt = Completer<void>(), stderrReceipt = Completer<void>();
  late final WindowsBridgeProcess custody;
  ObservedWindowsTestChild? child;
  int creates = 0;
  String creationStage = 'idle';
  Object? creationFailure;

  @override
  Future<Map<String, Uint8List>> inspect() async {
    creationStage = 'inspection';
    return inventory.inspect();
  }

  @override
  Future<WindowsCreatedBridgeProcess> create() async {
    creates++;
    creationStage = 'executable-resolution';
    late Process original;
    try {
      final executable = flutterDartExecutable();
      creationStage = 'sdk-create';
      original = await Process.start(
          executable,
          [
            p.join(root.path, 'child.dart'),
            p.join(root.path, 'exit.allowed'),
            '$code',
            waitsForEof ? 'eof' : 'independent',
          ],
          workingDirectory: root.path,
          runInShell: false,
          includeParentEnvironment: false,
          environment: const {'SHIROHA_PROCESS_ENV_PAD': ''});
    } catch (error) {
      creationFailure = error;
      rethrow;
    }
    creationStage = 'stream-attachment';
    final result = child = ObservedWindowsTestChild(original,
        stdoutReceipt: stdoutReceipt.future,
        stderrReceipt: stderrReceipt.future,
        hideExit: hideExit,
        failInput: failInput,
        failDrain: failDrain);
    created.complete(result);
    creationStage = 'transfer';
    await transfer.future;
    return result;
  }

  Future<void> start() async {
    try {
      await custody.start();
    } catch (_) {
      final error = creationFailure;
      final osCode = error is ProcessException
          ? error.errorCode
          : error is FileSystemException
              ? error.osError?.errorCode
              : null;
      fail('Ordinary child start failed: $creationStage, '
          '${error.runtimeType}, OS code $osCode');
    }
    await child!.ready.future;
    expect(custody.isCurrent, isTrue);
  }

  Future<void> allowExit() =>
      File(p.join(root.path, 'exit.allowed')).writeAsString('exit');

  Future<void> releaseForCleanup() async {
    if (!transfer.isCompleted) transfer.complete();
    if (!stdoutReceipt.isCompleted) stdoutReceipt.complete();
    if (!stderrReceipt.isCompleted) stderrReceipt.complete();
    await allowExit();
    await child?.requestEof();
  }

  Future<void> dispose() async {
    await releaseForCleanup();
    final original = child;
    if (original != null) {
      // Join actual SDK work even when the injected custody result is unknown.
      await original.requestEof();
      expect(await original.rawExit, code);
      await Future.wait([original.rawStdout, original.rawStderr]);
    }
    try {
      await custody.stopAndWait();
    } on StateError {
      // The tests assert the latched failure; disposal is not product recovery.
    }
    final cache = p.join(Directory.current.path, '.dart_tool');
    expect(p.isWithin(cache, root.path), isTrue);
    await root.delete(recursive: true);
    expect(await root.exists(), isFalse);
  }
}

/// Real SDK exit and raw stream completion, with separately controlled test
/// receipts/faults for the existing Owner/Startup failure and drain boundaries.
final class ObservedWindowsTestChild implements WindowsCreatedBridgeProcess {
  ObservedWindowsTestChild(this.original,
      {required Future<void> stdoutReceipt,
      required Future<void> stderrReceipt,
      required bool hideExit,
      required this.failInput,
      required bool failDrain}) {
    rawExit = original.exitCode.then((code) {
      exitObserved = true;
      return code;
    });
    exitCode = rawExit.then((code) {
      if (hideExit) throw StateError('Test exit observation unavailable');
      return code;
    });
    rawStdout =
        _collect(original.stdout, stdoutBytes, ready, readyBytes.length);
    rawStderr = _collect(original.stderr, stderrBytes, eof, eofBytes.length);
    stdoutDrained = rawStdout.then((_) => stdoutReceipt);
    stderrDrained = rawStderr.then((_) => stderrReceipt);
    settlement = Future.wait([rawExit, stdoutDrained, stderrDrained]).then((_) {
      if (failDrain) throw StateError('Test drain receipt unavailable');
      return rawExit;
    });
  }

  final Process original;
  final bool failInput;
  final stdoutBytes = <int>[], stderrBytes = <int>[];
  final ready = Completer<void>(), eof = Completer<void>();
  final inputReached = Completer<void>();
  late final Future<int> rawExit;
  late final Future<void> rawStdout, rawStderr, stdoutDrained, stderrDrained;
  @override
  late final Future<int> exitCode;
  @override
  late final Future<int> settlement;
  Future<void>? _input;
  int closes = 0;
  bool exitObserved = false;

  static Future<void> _collect(Stream<List<int>> stream, List<int> bytes,
      Completer<void> marker, int markerLength) async {
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length >= markerLength && !marker.isCompleted) {
        marker.complete();
      }
    }
  }

  Future<void> requestEof() => _input ??= original.stdin.close();

  @override
  Future<void> closeInput() async {
    closes++;
    if (!inputReached.isCompleted) inputReached.complete();
    await requestEof();
    if (failInput) throw StateError('Test input receipt unavailable');
  }

  void expectRawOutput({bool waitsForEof = true}) {
    expect(stdoutBytes, expectedProcessOutput(stderr: false));
    expect(stderrBytes,
        expectedProcessOutput(stderr: true, waitsForEof: waitsForEof));
  }
}
