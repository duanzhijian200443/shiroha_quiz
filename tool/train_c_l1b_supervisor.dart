import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    } catch (_) {
      throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
    } finally {
      await socket?.close();
    }
  }
}

/// Owns one Run #1 in a plain Dart process while every application phase runs
/// in a separate Flutter OS process. The supervisor keeps source-side facts in
/// memory only and never prints child stdout/stderr.
final class TrainCL1BSupervisor {
  const TrainCL1BSupervisor._();

  static Future<int> run({
    required Map<String, String> liveEnvironment,
    required Map<String, String> continuationEnvironment,
    TrainCL1BChildStarter? startChild,
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
        final child = await (startChild ?? _startFlutterChild)(phase, environment);
        final stdoutDrain = child.stdout.drain<void>();
        final stderrDrain = child.stderr.drain<void>();
        final timeout = switch (phase) {
          TrainCL1BChildPhase.parse => const Duration(minutes: 20),
          TrainCL1BChildPhase.commit => const Duration(minutes: 30),
          TrainCL1BChildPhase.restart => const Duration(minutes: 10),
          TrainCL1BChildPhase.finalize => const Duration(minutes: 15),
        };
        try {
          final values = await Future.wait<Object?>(<Future<Object?>>[
            reportFuture,
            child.exitCode,
            stdoutDrain,
            stderrDrain,
          ]).timeout(timeout);
          final report = values[0];
          final exitCode = values[1];
          if (report is! Map<String, Object?> ||
              exitCode is! int ||
              exitCode != 0) {
            throw const TrainCL1BSupervisorException(
              'TRAIN_C_HARNESS_NOT_READY',
            );
          }
          if (report['status'] != 'PASS') {
            final code = report['failureCode'];
            throw TrainCL1BSupervisorException(
              code is String && code.isNotEmpty
                  ? code
                  : 'TRAIN_C_HARNESS_NOT_READY',
            );
          }
          final payload = report['payload'];
          if (payload is! Map) {
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
          throw const TrainCL1BSupervisorException(
            'TRAIN_C_HARNESS_NOT_READY',
          );
        }
      }
      return 0;
    } finally {
      await server.close();
    }
  }

  static Future<TrainCL1BStartedChild> _startFlutterChild(
    TrainCL1BChildPhase phase,
    Map<String, String> environment,
  ) async {
    final process = await Process.start(
      'flutter',
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
    } catch (_) {
      // Invalid loopback traffic never mutates supervisor state. The expected
      // child will still have to provide its authenticated report or timeout.
    } finally {
      await socket.close();
    }
  }
}
