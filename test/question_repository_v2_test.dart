// R6C repository atomic V2 persistence/read/mutation guard acceptance.
//
// All databases in this file are synthetic: sqflite FFI in-memory singleton
// handles for the repository APIs and temp-file handles opened only through
// the frozen DatabaseHelper.openPathForTesting seam for close/reopen
// evidence. No real application database, private document, OCR, Replay,
// Provider, or network path is touched. Payload and folder failures are
// induced with synthetic rollback-only triggers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/latex_migration_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'synthetic_bank';
const _globalWrongBookBankName = '🔥 全局错题本';
const _storageIdA = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _storageIdB = 'b4f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

final _canonicalUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
  r'[0-9a-f]{12}$',
);

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _draft(
  String questionId, {
  String stem = 'Synthetic stem text.',
  QuestionKind kind = QuestionKind.singleChoice,
  bool withOptions = true,
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: kind,
    stem: _text(stem),
    options: withOptions
        ? <QuestionOption>[
            QuestionOption(
              optionId: 'A',
              label: '甲',
              content: _text('first'),
            ),
            QuestionOption(
              optionId: 'B',
              label: '乙',
              content: _text('second'),
            ),
          ]
        : const <QuestionOption>[],
    answer: withOptions
        ? ChoiceAnswer(optionIds: <String>['A'])
        : ContentAnswer(content: _text('answer text')),
    explanation: _text('Synthetic explanation.'),
  );
}

Future<Database> _singletonDb() => DatabaseHelper.instance.database;

Future<void> _insertTypedRow(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
  required int createdAt,
  String bank = _bankName,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: bank,
    createdAt: createdAt,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
}

Future<void> _insertLegacyRow(
  Database db, {
  required String id,
  required int createdAt,
  String bank = _bankName,
  String content = 'Legacy stem text.',
  int type = 3,
  String options = '[]',
  String? explanation = 'Legacy explanation.',
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': type,
    'content': content,
    'options': options,
    'standard_answer': 'Legacy answer|||$explanation',
    'explanation': explanation,
    'raw_explanation': 'Legacy raw explanation.',
    'created_at': createdAt,
    'bank_name': bank,
  });
}

Future<void> _insertReviewState(
  Database db, {
  required String questionId,
  required int lapses,
  required int lastLapseTime,
}) async {
  await db.insert('review_states', <String, Object?>{
    'question_id': questionId,
    'state': 0,
    'next_review_time': 0,
    'lapses': lapses,
    'difficulty': 5.0,
    'stability': 0.0,
    'reps': 0,
    'last_lapse_time': lastLapseTime,
    'last_review_time': 0,
  });
}

TypedImportCommitGuard _importGuard({
  String taskId = 'import-task',
  String token = 'attempt-A',
  int number = 1,
  int revision = 1,
}) {
  return TypedImportCommitGuard(
    taskId: taskId,
    attemptToken: token,
    attemptNumber: number,
    reviewDraftRevision: revision,
    storageRoute: TypedImportCommitPersistence.typedV2RouteValue,
    storageReason: TypedImportCommitPersistence.typedCandidateReadyReasonValue,
  );
}

Map<String, Object?> _importDiagnostics({
  String token = 'attempt-A',
  int number = 1,
  int revision = 1,
  String route = 'typedV2',
  String? reason = 'typed_candidate_ready',
  String attemptState = 'readyForReview',
}) {
  return <String, Object?>{
    TypedImportCommitPersistence.keyAttemptToken: token,
    TypedImportCommitPersistence.keyAttemptNumber: number,
    TypedImportCommitPersistence.keyAttemptState: attemptState,
    TypedImportCommitPersistence.keyImportStorageRoute: route,
    if (reason != null)
      TypedImportCommitPersistence.keyImportStorageReason: reason,
    TypedImportCommitPersistence.keyReviewDraftRevision: revision,
  };
}

Future<void> _insertImportTask(
  Database db, {
  String id = 'import-task',
  int status = 1,
  String? parsedData = '[{"q_num":1}]',
  Map<String, Object?>? diagnostics,
  String? diagnosticsJson,
}) async {
  await db.insert(
    'import_tasks',
    <String, Object?>{
      'id': id,
      'title': 'Synthetic typed import',
      'status': status,
      'progress_text': 'Ready for review',
      'percent': 1.0,
      'error_msg': null,
      'parsed_data': parsedData,
      'bank_name': _bankName,
      'folder_name': 'Math',
      'created_at': 1700000000,
      'completed_at': null,
      'source_type': 'vision',
      'warnings': null,
      'diagnostics':
          diagnosticsJson ?? jsonEncode(diagnostics ?? _importDiagnostics()),
    },
  );
}

Future<List<Map<String, Object?>>> _importTaskRows(Database db) {
  return db.query('import_tasks');
}

