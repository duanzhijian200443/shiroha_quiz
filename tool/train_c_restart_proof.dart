import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/sqflite_runtime.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';

const trainCRestartProcessStartFailure =
    'TRAIN_C_RESTART_PROCESS_START_FAILURE';
const trainCRestartTimeout = 'TRAIN_C_RESTART_TIMEOUT';
const trainCRestartChildFailure = 'TRAIN_C_RESTART_CHILD_FAILURE';
const trainCRestartProtocolFailure = 'TRAIN_C_RESTART_PROTOCOL_FAILURE';
const trainCRestartStateMismatch = 'TRAIN_C_RESTART_STATE_MISMATCH';

final class TrainCRestartException implements Exception {
  const TrainCRestartException(this.code, {this.safeDetail});

  final String code;
  final String? safeDetail;

  @override
  String toString() => safeDetail == null ? code : '$code:$safeDetail';
}

/// Canonical observation of the durable TRAIN C store shared by the child
/// restart probe and the parent acceptance source.
final class TrainCDurableRestartCheckpoint {
  const TrainCDurableRestartCheckpoint({
    required this.questionRows,
    required this.v2Sidecars,
    required this.managedFileCount,
    required this.durableDigest,
  });

  final int questionRows;
  final int v2Sidecars;
  final int managedFileCount;
  final String durableDigest;

  bool equivalentTo(TrainCDurableRestartCheckpoint other) =>
      questionRows == other.questionRows &&
      v2Sidecars == other.v2Sidecars &&
      managedFileCount == other.managedFileCount &&
      durableDigest == other.durableDigest;
}

/// Strongly typed proof emitted only after a different OS process has read the
/// isolated durable store.
final class TrainCOsProcessRestartProof {
  const TrainCOsProcessRestartProof({
    required this.parentPid,
    required this.childPid,
    required this.checkpoint,
    required this.providerDispatchCount,
  });

  factory TrainCOsProcessRestartProof.fromProtocol({
    required Map<String, Object?> protocol,
    required int parentPid,
  }) {
    final childPid = protocol['childPid'];
    final questionRows = protocol['questionRows'];
    final v2Sidecars = protocol['v2Sidecars'];
    final managedFileCount = protocol['managedFileCount'];
    final durableDigest = protocol['durableDigest'];
    final providerDispatchCount = protocol['providerDispatchCount'];
    if (protocol['status'] != 'PASS' ||
        childPid is! int ||
        childPid <= 0 ||
        childPid == parentPid ||
        questionRows is! int ||
        questionRows < 0 ||
        v2Sidecars is! int ||
        v2Sidecars < 0 ||
        managedFileCount is! int ||
        managedFileCount < 0 ||
        durableDigest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(durableDigest) ||
        providerDispatchCount != 0) {
      throw const TrainCRestartException(trainCRestartProtocolFailure);
    }
    return TrainCOsProcessRestartProof(
      parentPid: parentPid,
      childPid: childPid,
      checkpoint: TrainCDurableRestartCheckpoint(
        questionRows: questionRows,
        v2Sidecars: v2Sidecars,
        managedFileCount: managedFileCount,
        durableDigest: durableDigest,
      ),
      providerDispatchCount: providerDispatchCount as int,
    );
  }

  final int parentPid;
  final int childPid;
  final TrainCDurableRestartCheckpoint checkpoint;
  final int providerDispatchCount;

  bool matches(TrainCDurableRestartCheckpoint expected) =>
      childPid > 0 &&
      childPid != parentPid &&
      providerDispatchCount == 0 &&
      checkpoint.equivalentTo(expected);
}

typedef TrainCRestartStartedProcess = ({
  Stream<List<int>> stdout,
  Stream<List<int>> stderr,
  Future<int> exitCode,
  bool Function() kill,
});

