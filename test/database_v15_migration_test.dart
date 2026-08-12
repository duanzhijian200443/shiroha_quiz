// R6B v15 additive Question V2 sidecar migration matrix.
//
// All databases in this file are synthetic temp files or in-memory handles
// created by the test framework. No real application database, private
// document, OCR, Replay, Provider, or network path is touched.
//
// Seam limitations: through the frozen openPathForTesting seam,
// `foreignKeysDisabled` and the non-test StateError branch of the seam are
// not reachable (onConfigure always enables foreign keys before validation
// runs, and FLUTTER_TEST is always present under flutter_test). Their fixed
// messages are covered by the exception contract tests and positive FK
// enforcement is asserted on every opened connection.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/question_v2_schema_exception.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Independent copy of the frozen sidecar definition with deliberately
/// different formatting, used to prove canonical SQL equality.
const String _frozenSidecarDdl = '''
CREATE TABLE question_v2_payloads (
    question_id TEXT PRIMARY KEY NOT NULL,
    payload_schema_version INTEGER NOT NULL CHECK ( payload_schema_version > 0 ),
    payload_json TEXT NOT NULL CHECK ( length(payload_json) > 0 ),
    FOREIGN KEY ( question_id ) REFERENCES questions ( id ) ON DELETE CASCADE
);
''';

const List<String> _v1Tables = <String>[
  'questions',
  'review_states',
  'review_logs',
  'pomodoro_sessions',
  'ai_profiles',
  'bank_folders',
  'ai_engines',
  'import_tasks',
];

/// Tables whose full rows must survive every v10-v14 upgrade unchanged.
const List<String> _stableTables = <String>[
  'review_states',
  'review_logs',
  'pomodoro_sessions',
  'ai_profiles',
  'bank_folders',
];

const List<String> _allTables = <String>[
  ..._v1Tables,
  'question_v2_payloads',
];

/// Independent, simpler canonicalizer used only to compare accepted stored
/// SQL against the frozen definition.
String testCanonical(String sql) {
  var s = sql.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ');
  s = s.replaceAll(RegExp(r'--[^\n]*'), ' ');
  s = s.toLowerCase();
  s = s
      .replaceAll('"', '')
      .replaceAll('`', '')
      .replaceAll('[', '')
      .replaceAll(']', '');
  s = s.replaceAllMapped(
    RegExp(r'\s*([(),;])\s*'),
    (match) => ' ${match[1]} ',
  );
  s = s.replaceAllMapped(
    RegExp(r'\s*(>=|<=|!=|<>|==|>|<|=)\s*'),
    (match) => ' ${match[1]} ',
  );
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  s = s.trim();
  if (s.endsWith(';')) {
    s = s.substring(0, s.length - 1).trim();
  }
  s = s.replaceFirst(
    RegExp(r'^create table if not exists '),
    'create table ',
  );
  return s;
}

