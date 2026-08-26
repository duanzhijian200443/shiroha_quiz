import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

const trainCL1BSupervisorPortEnvironment = 'TRAIN_C_L1B_SUPERVISOR_PORT';
const trainCL1BSupervisorNonceEnvironment = 'TRAIN_C_L1B_SUPERVISOR_NONCE';
const trainCL1BChildPhaseEnvironment = 'TRAIN_C_L1B_CHILD_PHASE';

enum TrainCL1BChildPhase { parse, commit, restart, finalize }

extension TrainCL1BChildPhaseX on TrainCL1BChildPhase {
  String get wireName => switch (this) {
        TrainCL1BChildPhase.parse => 'parse',
        TrainCL1BChildPhase.commit => 'commit',
        TrainCL1BChildPhase.restart => 'restart',
        TrainCL1BChildPhase.finalize => 'finalize',
      };

  static TrainCL1BChildPhase parse(String value) {
    for (final phase in TrainCL1BChildPhase.values) {
      if (phase.wireName == value) return phase;
    }
    throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
  }
}

final class TrainCL1BSupervisorException implements Exception {
  const TrainCL1BSupervisorException(this.code);

  final String code;

  @override
  String toString() => code;
}

typedef TrainCL1BStartedChild = ({
  int pid,
  Stream<List<int>> stdout,
  Stream<List<int>> stderr,
  Future<int> exitCode,
  bool Function() kill,
});

typedef TrainCL1BChildStarter = Future<TrainCL1BStartedChild> Function(
  TrainCL1BChildPhase phase,
  Map<String, String> environment,
);

typedef TrainCL1BProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  required bool includeParentEnvironment,
  required bool runInShell,
});

typedef TrainCL1BParseFailureHandler = void Function();

/// Loopback-only client used by a Flutter child to exchange transient TRAIN C
/// facts with its parent supervisor. Raw source identities/hashes never touch
/// stdout, a durable file, or the final evidence map.
final class TrainCL1BSupervisorClient {
  TrainCL1BSupervisorClient._({
    required this.port,
    required this.nonce,
    required this.phase,
  });

  final int port;
  final String nonce;
  final TrainCL1BChildPhase phase;

  factory TrainCL1BSupervisorClient.fromEnvironment({
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    final port = int.tryParse(
      values[trainCL1BSupervisorPortEnvironment]?.trim() ?? '',
    );
    final nonce = values[trainCL1BSupervisorNonceEnvironment]?.trim() ?? '';
    final phaseValue = values[trainCL1BChildPhaseEnvironment]?.trim() ?? '';
    if (port == null || port <= 0 || port > 65535 || nonce.isEmpty) {
      throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
    }
    return TrainCL1BSupervisorClient._(
      port: port,
      nonce: nonce,
      phase: TrainCL1BChildPhaseX.parse(phaseValue),
    );
  }

  Future<void> reportPass(Map<String, Object?> payload) {
    return _send(<String, Object?>{
      'kind': 'report',
      'nonce': nonce,
      'phase': phase.wireName,
      'status': 'PASS',
      'payload': payload,
    });
  }

  Future<void> reportFailure(String code) {
    return _send(<String, Object?>{
      'kind': 'report',
      'nonce': nonce,
      'phase': phase.wireName,
      'status': 'FAIL',
      'failureCode': code,
      'payload': const <String, Object?>{},
    });
  }

  Future<Map<String, Object?>> requestFacts() async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.writeln(jsonEncode(<String, Object?>{
        'kind': 'request',
        'nonce': nonce,
        'phase': phase.wireName,
      }));
      await socket.flush();
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      if (line.length > 1024 * 1024) {
        throw const FormatException();
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map || decoded['status'] != 'PASS') {
        throw const FormatException();
      }
      final facts = decoded['facts'];
      if (facts is! Map) throw const FormatException();
      return Map<String, Object?>.from(facts);
    } catch (_) {
      throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
    } finally {
      await socket?.close();
    }
  }

  Future<void> _send(Map<String, Object?> message) async {
    Socket? socket;
    try {
      final encoded = jsonEncode(message);
      if (encoded.length > 1024 * 1024) {
        throw const FormatException();
      }
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.writeln(encoded);
      await socket.flush();
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      if (line.length > 1024) throw const FormatException();
      final decoded = jsonDecode(line);
      if (decoded is! Map || decoded['status'] != 'PASS') {
        throw const FormatException();
      }
    } catch (_) {
      throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
    } finally {
      await socket?.close();
    }
  }
}

