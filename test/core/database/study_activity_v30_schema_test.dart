import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/study_activity_v30_schema.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';

Map<String, Object?> sessionRow(String id,
        {String status = 'active',
        String? reason,
        int? ended,
        int started = 1000,
        int checkpoint = 100}) =>
    {
      'session_id': id,
      'scene': 'ordinaryPractice',
      'lifecycle_status': status,
      'started_at_utc_ms': started,
      'last_checkpoint_at_utc_ms': checkpoint,
      'ended_at_utc_ms': ended,
      'end_reason': reason,
      'checkpoint_sequence': 0,
      'revision': 1,
    };
Map<String, Object?> segmentRow(String id, int seq) => {
      'segment_id': '$id-$seq',
      'session_id': id,
      'sequence': seq,
      'local_date': '2026-10-04',
      'utc_offset_minutes': 480,
      'start_utc_ms': 100,
      'end_utc_ms': 101,
      'duration_ms': 900,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final helper = DatabaseHelper.instance;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('activity_schema_');
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });
  Future<Database> fresh(String name) =>
      helper.openPathForTesting(p.join(temp.path, '$name.db'));

  test('fresh v30 exact shape, indexes, soft context and segment-only cascade',
      () async {
    final db = await fresh('fresh');
    try {
      expect(await db.getVersion(), DatabaseHelper.databaseVersion);
      expect(DatabaseHelper.databaseVersion, BackupValues.currentSchemaVersion);
      expect(studyActivitySchemaVersion, 30);
      expect(BackupValues.currentPackageVersion, 2);
      await validateStudyActivityV30Schema(db);
      await validateStudyActivityV30Data(db);
      final columns =
          (await db.rawQuery('PRAGMA table_info(study_activity_sessions)'))
              .map((r) => r['name']);
      expect(columns, [
        'session_id',
        'scene',
        'lifecycle_status',
        'started_at_utc_ms',
        'last_checkpoint_at_utc_ms',
        'ended_at_utc_ms',
        'end_reason',
        'checkpoint_sequence',
        'revision',
        'category_key',
        'content_id',
        'bank_name',
        'plan_id',
        'paper_id'
      ]);
      expect(
          await db.rawQuery('PRAGMA foreign_key_list(study_activity_sessions)'),
          isEmpty);
      expect(
          (await db
                  .rawQuery('PRAGMA foreign_key_list(study_activity_segments)'))
              .single['on_delete'],
          'CASCADE');
      await db.insert(studyActivitySessionsTable, sessionRow('s'));
      await db.insert(studyActivitySegmentsTable, segmentRow('s', 1));
      // Wall time can go backwards; duration may differ from UTC width.
      await validateStudyActivityV30Data(db);
      await db.delete(studyActivitySessionsTable);
      expect(await db.query(studyActivitySegmentsTable), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('SQL and Domain both enforce every lifecycle/reason/null matrix row',
      () async {
    final db = await fresh('matrix');
    try {
      for (final status in StudyActivityLifecycleStatus.values) {
        for (final reason in <StudyActivityEndReason?>[
          null,
          ...StudyActivityEndReason.values
        ]) {
          for (final ended in <int?>[null, 100]) {
            var valid = true;
            try {
              StudyActivityLifecycle(
                  status: status, endedAtUtcMs: ended, endReason: reason);
            } catch (_) {
              valid = false;
            }
            final values = sessionRow('s',
                status: status.name, reason: reason?.name, ended: ended);
            if (valid) {
              await db.insert(studyActivitySessionsTable, values);
              await db.delete(studyActivitySessionsTable);
            } else {
              await expectLater(db.insert(studyActivitySessionsTable, values),
                  throwsA(anything));
            }
          }
        }
      }
      for (final change in [
        {'scene': 'singleQuestionStudy'},
        {'scene': 'unknown'},
        {'revision': 0},
        {'checkpoint_sequence': -1},
        {'started_at_utc_ms': -1}
      ]) {
        await expectLater(
            db.insert(
                studyActivitySessionsTable, {...sessionRow('s'), ...change}),
            throwsA(anything));
      }
      await db.insert(studyActivitySessionsTable, sessionRow('s'));
      for (final change in [
        {'sequence': 0},
        {'duration_ms': -1},
        {'start_utc_ms': -1},
        {'end_utc_ms': 99},
        {'session_id': 'missing'}
      ]) {
        await expectLater(
            db.insert(
                studyActivitySegmentsTable, {...segmentRow('s', 1), ...change}),
            throwsA(anything));
      }
      await db.insert(studyActivitySegmentsTable, segmentRow('s', 1));
      await expectLater(
          db.insert(studyActivitySegmentsTable,
              {...segmentRow('s', 1), 'segment_id': 'different'}),
          throwsA(anything));
    } finally {
      await db.close();
    }
  });

  test('v29 upgrade preserves Question data and creates empty Activity tables',
      () async {
    final path = p.join(temp.path, 'v29.db');
    final old = await helper.openPathForTesting(path);
    await old.insert('questions', {
      'id': 'keep',
      'type': 1,
      'content': 'synthetic',
      'standard_answer': 'A',
      'created_at': 1
    });
    await old.execute('DROP TABLE study_activity_segments');
    await old.execute('DROP TABLE study_activity_sessions');
    await old.setVersion(29);
    await old.close();
    final upgraded = await helper.openPathForTesting(path);
    try {
      expect(await upgraded.getVersion(), DatabaseHelper.databaseVersion);
      expect((await upgraded.query('questions')).single['id'], 'keep');
      expect(await upgraded.query(studyActivitySessionsTable), isEmpty);
      expect(await upgraded.query(studyActivitySegmentsTable), isEmpty);
      await validateStudyActivityV30Schema(upgraded);
    } finally {
      await upgraded.close();
    }
  });

  test('malformed pre-existing object rolls back all migration DDL and version',
      () async {
    final path = p.join(temp.path, 'bad.db');
    final old = await helper.openPathForTesting(path);
    await old.execute('DROP TABLE study_activity_segments');
    await old.execute('DROP TABLE study_activity_sessions');
    await old.execute('CREATE TABLE study_activity_sessions (session_id TEXT)');
    await old.setVersion(29);
    await old.close();
    await expectLater(helper.openPathForTesting(path), throwsA(anything));
    final probe = await databaseFactory.openDatabase(path);
    try {
      expect(await probe.getVersion(), 29);
      expect(
          await probe.rawQuery(
              "SELECT 1 FROM sqlite_master WHERE name='study_activity_segments'"),
          isEmpty);
      expect(
          (await probe.rawQuery('PRAGMA table_info(study_activity_sessions)')),
          hasLength(1));
    } finally {
      await probe.close();
    }
  });

  test('data validation rejects invalid dates/enums/Category without repair',
      () async {
    final db = await fresh('data');
    try {
      await db.insert(studyActivitySessionsTable, sessionRow('s'));
      await db.insert(studyActivitySegmentsTable,
          {...segmentRow('s', 1), 'local_date': '2026-02-30'});
      await expectLater(validateStudyActivityV30Data(db),
          throwsA(isA<StudyActivitySchemaException>()));
      expect((await db.query(studyActivitySegmentsTable)).single['local_date'],
          '2026-02-30');
      await db.delete(studyActivitySegmentsTable);
      await db.update(
          studyActivitySessionsTable, {'category_key': '[ "uncategorized" ]'});
      await expectLater(validateStudyActivityV30Data(db),
          throwsA(isA<StudyActivitySchemaException>()));
      await db.update(studyActivitySessionsTable, {'category_key': null});
      await db.execute('PRAGMA ignore_check_constraints=ON');
      await db.update(studyActivitySessionsTable, {'end_reason': 'exited'});
      await expectLater(validateStudyActivityV30Data(db),
          throwsA(isA<StudyActivitySchemaException>()));
    } finally {
      await db.close();
    }
  });
}
