import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/answer_completion_v28_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_filesystem.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

final class _InfiniteDisk implements BackupDiskSpaceProbe {
  const _InfiniteDisk();

  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

Matcher get _databaseInvalid => throwsA(isA<BackupException>().having(
      (error) => error.failure,
      'failure',
      BackupFailure.databaseInvalid,
    ));

Future<void> _insertQuestion(Database db, String id, String bankName) {
  return db.insert('questions', <String, Object?>{
    'id': id,
    'type': 0,
    'content': 'synthetic question',
    'standard_answer': 'A',
    'created_at': 10,
    'bank_name': bankName,
  });
}

Future<void> _insertSet(Database db, {String? sourceFileId}) {
  return db.insert(importedQuestionSetsTable, <String, Object?>{
    'set_id': 'set-1',
    'bank_name': 'Math',
    'display_name': 'Synthetic source',
    'created_at': 42,
    'source_file_id': sourceFileId,
  });
}

Future<void> _insertMember(Database db, String questionId, int position) {
  return db.insert(importedQuestionSetItemsTable, <String, Object?>{
    'set_id': 'set-1',
    'question_storage_id': questionId,
    'position': position,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory managedRoot;
  late Directory restoreRoot;
  late DatabaseHelper helper;
  late BackupSnapshotRepository snapshots;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('answer_comp_b0_');
    final dbRoot = Directory(p.join(temp.path, 'db'))
      ..createSync(recursive: true);
    managedRoot = Directory(p.join(temp.path, 'managed'))
      ..createSync(recursive: true);
    restoreRoot = Directory(p.join(temp.path, 'restore'))
      ..createSync(recursive: true);
    await databaseFactory.setDatabasesPath(dbRoot.path);
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitFile,
      databasePath: dbRoot.path,
    );
    helper = DatabaseHelper.instance;
    snapshots = BackupSnapshotRepository(databaseHelper: helper);
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  BackupRestoreRuntime runtime() => BackupRestoreRuntime(
        databaseAuthority: SqliteBackupDatabaseAuthority(
          databaseHelper: helper,
          snapshotRepository: snapshots,
        ),
        snapshotRepository: snapshots,
        managedFileStorage: ManagedFileStorageAdapter(managedRoot: managedRoot),
        restoreRoot: restoreRoot,
        managedFilesRoot: managedRoot,
        diskSpaceProbe: const _InfiniteDisk(),
      );

  Future<String> packageDatabase(String databasePath, String name) async {
    final manifest = BackupManifest(
      schemaVersion: BackupValues.currentSchemaVersion,
      createdAtUtc: DateTime.utc(2026),
      database: BackupDatabaseEntry(
        archivePath: BackupValues.databaseArchivePath,
        sizeBytes: File(databasePath).lengthSync(),
        sha256: BackupFilesystem.sha256File(databasePath),
      ),
      managedFiles: const <BackupManagedFileEntry>[],
    );
    final manifestPath = p.join(temp.path, '$name.json');
    await File(manifestPath).writeAsString(manifest.encode(), flush: true);
    final packagePath = p.join(temp.path, '$name.shiroha');
    await BackupArchiveIo.writeStoredPackage(
      packagePath: packagePath,
      manifestPath: manifestPath,
      databasePath: databasePath,
      files: const <ArchiveSourceFile>[],
    );
    return packagePath;
  }

  for (final sourceFileId in <String?>[null, 'deleted-file-id']) {
    test('v28 export and restore preserves ordered set with $sourceFileId',
        () async {
      final db = await helper.database;
      await _insertQuestion(db, 'q-0', 'Math');
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertSet(db, sourceFileId: sourceFileId);
      await _insertMember(db, 'q-0', 0);
      await _insertMember(db, 'q-1', 1);
      final setBefore = (await db.query(importedQuestionSetsTable)).single;
      final itemsBefore = await db.query(
        importedQuestionSetItemsTable,
        orderBy: 'position',
      );
      expect(await db.query('library_files'), isEmpty);

      final package = p.join(temp.path, 'round-trip.shiroha');
      await runtime().exportTo(package);
      await db.delete('questions');
      expect(await db.query(importedQuestionSetsTable), isEmpty);

      final restoring = runtime();
      await restoring.prepareRestore(package);
      await restoring.commitPreparedRestore();

      final restored = await helper.database;
      expect(
          (await restored.query(importedQuestionSetsTable)).single, setBefore);
      expect(
        await restored.query(importedQuestionSetItemsTable,
            orderBy: 'position'),
        itemsBefore,
      );
      expect(
        (await restored.query('questions', orderBy: 'id'))
            .map((row) => row['id']),
        <String>['q-0', 'q-1'],
      );
      expect(await restored.query('library_files'), isEmpty);
    });
  }

  test('durable empty set fails export and staged restore', () async {
    final db = await helper.database;
    await _insertSet(db);
    await expectLater(
      snapshots.createSanitizedSnapshot(p.join(temp.path, 'empty-export.db')),
      _databaseInvalid,
    );
    final rawPath = p.join(temp.path, 'empty-staged.db');
    await snapshots.createRawConsistentSnapshot(rawPath);
    final package = await packageDatabase(rawPath, 'empty');
    await expectLater(runtime().prepareRestore(package), _databaseInvalid);
  });

  test('same-schema cross-bank relation fails staged restore', () async {
    final path = p.join(temp.path, 'cross-bank.db');
    final db = await helper.openPathForTesting(path);
    await _insertQuestion(db, 'q-other', 'Other');
    await _insertSet(db);
    await db.execute('DROP TRIGGER $answerCompletionMemberInsertBankTrigger');
    await _insertMember(db, 'q-other', 0);
    await db.execute(answerCompletionMemberInsertBankTriggerDdl);
    await validateAnswerCompletionV28Schema(db);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await db.close();

    final package = await packageDatabase(path, 'cross-bank');
    await expectLater(runtime().prepareRestore(package), _databaseInvalid);
  });

  test('staged restore delegates structural rejection to v28 authority',
      () async {
    final mutations = <String, Future<void> Function(Database)>{
      'missing-trigger': (db) => db.execute(
            'DROP TRIGGER $answerCompletionMemberDeleteCleanupTrigger',
          ),
      'weakened-trigger': (db) async {
        await db
            .execute('DROP TRIGGER $answerCompletionMemberInsertBankTrigger');
        await db.execute('''
          CREATE TRIGGER $answerCompletionMemberInsertBankTrigger
          AFTER INSERT ON $importedQuestionSetItemsTable
          BEGIN SELECT 1; END
        ''');
      },
      'malformed-relation': (db) => db.execute(
            'ALTER TABLE $importedQuestionSetItemsTable '
            'RENAME COLUMN position TO wrong_position',
          ),
      'missing-index': (db) =>
          db.execute('DROP INDEX $importedQuestionSetBankIndex'),
      'missing-unique-and-fk': (db) async {
        await db.execute('DROP TABLE $importedQuestionSetItemsTable');
        await db.execute('''
          CREATE TABLE $importedQuestionSetItemsTable (
            set_id TEXT NOT NULL,
            question_storage_id TEXT NOT NULL,
            position INTEGER NOT NULL
          )
        ''');
        await _insertQuestion(db, 'q-0', 'Math');
        await _insertQuestion(db, 'q-1', 'Math');
        await _insertSet(db);
        await _insertMember(db, 'q-0', 0);
        await _insertMember(db, 'q-0', 0);
        await _insertMember(db, 'q-1', 0);
      },
      'dangling-member': (db) async {
        await _insertSet(db);
        await db.execute('PRAGMA foreign_keys = OFF');
        await _insertMember(db, 'missing-question', 0);
        await db.execute('PRAGMA foreign_keys = ON');
      },
    };
    for (final entry in mutations.entries) {
      final path = p.join(temp.path, '${entry.key}.db');
      final db = await helper.openPathForTesting(path);
      await entry.value(db);
      await db.close();
      final package = await packageDatabase(path, entry.key);
      await expectLater(
        runtime().prepareRestore(package),
        _databaseInvalid,
        reason: entry.key,
      );
    }
  });

  test('v27 staged snapshot migrates to empty valid v28 relation', () async {
    final path = p.join(temp.path, 'v27.db');
    final db = await helper.openPathForTesting(path);
    for (final trigger in <String>[
      answerCompletionMemberInsertBankTrigger,
      answerCompletionMemberUpdateBankTrigger,
      answerCompletionQuestionBankDetachTrigger,
      answerCompletionMemberDeleteCleanupTrigger,
      answerCompletionMemberMoveCleanupTrigger,
      answerCompletionSetBankImmutableTrigger,
    ]) {
      await db.execute('DROP TRIGGER $trigger');
    }
    await db.execute('DROP TABLE $importedQuestionSetItemsTable');
    await db.execute('DROP TABLE $importedQuestionSetsTable');
    await db.execute('PRAGMA user_version = 27');
    await db.close();

    await snapshots.openStagedAndValidate(path);
    final migrated = await databaseFactory.openDatabase(path);
    try {
      expect(await migrated.getVersion(), DatabaseHelper.databaseVersion);
      await validateAnswerCompletionV28Schema(migrated);
      expect(await migrated.query(importedQuestionSetsTable), isEmpty);
      expect(await migrated.query(importedQuestionSetItemsTable), isEmpty);
    } finally {
      await migrated.close();
    }
  });
}