typedef TrainCL1BDiagnosticSink = void Function(String message);

/// Owns one Run #1 in a plain Dart process while every application phase runs
/// in a separate Flutter OS process. The supervisor keeps source-side facts in
/// memory only and emits only allowlisted supervisor-owned diagnostics.
final class TrainCL1BSupervisor {
  const TrainCL1BSupervisor._();

  static Future<int> run({
    required Map<String, String> liveEnvironment,
    required Map<String, String> continuationEnvironment,
    TrainCL1BChildStarter? startChild,
    TrainCL1BProcessStarter? processStart,
    TrainCL1BParseFailureHandler? onParseFailure,
    TrainCL1BDiagnosticSink? diagnosticSink,
    Duration? phaseTimeoutOverrideForTesting,
  }) async {
    final server = await _TrainCL1BSupervisorServer.bind();
    try {
      for (final phase in TrainCL1BChildPhase.values) {
        final base = phase == TrainCL1BChildPhase.parse
            ? liveEnvironment
            : continuationEnvironment;
        final environment = <String, String>{
          ...base,
          trainCL1BSupervisorPortEnvironment: server.port.toString(),
          trainCL1BSupervisorNonceEnvironment: server.nonce,
          trainCL1BChildPhaseEnvironment: phase.wireName,
        };
        final reportFuture = server.expect(phase);
        final child = startChild != null
            ? await startChild(phase, environment)
            : await _startFlutterChild(
                phase,
                environment,
                processStart: processStart,
              );
        final stdoutDrain = child.stdout.drain<void>();
        final stderrDrain = child.stderr.drain<void>();
        final timeout = phaseTimeoutOverrideForTesting ??
            switch (phase) {
              TrainCL1BChildPhase.parse => const Duration(minutes: 20),
              TrainCL1BChildPhase.commit => const Duration(minutes: 30),
              TrainCL1BChildPhase.restart => const Duration(minutes: 10),
              TrainCL1BChildPhase.finalize => const Duration(minutes: 15),
            };
        final deadline = DateTime.now().add(timeout);
        var diagnosticCategory = 'SUPERVISOR_FAILURE';
        var reportReceived = false;
        int? observedExitCode;
        try {
          final race = await _waitForReportOrEarlyExit(
            reportFuture: reportFuture,
            exitCodeFuture: child.exitCode,
          ).timeout(_remainingUntil(deadline));
          final report = race.report;
          if (report == null) {
            diagnosticCategory = 'CHILD_EARLY_EXIT';
            observedExitCode = race.earlyExitCode;
            throw const TrainCL1BSupervisorException(
              'TRAIN_C_HARNESS_NOT_READY',
            );
          }
          reportReceived = true;

          final exitCode =
              await child.exitCode.timeout(_remainingUntil(deadline));
          observedExitCode = exitCode;
          await Future.wait<void>(<Future<void>>[
            stdoutDrain,
            stderrDrain,
          ]).timeout(_remainingUntil(deadline));

          if (report['status'] != 'PASS') {
            diagnosticCategory = 'CHILD_REPORTED_FAILURE';
            final code = report['failureCode'];
            throw TrainCL1BSupervisorException(
              code is String && code.isNotEmpty
                  ? code
                  : 'TRAIN_C_HARNESS_NOT_READY',
            );
          }
          if (exitCode != 0) {
            diagnosticCategory = 'CHILD_NONZERO_EXIT';
            throw const TrainCL1BSupervisorException(
              'TRAIN_C_HARNESS_NOT_READY',
            );
          }
          final payload = report['payload'];
          if (payload is! Map) {
            diagnosticCategory = 'INVALID_REPORT_PAYLOAD';
            throw const TrainCL1BSupervisorException(
              'TRAIN_C_HARNESS_NOT_READY',
            );
          }
          server.acceptReport(
            phase,
            Map<String, Object?>.from(payload),
          );
        } on TimeoutException {
          child.kill();
          _notifyParseFailure(phase, onParseFailure);
          _emitSafeDiagnostic(
            phase: phase,
            category: 'PHASE_TIMEOUT',
            reportReceived: reportReceived,
            childExitCode: observedExitCode,
            sink: diagnosticSink,
          );
          throw const TrainCL1BSupervisorException(
            'TRAIN_C_HARNESS_NOT_READY',
          );
        } catch (_) {
          child.kill();
          _notifyParseFailure(phase, onParseFailure);
          _emitSafeDiagnostic(
            phase: phase,
            category: diagnosticCategory,
            reportReceived: reportReceived,
            childExitCode: observedExitCode,
            sink: diagnosticSink,
          );
          rethrow;
        }
      }
      return 0;
    } finally {
      await server.close();
    }
  }

