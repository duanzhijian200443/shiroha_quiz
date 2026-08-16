import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/restore_journal.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_filesystem.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

final class _InfiniteDisk implements BackupDiskSpaceProbe {
  const _InfiniteDisk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _Faults extends BackupFaultInjector {
  _Faults({
    this.onPrepared,
    this.onDbReplaced,
    this.onFilesReplaced,
    this.onBeforeRollbackDb,
    this.onBeforeRollbackFiles,
    this.onPermanentRollbackFailure,
    this.onBeforeCleanup,
    this.onBeforePostSwapValidation,
  });

  Future<void> Function()? onPrepared;
  Future<void> Function()? onDbReplaced;
  Future<void> Function()? onFilesReplaced;
  Future<void> Function()? onBeforeRollbackDb;
  Future<void> Function()? onBeforeRollbackFiles;
  Future<void> Function()? onPermanentRollbackFailure;
  Future<void> Function()? onBeforeCleanup;
  Future<void> Function()? onBeforePostSwapValidation;

  @override
  Future<void> afterJournalPrepared() => onPrepared?.call() ?? Future.value();
  @override
  Future<void> afterLiveDbReplaced() => onDbReplaced?.call() ?? Future.value();
  @override
  Future<void> afterLiveFilesReplaced() =>
      onFilesReplaced?.call() ?? Future.value();
  @override
  Future<void> beforeRollbackDbRestore() =>
      onBeforeRollbackDb?.call() ?? Future.value();
  @override
  Future<void> beforeRollbackFilesRestore() =>
      onBeforeRollbackFiles?.call() ?? Future.value();
  @override
  Future<void> failRollbackPermanently() =>
      onPermanentRollbackFailure?.call() ?? Future.value();
  @override
  Future<void> beforeCommittedCleanup() =>
      onBeforeCleanup?.call() ?? Future.value();
  @override
  Future<void> beforePostSwapValidation() =>
      onBeforePostSwapValidation?.call() ?? Future.value();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temp;
  late Directory dbDir;
  late Directory managedRoot;
  late Directory restoreRoot;
  late ManagedFileStorageAdapter storage;
  late DatabaseHelper helper;
  late BackupSnapshotRepository snapshots;
  late String sourceHash;

  BackupRestoreRuntime runtime(
      {BackupFaultInjector faults = const BackupFaultInjector()}) {
    return BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: storage,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: const _InfiniteDisk(),
      faultInjector: faults,
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('b0_restore_');
    dbDir = Directory(p.join(temp.path, 'db'))..createSync(recursive: true);
    managedRoot = Directory(p.join(temp.path, 'managed'))
      ..createSync(recursive: true);
    restoreRoot = Directory(p.join(temp.path, 'restore'))
      ..createSync(recursive: true);
    await databaseFactory.setDatabasesPath(dbDir.path);
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitFile,
      databasePath: dbDir.path,
    );
    storage = ManagedFileStorageAdapter(managedRoot: managedRoot);
    helper = DatabaseHelper.instance;
    snapshots = BackupSnapshotRepository(databaseHelper: helper);
    final source = File(p.join(temp.path, 'source.txt'));
    final bytes = 'original-bytes'.codeUnits;
    await source.writeAsBytes(bytes, flush: true);
    await storage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: 'library/file-1',
    );
    sourceHash = BackupFilesystem.sha256File(
      storage.resolveManagedFile('library/file-1').path,
    );

