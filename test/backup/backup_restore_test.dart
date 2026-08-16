import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/backup/backup_contracts.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/restore_journal.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_filesystem.dart';
import 'package:shiroha_quiz/services/backup/backup_journal_store.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

final class _InfiniteDisk implements BackupDiskSpaceProbe {
  const _InfiniteDisk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _CommitFreeSpaceFailure implements BackupDiskSpaceProbe {
  int calls = 0;

  @override
  Future<int?> availableBytes(String path) async {
    calls++;
    return calls == 1 ? 1 << 40 : 0;
  }
}

final class _Faults extends BackupFaultInjector {
  _Faults({
    this.onPrepared,
    this.onDbReplaced,
    this.onFilesReplaced,
    this.onBeforeRollbackDb,
    this.onBeforeRollbackFiles,
    this.onBeforeRollbackSnapshot,
    this.onBeforeRollbackManagedFileCopy,
    this.onBeforePreparedJournalWrite,
    this.onPermanentRollbackFailure,
    this.onBeforeCleanup,
    this.onBeforePostSwapValidation,
  });

  Future<void> Function()? onPrepared;
  Future<void> Function()? onDbReplaced;
  Future<void> Function()? onFilesReplaced;
  Future<void> Function()? onBeforeRollbackDb;
  Future<void> Function()? onBeforeRollbackFiles;
  Future<void> Function()? onBeforeRollbackSnapshot;
  Future<void> Function()? onBeforeRollbackManagedFileCopy;
  Future<void> Function()? onBeforePreparedJournalWrite;
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
  Future<void> beforeRollbackSnapshot() =>
      onBeforeRollbackSnapshot?.call() ?? Future.value();
  @override
  Future<void> beforeRollbackManagedFileCopy() =>
      onBeforeRollbackManagedFileCopy?.call() ?? Future.value();
  @override
  Future<void> beforePreparedJournalWrite() =>
      onBeforePreparedJournalWrite?.call() ?? Future.value();
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