String fixedMessage(QuestionV2SchemaFailure failure) {
  final detail = switch (failure) {
    QuestionV2SchemaFailure.unsupportedSourceVersion =>
      'The source database version is below the supported migration floor.',
    QuestionV2SchemaFailure.malformedParentSchema =>
      'The parent schema does not satisfy the frozen v15 requirements.',
    QuestionV2SchemaFailure.malformedSidecarSchema =>
      'The question_v2_payloads sidecar does not match the frozen '
          'definition.',
    QuestionV2SchemaFailure.foreignKeysDisabled =>
      'Foreign key enforcement is disabled on the opened connection.',
    QuestionV2SchemaFailure.foreignKeyViolation =>
      'The database contains foreign key violations.',
  };
  return 'QuestionV2SchemaException(${failure.name}): $detail';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('r6b_v15_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String dbPath(String name) => p.join(tempDir.path, name);

  Future<Database> openSeam(String path) =>
      DatabaseHelper.instance.openPathForTesting(path);

  Future<Database> openRaw(String path, {bool foreignKeysOn = false}) {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        onConfigure: (db) async {
          await db.execute(
            foreignKeysOn
                ? 'PRAGMA foreign_keys = ON'
                : 'PRAGMA foreign_keys = OFF',
          );
        },
      ),
    );
  }

  Future<void> setUserVersion(Database db, int version) async {
    await db.execute('PRAGMA user_version = $version');
  }

  Future<int> userVersion(Database db) async {
    final rows = await db.rawQuery('PRAGMA user_version');
    return rows.single['user_version'] as int;
  }

  Future<Map<String, String>> snapshotTables(
    Database db, {
    List<String> tables = _allTables,
  }) async {
    final snapshot = <String, String>{};
    for (final table in tables) {
      snapshot[table] = jsonEncode(await db.query(table, orderBy: 'rowid'));
    }
    return snapshot;
  }

  Future<void> seedV1Data(Database db) async {
    await db.insert('questions', <String, Object?>{
      'id': 'q_seed_1',
      'type': 0,
      'content': 'seed stem one',
      'options': jsonEncode(<String>['A. one', 'B. two']),
      'standard_answer': 'A|||seed explanation',
      'explanation': 'seed explanation',
      'raw_explanation': 'raw seed',
      'created_at': 1700000001,
      'bank_name': 'seed_bank',
    });
    await db.insert('questions', <String, Object?>{
      'id': 'q_seed_2',
      'type': 3,
      'content': 'seed stem two',
      'options': '[]',
      'standard_answer': 'answer two|||',
      'created_at': 1700000002,
      'bank_name': 'seed_bank',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q_seed_1',
      'state': 1,
      'next_review_time': 1700001000,
      'lapses': 2,
      'difficulty': 3.5,
      'stability': 4.5,
      'reps': 7,
      'last_lapse_time': 1700000000,
      'last_review_time': 1700000005,
    });
    await db.insert('review_logs', <String, Object?>{
      'id': 'log_seed_1',
      'question_id': 'q_seed_1',
      'grade': 3,
      'llm_score': 0.8,
      'review_time': 1700000010,
      'duration_ms': 1200,
      'user_answer': 'A',
      'ai_evaluation': 'ok',
    });
    await db.insert('pomodoro_sessions', <String, Object?>{
      'id': 'pomo_seed_1',
      'bank_name': 'seed_bank',
      'start_time': 1700000000,
      'end_time': 1700000600,
      'target_duration': 600,
      'actual_duration': 590,
      'status': 0,
      'questions_solved': 3,
    });
    await db.insert('ai_profiles', <String, Object?>{
      'id': 'profile_seed_1',
      'name': 'seed profile',
      'is_active': 1,
    });
    await db.insert('bank_folders', <String, Object?>{
      'bank_name': 'seed_bank',
      'folder_name': '默认学科',
    });
    await db.insert('ai_engines', <String, Object?>{
      'id': 'engine_seed_1',
      'engine_type': 'text',
      'name': 'seed engine',
      'is_active': 1,
    });
    await db.insert('import_tasks', <String, Object?>{
      'id': 'task_seed_1',
      'title': 'seed task',
      'status': 2,
      'progress_text': 'done',
      'percent': 1.0,
      'error_msg': null,
      'parsed_data': null,
      'bank_name': 'seed_bank',
      'folder_name': '默认学科',
      'created_at': 1700000000,
      'completed_at': 1700000100,
      'source_type': 'pdf',
      'pending_chunks': '[]',
      'failed_chunks': '[]',
      'warnings': '[]',
      'diagnostics': '[]',
    });
  }

  Future<void> seedSidecarRows(Database db) async {
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q_seed_1',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"synthetic":true}',
    });
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q_seed_2',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"synthetic":true,"n":2}',
    });
  }

  /// Opens through the seam, expects the given failure, then proves the
  /// failed open left user_version and the sidecar SQL text unchanged.
  Future<void> expectRejectedWithoutReplacement(
    String path,
    QuestionV2SchemaFailure expectedFailure,
  ) async {
    final raw = await openRaw(path);
    final sidecarRows = await raw.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' "
      "AND name = 'question_v2_payloads'",
    );
    final sqlBefore =
        sidecarRows.isEmpty ? null : sidecarRows.single['sql'] as String;
    final versionBefore = await userVersion(raw);
    await raw.close();

    await expectLater(
      openSeam(path),
      throwsA(
        isA<QuestionV2SchemaException>()
            .having((e) => e.failure, 'failure', expectedFailure)
            .having(
              (e) => e.toString(),
              'toString',
              fixedMessage(expectedFailure),
            ),
      ),
    );

    final probe = await openRaw(path);
    expect(await userVersion(probe), versionBefore);
    final sidecarAfter = await probe.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' "
      "AND name = 'question_v2_payloads'",
    );
    final sqlAfter =
        sidecarAfter.isEmpty ? null : sidecarAfter.single['sql'] as String;
    expect(sqlAfter, sqlBefore);
    await probe.close();
  }

  Future<void> replaceSidecar(
    String path,
    String createSql, {
    String? alterSql,
  }) async {
    final raw = await openRaw(path);
    await raw.execute('DROP TABLE question_v2_payloads');
    await raw.execute(createSql);
    if (alterSql != null) {
      await raw.execute(alterSql);
    }
    await setUserVersion(raw, 14);
    await raw.close();
  }

  Future<Map<String, String>> snapshotStableRows(Database db) async {
    final snapshot = <String, String>{};
    for (final table in _stableTables) {
      snapshot[table] = jsonEncode(await db.query(table, orderBy: 'rowid'));
    }
    snapshot['questions'] = jsonEncode(await db.rawQuery(
      'SELECT id, type, content, options, standard_answer, explanation, '
      'created_at, bank_name FROM questions ORDER BY id',
    ));
    return snapshot;
  }

  Future<List<String>> columnNames(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((row) => row['name'] as String).toList();
  }

  /// Downgrades a v15 fixture to the schema shape that existed at [version],
  /// always removing the v15 sidecar and, where practical, the legacy
  /// columns/tables that the matching onUpgrade steps recreate.
  Future<void> downgradeToVersion(Database raw, int version) async {
    await raw.execute('DROP TABLE question_v2_payloads');
    if (version < 13) {
      await raw.execute('ALTER TABLE questions DROP COLUMN raw_explanation');
    }
    if (version < 11) {
      await raw.execute('DROP TABLE import_tasks');
    } else if (version < 14) {
      await raw.execute('ALTER TABLE import_tasks DROP COLUMN warnings');
      await raw.execute('ALTER TABLE import_tasks DROP COLUMN diagnostics');
    }
  }

  group('frozen v15 schema', () {
    test('fresh production create preserves the frozen v15 sidecar contract',
        () async {
      final db = await openSeam(inMemoryDatabasePath);
      try {
        expect(await userVersion(db), 20);
        expect(
          (await db.rawQuery('PRAGMA foreign_keys')).single.values.single,
          1,
        );
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

        final tableNames = <String>{
          for (final row in await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table'",
          ))
            row['name'] as String,
        };
        for (final expected in _allTables) {
          expect(tableNames, contains(expected));
        }

        final sidecarSql = (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE type = 'table' "
          "AND name = 'question_v2_payloads'",
        ))
            .single['sql'] as String;
        expect(testCanonical(sidecarSql), testCanonical(_frozenSidecarDdl));

        final columns =
            await db.rawQuery('PRAGMA table_info(question_v2_payloads)');
        expect(
          columns.map((row) => row['name']).toList(),
          <String>['question_id', 'payload_schema_version', 'payload_json'],
        );
        expect(
          columns.map((row) => (row['type'] as String).toUpperCase()).toList(),
          <String>['TEXT', 'INTEGER', 'TEXT'],
        );
        expect(
          columns.map((row) => row['notnull']).toList(),
          <int>[1, 1, 1],
        );
        expect(columns.map((row) => row['pk']).toList(), <int>[1, 0, 0]);

        final foreignKeys =
            await db.rawQuery('PRAGMA foreign_key_list(question_v2_payloads)');
        expect(foreignKeys.length, 1);
        expect(foreignKeys.single['table'], 'questions');
        expect(foreignKeys.single['from'], 'question_id');
        expect(foreignKeys.single['to'], 'id');
        expect(foreignKeys.single['on_update'], 'NO ACTION');
        expect(foreignKeys.single['on_delete'], 'CASCADE');

        final questionColumns = <String, Map<String, Object?>>{
          for (final row in await db.rawQuery('PRAGMA table_info(questions)'))
            row['name'] as String: row,
        };
        expect(questionColumns['id']!['pk'], 1);
        expect(questionColumns['type']!['notnull'], 1);
        expect(questionColumns['content']!['notnull'], 1);
        expect(questionColumns['standard_answer']!['notnull'], 1);
        expect(questionColumns['created_at']!['notnull'], 1);
        expect(questionColumns, contains('bank_name'));

        final bankFolders =
            await db.rawQuery('PRAGMA table_info(bank_folders)');
        expect(
          bankFolders.map((row) => row['name']).toList(),
          <String>['bank_name', 'folder_name'],
        );
        expect(bankFolders[0]['pk'], 1);
        expect(bankFolders[1]['notnull'], 1);
        expect(
          (bankFolders[1]['dflt_value'] as String).contains('默认学科'),
          isTrue,
        );

        // Write path round trip and ON DELETE CASCADE.
        await db.insert('questions', <String, Object?>{
          'id': 'q_new',
          'type': 0,
          'content': 'new stem',
          'standard_answer': 'A',
          'created_at': 1,
        });
        await db.insert('question_v2_payloads', <String, Object?>{
          'question_id': 'q_new',
          'payload_schema_version': 2,
          'payload_json': '{"synthetic":true}',
        });
        final written = (await db.query(
          'question_v2_payloads',
          where: 'question_id = ?',
          whereArgs: <Object?>['q_new'],
        ))
            .single;
        expect(written['question_id'], 'q_new');
        expect(written['payload_schema_version'], 2);
        expect(written['payload_json'], '{"synthetic":true}');
        await db.delete('questions',
            where: 'id = ?', whereArgs: <Object?>['q_new']);
        expect(
          await db.query(
            'question_v2_payloads',
            where: 'question_id = ?',
            whereArgs: <Object?>['q_new'],
          ),
          isEmpty,
        );
      } finally {
        await db.close();
      }
    });

    test('every seam-opened connection enforces foreign keys', () async {
      final path = dbPath('fk_enforced.db');
      final first = await openSeam(path);
      try {
        expect(
          (await first.rawQuery('PRAGMA foreign_keys')).single.values.single,
          1,
        );
        await expectLater(
          first.insert('question_v2_payloads', <String, Object?>{
            'question_id': 'no_parent',
            'payload_schema_version': 2,
            'payload_json': '{}',
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await first.close();
      }

      final second = await openSeam(path);
      try {
        expect(
          (await second.rawQuery('PRAGMA foreign_keys')).single.values.single,
          1,
        );
      } finally {
        await second.close();
      }
    });
  });

  group('upgrade matrix', () {
    test('v10 through v14 migrate real missing-sidecar fixtures', () async {
      for (final oldVersion in <int>[10, 11, 12, 13, 14]) {
        final path = dbPath('missing_sidecar_v$oldVersion.db');
        final created = await openSeam(path);
        await seedV1Data(created);
        final stableBefore = await snapshotStableRows(created);
        await created.close();

        final raw = await openRaw(path);
        await downgradeToVersion(raw, oldVersion);
        await setUserVersion(raw, oldVersion);
        await raw.close();

        final upgraded = await openSeam(path);
        expect(await userVersion(upgraded), 20, reason: 'v$oldVersion');
        expect(
          (await upgraded.rawQuery('PRAGMA foreign_keys')).single.values.single,
          1,
          reason: 'v$oldVersion',
        );
        expect(
          await upgraded.rawQuery('PRAGMA foreign_key_check'),
          isEmpty,
          reason: 'v$oldVersion',
        );
        expect(
          await upgraded.query('question_v2_payloads'),
          isEmpty,
          reason: 'v$oldVersion',
        );
        final questionIds = (await upgraded.query('questions'))
            .map((row) => row['id'] as String)
            .toList();
        expect(
          questionIds.where((id) => id.startsWith('r6b_v15_probe_parent_')),
          isEmpty,
          reason: 'v$oldVersion',
        );
        final sidecarSql = (await upgraded.rawQuery(
          "SELECT sql FROM sqlite_master WHERE type = 'table' "
          "AND name = 'question_v2_payloads'",
        ))
            .single['sql'] as String;
        expect(
          testCanonical(sidecarSql),
          testCanonical(_frozenSidecarDdl),
          reason: 'v$oldVersion',
        );
        expect(
          await snapshotStableRows(upgraded),
          stableBefore,
          reason: 'v$oldVersion',
        );

        final importColumns = await columnNames(upgraded, 'import_tasks');
        expect(importColumns.length, 16, reason: 'v$oldVersion');
        for (final column in <String>[
          'source_type',
          'pending_chunks',
          'failed_chunks',
          'warnings',
          'diagnostics',
        ]) {
          expect(importColumns, contains(column), reason: 'v$oldVersion');
        }
        expect(
          await columnNames(upgraded, 'questions'),
          contains('raw_explanation'),
          reason: 'v$oldVersion',
        );

        final rawExplanations = await upgraded.rawQuery(
          'SELECT raw_explanation FROM questions ORDER BY id',
        );
        if (oldVersion == 10) {
          expect(
            (await upgraded.query('ai_engines')).map((row) => row['id']),
            contains('engine_seed_1'),
            reason: 'v$oldVersion',
          );
          expect(
            await upgraded.query('import_tasks'),
            isEmpty,
            reason: 'v$oldVersion',
          );
          expect(
            rawExplanations.every((row) => row['raw_explanation'] == null),
            isTrue,
            reason: 'v$oldVersion',
          );
        } else if (oldVersion == 11 || oldVersion == 12) {
          expect(
            (await upgraded.query('ai_engines')).map((row) => row['id']),
            contains('engine_seed_1'),
            reason: 'v$oldVersion',
          );
          final task = (await upgraded.query('import_tasks')).single;
          expect(task['id'], 'task_seed_1', reason: 'v$oldVersion');
          expect(task['source_type'], 'pdf', reason: 'v$oldVersion');
          expect(task['pending_chunks'], '[]', reason: 'v$oldVersion');
          expect(task['failed_chunks'], '[]', reason: 'v$oldVersion');
          expect(task['warnings'], isNull, reason: 'v$oldVersion');
          expect(task['diagnostics'], isNull, reason: 'v$oldVersion');
          expect(
            rawExplanations.every((row) => row['raw_explanation'] == null),
            isTrue,
            reason: 'v$oldVersion',
          );
        } else if (oldVersion == 13) {
          final task = (await upgraded.query('import_tasks')).single;
          expect(task['id'], 'task_seed_1', reason: 'v$oldVersion');
          expect(task['warnings'], isNull, reason: 'v$oldVersion');
          expect(task['diagnostics'], isNull, reason: 'v$oldVersion');
          expect(
            rawExplanations.map((row) => row['raw_explanation']).toList(),
            <String?>['raw seed', null],
            reason: 'v$oldVersion',
          );
        } else {
          final task = (await upgraded.query('import_tasks')).single;
          expect(task['id'], 'task_seed_1', reason: 'v$oldVersion');
          expect(task['warnings'], '[]', reason: 'v$oldVersion');
          expect(task['diagnostics'], '[]', reason: 'v$oldVersion');
          expect(
            rawExplanations.map((row) => row['raw_explanation']).toList(),
            <String?>['raw seed', null],
            reason: 'v$oldVersion',
          );
        }
        await upgraded.close();
      }
    });

    test('existing exact sidecar is accepted idempotently with data intact',
        () async {
      final path = dbPath('idempotent.db');
      final created = await openSeam(path);
      await seedV1Data(created);
      await seedSidecarRows(created);
      final before = await snapshotTables(created);
      await setUserVersion(created, 14);
      await created.close();

      final upgraded = await openSeam(path);
      expect(await userVersion(upgraded), 20);
      expect(await snapshotTables(upgraded), before);
      await upgraded.close();

      // A second identical pass must also succeed.
      final second = await openRaw(path);
      await setUserVersion(second, 14);
      await second.close();
      final upgradedAgain = await openSeam(path);
      expect(await userVersion(upgradedAgain), 20);
      expect(await snapshotTables(upgradedAgain), before);
      await upgradedAgain.close();
    });
  });

  group('source version floor', () {
    test('versions below 10 are rejected before any mutation', () async {
      final path = dbPath('source_v9.db');
      final raw = await openRaw(path);
      await raw.execute('CREATE TABLE questions (id TEXT PRIMARY KEY)');
      await setUserVersion(raw, 9);
      await raw.close();

      await expectLater(
        openSeam(path),
        throwsA(
          isA<QuestionV2SchemaException>()
              .having(
                (e) => e.failure,
                'failure',
                QuestionV2SchemaFailure.unsupportedSourceVersion,
              )
              .having(
                (e) => e.toString(),
                'toString',
                fixedMessage(
                  QuestionV2SchemaFailure.unsupportedSourceVersion,
                ),
              ),
        ),
      );

      final probe = await openRaw(path);
      expect(await userVersion(probe), 9);
      expect(
        (await probe.rawQuery(
          "SELECT COUNT(*) AS c FROM sqlite_master "
          "WHERE name = 'question_v2_payloads'",
        ))
            .single['c'],
        0,
      );
      expect(
        (await probe.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name = 'questions'",
        ))
            .single['sql'],
        'CREATE TABLE questions (id TEXT PRIMARY KEY)',
      );
      await probe.close();
    });
  });

  group('malformed schema rejection', () {
    test('malformed sidecar fails safely and old rows stay untouched',
        () async {
      final path = dbPath('sidecar_extra_column.db');
      final created = await openSeam(path);
      await seedV1Data(created);
      await seedSidecarRows(created);
      final v1Before = await snapshotTables(created, tables: _v1Tables);
      await created.close();

      final raw = await openRaw(path);
      await raw.execute(
        'ALTER TABLE question_v2_payloads ADD COLUMN extra TEXT',
      );
      await setUserVersion(raw, 14);
      await raw.close();

      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );

      final probe = await openRaw(path);
      expect(await snapshotTables(probe, tables: _v1Tables), v1Before);
      final rows = await probe.rawQuery(
        'SELECT question_id, payload_schema_version, payload_json '
        'FROM question_v2_payloads ORDER BY question_id',
      );
      expect(rows.length, 2);
      expect(rows.first['question_id'], 'q_seed_1');
      expect(rows.first['payload_schema_version'], 2);
      expect(
          rows.first['payload_json'], '{"schemaVersion":2,"synthetic":true}');
      await probe.close();
    });

    test('missing sidecar check constraints are rejected', () async {
      final path = dbPath('sidecar_no_check.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL,
          payload_json TEXT NOT NULL,
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('over-strict sidecar checks are rejected', () async {
      final path = dbPath('sidecar_overstrict.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version = 2),
          payload_json TEXT NOT NULL CHECK(length(payload_json) > 1),
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('comment-spoof sidecar checks are rejected', () async {
      final path = dbPath('sidecar_comment_spoof.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          -- CHECK(payload_schema_version > 0)
          payload_schema_version INTEGER NOT NULL,
          payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('wrong FK action on the sidecar is rejected', () async {
      final path = dbPath('sidecar_wrong_action.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0),
          payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE SET NULL
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('sidecar FK referencing the wrong parent is rejected', () async {
      final path = dbPath('sidecar_wrong_parent.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0),
          payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
          FOREIGN KEY(question_id) REFERENCES review_states(id) ON DELETE CASCADE
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('sidecar missing the foreign key is rejected', () async {
      final path = dbPath('sidecar_no_fk.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0),
          payload_json TEXT NOT NULL CHECK(length(payload_json) > 0)
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('reordered sidecar columns are rejected', () async {
      final path = dbPath('sidecar_reordered.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0),
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('sidecar missing a required column is rejected', () async {
      final path = dbPath('sidecar_missing_column.db');
      final created = await openSeam(path);
      await created.close();
      await replaceSidecar(
        path,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0),
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });

    test('malformed parent questions table is rejected', () async {
      final path = dbPath('parent_missing_column.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('DROP TABLE questions');
      await raw.execute('''
        CREATE TABLE questions (
          id TEXT PRIMARY KEY NOT NULL,
          type INTEGER NOT NULL,
          content TEXT NOT NULL,
          options TEXT,
          standard_answer TEXT NOT NULL,
          explanation TEXT,
          raw_explanation TEXT,
          bank_name TEXT
        );
      ''');
      await setUserVersion(raw, 14);
      await raw.close();
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    });

    test('parent with nullable required columns is rejected', () async {
      final path = dbPath('parent_nullable.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('DROP TABLE questions');
      await raw.execute('''
        CREATE TABLE questions (
          id TEXT PRIMARY KEY NOT NULL,
          type INTEGER,
          content TEXT,
          options TEXT,
          standard_answer TEXT,
          explanation TEXT,
          raw_explanation TEXT,
          created_at INTEGER,
          bank_name TEXT
        );
      ''');
      await setUserVersion(raw, 14);
      await raw.close();
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    });

    test('missing bank_folders table is rejected', () async {
      final path = dbPath('bank_folders_missing.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('DROP TABLE bank_folders');
      await setUserVersion(raw, 14);
      await raw.close();
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    });

    test('bank_folders with a wrong default is rejected', () async {
      final path = dbPath('bank_folders_wrong_default.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('DROP TABLE bank_folders');
      await raw.execute('''
        CREATE TABLE bank_folders (
          bank_name TEXT PRIMARY KEY,
          folder_name TEXT NOT NULL DEFAULT 'wrong'
        );
      ''');
      await setUserVersion(raw, 14);
      await raw.close();
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    });

    test('bank_folders with extra columns is rejected', () async {
      final path = dbPath('bank_folders_extra.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('DROP TABLE bank_folders');
      await raw.execute('''
        CREATE TABLE bank_folders (
          bank_name TEXT PRIMARY KEY,
          folder_name TEXT NOT NULL DEFAULT '默认学科',
          extra TEXT
        );
      ''');
      await setUserVersion(raw, 14);
      await raw.close();
      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    });

    test('blocking sidecar trigger is rejected safely and retained', () async {
      final path = dbPath('sidecar_trigger.db');
      final created = await openSeam(path);
      await seedV1Data(created);
      await seedSidecarRows(created);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('''
        CREATE TRIGGER block_v2_insert BEFORE INSERT ON question_v2_payloads
        BEGIN SELECT RAISE(ABORT, 'probe_blocked'); END;
      ''');
      await setUserVersion(raw, 14);
      await raw.close();

      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );

      final probe = await openRaw(path);
      expect(
        (await probe.rawQuery(
          "SELECT COUNT(*) AS c FROM sqlite_master "
          "WHERE type = 'trigger' AND tbl_name = 'question_v2_payloads'",
        ))
            .single['c'],
        1,
      );
      expect((await probe.query('question_v2_payloads')).length, 2);
      final questionIds = (await probe.query('questions'))
          .map((row) => row['id'] as String)
          .toList();
      expect(questionIds.length, 2);
      expect(
        questionIds.where((id) => id.startsWith('r6b_v15_probe_parent_')),
        isEmpty,
      );
      await probe.close();
    });

    test('blocking questions trigger is rejected safely and retained',
        () async {
      final path = dbPath('questions_trigger.db');
      final created = await openSeam(path);
      await seedV1Data(created);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('''
        CREATE TRIGGER block_question_insert BEFORE INSERT ON questions
        BEGIN SELECT RAISE(ABORT, 'probe_blocked'); END;
      ''');
      await setUserVersion(raw, 14);
      await raw.close();

      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );

      final probe = await openRaw(path);
      expect(
        (await probe.rawQuery(
          "SELECT COUNT(*) AS c FROM sqlite_master "
          "WHERE type = 'trigger' AND tbl_name = 'questions'",
        ))
            .single['c'],
        1,
      );
      expect((await probe.query('questions')).length, 2);
      await probe.close();
    });
  });

  group('data integrity', () {
    test('foreign key violations fail the open safely', () async {
      final path = dbPath('fk_violation.db');
      final created = await openSeam(path);
      await seedV1Data(created);
      await created.close();

      final raw = await openRaw(path);
      await raw.insert('question_v2_payloads', <String, Object?>{
        'question_id': 'orphan_probe',
        'payload_schema_version': 2,
        'payload_json': '{"synthetic":true}',
      });
      await setUserVersion(raw, 14);
      await raw.close();

      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.foreignKeyViolation,
      );

      final probe = await openRaw(path);
      final orphan = await probe.query(
        'question_v2_payloads',
        where: 'question_id = ?',
        whereArgs: <Object?>['orphan_probe'],
      );
      expect(orphan.length, 1);
      expect(orphan.single['payload_json'], '{"synthetic":true}');
      await probe.close();
    });
  });

  group('production sidecar probes', () {
    test(
        'benign sidecar audit trigger is allowed, retained, and probe rows '
        'roll back', () async {
      final path = dbPath('benign_audit_trigger.db');
      final created = await openSeam(path);
      await seedV1Data(created);
      await seedSidecarRows(created);
      await created.close();

      final raw = await openRaw(path);
      await raw.execute('''
        CREATE TABLE sidecar_probe_audit (
          question_id TEXT NOT NULL,
          payload_schema_version INTEGER NOT NULL,
          payload_json TEXT NOT NULL
        )
      ''');
      await raw.execute('''
        CREATE TRIGGER audit_sidecar_insert AFTER INSERT ON question_v2_payloads
        BEGIN
          INSERT INTO sidecar_probe_audit(question_id, payload_schema_version, payload_json)
          VALUES (NEW.question_id, NEW.payload_schema_version, NEW.payload_json);
        END;
      ''');
      await setUserVersion(raw, 14);
      await raw.close();

      final upgraded = await openSeam(path);
      try {
        expect(await userVersion(upgraded), 20);
        expect(await upgraded.query('sidecar_probe_audit'), isEmpty);
        expect((await upgraded.query('question_v2_payloads')).length, 2);
        expect(
          (await upgraded.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' "
            "AND tbl_name = 'question_v2_payloads'",
          ))
              .map((row) => row['name'])
              .toList(),
          <String>['audit_sidecar_insert'],
        );
        final questionIds = (await upgraded.query('questions'))
            .map((row) => row['id'] as String)
            .toList();
        expect(
          questionIds.where((id) => id.startsWith('r6b_v15_probe_parent_')),
          isEmpty,
        );
      } finally {
        await upgraded.close();
      }
    });

    test('version-0 probe must fail via DatabaseException', () async {
      final path = dbPath('sidecar_ignore_v0.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('''
        CREATE TRIGGER ignore_v0 BEFORE INSERT ON question_v2_payloads
        WHEN NEW.payload_schema_version = 0
        BEGIN SELECT RAISE(IGNORE); END;
      ''');
      await setUserVersion(raw, 14);
      await raw.close();

      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );

      final probe = await openRaw(path);
      expect(
        (await probe.rawQuery(
          "SELECT COUNT(*) AS c FROM sqlite_master "
          "WHERE type = 'trigger' AND tbl_name = 'question_v2_payloads'",
        ))
            .single['c'],
        1,
      );
      await probe.close();
    });

    test('empty-payload probe must fail via DatabaseException', () async {
      final path = dbPath('sidecar_ignore_empty.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('''
        CREATE TRIGGER ignore_empty BEFORE INSERT ON question_v2_payloads
        WHEN NEW.payload_json = ''
        BEGIN SELECT RAISE(IGNORE); END;
      ''');
      await setUserVersion(raw, 14);
      await raw.close();

      await expectRejectedWithoutReplacement(
        path,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );

      final probe = await openRaw(path);
      expect(
        (await probe.rawQuery(
          "SELECT COUNT(*) AS c FROM sqlite_master "
          "WHERE type = 'trigger' AND tbl_name = 'question_v2_payloads'",
        ))
            .single['c'],
        1,
      );
      await probe.close();
    });

    test(
        'pre-existing trap suffixes stay untouched and the probe picks an '
        'absent candidate without residue', () async {
      final path = dbPath('probe_parent_traps.db');
      final created = await openSeam(path);
      for (final suffix in <String>['9', '10', 'abc', '1000001']) {
        await created.insert('questions', <String, Object?>{
          'id': 'r6b_v15_probe_parent_$suffix',
          'type': 0,
          'content': 'trap stem $suffix',
          'options': '["A","B"]',
          'standard_answer': 'A',
          'explanation': 'trap explanation $suffix',
          'raw_explanation': 'trap raw $suffix',
          'created_at': 1,
          'bank_name': 'r6b_v15_probe_trap_bank',
        });
      }
      await setUserVersion(created, 14);
      await created.close();

      final upgraded = await openSeam(path);
      try {
        expect(await userVersion(upgraded), 20);
        final trapIds = (await upgraded.rawQuery(
          "SELECT id FROM questions WHERE id LIKE 'r6b_v15_probe_parent_%'",
        ))
            .map((row) => row['id'] as String)
            .toSet();
        expect(
          trapIds,
          <String>{
            'r6b_v15_probe_parent_9',
            'r6b_v15_probe_parent_10',
            'r6b_v15_probe_parent_abc',
            'r6b_v15_probe_parent_1000001',
          },
        );
        expect(
          trapIds,
          isNot(contains('r6b_v15_probe_parent_1')),
        );
        expect(await upgraded.query('question_v2_payloads'), isEmpty);
      } finally {
        await upgraded.close();
      }
    });

    test('probe parent selection takes the first absent candidate', () async {
      final path = dbPath('probe_parent_gap.db');
      final created = await openSeam(path);
      for (final suffix in <int>[1, 3]) {
        await created.insert('questions', <String, Object?>{
          'id': 'r6b_v15_probe_parent_$suffix',
          'type': 0,
          'content': 'gap stem $suffix',
          'options': '["A","B"]',
          'standard_answer': 'A',
          'explanation': 'gap explanation $suffix',
          'raw_explanation': 'gap raw $suffix',
          'created_at': 1,
          'bank_name': 'r6b_v15_probe_gap_bank',
        });
      }
      await setUserVersion(created, 14);
      await created.close();

      final upgraded = await openSeam(path);
      try {
        expect(await userVersion(upgraded), 20);
        final ids = (await upgraded.rawQuery(
          "SELECT id FROM questions WHERE id LIKE 'r6b_v15_probe_parent_%'",
        ))
            .map((row) => row['id'] as String)
            .toSet();
        expect(
          ids,
          <String>{
            'r6b_v15_probe_parent_1',
            'r6b_v15_probe_parent_3',
          },
        );
        expect(await upgraded.query('question_v2_payloads'), isEmpty);
      } finally {
        await upgraded.close();
      }
    });

    test('probe lifecycle failures surface only the fixed schema exception',
        () async {
      final path = dbPath('probe_raw_leak.db');
      final created = await openSeam(path);
      await created.close();
      final raw = await openRaw(path);
      await raw.execute('''
        CREATE TRIGGER r6b_leak_probe BEFORE INSERT ON questions
        BEGIN SELECT RAISE(ABORT, 'r6b_raw_leak_marker'); END;
      ''');
      await setUserVersion(raw, 14);
      await raw.close();

      QuestionV2SchemaException? caught;
      try {
        await openSeam(path);
      } on QuestionV2SchemaException catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      expect(
        caught!.failure,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
      expect(
        caught.toString(),
        fixedMessage(QuestionV2SchemaFailure.malformedSidecarSchema),
      );
      expect(caught.toString(), isNot(contains('r6b_raw_leak_marker')));
      expect(caught.toString(), isNot(contains('DatabaseException')));
      expect(
        () => (caught as dynamic).cause,
        throwsA(isA<NoSuchMethodError>()),
      );
      expect(
        () => (caught as dynamic).message,
        throwsA(isA<NoSuchMethodError>()),
      );

      final probe = await openRaw(path);
      expect(await userVersion(probe), 14);
      await probe.close();
    });
  });

  group('whitespace canonicalization', () {
    test('operator-adjacent CHECK is accepted while >= stays rejected',
        () async {
      final acceptedPath = dbPath('sidecar_ws_adjacent.db');
      final created = await openSeam(acceptedPath);
      await created.close();
      await replaceSidecar(
        acceptedPath,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version>0),
          payload_json TEXT NOT NULL CHECK(length(payload_json)>0),
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        ''',
      );
      final upgraded = await openSeam(acceptedPath);
      try {
        expect(await userVersion(upgraded), 20);
        final sidecarSql = (await upgraded.rawQuery(
          "SELECT sql FROM sqlite_master WHERE type = 'table' "
          "AND name = 'question_v2_payloads'",
        ))
            .single['sql'] as String;
        expect(
          testCanonical(sidecarSql),
          testCanonical(_frozenSidecarDdl),
        );
        await upgraded.insert('questions', <String, Object?>{
          'id': 'q_ws',
          'type': 0,
          'content': 'ws stem',
          'standard_answer': 'A',
          'created_at': 1,
        });
        await upgraded.insert('question_v2_payloads', <String, Object?>{
          'question_id': 'q_ws',
          'payload_schema_version': 2,
          'payload_json': '{"synthetic":true}',
        });
      } finally {
        await upgraded.close();
      }

      final rejectedPath = dbPath('sidecar_ge.db');
      final rejectedBase = await openSeam(rejectedPath);
      await rejectedBase.close();
      await replaceSidecar(
        rejectedPath,
        '''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version >= 1),
          payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
          FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
        );
        ''',
      );
      await expectRejectedWithoutReplacement(
        rejectedPath,
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    });
  });

  group('exception contract', () {
    test('fixed safe messages for every schema failure', () {
      const expected = <QuestionV2SchemaFailure, String>{
        QuestionV2SchemaFailure.unsupportedSourceVersion:
            'QuestionV2SchemaException(unsupportedSourceVersion): '
                'The source database version is below the supported '
                'migration floor.',
        QuestionV2SchemaFailure.malformedParentSchema:
            'QuestionV2SchemaException(malformedParentSchema): '
                'The parent schema does not satisfy the frozen v15 '
                'requirements.',
        QuestionV2SchemaFailure.malformedSidecarSchema:
            'QuestionV2SchemaException(malformedSidecarSchema): '
                'The question_v2_payloads sidecar does not match the frozen '
                'definition.',
        QuestionV2SchemaFailure.foreignKeysDisabled:
            'QuestionV2SchemaException(foreignKeysDisabled): '
                'Foreign key enforcement is disabled on the opened connection.',
        QuestionV2SchemaFailure.foreignKeyViolation:
            'QuestionV2SchemaException(foreignKeyViolation): '
                'The database contains foreign key violations.',
      };
      for (final entry in expected.entries) {
        expect(
          QuestionV2SchemaException(entry.key).toString(),
          entry.value,
          reason: entry.key.name,
        );
      }
    });

    test('schema exception exposes no arbitrary message field', () {
      const error = QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
      expect(error.failure, QuestionV2SchemaFailure.malformedSidecarSchema);
      expect(
        () => (error as dynamic).message,
        throwsA(isA<NoSuchMethodError>()),
      );
    });
  });

  group('test seam and runtime profile', () {
    test('seam opens use production callbacks without singleton mutation',
        () async {
      DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.isolatedSmokeInMemory,
      );
      final path = dbPath('seam_isolated.db');
      final seamDb = await DatabaseHelper.instance.openPathForTesting(path);
      try {
        expect(await userVersion(seamDb), 20);
        expect(
          DatabaseHelper.runtimeProfile,
          DatabaseRuntimeProfile.isolatedSmokeInMemory,
        );
        expect(DatabaseHelper.openedDatabasePathForTesting, isNull);

        final singletonDb = await DatabaseHelper.instance.database;
        expect(
          DatabaseHelper.openedDatabasePathForTesting,
          inMemoryDatabasePath,
        );
        expect(await userVersion(singletonDb), 20);
      } finally {
        await seamDb.close();
        await DatabaseHelper.instance.close();
      }
    });
  });
}
