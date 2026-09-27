import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/answer_completion_v28_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

Future<void> _insertQuestion(
  Database db,
  String id,
  String? bankName,
) {
  return db.insert('questions', <String, Object?>{
    'id': id,
    'type': 0,
    'content': 'synthetic stem',
    'standard_answer': 'A',
    'created_at': 10,
    'bank_name': bankName,
  });
}

Future<void> _insertSet(
  Database db,
  String setId,
  String bankName, {
  String? sourceFileId,
}) {
  return db.insert(importedQuestionSetsTable, <String, Object?>{
    'set_id': setId,
    'bank_name': bankName,
    'display_name': 'synthetic.pdf',
    'created_at': 10,
    'source_file_id': sourceFileId,
  });
}

Future<void> _insertMember(
  Database db,
  String setId,
  String questionStorageId,
  int position,
) {
  return db.insert(importedQuestionSetItemsTable, <String, Object?>{
    'set_id': setId,
    'question_storage_id': questionStorageId,
    'position': position,
  });
}

Matcher _throwsSchemaFailure() =>
    throwsA(isA<AnswerCompletionSchemaException>().having(
      (exception) => exception.failure,
      'failure',
      AnswerCompletionSchemaFailure.malformedSchema,
    ));

Matcher _throwsFixedString(String fixedFailure) => throwsA(
      isA<DatabaseException>().having(
        (exception) => exception.toString(),
        'message',
        contains(fixedFailure),
      ),
    );