  BackupRestoreRuntime runtime({
    BackupFaultInjector faults = const BackupFaultInjector(),
    BackupDiskSpaceProbe diskSpaceProbe = const _InfiniteDisk(),
  }) {
    return BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: storage,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: diskSpaceProbe,
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

  test('pre-PREPARED free-space failure keeps live state and avoids rollback',
      () async {
    final package = await exportPackage();
    final disk = _CommitFreeSpaceFailure();
    final restoring = runtime(diskSpaceProbe: disk);
    await restoring.prepareRestore(package);

    await expectLater(
      restoring.commitPreparedRestore(),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.resourceLimitExceeded,
      )),
    );
    expect(disk.calls, 2);
    expect(restoring.preparedRestore, isNotNull);
    await expectLiveRestored();
    expect(
      File(p.join(restoreRoot.path, 'journal', 'journal.json')).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(restoreRoot.path, 'rollback')).existsSync()
          ? Directory(p.join(restoreRoot.path, 'rollback')).listSync()
          : const <FileSystemEntity>[],
      isEmpty,
    );
    await restoring.cancelPreparedRestore();
  });

  test('pre-PREPARED snapshot failure is not reported as rollbackFailed',
      () async {
    final package = await exportPackage();
    final restoring = runtime(
      faults: _Faults(
        onBeforeRollbackSnapshot: () async =>
            throw const BackupException(BackupFailure.databaseInvalid),
      ),
    );
    await restoring.prepareRestore(package);

    await expectLater(
      restoring.commitPreparedRestore(),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.databaseInvalid,
      )),
    );
    expect(restoring.preparedRestore, isNotNull);
    await expectLiveRestored();
    expect(
      File(p.join(restoreRoot.path, 'journal', 'journal.json')).existsSync(),
      isFalse,
    );
    await restoring.cancelPreparedRestore();
  });

  test('pre-PREPARED managed-file snapshot failure cleans partial rollback',
      () async {
    final package = await exportPackage();
    final restoring = runtime(
      faults: _Faults(
        onBeforeRollbackManagedFileCopy: () async =>
            throw const BackupException(BackupFailure.integrityMismatch),
      ),
    );
    await restoring.prepareRestore(package);

    await expectLater(
      restoring.commitPreparedRestore(),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.integrityMismatch,
      )),
    );
    expect(restoring.preparedRestore, isNotNull);
    await expectLiveRestored();
    expect(
      File(p.join(restoreRoot.path, 'journal', 'journal.json')).existsSync(),
      isFalse,
    );
    await restoring.cancelPreparedRestore();
  });

  test('PRE-JOURNAL failure does not enter rollbackFailed', () async {
    final package = await exportPackage();
    final restoring = runtime(
      faults: _Faults(
        onBeforePreparedJournalWrite: () async =>
            throw const BackupException(BackupFailure.databaseInvalid),
      ),
    );
    await restoring.prepareRestore(package);

    await expectLater(
      restoring.commitPreparedRestore(),
      throwsA(isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.databaseInvalid,
      )),
    );
    expect(restoring.preparedRestore, isNotNull);
    await expectLiveRestored();
    expect(
      File(p.join(restoreRoot.path, 'journal', 'journal.json')).existsSync(),
      isFalse,
    );
    await restoring.cancelPreparedRestore();
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

  test('composition reload runs before COMMITTED and failure rolls back',
      () async {
    final package = await exportPackage();
    final store = BackupJournalStore(keyRoot: restoreRoot);
    final restoring = runtime();
    await restoring.prepareRestore(package);

    RestoreJournalState? stateDuringReload;
    Future<void> beforeCommitted() async {
      final journal = await store.read();
      stateDuringReload = journal?.state;
    }

    await restoring.commitPreparedRestore(beforeCommitted: beforeCommitted);
    expect(stateDuringReload, RestoreJournalState.swapping);

    // A failed authoritative reload must roll back, not COMMIT.
    await mutateLive();
    final failingReload = runtime();
    await failingReload.prepareRestore(package);
    await expectLater(
      failingReload.commitPreparedRestore(
        beforeCommitted: () async => throw StateError('reload failed'),
      ),
      throwsA(isA<StateError>()),
    );
    await expectLiveMutated();
  });

  test('post-swap managed-file corruption is detected before COMMITTED',
      () async {
    final package = await exportPackage();
    final corrupting = runtime(
      faults: _Faults(
        onFilesReplaced: () async {
          await storage
              .resolveManagedFile('library/file-1')
              .writeAsBytes('corrupt'.codeUnits, flush: true);
        },
      ),
    );
    await corrupting.prepareRestore(package);
    await expectLater(
      corrupting.commitPreparedRestore(),
      throwsA(isA<BackupException>()),
    );
    await expectLiveRestored();
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

  test('journal keys resolve against restore root, not journal directory',
      () async {
    final store = BackupJournalStore(keyRoot: restoreRoot);
    final journal = RestoreJournal(
      version: 1,
      operationId: 'op-1',
      format: 'shiroha-backup',
      packageVersion: 1,
      schemaVersion: 22,
      packageDigest: 'a' * 64,
      state: RestoreJournalState.prepared,
      updatedAtUtc: DateTime.utc(2026),
      stagingKey: 'staging/op-1',
      rollbackDbKey: 'rollback/op-1/db',
      rollbackFilesKey: 'rollback/op-1/files',
    );
    await store.write(journal);

    expect(
      store.resolveKey('staging/op-1'),
      p.join(restoreRoot.path, 'staging', 'op-1'),
    );

    // Simulate the crash window where the previous journal was renamed to
    // .bak before the replacement became visible.
    await File(store.journalPath).rename('${store.journalPath}.bak');
    final recovered = await store.read();
    expect(recovered?.state, RestoreJournalState.prepared);

    await store.clear();
    expect(File(store.journalPath).existsSync(), isFalse);
    expect(File('${store.journalPath}.bak').existsSync(), isFalse);
  });

  test('clear marker is consumed once and future swapping journal recovers',
      () async {
    final store = BackupJournalStore(keyRoot: restoreRoot);
    final stale = RestoreJournal(
      version: 1,
      operationId: 'op-stale',
      format: 'shiroha-backup',
      packageVersion: 1,
      schemaVersion: 22,
      packageDigest: 'a' * 64,
      state: RestoreJournalState.swapping,
      updatedAtUtc: DateTime.utc(2026),
      stagingKey: 'staging/op-stale',
      rollbackDbKey: 'rollback/op-stale/db',
      rollbackFilesKey: 'rollback/op-stale/files',
    );
    await store.write(stale);
    await File(store.journalPath).rename('${store.journalPath}.bak');

    // Generation A: simulate the crash window after the clear marker became
    // durable while the stale .bak generation remained.
    final staleDigest = BackupFilesystem.sha256File(
      '${store.journalPath}.bak',
    );
    await BackupFilesystem.atomicWriteString(
      '${store.journalPath}.tombstone',
      jsonEncode(<String, Object?>{
        'version': 1,
        'journalSha256': null,
        'backupSha256': staleDigest,
      }),
    );
    expect(await store.read(), isNull);
    expect(File(store.journalPath).existsSync(), isFalse);
    expect(File('${store.journalPath}.bak').existsSync(), isFalse);
    expect(File('${store.journalPath}.tombstone').existsSync(), isFalse);

    // Generation B: a later restore must not be hidden by the consumed
    // marker. Use the real runtime crash seam so startup must recover the new
    // SWAPPING journal rather than merely returning it from read().
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

  test('startup recovery diagnostic id is the active valid OBS correlation',
      () async {
    late String correlationId;
    final recovery = await TraceContext.runRoot<BackupStartupRecovery>(
      operationKind: TraceOperationKind.backupRestore,
      action: () {
        correlationId = TraceContext.correlationId!;
        return runtime().recoverStartupIfNeeded();
      },
    );
    expect(recovery.diagnosticId, correlationId);
    expect(
      TraceContext.isValidCorrelationId(recovery.diagnosticId),
      isTrue,
    );
    expect(recovery.diagnosticId, isNot('OBS-B0P0-SAFE'));
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
