import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/backup/sha256.dart';

import 'train_c_isolated_runtime.dart';

const _capabilityEnvironmentKey = 'TRAIN_C_REATTACH_CAPABILITY';

Future<Map<String, Object?>> captureTrainCRestartDurableCheckpoint(
  TrainCIsolatedRuntime runtime,
) async {
  final db = await runtime.database;
  final questionRows = await db.query(
    'questions',
    columns: <String>['id'],
    orderBy: 'id',
  );
  final sidecars = await db.query(
    'question_v2_payloads',
    columns: <String>[
      'question_id',
      'payload_schema_version',
      'payload_json',
    ],
    orderBy: 'question_id',
  );

  final logicalRows = <String>[
    for (final row in questionRows) jsonEncode(<String, Object?>{'id': row['id']}),
    for (final row in sidecars)
      jsonEncode(<String, Object?>{
        'questionId': row['question_id'],
        'schemaVersion': row['payload_schema_version'],
        'payload': row['payload_json'],
      }),
  ];

  final managedFiles = <String>[];
  if (await runtime.managedDirectory.exists()) {
    final files = await runtime.managedDirectory
        .list(recursive: true, followLinks: false)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    files.sort((left, right) => left.path.compareTo(right.path));
    for (final file in files) {
      final relative = p
          .relative(file.path, from: runtime.managedDirectory.path)
          .replaceAll('\\', '/');
      final bytes = await file.readAsBytes();
      managedFiles.add(
        '$relative\u0000${bytes.length}\u0000${sha256Hex(bytes)}',
      );
    }
  }

  final durableDigest = sha256Hex(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'logicalRows': logicalRows,
        'managedFiles': managedFiles,
      }),
    ),
  );

  return <String, Object?>{
    'status': 'PASS',
    'childPid': pid,
    'questionRows': questionRows.length,
    'v2Sidecars': sidecars.length,
    'managedFileCount': managedFiles.length,
    'durableDigest': durableDigest,
    'providerDispatchCount': 0,
  };
}

Future<void> main(List<String> args) async {
  if (args.length != 1 || args.single != '--child') {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 2;
    return;
  }
  final capability = Platform.environment[_capabilityEnvironmentKey];
  if (capability == null || capability.trim().isEmpty) {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 2;
    return;
  }

  TrainCIsolatedRuntime? runtime;
  try {
    runtime = await TrainCIsolatedRuntime.reattachFromCapability(
      capability,
      deleteRootOnDispose: false,
    );
    final checkpoint = await captureTrainCRestartDurableCheckpoint(runtime);
    stdout.writeln(jsonEncode(checkpoint));
    await runtime.closeForRestart();
  } catch (_) {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 1;
  }
}