Future<int> _userVersion(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  return rows.single['user_version'] as int;
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
    tempDir = await Directory.systemTemp.createTemp('answer_comp_v28_');
  });

  tearDown(() async {
    await DatabaseHelper.instance.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String dbPath(String name) => p.join(tempDir.path, name);

  Future<Database> openSeam(String name) =>
      DatabaseHelper.instance.openPathForTesting(dbPath(name));

  Future<Database> openReadOnly(String name) => databaseFactory.openDatabase(
        dbPath(name),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );

  Future<int> rowCount(Database db, String table) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS total FROM $table');
    return rows.single['total']! as int;
  }

  test('fresh v28 exposes the frozen schema authority', () async {
    final db = await openSeam('fresh.db');
    try {
      expect(DatabaseHelper.databaseVersion, answerCompletionSchemaVersion);
      expect(DatabaseHelper.databaseVersion, 28);
      expect(await db.getVersion(), 28);

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        'AND name IN (?, ?)',
        <Object?>[importedQuestionSetsTable, importedQuestionSetItemsTable],
      );
      expect(tables, hasLength(2));

      final index = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
        <Object?>[importedQuestionSetBankIndex],
      );
      expect(index, hasLength(1));

      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' "
        'AND name LIKE ?',
        <Object?>['trg_answer_completion_%'],
      );
      expect(triggers, hasLength(6));

      await validateAnswerCompletionV28Schema(db);

      final foreignKeys = await db.rawQuery('PRAGMA foreign_keys');
      expect(foreignKeys.single.values.single, 1);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('v27 to v28 migration is additive and never backfills', () async {
    final path = dbPath('upgrade.db');
    final seed = await openSeam('upgrade.db');
    final frozen = const QuestionV2PersistenceMapper().freezeForWrite(
      storageId: _storageId,
      bankName: 'Math',
      createdAt: 10,
      draft: QuestionDraftV2(
        questionId: 'typed-1',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: <ContentNode>[TextNode('Synthetic question')]),
      ),
    );
    await seed.insert('questions', frozen.questionRow);
    await seed.insert('question_v2_payloads', frozen.payloadRow);
    await seed.insert('review_states', <String, Object?>{
      'question_id': _storageId,
      'state': 1,
    });
    await seed.insert('library_files', <String, Object?>{
      'file_id': 'file-1',
      'display_name': 'Synthetic file',
      'mime_type': 'text/plain',
      'size_bytes': 1,
      'sha256': 'a' * 64,
      'storage_key': 'files/file-1',
      'created_at': 10,
    });
    await seed.insert('import_tasks', <String, Object?>{
      'id': 'task-1',
      'title': 'Synthetic import',
      'status': 1,
      'progress_text': 'review',
      'percent': 1.0,
      'created_at': 10,
    });

    const preserved = <String>[
      'questions',
      'question_v2_payloads',
      'review_states',
      'library_files',
      'import_tasks',
    ];
    final before = <String, List<Map<String, Object?>>>{
      for (final table in preserved) table: await seed.query(table),
    };

    // Dropping a table drops its own triggers, so every drop stays guarded.
    for (final trigger in <String>[
      answerCompletionMemberInsertBankTrigger,
      answerCompletionMemberUpdateBankTrigger,
      answerCompletionQuestionBankDetachTrigger,
      answerCompletionMemberDeleteCleanupTrigger,
      answerCompletionMemberMoveCleanupTrigger,
      answerCompletionSetBankImmutableTrigger,
    ]) {
      await seed.execute('DROP TRIGGER IF EXISTS $trigger');
    }
    await seed.execute('DROP TABLE $importedQuestionSetItemsTable');
    await seed.execute('DROP TABLE $importedQuestionSetsTable');
    await seed.execute('DROP INDEX IF EXISTS $importedQuestionSetBankIndex');
    await seed.execute('PRAGMA user_version = 27');
    await seed.close();

    final migrated = await DatabaseHelper.instance.openPathForTesting(path);
    try {
      expect(await migrated.getVersion(), 28);
      await validateAnswerCompletionV28Schema(migrated);
      expect(await migrated.query(importedQuestionSetsTable), isEmpty);
      expect(await migrated.query(importedQuestionSetItemsTable), isEmpty);
      for (final table in preserved) {
        expect(await migrated.query(table), before[table], reason: table);
      }
    } finally {
      await migrated.close();
    }
  });

  test('a malformed pre-existing v28 object rolls back the migration',
      () async {
    final seed = await openSeam('rollback.db');
    await _insertQuestion(seed, 'q-keep', 'Math');
    await seed.insert('import_tasks', <String, Object?>{
      'id': 'task-keep',
      'title': 'Synthetic import',
      'status': 1,
      'progress_text': 'review',
      'percent': 1.0,
      'created_at': 10,
    });
    await seed.execute('DROP TABLE $importedQuestionSetItemsTable');
    await seed.execute('DROP TABLE $importedQuestionSetsTable');
    // A malformed pre-existing v28 object: the source_file_id column is gone.
    await seed.execute('''
      CREATE TABLE imported_question_sets (
        set_id TEXT PRIMARY KEY NOT NULL,
        bank_name TEXT NOT NULL,
        display_name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await seed.execute('PRAGMA user_version = 27');
    await seed.close();

    await expectLater(openSeam('rollback.db'), _throwsSchemaFailure());

    final probe = await openReadOnly('rollback.db');
    try {
      expect(await _userVersion(probe), 27);
      expect(
        await probe.query('questions',
            where: 'id = ?', whereArgs: <Object?>['q-keep']),
        hasLength(1),
      );
      expect(
        await probe.query('import_tasks',
            where: 'id = ?', whereArgs: <Object?>['task-keep']),
        hasLength(1),
      );
      final items = await probe.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        <Object?>[importedQuestionSetItemsTable],
      );
      expect(items, isEmpty);
      final triggers = await probe.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?",
        <Object?>[answerCompletionMemberInsertBankTrigger],
      );
      expect(triggers, isEmpty);
    } finally {
      await probe.close();
    }
  });

  test('same-bank membership inserts', () async {
    final db = await openSeam('same_bank.db');
    try {
      await _insertQuestion(db, 'q-math', 'Math');
      await _insertSet(db, 'set-a', 'Math');

      await _insertMember(db, 'set-a', 'q-math', 0);

      expect(await rowCount(db, importedQuestionSetsTable), 1);
      expect(await rowCount(db, importedQuestionSetItemsTable), 1);
    } finally {
      await db.close();
    }
  });

  test('cross-bank INSERT is rejected by the fixed trigger', () async {
    final db = await openSeam('cross_insert.db');
    try {
      await _insertQuestion(db, 'q-phys', 'Physics');
      await _insertSet(db, 'set-math', 'Math');

      await expectLater(
        _insertMember(db, 'set-math', 'q-phys', 0),
        _throwsFixedString(answerCompletionCrossBankMembershipFailure),
      );
      expect(await rowCount(db, importedQuestionSetItemsTable), 0);
    } finally {
      await db.close();
    }
  });

  test('cross-bank UPDATE is rejected by the fixed trigger', () async {
    final db = await openSeam('cross_update.db');
    try {
      await _insertQuestion(db, 'q-math', 'Math');
      await _insertQuestion(db, 'q-phys', 'Physics');
      await _insertSet(db, 'set-math', 'Math');
      await _insertSet(db, 'set-phys', 'Physics');
      await _insertMember(db, 'set-math', 'q-math', 0);

      await expectLater(
        db.execute(
          'UPDATE $importedQuestionSetItemsTable SET set_id = ? '
          'WHERE set_id = ?',
          <Object?>['set-phys', 'set-math'],
        ),
        _throwsFixedString(answerCompletionCrossBankMembershipFailure),
      );
      await expectLater(
        db.execute(
          'UPDATE $importedQuestionSetItemsTable SET question_storage_id = ? '
          'WHERE question_storage_id = ?',
          <Object?>['q-phys', 'q-math'],
        ),
        _throwsFixedString(answerCompletionCrossBankMembershipFailure),
      );
      final member = (await db.query(importedQuestionSetItemsTable)).single;
      expect(member['set_id'], 'set-math');
      expect(member['question_storage_id'], 'q-math');
    } finally {
      await db.close();
    }
  });

  test('one question belongs to at most one set', () async {
    final db = await openSeam('unique_question.db');
    try {
      await _insertQuestion(db, 'q-shared', 'Math');
      await _insertSet(db, 'set-a', 'Math');
      await _insertSet(db, 'set-b', 'Math');
      await _insertMember(db, 'set-a', 'q-shared', 0);

      await expectLater(
        _insertMember(db, 'set-b', 'q-shared', 0),
        throwsA(isA<DatabaseException>()),
      );
      expect(await rowCount(db, importedQuestionSetItemsTable), 1);
    } finally {
      await db.close();
    }
  });

  test('one position per set', () async {
    final db = await openSeam('unique_position.db');
    try {
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertQuestion(db, 'q-2', 'Math');
      await _insertSet(db, 'set-a', 'Math');
      await _insertMember(db, 'set-a', 'q-1', 0);

      await expectLater(
        _insertMember(db, 'set-a', 'q-2', 0),
        throwsA(isA<DatabaseException>()),
      );
      expect(await rowCount(db, importedQuestionSetItemsTable), 1);
    } finally {
      await db.close();
    }
  });

  test('position must be non-negative', () async {
    final db = await openSeam('position_check.db');
    try {
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertSet(db, 'set-a', 'Math');

      await expectLater(
        _insertMember(db, 'set-a', 'q-1', -1),
        throwsA(isA<DatabaseException>()),
      );
      await _insertMember(db, 'set-a', 'q-1', 0);
      expect(await rowCount(db, importedQuestionSetItemsTable), 1);
    } finally {
      await db.close();
    }
  });

  test('set bank_name is immutable while same-value updates stay legal',
      () async {
    final db = await openSeam('immutable_bank.db');
    try {
      await _insertSet(db, 'set-a', 'Math');

      await expectLater(
        db.execute(
          'UPDATE $importedQuestionSetsTable SET bank_name = ? WHERE set_id = ?',
          <Object?>['Physics', 'set-a'],
        ),
        _throwsFixedString(answerCompletionSetBankImmutableFailure),
      );

      await db.execute(
        'UPDATE $importedQuestionSetsTable SET bank_name = ? WHERE set_id = ?',
        <Object?>['Math', 'set-a'],
      );
      final row = (await db.query(importedQuestionSetsTable)).single;
      expect(row['bank_name'], 'Math');
    } finally {
      await db.close();
    }
  });

  test('a question bank move detaches membership without re-attaching',
      () async {
    final db = await openSeam('bank_move.db');
    try {
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertQuestion(db, 'q-2', 'Math');
      await _insertSet(db, 'set-a', 'Math');
      await _insertMember(db, 'set-a', 'q-1', 0);
      await _insertMember(db, 'set-a', 'q-2', 1);

      await db.execute(
        'UPDATE questions SET bank_name = ? WHERE id = ?',
        <Object?>['Physics', 'q-1'],
      );
      expect(
        (await db.query(importedQuestionSetItemsTable))
            .single['question_storage_id'],
        'q-2',
      );
      expect(await rowCount(db, importedQuestionSetsTable), 1);

      await db.execute(
        'UPDATE questions SET bank_name = ? WHERE id = ?',
        <Object?>['Physics', 'q-2'],
      );
      expect(await rowCount(db, importedQuestionSetItemsTable), 0);
      expect(await rowCount(db, importedQuestionSetsTable), 0);
    } finally {
      await db.close();
    }
  });

  test('removing the last member deletes the empty set', () async {
    final db = await openSeam('last_member.db');
    try {
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertSet(db, 'set-a', 'Math');
      await _insertMember(db, 'set-a', 'q-1', 0);

      await db.execute(
        'DELETE FROM $importedQuestionSetItemsTable WHERE set_id = ?',
        <Object?>['set-a'],
      );

      expect(await rowCount(db, importedQuestionSetItemsTable), 0);
      expect(await rowCount(db, importedQuestionSetsTable), 0);
      expect(await rowCount(db, 'questions'), 1);
    } finally {
      await db.close();
    }
  });

  test('moving a membership clears the former empty set', () async {
    final db = await openSeam('member_move.db');
    try {
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertQuestion(db, 'q-2', 'Math');
      await _insertSet(db, 'set-a', 'Math');
      await _insertSet(db, 'set-b', 'Math');
      await _insertMember(db, 'set-a', 'q-1', 0);
      await _insertMember(db, 'set-b', 'q-2', 1);

      await db.execute(
        'UPDATE $importedQuestionSetItemsTable SET set_id = ? WHERE set_id = ?',
        <Object?>['set-b', 'set-a'],
      );

      final sets = await db.query(importedQuestionSetsTable);
      expect(sets.map((row) => row['set_id']), <Object?>['set-b']);
      final members = await db.query(
        importedQuestionSetItemsTable,
        orderBy: 'position',
      );
      expect(members.map((row) => row['set_id']), <Object?>['set-b', 'set-b']);
      expect(
        members.map((row) => row['question_storage_id']),
        <Object?>['q-1', 'q-2'],
      );
    } finally {
      await db.close();
    }
  });

  test('question deletion cascades membership and clears the empty set',
      () async {
    final db = await openSeam('question_delete.db');
    try {
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertSet(db, 'set-a', 'Math');
      await _insertMember(db, 'set-a', 'q-1', 0);

      await db.execute('DELETE FROM questions WHERE id = ?', <Object?>['q-1']);

      expect(await rowCount(db, 'questions'), 0);
      expect(await rowCount(db, importedQuestionSetItemsTable), 0);
      expect(await rowCount(db, importedQuestionSetsTable), 0);
    } finally {
      await db.close();
    }
  });

  test('set deletion cascades memberships and preserves questions', () async {
    final db = await openSeam('set_delete.db');
    try {
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertQuestion(db, 'q-2', 'Math');
      await _insertSet(db, 'set-a', 'Math');
      await _insertMember(db, 'set-a', 'q-1', 0);
      await _insertMember(db, 'set-a', 'q-2', 1);

      await db.execute(
        'DELETE FROM $importedQuestionSetsTable WHERE set_id = ?',
        <Object?>['set-a'],
      );

      expect(await rowCount(db, importedQuestionSetItemsTable), 0);
      expect(await rowCount(db, 'questions'), 2);
    } finally {
      await db.close();
    }
  });

  test('library file deletion preserves the set', () async {
    final db = await openSeam('soft_provenance.db');
    try {
      await db.insert('library_files', <String, Object?>{
        'file_id': 'file-1',
        'display_name': 'Synthetic file',
        'mime_type': 'text/plain',
        'size_bytes': 1,
        'sha256': 'a' * 64,
        'storage_key': 'files/file-1',
        'created_at': 10,
      });
      await _insertQuestion(db, 'q-1', 'Math');
      await _insertSet(db, 'set-a', 'Math', sourceFileId: 'file-1');
      await _insertMember(db, 'set-a', 'q-1', 0);

      await db.execute(
        'DELETE FROM library_files WHERE file_id = ?',
        <Object?>['file-1'],
      );

      expect(await rowCount(db, importedQuestionSetsTable), 1);
      expect(await rowCount(db, importedQuestionSetItemsTable), 1);
      expect(await rowCount(db, 'questions'), 1);
      final foreignKeys = await db.rawQuery(
        'PRAGMA foreign_key_list($importedQuestionSetsTable)',
      );
      expect(foreignKeys, isEmpty);
    } finally {
      await db.close();
    }
  });

  test('an empty set is legal as an intermediate state', () async {
    final db = await openSeam('empty_intermediate.db');
    try {
      await _insertSet(db, 'set-pending', 'Math');

      expect(await rowCount(db, importedQuestionSetsTable), 1);
      await db.execute(
        'DELETE FROM $importedQuestionSetsTable WHERE set_id = ?',
        <Object?>['set-pending'],
      );
      expect(await rowCount(db, importedQuestionSetsTable), 0);
    } finally {
      await db.close();
    }
  });

  test('validator rejects a missing bank index', () async {
    final db = await openSeam('corrupt_index.db');
    try {
      await db.execute('DROP INDEX $importedQuestionSetBankIndex');
      await expectLater(
          validateAnswerCompletionV28Schema(db), _throwsSchemaFailure());
    } finally {
      await db.close();
    }
  });

  test('validator rejects a dropped required trigger', () async {
    final db = await openSeam('corrupt_trigger.db');
    try {
      await db.execute(
        'DROP TRIGGER $answerCompletionMemberDeleteCleanupTrigger',
      );
      await expectLater(
          validateAnswerCompletionV28Schema(db), _throwsSchemaFailure());
    } finally {
      await db.close();
    }
  });

  test('validator rejects a weakened required trigger', () async {
    final db = await openSeam('weakened_trigger.db');
    try {
      await db.execute(
        'DROP TRIGGER $answerCompletionMemberInsertBankTrigger',
      );
      await db.execute('''
        CREATE TRIGGER trg_answer_completion_member_insert_bank
        AFTER INSERT ON imported_question_set_items
        BEGIN
          SELECT 1;
        END;
      ''');
      await expectLater(
          validateAnswerCompletionV28Schema(db), _throwsSchemaFailure());
    } finally {
      await db.close();
    }
  });

  test('validator rejects a renamed column', () async {
    final db = await openSeam('renamed_column.db');
    try {
      await db.execute(
        'ALTER TABLE $importedQuestionSetItemsTable '
        'RENAME COLUMN position TO renamed_position',
      );
      await expectLater(
          validateAnswerCompletionV28Schema(db), _throwsSchemaFailure());
    } finally {
      await db.close();
    }
  });

  test('validator rejects a removed cascade and a removed unique shape',
      () async {
    final removedCascade = await openSeam('no_cascade.db');
    try {
      await removedCascade.execute('DROP TABLE $importedQuestionSetItemsTable');
      await removedCascade.execute('''
        CREATE TABLE imported_question_set_items (
          set_id TEXT NOT NULL,
          question_storage_id TEXT NOT NULL,
          position INTEGER NOT NULL CHECK(position >= 0),
          PRIMARY KEY(set_id, question_storage_id),
          UNIQUE(question_storage_id),
          UNIQUE(set_id, position),
          FOREIGN KEY(set_id) REFERENCES imported_question_sets(set_id),
          FOREIGN KEY(question_storage_id) REFERENCES questions(id)
        );
      ''');
      await expectLater(
        validateAnswerCompletionV28Schema(removedCascade),
        _throwsSchemaFailure(),
      );
    } finally {
      await removedCascade.close();
    }

    final removedUnique = await openSeam('no_unique.db');
    try {
      await removedUnique.execute('DROP TABLE $importedQuestionSetItemsTable');
      await removedUnique.execute('''
        CREATE TABLE imported_question_set_items (
          set_id TEXT NOT NULL,
          question_storage_id TEXT NOT NULL,
          position INTEGER NOT NULL CHECK(position >= 0),
          PRIMARY KEY(set_id, question_storage_id),
          UNIQUE(set_id, position),
          FOREIGN KEY(set_id) REFERENCES imported_question_sets(set_id)
            ON DELETE CASCADE,
          FOREIGN KEY(question_storage_id) REFERENCES questions(id)
            ON DELETE CASCADE
        );
      ''');
      await expectLater(
        validateAnswerCompletionV28Schema(removedUnique),
        _throwsSchemaFailure(),
      );
    } finally {
      await removedUnique.close();
    }
  });
}