    final db = await helper.database;
    await db.insert('questions', <String, Object?>{
      'id': 'q-1',
      'type': 0,
      'content': 'question sentinel',
      'options': '[]',
      'standard_answer': 'answer',
      'explanation': null,
      'raw_explanation': null,
      'created_at': 1,
      'bank_name': '默认题库',
    });
    await db.insert('review_states', <String, Object?>{
      'id': 1,
      'question_id': 'q-1',
      'state': 2,
      'next_review_time': 99,
      'lapses': 1,
      'difficulty': 5.0,
      'stability': 1.0,
      'reps': 3,
      'last_lapse_time': 1,
      'last_review_time': 1,
    });
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-1',
      'display_name': 'secret-filename.txt',
      'mime_type': 'text/plain',
      'size_bytes': bytes.length,
      'sha256': sourceHash,
      'storage_key': 'library/file-1',
      'created_at': 1,
    });
    await db.insert('ai_engines', <String, Object?>{
      'id': 'engine-1',
      'engine_type': 'text',
      'name': 'engine',
      'api_key': 'SECRET_API_KEY_SENTINEL',
      'base_url': 'https://example.invalid',
      'model_name': 'm',
      'temperature': 0.7,
      'reasoning_effort': '',
      'is_active': 0,
    });
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<String> exportPackage() async {
    final package = p.join(temp.path, 'package.shiroha');
    await runtime().exportTo(package);
    return package;
  }

  Future<void> mutateLive() async {
    final db = await helper.database;
    await db.delete('questions', where: 'id = ?', whereArgs: <Object?>['q-1']);
    await storage
        .resolveManagedFile('library/file-1')
        .writeAsBytes('mutated'.codeUnits, flush: true);
  }

  Future<void> expectLiveMutated() async {
    final db = await helper.database;
    expect((await db.query('questions')), isEmpty);
    expect(
      storage.resolveManagedFile('library/file-1').readAsBytesSync(),
      'mutated'.codeUnits,
    );
  }

  Future<void> expectLiveRestored() async {
    final db = await helper.database;
    expect((await db.query('questions')).single['id'], 'q-1');
    expect(
      storage.resolveManagedFile('library/file-1').readAsBytesSync(),
      'original-bytes'.codeUnits,
    );
  }

  test(
      'whole restore replaces DB and managed files, second restore is identical',
      () async {
    final package = await exportPackage();
    await mutateLive();
    final first = runtime();
    final preview = await first.prepareRestore(package);
    expect(preview.fileCount, 1);
    final result = await first.commitPreparedRestore();
    expect(result.fileCount, 1);
    await expectLiveRestored();

    await mutateLive();
    final second = runtime();
    await second.prepareRestore(package);
    await second.commitPreparedRestore();
    await expectLiveRestored();
  });

  test(
      'PREPARED crash recovery performs zero live writes and clears transient state',
      () async {
    final package = await exportPackage();
    final beforeDb = File(
      p.join(dbDir.path, DatabaseHelper.databaseFileName),
    ).readAsBytesSync();
    final beforeFile =
        storage.resolveManagedFile('library/file-1').readAsBytesSync();

    final crashing = runtime(
      faults: _Faults(
        onPrepared: () async => throw const BackupCrashSimulation(),
      ),
    );
    await crashing.prepareRestore(package);
    await expectLater(
      crashing.commitPreparedRestore(),
      throwsA(isA<BackupCrashSimulation>()),
    );

    final recovery = await runtime().recoverStartupIfNeeded();
    expect(recovery.blocked, isFalse);
    expect(recovery.recoveredJournalState, RestoreJournalState.prepared);
    expect(
      File(p.join(dbDir.path, DatabaseHelper.databaseFileName))
          .readAsBytesSync(),
      beforeDb,
    );
    expect(
      storage.resolveManagedFile('library/file-1').readAsBytesSync(),
      beforeFile,
    );
    final journalFile =
        File(p.join(restoreRoot.path, 'journal', 'journal.json'));
    expect(journalFile.existsSync(), isFalse);
  });

  test(
      'SWAPPING crash after DB replacement restores complete old state on startup',
      () async {
    final package = await exportPackage();
    await mutateLive();
    final crashing = runtime(
      faults: _Faults(
        onDbReplaced: () async => throw const BackupCrashSimulation(),
      ),
    );
    await crashing.prepareRestore(package);
    await expectLater(
      crashing.commitPreparedRestore(),
      throwsA(isA<BackupCrashSimulation>()),
    );

    final recovery = await runtime().recoverStartupIfNeeded();
    expect(recovery.blocked, isFalse);
    expect(recovery.recoveredJournalState, RestoreJournalState.rolledBack);
    await expectLiveMutated();
  });

  test('rollback failure becomes ROLLBACK_FAILED and blocks startup', () async {
    final package = await exportPackage();
    final failing = runtime(
      faults: _Faults(
        onFilesReplaced: () async =>
            throw const BackupException(BackupFailure.integrityMismatch),
        onPermanentRollbackFailure: () async => throw StateError('permanent'),
      ),
    );
    await failing.prepareRestore(package);
    await expectLater(
      failing.commitPreparedRestore(),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.rollbackFailed,
      )),
    );

    final recovery = await runtime().recoverStartupIfNeeded();
    expect(recovery.blocked, isTrue);
    expect(recovery.failure, BackupFailure.rollbackFailed);
    expect(
      File(p.join(restoreRoot.path, 'journal', 'journal.json')).existsSync(),
      isTrue,
    );
  });

  test('COMMITTED cleanup failure keeps journal and next startup cleans it',
      () async {
    final package = await exportPackage();
    final committing = runtime(
      faults: _Faults(
        onBeforeCleanup: () async => throw StateError('cleanup failed'),
      ),
    );
    await committing.prepareRestore(package);
    final result = await committing.commitPreparedRestore();
    expect(result.fileCount, 1);
    expect(
      File(p.join(restoreRoot.path, 'journal', 'journal.json')).existsSync(),
      isTrue,
    );

    final recovery = await runtime().recoverStartupIfNeeded();
    expect(recovery.blocked, isFalse);
    expect(recovery.recoveredJournalState, RestoreJournalState.committed);
    expect(
      File(p.join(restoreRoot.path, 'journal', 'journal.json')).existsSync(),
      isFalse,
    );
  });

  test('DB replacement failure rolls back original durable state', () async {
    final package = await exportPackage();
    await mutateLive();
    final failing = runtime(
      faults: _Faults(
        onDbReplaced: () async =>
            throw const BackupException(BackupFailure.databaseInvalid),
      ),
    );
    await failing.prepareRestore(package);
    await expectLater(
      failing.commitPreparedRestore(),
      throwsA(isA<BackupException>()),
    );
    await expectLiveMutated();
  });

  test('post-swap validation failure rolls back original durable state',
      () async {
    final package = await exportPackage();
    await mutateLive();
    final failing = runtime(
      faults: _Faults(
        onBeforePostSwapValidation: () async =>
            throw const BackupException(BackupFailure.integrityMismatch),
      ),
    );
    await failing.prepareRestore(package);
    await expectLater(
      failing.commitPreparedRestore(),
      throwsA(isA<BackupException>()),
    );
    await expectLiveMutated();
  });

  test('double crash during rollback resumes and ends ROLLED_BACK', () async {
    final package = await exportPackage();
    final firstCrash = runtime(
      faults: _Faults(
        onFilesReplaced: () async =>
            throw const BackupException(BackupFailure.integrityMismatch),
        onBeforeRollbackDb: () async => throw const BackupCrashSimulation(),
      ),
    );
    await firstCrash.prepareRestore(package);
    await expectLater(
      firstCrash.commitPreparedRestore(),
      throwsA(isA<BackupCrashSimulation>()),
    );

    final secondCrash = runtime(
      faults: _Faults(
        onBeforeRollbackFiles: () async => throw const BackupCrashSimulation(),
      ),
    );
    await expectLater(
      secondCrash.recoverStartupIfNeeded(),
      throwsA(isA<BackupCrashSimulation>()),
    );

    final recovery = await runtime().recoverStartupIfNeeded();
    expect(recovery.blocked, isFalse);
    expect(recovery.recoveredJournalState, RestoreJournalState.rolledBack);
  });

  test('pre-commit cancel deletes staging and leaves live state unchanged',
      () async {
    final package = await exportPackage();
    final restoring = runtime();
    await restoring.prepareRestore(package);
    await restoring.cancelPreparedRestore();
    final db = await helper.database;
    expect((await db.query('questions')).single['id'], 'q-1');
    expect(
      storage.resolveManagedFile('library/file-1').readAsBytesSync(),
      'original-bytes'.codeUnits,
    );
    final staging = Directory(p.join(restoreRoot.path, 'staging'));
    expect(staging.existsSync() ? staging.listSync() : const [], isEmpty);
  });
}