/// Executes and validates the restart protocol with fixed, privacy-safe
/// failure categories. Stderr is drained but never retained or surfaced.
Future<TrainCOsProcessRestartProof> runTrainCRestartProcess({
  required Future<TrainCRestartStartedProcess> Function() start,
  required Duration timeout,
  required int parentPid,
  required TrainCDurableRestartCheckpoint expectedCheckpoint,
}) async {
  final stopwatch = Stopwatch()..start();
  late final TrainCRestartStartedProcess process;
  try {
    process = await start().timeout(timeout);
  } on TimeoutException {
    throw const TrainCRestartException(trainCRestartTimeout);
  } catch (_) {
    throw const TrainCRestartException(trainCRestartProcessStartFailure);
  }

  try {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      process.kill();
      throw const TrainCRestartException(trainCRestartTimeout);
    }
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.drain<void>();
    final values = await Future.wait<Object?>(<Future<Object?>>[
      process.exitCode,
      stdoutFuture,
      stderrFuture,
    ]).timeout(remaining);
    final exitCode = values[0];
    final stdout = values[1];
    if (exitCode is! int || exitCode != 0) {
      throw TrainCRestartException(
        trainCRestartChildFailure,
        safeDetail: switch (exitCode) {
          11 => 'TRAIN_C_RESTART_CHILD_REATTACH_FAILURE',
          12 => 'TRAIN_C_RESTART_CHILD_CHECKPOINT_FAILURE',
          13 => 'TRAIN_C_RESTART_CHILD_CLOSE_FAILURE',
          21 => 'TRAIN_C_REATTACH_CAPABILITY_INVALID',
          22 => 'TRAIN_C_REATTACH_ROOT_INVALID',
          23 => 'TRAIN_C_REATTACH_NONCE_INVALID',
          24 => 'TRAIN_C_REATTACH_DATABASE_FAILURE',
          25 => 'TRAIN_C_REATTACH_DATABASE_INIT_FAILURE',
          26 => 'TRAIN_C_REATTACH_DATABASE_PATH_FAILURE',
          27 => 'TRAIN_C_REATTACH_DATABASE_PROFILE_FAILURE',
          28 => 'TRAIN_C_REATTACH_DATABASE_OPEN_FAILURE',
          29 => 'TRAIN_C_REATTACH_DATABASE_IDENTITY_FAILURE',
          _ => 'TRAIN_C_RESTART_CHILD_UNKNOWN_FAILURE',
        },
      );
    }
    if (stdout is! String || stdout.length > 8192) {
      throw const TrainCRestartException(trainCRestartProtocolFailure);
    }
    final lines = stdout
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    if (lines.length != 1) {
      throw const TrainCRestartException(trainCRestartProtocolFailure);
    }
    final decoded = jsonDecode(lines.single);
    if (decoded is! Map) {
      throw const TrainCRestartException(trainCRestartProtocolFailure);
    }
    final proof = TrainCOsProcessRestartProof.fromProtocol(
      protocol: Map<String, Object?>.from(decoded),
      parentPid: parentPid,
    );
    if (!proof.matches(expectedCheckpoint)) {
      throw const TrainCRestartException(trainCRestartStateMismatch);
    }
    return proof;
  } on TimeoutException {
    process.kill();
    throw const TrainCRestartException(trainCRestartTimeout);
  } on TrainCRestartException {
    rethrow;
  } catch (_) {
    throw const TrainCRestartException(trainCRestartProtocolFailure);
  } finally {
    stopwatch.stop();
  }
}

Future<TrainCDurableRestartCheckpoint> captureTrainCDurableRestartCheckpoint({
  required Database database,
  required Directory managedDirectory,
}) async {
  try {
    final questionRows = await database.query(
      'questions',
      columns: <String>['id'],
      orderBy: 'id',
    );
    final sidecars = await database.query(
      'question_v2_payloads',
      columns: <String>[
        'question_id',
        'payload_schema_version',
        'payload_json',
      ],
      orderBy: 'question_id',
    );
    final logicalRows = <String>[
      for (final row in questionRows)
        jsonEncode(<String, Object?>{'id': row['id']}),
      for (final row in sidecars)
        jsonEncode(<String, Object?>{
          'questionId': row['question_id'],
          'schemaVersion': row['payload_schema_version'],
          'payload': row['payload_json'],
        }),
    ];
    final managedFiles = <String>[];
    if (await managedDirectory.exists()) {
      final files = await managedDirectory
          .list(recursive: true, followLinks: false)
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      files.sort((left, right) {
        final leftRelative = p.relative(left.path, from: managedDirectory.path);
        final rightRelative = p.relative(
          right.path,
          from: managedDirectory.path,
        );
        return leftRelative.compareTo(rightRelative);
      });
      for (final file in files) {
        final relative = p
            .relative(file.path, from: managedDirectory.path)
            .replaceAll('\\', '/');
        final bytes = await file.readAsBytes();
        managedFiles.add(
          '$relative\u0000${bytes.length}\u0000${sha256Hex(bytes)}',
        );
      }
    }
    return TrainCDurableRestartCheckpoint(
      questionRows: questionRows.length,
      v2Sidecars: sidecars.length,
      managedFileCount: managedFiles.length,
      durableDigest: sha256Hex(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'logicalRows': logicalRows,
            'managedFiles': managedFiles,
          }),
        ),
      ),
    );
  } on TrainCRestartException {
    rethrow;
  } catch (_) {
    throw const TrainCRestartException(trainCRestartStateMismatch);
  }
}

Map<String, Object?> trainCRestartProtocolMap({
  required int childPid,
  required TrainCDurableRestartCheckpoint checkpoint,
}) {
  return <String, Object?>{
    'status': 'PASS',
    'childPid': childPid,
    'questionRows': checkpoint.questionRows,
    'v2Sidecars': checkpoint.v2Sidecars,
    'managedFileCount': checkpoint.managedFileCount,
    'durableDigest': checkpoint.durableDigest,
    'providerDispatchCount': 0,
  };
}
