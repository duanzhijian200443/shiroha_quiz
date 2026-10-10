import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/import_task_v31_schema.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  late Directory temp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('task_v31_');
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });

  test('fresh v31 preserves old shape with three nullable seconds fields',
      () async {
    final db = await helper.openPathForTesting(p.join(temp.path, 'fresh.db'));
    try {
      expect(importTaskSchemaVersion, 31);
      expect(
          DatabaseHelper.databaseVersion, externalAuthorizationSchemaVersion);
      expect(await db.getVersion(), externalAuthorizationSchemaVersion);
      expect(BackupValues.currentSchemaVersion,
          externalAuthorizationSchemaVersion);
      expect(BackupValues.currentPackageVersion, 2);
      await validateImportTaskV31Schema(db);
      final columns = await db.rawQuery('PRAGMA table_info(import_tasks)');
      expect(columns, hasLength(19));
      for (final column
          in columns.where((c) => importTaskEventColumns.contains(c['name']))) {
        expect(column['notnull'], 0);
        expect(column['dflt_value'], isNull);
      }
    } finally {
      await db.close();
    }
  });

  for (final oldVersion in [29, 30, 31]) {
    test(
        'v$oldVersion -> current preserves all task rows and never backfills event time',
        () async {
      final path = p.join(temp.path, 'old.db');
      final old = await helper.openPathForTesting(path);
      for (final status in TaskStatus.values) {
        await old.insert(
            'import_tasks',
            ImportTask(
                id: 'task-${status.name}',
                title: 'Synthetic.pdf',
                status: status,
                createdAt: 100,
                completedAt: 170,
                diagnostics: {}).toMap());
      }
      if (oldVersion < 31) {
        for (final column in importTaskEventColumns) {
          await old.execute('ALTER TABLE import_tasks DROP COLUMN $column');
        }
      }
      if (oldVersion == 29) {
        await old.execute('DROP TABLE study_activity_segments');
        await old.execute('DROP TABLE study_activity_sessions');
      }
      final before = await old.query('import_tasks', orderBy: 'id');
      for (final table in generatedProposalTables.reversed) {
        expect(await old.query(table), isEmpty);
        await old.execute('DROP TABLE $table');
      }
      await old.setVersion(oldVersion);
      await old.close();
      final oldProbe = await databaseFactory.openDatabase(path);
      expect(await oldProbe.getVersion(), oldVersion);
      if (oldVersion == 31) {
        await validateImportTaskV31Schema(oldProbe);
      }
      await oldProbe.close();
      final db = await helper.openPathForTesting(path);
      try {
        expect(await db.getVersion(), externalAuthorizationSchemaVersion);
        final after = await db.query('import_tasks', orderBy: 'id');
        expect(after, hasLength(4));
        for (var i = 0; i < after.length; i++) {
          for (final entry in before[i].entries) {
            expect(after[i][entry.key], entry.value);
          }
          for (final column in importTaskEventColumns) {
            expect(after[i][column], isNull);
          }
        }
        await validateImportTaskV31Schema(db);
        expect(await db.query('study_activity_sessions'), isEmpty);
      } finally {
        await db.close();
      }
    });
  }

  test('malformed old/new shape rolls migration back without a schema bump',
      () async {
    final path = p.join(temp.path, 'bad.db');
    final old = await helper.openPathForTesting(path);
    for (final column in importTaskEventColumns) {
      await old.execute('ALTER TABLE import_tasks DROP COLUMN $column');
    }
    await old.execute(
        'ALTER TABLE import_tasks ADD COLUMN parsed_at TEXT NOT NULL DEFAULT \'bad\'');
    for (final table in generatedProposalTables.reversed) {
      expect(await old.query(table), isEmpty);
      await old.execute('DROP TABLE $table');
    }
    await old.setVersion(30);
    await old.close();
    await expectLater(helper.openPathForTesting(path),
        throwsA(isA<ImportTaskSchemaException>()));
    final probe = await databaseFactory.openDatabase(path);
    try {
      expect(await probe.getVersion(), 30);
      final names = (await probe.rawQuery('PRAGMA table_info(import_tasks)'))
          .map((r) => r['name']);
      expect(names, isNot(contains('attempt_started_at')));
    } finally {
      await probe.close();
    }
  });

  test('B0 scrubs task event fields from v31; live rows unchanged', () async {
    final db = await helper.database;
    final task = ImportTask(
        id: 'task',
        title: 'Synthetic.pdf',
        createdAt: 10,
        attemptStartedAt: 20,
        parsedAt: 30,
        failedAt: 40);
    await db.insert('import_tasks', task.toMap());
    final before = await db.query('import_tasks');
    final path = p.join(temp.path, 'snapshot.db');
    final snapshots = BackupSnapshotRepository(databaseHelper: helper);
    final snapshot = await snapshots.createSanitizedSnapshot(path);
    expect(snapshot.schemaVersion, externalAuthorizationSchemaVersion);
    expect(await db.query('import_tasks'), before);
    final probe = await databaseFactory.openDatabase(path);
    try {
      expect(await probe.query('import_tasks'), isEmpty);
      await validateImportTaskV31Schema(probe);
    } finally {
      await probe.close();
    }
    // Portable v30 staged backups already have scrubbed ImportTask rows.
    final old = await databaseFactory.openDatabase(path);
    for (final column in importTaskEventColumns) {
      await old.execute('ALTER TABLE import_tasks DROP COLUMN $column');
    }
    for (final table in generatedProposalTables.reversed) {
      expect(await old.query(table), isEmpty);
      await old.execute('DROP TABLE $table');
    }
    await old.setVersion(30);
    await old.close();
    await snapshots.openStagedAndValidate(path);
    final staged = await databaseFactory.openDatabase(path);
    try {
      expect(await staged.getVersion(), externalAuthorizationSchemaVersion);
      expect(await staged.query('import_tasks'), isEmpty);
    } finally {
      await staged.close();
    }
    expect(await db.query('import_tasks'), before);
  });
}
