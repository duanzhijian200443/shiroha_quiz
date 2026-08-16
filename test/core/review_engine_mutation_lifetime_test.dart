import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/memory_engine_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temp;
  final reviewEngine = ReviewEngineService();

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await reviewEngine.flushPending();
    reviewEngine.resetTransientStateForRestore();
    temp = await Directory.systemTemp.createTemp('review_gate_');
    final dbRoot = Directory(p.join(temp.path, 'db'))
      ..createSync(recursive: true);
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitFile,
      databasePath: dbRoot.path,
    );
    final db = await DatabaseHelper.instance.database;
    await db.insert('questions', <String, Object?>{
      'id': 'review-q',
      'type': 0,
      'content': 'review question',
      'options': '[]',
      'standard_answer': 'A',
      'explanation': null,
      'raw_explanation': null,
      'created_at': 1,
      'bank_name': 'default',
    });
  });

  tearDown(() async {
    await reviewEngine.flushPending();
    reviewEngine.resetTransientStateForRestore();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    BackupRestoreMutationGate.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('deferred review write holds the lease until durable flush terminal',
      () async {
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: MemoryEngineCredentialStore(),
    );

    await reviewEngine.submitReviewResult(
      'review-q',
      3,
      100,
      engineRepository: repository,
    );
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 1);

    final drained = BackupRestoreMutationGate.instance.enterQuiescence();
    var drainCompleted = false;
    unawaited(drained.then((_) => drainCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(drainCompleted, isFalse);

    await reviewEngine.flushPending();
    await drained;
    expect(drainCompleted, isTrue);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);

    final states = await DatabaseHelper.instance.database.then(
      (db) => db.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>['review-q'],
      ),
    );
    expect(states, hasLength(1));
    BackupRestoreMutationGate.instance.exitQuiescence();
  });
}