  static Duration _remainingUntil(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) throw TimeoutException('phase deadline');
    return remaining;
  }

  static Future<
      ({
        Map<String, Object?>? report,
        int? earlyExitCode,
      })> _waitForReportOrEarlyExit({
    required Future<Map<String, Object?>> reportFuture,
    required Future<int> exitCodeFuture,
  }) {
    final completer = Completer<
        ({
          Map<String, Object?>? report,
          int? earlyExitCode,
        })>();

    reportFuture.then((report) {
      if (!completer.isCompleted) {
        completer.complete((report: report, earlyExitCode: null));
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    });

    exitCodeFuture.then((code) {
      if (!completer.isCompleted) {
        completer.complete((report: null, earlyExitCode: code));
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  }

  static void _emitSafeDiagnostic({
    required TrainCL1BChildPhase phase,
    required String category,
    required bool reportReceived,
    required int? childExitCode,
    TrainCL1BDiagnosticSink? sink,
  }) {
    final emit = sink ?? (String message) => stderr.writeln(message);
    emit(
      '[TRAIN_C_SUPERVISOR_DIAGNOSTIC] '
      'phase=${phase.wireName} '
      'category=$category '
      'reportReceived=$reportReceived '
      'childExitCode=${childExitCode ?? 'unknown'}',
    );
  }

  static void _notifyParseFailure(
    TrainCL1BChildPhase phase,
    TrainCL1BParseFailureHandler? onParseFailure,
  ) {
    if (phase != TrainCL1BChildPhase.parse || onParseFailure == null) return;
    try {
      onParseFailure();
    } catch (_) {
      // Failure terminalization is best-effort here. The durable consumed
      // attempt itself remains fail-closed even if this status update fails.
    }
  }

  static String resolveFlutterExecutable([Map<String, String>? environment]) {
    return resolveFlutterExecutableForPlatform(environment: environment);
  }

  static String resolveFlutterExecutableForPlatform({
    Map<String, String>? environment,
    bool? isWindows,
    bool Function(String path)? fileExists,
  }) {
    final env = environment ?? Platform.environment;
    final windows = isWindows ?? Platform.isWindows;
    bool exists(String path) =>
        fileExists?.call(path) ?? File(path).existsSync();
    final flutterRoot = env['FLUTTER_ROOT']?.trim();
    final executableName = windows ? 'flutter.bat' : 'flutter';
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      final candidate = p.join(
        flutterRoot,
        'bin',
        executableName,
      );
      if (exists(candidate)) return candidate;
    }
    return executableName;
  }

  static Future<TrainCL1BStartedChild> _startFlutterChild(
    TrainCL1BChildPhase phase,
    Map<String, String> environment, {
    TrainCL1BProcessStarter? processStart,
  }) async {
    try {
      final executable = resolveFlutterExecutable(environment);
      final process = await (processStart ?? _startProcess)(
        executable,
        const <String>[
          'run',
          '-d',
          'windows',
          '-t',
          'tool/train_c_l1b_live_runtime.dart',
        ],
        workingDirectory: Directory.current.path,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: false,
      );
      return (
        pid: process.pid,
        stdout: process.stdout,
        stderr: process.stderr,
        exitCode: process.exitCode,
        kill: process.kill,
      );
    } catch (_) {
      throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
    }
  }

  static Future<Process> _startProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    required bool includeParentEnvironment,
    required bool runInShell,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
    );
  }
}

