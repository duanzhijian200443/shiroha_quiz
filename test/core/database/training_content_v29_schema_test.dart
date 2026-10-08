import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/training_content_v29_schema.dart';
import 'package:shiroha_quiz/core/database/import_task_v31_schema.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';

const _uncategorized = '["uncategorized"]';
const _tables = [
  trainingContentsTable,
  trainingContentMembersTable,
  trainingCategoryPreferencesTable
];

Future<void> _question(Database db, String bank, String id) async {
  await db.insert('questions', {
    'id': id,
    'type': 0,
    'content': 'synthetic',
    'standard_answer': 'A',
    'created_at': 1,
    'bank_name': bank
  });
}

Future<void> _setting(Database db, String key, String? value) async {
  await db.insert('app_settings', {'key': key, 'value': value});
}

Future<void> _content(Database db,
    {String id = 'a', int limit = 40, int revision = 1}) async {
  await db.insert(trainingContentsTable, {
    'content_id': id,
    'category_key': _uncategorized,
    'name': 'A',
    'question_limit': limit,
    'sort_order': 0,
    'revision': revision
  });
}

Future<void> _member(Database db,
    {String id = 'a',
    String bank = 'Bank',
    int weight = 100,
    int position = 0,
    String status = 'valid',
    String? reason}) async {
  await db.insert(trainingContentMembersTable, {
    'content_id': id,
    'bank_name': bank,
    'weight_percent': weight,
    'position': position,
    'binding_status': status,
    'invalidation_reason': reason
  });
}

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
    temp = await Directory.systemTemp.createTemp('training_v29_');
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });
  String path(String name) => p.join(temp.path, '$name.db');
  Future<Database> fresh(String name) => helper.openPathForTesting(path(name));
  Future<Database> legacy(String name) async {
    final db = await fresh(name);
    await db.execute('DROP TABLE $trainingCategoryPreferencesTable');
    await db.execute('DROP TABLE $trainingContentMembersTable');
    await db.execute('DROP TABLE $trainingContentsTable');
    await db.setVersion(28);
    return db;
  }

  test('fresh v29 has exact columns, key indexes and content-only cascade FK',
      () async {
    final db = await fresh('fresh');
    try {
      expect(importTaskSchemaVersion, 31);
      expect(DatabaseHelper.databaseVersion, generatedProposalSchemaVersion);
      expect(await db.getVersion(), generatedProposalSchemaVersion);
      await validateTrainingContentV29Schema(db);
      final expected = {
        trainingContentsTable: [
          'content_id',
          'category_key',
          'name',
          'question_limit',
          'sort_order',
          'revision'
        ],
        trainingContentMembersTable: [
          'content_id',
          'bank_name',
          'weight_percent',
          'position',
          'binding_status',
          'invalidation_reason'
        ],
        trainingCategoryPreferencesTable: [
          'category_key',
          'visual_key',
          'current_content_id',
          'revision'
        ],
      };
      for (final entry in expected.entries) {
        expect(
            (await db.rawQuery('PRAGMA table_info(${entry.key})'))
                .map((row) => row['name']),
            entry.value);
        expect(await db.query(entry.key), isEmpty);
      }
      final fk = await db
          .rawQuery('PRAGMA foreign_key_list($trainingContentMembersTable)');
      expect(fk, hasLength(1));
      expect(fk.single['from'], 'content_id');
      expect(fk.single['table'], trainingContentsTable);
      expect(fk.single['on_delete'], 'CASCADE');
      final shapes = <String>[];
      for (final row in await db
          .rawQuery('PRAGMA index_list($trainingContentMembersTable)')) {
        if (row['unique'] == 1) {
          shapes.add((await db.rawQuery('PRAGMA index_info(${row['name']})'))
              .map((column) => column['name'])
              .join(','));
        }
      }
      expect(shapes.toSet(), {'content_id,bank_name', 'content_id,position'});
      expect(
          (await db.rawQuery('PRAGMA index_info($trainingCategoryIndex)'))
              .single['name'],
          'category_key');
      await validateTrainingContentV29Data(db);
    } finally {
      await db.close();
    }
  });

  test(
      'SQLite enforces limits, revisions, weights, identities and binding matrix',
      () async {
    final db = await fresh('constraints');
    try {
      for (final limit in [0, 101]) {
        await expectLater(
            _content(db, limit: limit), throwsA(isA<DatabaseException>()));
      }
      await expectLater(
          _content(db, revision: 0), throwsA(isA<DatabaseException>()));
      await _content(db);
      await expectLater(
          db.insert(trainingCategoryPreferencesTable, {
            'category_key': _uncategorized,
            'revision': 0,
          }),
          throwsA(isA<DatabaseException>()));
      await expectLater(
          db.insert(trainingCategoryPreferencesTable, {
            'category_key': _uncategorized,
            'visual_key': 'arbitrary-path',
            'revision': 1,
          }),
          throwsA(isA<DatabaseException>()));
      for (final weight in [-1, 101]) {
        await expectLater(
            _member(db, weight: weight), throwsA(isA<DatabaseException>()));
      }
      for (final status in ['unknown', 'VALID']) {
        await expectLater(
            _member(db, status: status), throwsA(isA<DatabaseException>()));
      }
      await expectLater(_member(db, reason: 'bankMissing'),
          throwsA(isA<DatabaseException>()));
      await expectLater(_member(db, status: 'invalidated', reason: 'raw-error'),
          throwsA(isA<DatabaseException>()));
      await expectLater(
          _member(db, id: 'missing'), throwsA(isA<DatabaseException>()));
      await _member(db);
      await expectLater(
          _member(db, position: 1), throwsA(isA<DatabaseException>()));
      await expectLater(
          _member(db, bank: 'Other'), throwsA(isA<DatabaseException>()));
      await _member(db,
          bank: 'Deleted', weight: 0, position: 1, status: 'invalidated');
      await db.delete(trainingContentsTable);
      expect(await db.query(trainingContentMembersTable), isEmpty);
    } finally {
      await db.close();
    }
  });

  test(
      'v28 upgrade seeds exact mapped current bank once and preserves learning rows',
      () async {
    const bank = ' 📚 Bank ';
    const folder = ' Exact 📁 Folder ';
    final db = await legacy('seed');
    await _question(db, bank, 'q-a');
    await _question(db, 'Other bank', 'q-b');
    await db.insert('review_states', {'question_id': 'q-a', 'state': 1});
    await db.insert('review_logs', {
      'id': 'log',
      'question_id': 'q-a',
      'grade': 3,
      'review_time': 1,
      'duration_ms': 123
    });
    await db.insert('answer_attempts', {
      'attempt_id': 'attempt',
      'question_id': 'q-a',
      'session_kind': 'normal',
      'modality': 'text',
      'answer_payload_json': '{"text":"synthetic"}',
      'correctness': 1,
      'answered_at': 1,
      'duration_ms': 123,
    });
    await db.insert('imported_question_sets', {
      'set_id': 'set',
      'bank_name': bank,
      'display_name': 'Synthetic',
      'created_at': 1
    });
    await db.insert('imported_question_set_items',
        {'set_id': 'set', 'question_storage_id': 'q-a', 'position': 0});
    await db.insert('study_plans', {
      'plan_id': 'plan',
      'bank_name': 'Other bank',
      'daily_target': 20,
      'priority': 'balanced',
      'adopted_at': 1
    });
    await db.insert('bank_folders', {'bank_name': bank, 'folder_name': folder});
    await _setting(db, 'current_bank', bank);
    await _setting(db, '${bank}_daily_quota', '23');
    const preserved = [
      'questions',
      'review_states',
      'review_logs',
      'answer_attempts',
      'imported_question_sets',
      'imported_question_set_items',
      'study_plans',
      'bank_folders'
    ];
    final before = {
      for (final table in preserved) table: await db.query(table)
    };
    await db.close();
    final migrated = await fresh('seed');
    final content = (await migrated.query(trainingContentsTable)).single;
    final encoded =
        const CategoryKeyCodec().encodeString(FolderCategoryKey(folder));
    expect(content['name'], bank);
    expect(content['category_key'], encoded);
    expect(content['question_limit'], 23);
    expect(
        (await migrated.query(trainingContentMembersTable)).single['bank_name'],
        bank);
    expect(
        (await migrated.query(trainingContentMembersTable))
            .single['weight_percent'],
        100);
    expect(
        (await migrated.query(trainingCategoryPreferencesTable))
            .single['current_content_id'],
        content['content_id']);
    expect(
        (await migrated.query('app_settings',
                where: 'key = ?', whereArgs: [currentTrainingCategorySetting]))
            .single['value'],
        encoded);
    expect(
        (await migrated.query('app_settings',
                where: 'key = ?', whereArgs: ['current_bank']))
            .single['value'],
        bank);
    for (final table in preserved) {
      expect(await migrated.query(table), before[table], reason: table);
    }
    await migrated.close();
    final reopened = await fresh('seed');
    expect(await reopened.query(trainingContentsTable), [content]);
    await reopened.delete(trainingCategoryPreferencesTable);
    await reopened.delete(trainingContentsTable);
    await _question(reopened, bank, 'q-after');
    await reopened.close();
    final afterDeletion = await fresh('seed');
    for (final table in _tables) {
      expect(await afterDeletion.query(table), isEmpty);
    }
    await afterDeletion.close();
  });

  for (final (label, bank, exists) in <(String, String?, bool)>[
    ('absent-current', null, true),
    ('missing-bank', 'Missing', false),
    ('empty-mapped-bank', 'Empty', false),
    ('wrong-book', '🔥 全局错题本', true),
    ('hidden-exam', '📦 模考专属题库', true),
  ]) {
    test('$label does not seed or invent a current Category', () async {
      final db = await legacy(label);
      if (label == 'absent-current') {
        await db.execute('DROP TABLE app_settings');
      }
      if (bank != null) await _setting(db, 'current_bank', bank);
      await _question(db, 'Other', 'other');
      if (bank != null && exists) await _question(db, bank, 'reserved');
      if (label == 'empty-mapped-bank') {
        await db.insert(
            'bank_folders', {'bank_name': bank, 'folder_name': 'Folder'});
      }
      await db.close();
      final migrated = await fresh(label);
      for (final table in _tables) {
        expect(await migrated.query(table), isEmpty);
      }
      expect(
          await migrated.query('app_settings',
              where: 'key = ?', whereArgs: [currentTrainingCategorySetting]),
          isEmpty);
      await migrated.close();
    });
  }

  for (final (raw, expected) in <(String?, int)>[
    (null, 40),
    ('bad', 40),
    ('0', 40),
    ('-2', 40),
    ('101', 100),
    ('1', 1),
    ('65', 65),
  ]) {
    test('unmapped bank preserves quota semantics: $raw => $expected',
        () async {
      final db = await legacy('quota');
      // An arbitrary emoji name is real, not a reserved-name heuristic.
      await _question(db, '🔥 User bank', 'q');
      await _setting(db, 'current_bank', '🔥 User bank');
      if (raw != null) await _setting(db, '🔥 User bank_daily_quota', raw);
      await db.close();
      final migrated = await fresh('quota');
      final row = (await migrated.query(trainingContentsTable)).single;
      expect(row['question_limit'], expected);
      expect(row['category_key'], _uncategorized);
      await migrated.close();
    });
  }

  test('malformed pre-existing v29 object aborts upgrade atomically', () async {
    final db = await legacy('rollback');
    await _question(db, 'Bank', 'keep');
    await _setting(db, 'current_bank', 'Bank');
    await db.execute(
        'CREATE TABLE training_contents (content_id TEXT PRIMARY KEY)');
    await db.close();
    await expectLater(
        fresh('rollback'), throwsA(isA<TrainingContentSchemaException>()));
    final probe = await databaseFactory.openDatabase(path('rollback'));
    expect(await probe.getVersion(), 28);
    expect((await probe.query('questions')).single['id'], 'keep');
    expect(
        await probe.rawQuery(
            "SELECT name FROM sqlite_master WHERE name = 'training_content_members'"),
        isEmpty);
    await probe.close();
  });
}