String _unsafePayloadJson() {
  return jsonEncode(<String, Object?>{
    'schemaVersion': 2,
    'questionId': 'unsafe_question',
    'questionNumber': null,
    'kind': 'short_answer',
    'stem': <String, Object?>{
      'schemaVersion': 1,
      'nodes': <Object?>[
        <String, Object?>{
          'type': 'future_diagram',
          'providerResponse': <String, Object?>{'status': 'synthetic'},
        },
      ],
    },
    'options': <Object?>[],
    'answer': null,
    'explanation': null,
    'sourceRefs': <Object?>[],
    'assetRefs': <Object?>[],
    'issues': <Object?>[],
  });
}

class _CommitTrackingRepository extends Fake implements QuestionRepository {
  var v1SaveCalls = 0;
  var v2SaveCalls = 0;

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    v1SaveCalls++;
  }

  @override
  Future<void> saveQuestionDraftsV2ToBank({
    required String bankName,
    String? folderName,
    required List<QuestionDraftV2> questions,
  }) async {
    v2SaveCalls++;
  }
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
    tempDir = await Directory.systemTemp.createTemp('r6c_repository_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('typed save atomic batch', () {
    test('writes parent, sidecar, and initial review state for every draft',
        () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: '  $_bankName  ',
        folderName: null,
        questions: [_draft('question_001')],
      );

      final db = await _singletonDb();
      final questions = await db.query('questions');
      expect(questions, hasLength(1));
      final id = questions.single['id'] as String;
      expect(_canonicalUuidPattern.hasMatch(id), isTrue);
      expect(questions.single['bank_name'], _bankName);
      expect(questions.single['type'], 0);
      expect(questions.single['content'], 'Synthetic stem text.');
      expect(questions.single['options'], isNot(isEmpty));
      expect(questions.single['standard_answer'], isNot(isEmpty));
      expect(questions.single['created_at'], isA<int>());
      expect(questions.single['id'], isNot('question_001'));

      final payloads = await db.query('question_v2_payloads');
      expect(payloads, hasLength(1));
      expect(payloads.single['question_id'], id);
      expect(payloads.single['payload_schema_version'], 2);
      final payloadRoot = jsonDecode(payloads.single['payload_json']! as String)
          as Map<String, dynamic>;
      expect(payloadRoot['schemaVersion'], 2);
      expect(payloadRoot['questionId'], 'question_001');

      final states = await db.query('review_states');
      expect(states, hasLength(1));
      expect(states.single['question_id'], id);
      expect(states.single['state'], 0);
      expect(states.single['lapses'], 0);
    });

    test('upserts an explicit trimmed folder mapping in the same transaction',
        () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: '  Math  ',
        questions: [_draft('question_folder')],
      );

      final db = await _singletonDb();
      var mappings = await db.query('bank_folders');
      expect(mappings, hasLength(1));
      expect(mappings.single['bank_name'], _bankName);
      expect(mappings.single['folder_name'], 'Math');

      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: 'Physics',
        questions: [_draft('question_folder_2')],
      );
      mappings = await db.query('bank_folders');
      expect(mappings, hasLength(1));
      expect(mappings.single['folder_name'], 'Physics');
    });

    test('maps a matching custom folder to the bank name', () async {
      final db = await _singletonDb();
      await db.execute('CREATE TABLE custom_folders (name TEXT PRIMARY KEY)');
      await db.insert('custom_folders', <String, Object?>{'name': _bankName});

      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [_draft('question_custom_folder')],
      );

      final mappings = await db.query('bank_folders');
      expect(mappings, hasLength(1));
      expect(mappings.single['bank_name'], _bankName);
      expect(mappings.single['folder_name'], _bankName);
    });

    test('maps a bank_folders folder that already uses the bank name',
        () async {
      final db = await _singletonDb();
      await db.insert('bank_folders', <String, Object?>{
        'bank_name': 'other_bank',
        'folder_name': _bankName,
      });

      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [_draft('question_mapped_folder')],
      );

      final mappings = await db.query('bank_folders', orderBy: 'bank_name');
      expect(mappings, hasLength(2));
      final selfMapping =
          mappings.singleWhere((row) => row['bank_name'] == _bankName);
      expect(selfMapping['folder_name'], _bankName);
    });

    test('leaves bank_folders untouched when no folder matches', () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [_draft('question_no_folder')],
      );

      final db = await _singletonDb();
      expect(await db.query('bank_folders'), isEmpty);
      expect(await db.query('questions'), hasLength(1));
    });

    test('never creates a missing custom_folders table', () async {
      final db = await _singletonDb();
      // A fresh v15 database has no custom_folders table; it is created only
      // lazily by the legacy subject-tree path.
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'custom_folders'",
        ),
        isEmpty,
      );

      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [_draft('question_missing_custom')],
      );

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'custom_folders'",
      );
      expect(tables, isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
      expect(await db.query('questions'), hasLength(1));
    });

    test(
        'folder-decision reads run inside the transaction: a folder read '
        'failure maps to the fixed write exception with zero writes', () async {
      final db = await _singletonDb();
      // A real custom_folders table without a matching bank forces the lazy
      // resolver to read bank_folders. Dropping bank_folders makes that read
      // fail inside the transaction, so the failure must surface through the
      // same atomic rollback/mapping boundary as the write itself rather than
      // leaking a raw DatabaseException.
      await db.execute('CREATE TABLE custom_folders (name TEXT PRIMARY KEY)');
      await db.insert('custom_folders', <String, Object?>{'name': 'other'});
      await db.execute('DROP TABLE bank_folders');

      final repository = QuestionRepository();
      await expectLater(
        repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: null,
          questions: [_draft('question_transaction_read')],
        ),
        throwsA(
          isA<QuestionV2WriteException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2WriteFailure.transactionFailed,
          ),
        ),
      );

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
    });

    test('empty batch returns before any DB write or folder change', () async {
      final db = await _singletonDb();
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'custom_folders'",
        ),
        isEmpty,
      );

      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: 'ShouldNotWrite',
        questions: const <QuestionDraftV2>[],
      );

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'custom_folders'",
      );
      expect(tables, isEmpty);
    });

    test('rejects empty bank names before any DB write', () async {
      final db = await _singletonDb();
      final repository = QuestionRepository();

      await expectLater(
        repository.saveQuestionDraftsV2ToBank(
          bankName: '   ',
          folderName: null,
          questions: [_draft('question_empty_bank')],
        ),
        throwsArgumentError,
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
    });

    test(
        'uses one shared timestamp and canonical distinct storage ids for '
        'duplicate draft ids', () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [
          _draft('duplicate_question'),
          _draft('duplicate_question'),
        ],
      );

      final db = await _singletonDb();
      final questions = await db.query('questions', orderBy: 'rowid');
      expect(questions, hasLength(2));
      final ids = questions.map((row) => row['id'] as String).toList();
      expect(ids[0], isNot(ids[1]));
      for (final id in ids) {
        expect(_canonicalUuidPattern.hasMatch(id), isTrue);
        expect(id, isNot('duplicate_question'));
      }
      expect(questions[0]['created_at'], questions[1]['created_at']);

      final decoded = await repository.getPersistedQuestionsByBank(_bankName);
      expect(decoded, hasLength(2));
      final typed = decoded.cast<TypedPersistedQuestion>();
      expect(typed[0].storageId, isNot(typed[1].storageId));
      expect(typed[0].createdAt, typed[1].createdAt);
      expect(typed[0].draft.questionId, 'duplicate_question');
      expect(typed[0].draft, typed[1].draft);
    });

    test('second sidecar insert failure rolls back the entire batch', () async {
      final db = await _singletonDb();
      await db.execute('''
        CREATE TRIGGER r6c_block_second_payload
        BEFORE INSERT ON question_v2_payloads
        WHEN (SELECT COUNT(*) FROM question_v2_payloads) >= 1
        BEGIN SELECT RAISE(ABORT, 'r6c_synthetic_second_payload_failure'); END;
      ''');

      final repository = QuestionRepository();
      await expectLater(
        repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: null,
          questions: [
            _draft('question_rollback_1'),
            _draft('question_rollback_2')
          ],
        ),
        throwsA(
          isA<QuestionV2WriteException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2WriteFailure.transactionFailed,
          ),
        ),
      );

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
    });

    test('folder upsert failure rolls back parents, sidecars, and states',
        () async {
      final db = await _singletonDb();
      await db.execute('''
        CREATE TRIGGER r6c_block_folder
        BEFORE INSERT ON bank_folders
        BEGIN SELECT RAISE(ABORT, 'r6c_synthetic_folder_failure'); END;
      ''');

      final repository = QuestionRepository();
      await expectLater(
        repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: 'Math',
          questions: [_draft('question_folder_rollback')],
        ),
        throwsA(isA<QuestionV2WriteException>()),
      );

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
    });

    test('write exception renders fixed safe text and leaks nothing', () async {
      final db = await _singletonDb();
      await db.execute('''
        CREATE TRIGGER r6c_block_folder
        BEFORE INSERT ON bank_folders
        BEGIN SELECT RAISE(ABORT, 'r6c_synthetic_folder_failure'); END;
      ''');

      final repository = QuestionRepository();
      QuestionV2WriteException? caught;
      try {
        await repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: 'Math',
          questions: [_draft('question_fixed_error')],
        );
      } on QuestionV2WriteException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.failure, QuestionV2WriteFailure.transactionFailed);
      expect(
        caught.toString(),
        'QuestionV2WriteException(transactionFailed): '
        'The typed question batch cannot be written atomically.',
      );
      expect(
          caught.toString(), isNot(contains('r6c_synthetic_folder_failure')));
      expect(caught.toString(), isNot(contains(_bankName)));
      expect(caught.toString(), isNot(contains('Math')));
      expect(caught.toString(), isNot(contains('question_fixed_error')));
      expect(
        () => (caught as dynamic).cause,
        throwsA(isA<NoSuchMethodError>()),
      );
      expect(
        () => (caught as dynamic).message,
        throwsA(isA<NoSuchMethodError>()),
      );
    });
  });

  group('typed read', () {
    test('decodes typed rows structurally with a trimmed bank name', () async {
      final draft = _draft('question_read');
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [draft],
      );

      final decoded = await repository.getPersistedQuestionsByBank(_bankName);
      expect(decoded, hasLength(1));
      final typed = decoded.single as TypedPersistedQuestion;
      expect(_canonicalUuidPattern.hasMatch(typed.storageId), isTrue);
      expect(typed.bankName, _bankName);
      expect(typed.createdAt, greaterThan(0));
      expect(typed.draft, draft);
      expect(typed.draft.hashCode, draft.hashCode);
    });

    test('orders a normal bank by created_at descending', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draft('order_low'),
          storageId: _storageIdA, createdAt: 100);
      await _insertTypedRow(db, _draft('order_high'),
          storageId: _storageIdB, createdAt: 300);
      await _insertTypedRow(
        db,
        _draft('order_mid'),
        storageId: 'c3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        createdAt: 200,
      );

      final decoded =
          await QuestionRepository().getPersistedQuestionsByBank(_bankName);
      expect(
        decoded.map((question) => question.createdAt).toList(),
        <int>[300, 200, 100],
      );
    });

    test('global wrong book returns only lapsed rows by last lapse time',
        () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draft('wrong_typed'),
          storageId: _storageIdA, createdAt: 100);
      await _insertReviewState(db,
          questionId: _storageIdA, lapses: 2, lastLapseTime: 500);
      await _insertLegacyRow(db, id: 'legacy_lapsed', createdAt: 200);
      await _insertReviewState(db,
          questionId: 'legacy_lapsed', lapses: 1, lastLapseTime: 900);
      await _insertTypedRow(db, _draft('not_lapsed'),
          storageId: _storageIdB, createdAt: 300);
      await _insertReviewState(db,
          questionId: _storageIdB, lapses: 0, lastLapseTime: 1000);

      final repository = QuestionRepository();
      final decoded = await repository
          .getPersistedQuestionsByBank(_globalWrongBookBankName);
      expect(decoded, hasLength(2));
      expect(decoded[0].storageId, 'legacy_lapsed');
      expect(decoded[0], isA<LegacyPersistedQuestion>());
      expect(decoded[1].storageId, _storageIdA);
      expect(decoded[1], isA<TypedPersistedQuestion>());

      final bankRows = await repository.getPersistedQuestionsByBank(_bankName);
      expect(bankRows, hasLength(3));
      expect(
        bankRows.map((question) => question.storageId).toList(),
        <String>[_storageIdB, 'legacy_lapsed', _storageIdA],
      );
    });

    test('legacy rows without a sidecar fall back to the legacy question',
        () async {
      final db = await _singletonDb();
      await _insertLegacyRow(db, id: 'legacy_fallback', createdAt: 42);

      final decoded =
          await QuestionRepository().getPersistedQuestionsByBank(_bankName);
      final legacy = decoded.single as LegacyPersistedQuestion;
      expect(legacy.storageId, 'legacy_fallback');
      expect(legacy.bankName, _bankName);
      expect(legacy.createdAt, 42);
      expect(legacy.question.id, 'legacy_fallback');
      expect(legacy.question.answer, 'Legacy answer');
      expect(legacy.question.explanation, 'Legacy explanation.');
      expect(legacy.question.rawExplanation, 'Legacy raw explanation.');
    });

    test('corrupt sidecar fails the whole list without V1 fallback', () async {
      final db = await _singletonDb();
      await _insertLegacyRow(db, id: 'legacy_ok', createdAt: 1);
      final frozen = _mapper.freezeForWrite(
        storageId: _storageIdA,
        bankName: _bankName,
        createdAt: 2,
        draft: _draft('corrupt_typed'),
      );
      await db.insert('questions', frozen.questionRow);
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': _storageIdA,
        'payload_schema_version': 2,
        'payload_json': '{corrupt',
      });

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.malformedJson,
          ),
        ),
      );
    });

    test('partial sidecar fails the whole list', () async {
      final db = await _singletonDb();
      await _insertLegacyRow(db, id: 'legacy_ok', createdAt: 1);
      await db.execute('DROP TABLE question_v2_payloads');
      await db.execute('''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL,
          payload_json TEXT
        )
      ''');
      final frozen = _mapper.freezeForWrite(
        storageId: _storageIdA,
        bankName: _bankName,
        createdAt: 2,
        draft: _draft('partial_typed'),
      );
      await db.insert('questions', frozen.questionRow);
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': _storageIdA,
        'payload_schema_version': 2,
        'payload_json': null,
      });

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.invalidPayload,
          ),
        ),
      );
    });

    test('unsafe sidecar fails the whole list', () async {
      final db = await _singletonDb();
      await _insertLegacyRow(db, id: 'legacy_ok', createdAt: 1);
      final frozen = _mapper.freezeForWrite(
        storageId: _storageIdA,
        bankName: _bankName,
        createdAt: 2,
        draft: _draft('unsafe_typed'),
      );
      await db.insert('questions', frozen.questionRow);
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': _storageIdA,
        'payload_schema_version': 2,
        'payload_json': _unsafePayloadJson(),
      });

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.unsafePayload,
          ),
        ),
      );
    });

    test('rejects empty bank names and returns an empty list for unknown banks',
        () async {
      final repository = QuestionRepository();
      await expectLater(
        repository.getPersistedQuestionsByBank('   '),
        throwsArgumentError,
      );
      expect(await repository.getPersistedQuestionsByBank('unknown_bank'),
          isEmpty);
    });

    test('persisted rows survive close and reopen through the seam', () async {
      final path = p.join(tempDir.path, 'r6c_close_reopen.db');
      final draft = _draft('question_close_reopen');
      final first = await DatabaseHelper.instance.openPathForTesting(path);
      try {
        await _insertTypedRow(first, draft,
            storageId: _storageIdA, createdAt: 1700000001);
        await _insertLegacyRow(first,
            id: 'legacy_close', createdAt: 1700000000);
        await _insertReviewState(first,
            questionId: _storageIdA, lapses: 1, lastLapseTime: 1700000002);
      } finally {
        await first.close();
      }

      final second = await DatabaseHelper.instance.openPathForTesting(path);
      try {
        final version = await second.rawQuery('PRAGMA user_version');
        expect(version.single['user_version'], 15);
        final rows = await second.rawQuery('''
          SELECT q.*,
                 p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
                 p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
          FROM questions q
          LEFT JOIN question_v2_payloads p ON q.id = p.question_id
          WHERE q.bank_name = ?
          ORDER BY q.created_at DESC
        ''', [_bankName]);
        final decoded = rows.map(_mapper.decodeJoinedRow).toList();
        expect(decoded, hasLength(2));
        final typed = decoded.first as TypedPersistedQuestion;
        expect(typed.storageId, _storageIdA);
        expect(typed.draft, draft);
        final legacy = decoded.last as LegacyPersistedQuestion;
        expect(legacy.storageId, 'legacy_close');
        expect(legacy.question.answer, 'Legacy answer');
        final states = await second.query(
          'review_states',
          where: 'question_id = ?',
          whereArgs: <Object?>[_storageIdA],
        );
        expect(states.single['lapses'], 1);
      } finally {
        await second.close();
      }
    });
  });

  group('typed import atomic commit', () {
    test('valid guard and drafts commit atomically', () async {
      final db = await _singletonDb();
      await _insertImportTask(db);
      final repository = QuestionRepository();

      final result = await repository.commitQuestionDraftsV2ForImport(
        bankName: _bankName,
        folderName: 'Math',
        questions: <QuestionDraftV2>[
          _draft('import_question_1'),
          _draft('import_question_2'),
        ],
        guard: _importGuard(),
        completionText: '已成功导入题库: synthetic_bank',
      );

      expect(result.questionCount, 2);
      expect(result.completedAt, greaterThan(0));
      expect(await db.query('questions'), hasLength(2));
      expect(await db.query('question_v2_payloads'), hasLength(2));
      expect(await db.query('review_states'), hasLength(2));
      final folders = await db.query('bank_folders');
      expect(folders.single['bank_name'], _bankName);
      expect(folders.single['folder_name'], 'Math');

      final task = (await _importTaskRows(db)).single;
      expect(task['status'], 2);
      expect(task['progress_text'], '已成功导入题库: synthetic_bank');
      expect(task['percent'], 1.0);
      expect(task['error_msg'], isNull);
      expect(task['parsed_data'], isNull);
      expect(task['completed_at'], isNotNull);
      expect(task['id'], 'import-task');
      expect(task['title'], 'Synthetic typed import');
      expect(task['created_at'], 1700000000);
      expect(task['diagnostics'], isNotNull,
          reason: 'diagnostics audit metadata must be preserved');
    });

    test('task missing fails with zero question writes', () async {
      final db = await _singletonDb();
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_missing_task')],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.taskMissing,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
    });

    test('wrong persisted status fails with zero writes', () async {
      final db = await _singletonDb();
      await _insertImportTask(db, status: 0);
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_wrong_status')],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.taskNotPendingReview,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
    });

    test('already completed task fails with zero writes', () async {
      final db = await _singletonDb();
      await _insertImportTask(db, status: 2);
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_already_done')],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.alreadyCompleted,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
    });

    test('stale attempt token fails with zero writes', () async {
      final db = await _singletonDb();
      await _insertImportTask(db, diagnostics: _importDiagnostics(token: 'B'));
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_stale_token')],
          guard: _importGuard(token: 'A'),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.staleAttempt,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
    });

    test('stale attempt number fails with zero writes', () async {
      final db = await _singletonDb();
      await _insertImportTask(db, diagnostics: _importDiagnostics(number: 2));
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_stale_number')],
          guard: _importGuard(number: 1),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.staleAttempt,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
    });

    test('stale review revision fails with zero writes', () async {
      final db = await _singletonDb();
      await _insertImportTask(db, diagnostics: _importDiagnostics(revision: 2));
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_stale_revision')],
          guard: _importGuard(revision: 1),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.staleReviewDraft,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
    });

    test('wrong route, reason or attempt state fails with zero writes',
        () async {
      final db = await _singletonDb();
      final repository = QuestionRepository();

      for (final metadata in <Map<String, Object?>>[
        _importDiagnostics(route: 'legacyV1'),
        _importDiagnostics(reason: 'typed_candidate_shadow_ready'),
        _importDiagnostics(attemptState: 'failed'),
      ]) {
        await _insertImportTask(db, diagnostics: metadata);
        await expectLater(
          repository.commitQuestionDraftsV2ForImport(
            bankName: _bankName,
            folderName: 'Math',
            questions: <QuestionDraftV2>[_draft('import_bad_metadata')],
            guard: _importGuard(),
            completionText: 'done',
          ),
          throwsA(
            isA<TypedImportCommitPersistenceException>().having(
              (error) => error.failure,
              'failure',
              TypedImportCommitPersistenceFailure.invalidTaskMetadata,
            ),
          ),
        );
        await db.delete('import_tasks');
      }
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
    });

    test('invalid diagnostics JSON fails with zero writes', () async {
      final db = await _singletonDb();
      await _insertImportTask(db, diagnosticsJson: '{broken');
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_bad_json')],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.invalidTaskMetadata,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
    });

    test('null parsed_data fails with zero writes', () async {
      final db = await _singletonDb();
      await _insertImportTask(db, parsedData: null);
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_null_parsed')],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.invalidTaskMetadata,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
    });

    test('sidecar insert failure rolls back the task completion', () async {
      final db = await _singletonDb();
      await _insertImportTask(db);
      await db.execute('''
        CREATE TRIGGER r7c1_block_second_payload
        BEFORE INSERT ON question_v2_payloads
        WHEN (SELECT COUNT(*) FROM question_v2_payloads) >= 1
        BEGIN SELECT RAISE(ABORT, 'r7c1_synthetic_second_payload_failure'); END;
      ''');
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[
            _draft('import_rollback_1'),
            _draft('import_rollback_2'),
          ],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.transactionFailed,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
      final task = (await _importTaskRows(db)).single;
      expect(task['status'], 1, reason: 'task completion must roll back');
      expect(task['parsed_data'], isNotNull);
    });

    test('import_tasks update trigger failure rolls back all question rows',
        () async {
      final db = await _singletonDb();
      await _insertImportTask(db);
      await db.execute('''
        CREATE TRIGGER r7c1_block_completion
        BEFORE UPDATE ON import_tasks
        WHEN NEW.status = 2
        BEGIN SELECT RAISE(ABORT, 'r7c1_synthetic_completion_failure'); END;
      ''');
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_update_rollback')],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.transactionFailed,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
      final task = (await _importTaskRows(db)).single;
      expect(task['status'], 1);
      expect(task['parsed_data'], isNotNull);
    });

    test('CAS mismatch on the final update rolls back everything', () async {
      final db = await _singletonDb();
      await _insertImportTask(db);
      await db.execute('''
        CREATE TRIGGER r7c1_break_cas
        AFTER INSERT ON questions
        BEGIN
          UPDATE import_tasks SET status = 3 WHERE status = 1;
        END;
      ''');
      final repository = QuestionRepository();

      await expectLater(
        repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_cas_rollback')],
          guard: _importGuard(),
          completionText: 'done',
        ),
        throwsA(
          isA<TypedImportCommitPersistenceException>().having(
            (error) => error.failure,
            'failure',
            TypedImportCommitPersistenceFailure.transactionFailed,
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      final task = (await _importTaskRows(db)).single;
      expect(task['status'], 1,
          reason: 'the CAS trigger mutation must roll back with the '
              'transaction');
    });

    test('safe persistence exception leaks no SQL, token or trigger text',
        () async {
      final db = await _singletonDb();
      await _insertImportTask(db);
      await db.execute('''
        CREATE TRIGGER r7c1_block_completion
        BEFORE UPDATE ON import_tasks
        WHEN NEW.status = 2
        BEGIN SELECT RAISE(ABORT, 'r7c1_private_trigger_text'); END;
      ''');
      final repository = QuestionRepository();
      TypedImportCommitPersistenceException? caught;
      try {
        await repository.commitQuestionDraftsV2ForImport(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draft('import_safe_error')],
          guard: _importGuard(),
          completionText: 'done',
        );
      } on TypedImportCommitPersistenceException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.failure,
          TypedImportCommitPersistenceFailure.transactionFailed);
      expect(caught.toString(), isNot(contains('r7c1_private_trigger_text')));
      expect(caught.toString(), isNot(contains('attempt-A')));
      expect(caught.toString(), isNot(contains('import-task')));
      expect(caught.toString(), isNot(contains(_bankName)));
      expect(caught.toString(), isNot(contains('diagnostics')));
      expect(caught.toString(), isNot(contains('UPDATE')));
    });

    test('concurrent duplicate commits write exactly one batch', () async {
      final db = await _singletonDb();
      await _insertImportTask(db);
      final repository = QuestionRepository();
      final drafts = <QuestionDraftV2>[
        _draft('import_concurrent_1'),
        _draft('import_concurrent_2'),
      ];

      final results = await Future.wait<Object?>(
        <Future<Object?>>[
          repository
              .commitQuestionDraftsV2ForImport(
                bankName: _bankName,
                folderName: 'Math',
                questions: drafts,
                guard: _importGuard(),
                completionText: 'done',
              )
              .then<Object?>((result) => result),
          repository
              .commitQuestionDraftsV2ForImport(
                bankName: _bankName,
                folderName: 'Math',
                questions: drafts,
                guard: _importGuard(),
                completionText: 'done',
              )
              .then<Object?>((result) => result)
              .catchError((Object error) => error),
        ],
      );

      final successes =
          results.whereType<TypedImportCommitPersistenceResult>().toList();
      final failures =
          results.whereType<TypedImportCommitPersistenceException>().toList();
      expect(successes, hasLength(1));
      expect(failures, hasLength(1));
      expect(successes.single.questionCount, 2);
      expect(await db.query('questions'), hasLength(2),
          reason: 'exactly one batch of questions must be written');
      expect(await db.query('question_v2_payloads'), hasLength(2));
      expect(await db.query('review_states'), hasLength(2));
      expect((await _importTaskRows(db)).single['status'], 2);
    });
  });

  group('legacy mutation guards', () {
    test('preview REPLACE is blocked before mutation on a typed collision',
        () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [_draft('question_preview_target')],
      );
      final db = await _singletonDb();
      final typedId = (await db.query('questions')).single['id'] as String;

      await expectLater(
        repository.savePreviewQuestion(<String, dynamic>{
          'id': 'preview_$typedId',
          'type': 0,
          'content': 'Preview collision content',
          'options': '["A"]',
          'standard_answer': 'A',
          'bank_name': _bankName,
        }),
        throwsA(isA<QuestionV2LegacyMutationBlockedException>()),
      );

      final questions = await db.query('questions');
      expect(questions, hasLength(1));
      expect(questions.single['content'], 'Synthetic stem text.');
      expect(await db.query('question_v2_payloads'), hasLength(1));
      expect(await db.query('review_states'), hasLength(1));
    });

    test('preview save without a collision keeps the legacy path', () async {
      final repository = QuestionRepository();
      await repository.savePreviewQuestion(<String, dynamic>{
        'id': 'preview_fresh',
        'type': 0,
        'content': 'Fresh preview',
        'options': '["A","B"]',
        'standard_answer': 'A',
        'bank_name': _bankName,
      });

      final db = await _singletonDb();
      final questions = await db.query('questions');
      expect(questions.single['id'], 'fresh');
      expect(questions.single['content'], 'Fresh preview');
      expect(await db.query('question_v2_payloads'), isEmpty);
      final states = await db.query('review_states');
      expect(states.single['question_id'], 'fresh');
    });

    test(
        'DatabaseHelper updateQuestion blocks typed rows atomically and '
        'preserves V1 updates', () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [_draft('question_update_target')],
      );
      final db = await _singletonDb();
      final typedId = (await db.query('questions')).single['id'] as String;

      await expectLater(
        DatabaseHelper.instance.updateQuestion(<String, dynamic>{
          'id': typedId,
          'content': 'Typed row mutation attempt',
        }),
        throwsA(isA<QuestionV2LegacyMutationBlockedException>()),
      );
      expect(
        (await db.query('questions')).single['content'],
        'Synthetic stem text.',
      );

      await _insertLegacyRow(db, id: 'legacy_update', createdAt: 1);
      await DatabaseHelper.instance.updateQuestion(<String, dynamic>{
        'id': 'legacy_update',
        'content': 'Updated legacy content',
        'bank_name': _bankName,
      });
      final legacy =
          (await db.query('questions', where: 'id = ?', whereArgs: <Object?>[
        'legacy_update',
      ]))
              .single;
      expect(legacy['content'], 'Updated legacy content');
      expect(legacy['bank_name'], _bankName);
    });

    test('subject tree type self-repair skips typed rows', () async {
      final db = await _singletonDb();
      await _insertTypedRow(
        db,
        _draft('typed_fill', kind: QuestionKind.fillBlank),
        storageId: _storageIdA,
        createdAt: 1,
      );
      await _insertLegacyRow(
        db,
        id: 'legacy_repair',
        createdAt: 2,
        type: 3,
        options: '["A","B"]',
      );

      await QuestionRepository().getSubjectTree();

      final typed =
          (await db.query('questions', where: 'id = ?', whereArgs: <Object?>[
        _storageIdA,
      ]))
              .single;
      expect(typed['type'], 2);
      final legacy = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>['legacy_repair'],
      ))
          .single;
      expect(legacy['type'], 0);

      final states = await db.query('review_states', orderBy: 'question_id');
      expect(states, hasLength(2));
    });

    test('LaTeX migration list and field updates exclude typed rows', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draft('latex_typed'),
          storageId: _storageIdA, createdAt: 1);
      await _insertLegacyRow(db, id: 'legacy_latex', createdAt: 2);

      final repository = LatexMigrationRepository();
      final all = await repository.getAllQuestions();
      expect(all.map((row) => row['id']).toList(), <String>['legacy_latex']);

      await repository.updateQuestionFields(
        _storageIdA,
        <String, dynamic>{'content': 'Typed mutation attempt'},
      );
      expect(
        (await db.query('questions', where: 'id = ?', whereArgs: <Object?>[
          _storageIdA,
        ]))
            .single['content'],
        'Synthetic stem text.',
      );

      await repository.updateQuestionFields(
        'legacy_latex',
        <String, dynamic>{'content': 'Legacy latex update'},
      );
      expect(
        (await db.query(
          'questions',
          where: 'id = ?',
          whereArgs: <Object?>['legacy_latex'],
        ))
            .single['content'],
        'Legacy latex update',
      );
    });

    test('LaTeX field update rejects injection-shaped keys before any write',
        () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draft('latex_typed_malicious'),
          storageId: _storageIdA, createdAt: 1);
      await _insertLegacyRow(db, id: 'legacy_latex_malicious', createdAt: 2);

      final repository = LatexMigrationRepository();
      // A key shaped like SQL: a raw assignment builder would splice it into
      // the SET text and comment out the typed-row guard, rewriting the typed
      // row. The repository must reject it before any row is touched.
      await expectLater(
        repository.updateQuestionFields(
          _storageIdA,
          <String, dynamic>{'content = ? WHERE id = ? --': 'Injection'},
        ),
        throwsArgumentError,
      );
      expect(
        (await db.query('questions', where: 'id = ?', whereArgs: <Object?>[
          _storageIdA,
        ]))
            .single['content'],
        'Synthetic stem text.',
      );
      expect(
        (await db.query('questions', where: 'id = ?', whereArgs: <Object?>[
          'legacy_latex_malicious',
        ]))
            .single['content'],
        'Legacy stem text.',
      );
    });

    test('LaTeX field update restores the baseline empty-fields failure',
        () async {
      final db = await _singletonDb();
      await _insertLegacyRow(db, id: 'legacy_latex_empty', createdAt: 1);

      final repository = LatexMigrationRepository();
      await expectLater(
        repository.updateQuestionFields(
          'legacy_latex_empty',
          <String, dynamic>{},
        ),
        throwsArgumentError,
      );
      expect(
        (await db.query('questions', where: 'id = ?', whereArgs: <Object?>[
          'legacy_latex_empty',
        ]))
            .single['content'],
        'Legacy stem text.',
      );
    });
  });

  group('cascade and FTS compatibility', () {
    test('single delete cascades the sidecar and review state', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draft('delete_single'),
          storageId: _storageIdA, createdAt: 1);
      await _insertReviewState(db,
          questionId: _storageIdA, lapses: 1, lastLapseTime: 2);

      await DatabaseHelper.instance.deleteSingleQuestion(_storageIdA);

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
    });

    test('bank delete cascades sidecars and review states', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draft('delete_bank_1'),
          storageId: _storageIdA, createdAt: 1);
      await _insertTypedRow(db, _draft('delete_bank_2'),
          storageId: _storageIdB, createdAt: 2);
      await _insertReviewState(db,
          questionId: _storageIdA, lapses: 1, lastLapseTime: 3);

      await DatabaseHelper.instance.deleteQuestionBank(_bankName);

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
    });

    test('ReviewRepository delete and clear-all cascade sidecars', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draft('review_delete'),
          storageId: _storageIdA, createdAt: 1);
      await _insertReviewState(db,
          questionId: _storageIdA, lapses: 1, lastLapseTime: 2);

      final repository = ReviewRepository();
      await repository.deleteQuestionAndRelatedData(_storageIdA);
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);

      await _insertTypedRow(db, _draft('review_clear_1'),
          storageId: _storageIdA, createdAt: 3);
      await _insertTypedRow(db, _draft('review_clear_2'),
          storageId: _storageIdB, createdAt: 4);
      await _insertReviewState(db,
          questionId: _storageIdB, lapses: 2, lastLapseTime: 5);

      await repository.clearAllData();
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('review_logs'), isEmpty);
    });

    test('FTS mirror stays consistent for typed rows', () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: [_draft('question_fts')],
      );
      final db = await _singletonDb();
      final typedId = (await db.query('questions')).single['id'] as String;

      final results = await DatabaseHelper.instance
          .searchQuestionsByBank(_bankName, 'Synthetic');
      expect(results.map((row) => row['id']), contains(typedId));

      var ftsCount =
          await db.rawQuery('SELECT COUNT(*) AS c FROM questions_fts');
      expect(ftsCount.single['c'], 1);

      await DatabaseHelper.instance.deleteSingleQuestion(typedId);
      ftsCount = await db.rawQuery('SELECT COUNT(*) AS c FROM questions_fts');
      expect(ftsCount.single['c'], 0);
    });
  });

  group('production writer routing', () {
    test('ImportCommitService keeps the V1 write path only', () async {
      final manager = TaskManager.forTesting();
      await manager.ready;
      manager.tasks.clear();
      final repository = _CommitTrackingRepository();
      final service = ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      );

      await service.commit(
        bankName: _bankName,
        folderName: 'Folder',
        questions: const <QuestionDraft>[
          QuestionDraft(
            type: QuestionType.singleChoice,
            content: 'Synthetic question',
            options: <String>['A', 'B'],
            standardAnswer: 'A',
            explanation: '',
          ),
        ],
        diagnostics: const <String, dynamic>{},
      );

      expect(repository.v1SaveCalls, 1);
      expect(repository.v2SaveCalls, 0);
    });
  });
}