final class _TrainCL1BSupervisorServer {
  _TrainCL1BSupervisorServer._(this._server, this.nonce) {
    _subscription = _server.listen(_handleSocket);
  }

  final ServerSocket _server;
  final String nonce;
  late final StreamSubscription<Socket> _subscription;
  final Map<TrainCL1BChildPhase, Completer<Map<String, Object?>>> _waiters =
      <TrainCL1BChildPhase, Completer<Map<String, Object?>>>{};
  final Map<String, Object?> _facts = <String, Object?>{};
  TrainCL1BChildPhase? _expected;

  int get port => _server.port;

  static Future<_TrainCL1BSupervisorServer> bind() async {
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final random = Random.secure();
    final nonce = base64Url.encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    return _TrainCL1BSupervisorServer._(server, nonce);
  }

  Future<Map<String, Object?>> expect(TrainCL1BChildPhase phase) {
    if (_expected != null || _waiters.containsKey(phase)) {
      throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
    }
    _expected = phase;
    final completer = Completer<Map<String, Object?>>();
    _waiters[phase] = completer;
    return completer.future;
  }

  void acceptReport(
    TrainCL1BChildPhase phase,
    Map<String, Object?> payload,
  ) {
    _facts[phase.wireName] = payload;
    _expected = null;
    _waiters.remove(phase);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
  }

  Future<void> _handleSocket(Socket socket) async {
    try {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      if (line.length > 1024 * 1024) throw const FormatException();
      final decoded = jsonDecode(line);
      if (decoded is! Map || decoded['nonce'] != nonce) {
        throw const FormatException();
      }
      final phaseValue = decoded['phase'];
      if (phaseValue is! String) throw const FormatException();
      final phase = TrainCL1BChildPhaseX.parse(phaseValue);
      final kind = decoded['kind'];
      if (kind == 'request') {
        if (phase != TrainCL1BChildPhase.finalize ||
            _expected != TrainCL1BChildPhase.finalize) {
          throw const FormatException();
        }
        socket.writeln(jsonEncode(<String, Object?>{
          'status': 'PASS',
          'facts': _facts,
        }));
        await socket.flush();
        return;
      }
      if (kind != 'report' || _expected != phase) {
        throw const FormatException();
      }
      final waiter = _waiters[phase];
      if (waiter == null || waiter.isCompleted) throw const FormatException();
      final status = decoded['status'];
      final payload = decoded['payload'];
      if ((status != 'PASS' && status != 'FAIL') || payload is! Map) {
        throw const FormatException();
      }
      final report = <String, Object?>{
        'status': status,
        'payload': Map<String, Object?>.from(payload),
      };
      final failureCode = decoded['failureCode'];
      if (failureCode is String) report['failureCode'] = failureCode;
      waiter.complete(report);
      socket.writeln(jsonEncode(const <String, Object?>{'status': 'PASS'}));
      await socket.flush();
    } catch (_) {
      // Invalid loopback traffic never mutates supervisor state. The expected
      // child will still have to provide its authenticated report or timeout.
    } finally {
      await socket.close();
    }
  }
}
