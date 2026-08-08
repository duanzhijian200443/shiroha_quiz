// P5.1 synthetic acceptance: typed manual answer mutation on real v15
// databases. Repository scenarios run file-backed through the frozen
// DatabaseHelper.openPathForTesting seam (close/reopen durability) or on the
// frozen in-memory singleton under FLUTTER_TEST. No real application
// database, private PDF, OCR, Replay, Provider, network, or external fixture
// is touched; all content is constructed inside this file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/ui/models/persisted_question_view.dart';
import 'package:shiroha_quiz/ui/models/practice_question_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'p5_synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _choiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'p5_choice_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('Choice stem.'),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'opt_a',
        label: '甲',
        content: _text('first'),
      ),
      QuestionOption(
        optionId: 'opt_b',
        label: '乙',
        content: _text('second'),
      ),
      QuestionOption(
        optionId: 'opt_c',
        label: '丙',
        content: _text('third'),
      ),
    ],
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

QuestionDraftV2 _draftWithAnswer(QuestionDraftV2 draft, QuestionAnswer answer) {
  return QuestionDraftV2(
    questionId: draft.questionId,
    kind: draft.kind,
    questionNumber: draft.questionNumber,
    stem: draft.stem,
    options: draft.options,
    answer: answer,
    explanation: draft.explanation,
    sourceRefs: draft.sourceRefs,
    assetRefs: draft.assetRefs,
    issues: draft.issues,
  );
}

/// File-backed DatabaseHelper seam: repository APIs run against a real v15
/// database opened only through the frozen openPathForTesting seam.
class _FileDatabaseHelper extends Fake implements DatabaseHelper {
  _FileDatabaseHelper(this.path);

  final String path;
  Database? _database;

  @override
  Future<Database> get database async =>
      _database ??= await DatabaseHelper.instance.openPathForTesting(path);

  @override
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }
}

Future<void> _insertTypedRow(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: _bankName,
    createdAt: 1700000001,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': storageId,
    'state': 3,
    'difficulty': 2.5,
    'stability': 9.5,
    'reps': 7,
    'lapses': 4,
    'last_review_time': 1700001001,
    'next_review_time': 1700002001,
    'last_lapse_time': 1700000501,
  });
}

Future<void> _insertLegacyRow(Database db, {required String id}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 3,
    'content': 'Legacy stem text.',
    'options': '[]',
    'standard_answer': 'Legacy answer|||Legacy explanation.',
    'explanation': 'Legacy explanation.',
    'raw_explanation': 'Legacy raw explanation.',
    'created_at': 1700000000,
    'bank_name': _bankName,
  });
}

Future<TypedPersistedQuestion> _reloadTyped(
  Database db,
  String storageId,
) async {
  final rows = await db.rawQuery(
    '''
    SELECT q.*,
           p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
           p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
    FROM questions q
    LEFT JOIN question_v2_payloads p ON q.id = p.question_id
    WHERE q.id = ?
    ''',
    <Object?>[storageId],
  );
  expect(rows, hasLength(1));
  final decoded = _mapper.decodeJoinedRow(rows.single);
  expect(decoded, isA<TypedPersistedQuestion>());
  return decoded as TypedPersistedQuestion;
}

Future<String> _standardAnswer(Database db, String storageId) async {
  final rows = await db.query(
    'questions',
    columns: <String>['standard_answer'],
    where: 'id = ?',
    whereArgs: <Object?>[storageId],
  );
  return rows.single['standard_answer']! as String;
}

Future<String> _payloadJson(Database db, String storageId) async {
  final rows = await db.query(
    'question_v2_payloads',
    columns: <String>['payload_json'],
    where: 'question_id = ?',
    whereArgs: <Object?>[storageId],
  );
  return rows.single['payload_json']! as String;
}

Future<int> _userVersion(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  return rows.single['user_version'] as int;
}

String _fixedMutationMessage(TypedAnswerMutationFailure failure) {
  final detail = switch (failure) {
    TypedAnswerMutationFailure.notFound =>
      'The typed question cannot be found.',
    TypedAnswerMutationFailure.notTyped =>
      'The question is not stored as a typed question.',
    TypedAnswerMutationFailure.stale =>
      'The question changed after it was loaded.',
    TypedAnswerMutationFailure.corruptPayload =>
      'The typed question payload cannot be read safely.',
    TypedAnswerMutationFailure.invalidAnswer =>
      'The answer does not match the typed question options.',
    TypedAnswerMutationFailure.unsafePayload =>
      'The typed answer contains unsafe content.',
    TypedAnswerMutationFailure.transactionFailed =>
      'The typed answer cannot be saved atomically.',
  };
  return 'TypedAnswerMutationException(${failure.name}): $detail';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final openHelpers = <_FileDatabaseHelper>[];
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('p5_acceptance_');
  });

  tearDown(() async {
    for (final helper in openHelpers) {
      await helper.close();
    }
    openHelpers.clear();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  _FileDatabaseHelper newFileHelper(String name) {
    final helper = _FileDatabaseHelper(p.join(tempDir.path, name));
    openHelpers.add(helper);
    return helper;
  }

  group('A: null answer to manual answer', () {
    test('durable across close and reopen with user_version 16', () async {
      final helper = newFileHelper('p5a.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);

      final current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: ContentAnswer(content: _text('manual answer')),
      );
      await helper.close();

      final reopened = newFileHelper('p5a.db');
      final reopenedRepository = QuestionRepository(databaseHelper: reopened);
      final db2 = await reopened.database;
      expect(await _userVersion(db2), 16);
      final typed = await _reloadTyped(db2, _storageId);
      final answer = typed.draft.answer as ContentAnswer;
      expect((answer.content.nodes.single as TextNode).text, 'manual answer');
      expect(
        (jsonDecode(await _payloadJson(db2, _storageId))
            as Map<String, dynamic>)['answer']['content']['nodes'][0]['text'],
        'manual answer',
      );

      final reloaded =
          await reopenedRepository.getPersistedQuestionsByBank(_bankName);
      expect(reloaded, hasLength(1));
      final reloadedAnswer = ((reloaded.single as TypedPersistedQuestion)
              .draft
              .answer! as ContentAnswer)
          .content;
      expect((reloadedAnswer.nodes.single as TextNode).text, 'manual answer');
    });
  });

  group('B: existing answer repair', () {
    test('sidecar is authoritative and the V1 projection follows', () async {
      final helper = newFileHelper('p5b.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      expect(await _standardAnswer(db, _storageId), '甲|||Explanation.');
      final before = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>[_storageId],
      ))
          .single;

      final current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: ChoiceAnswer(optionIds: <String>['opt_c']),
      );

      final typed = await _reloadTyped(db, _storageId);
      expect(
        typed.draft.answer,
        ChoiceAnswer(optionIds: <String>['opt_c']),
      );
      expect(await _standardAnswer(db, _storageId), '丙|||Explanation.');

      final after = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>[_storageId],
      ))
          .single;
      final beforeWithoutAnswer = Map<String, Object?>.from(before)
        ..remove('standard_answer');
      final afterWithoutAnswer = Map<String, Object?>.from(after)
        ..remove('standard_answer');
      expect(afterWithoutAnswer, beforeWithoutAnswer);

      final view = PersistedQuestionViewAdapter.fromPersisted(typed);
      expect(view.isTyped, isTrue);
      expect((view.typedAnswer!.nodes.single as TextNode).text, '丙');
      expect(view.legacyAnswer, isEmpty);
    });
  });

  group('C: review state immutability', () {
    test('every review field is byte-identical after repair', () async {
      final helper = newFileHelper('p5c.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      final before = await db.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>[_storageId],
      );

      final current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
      );

      final after = await db.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>[_storageId],
      );
      expect(after, before);
      expect(
        after.single.keys.toSet(),
        <String>{
          'id',
          'question_id',
          'state',
          'difficulty',
          'stability',
          'reps',
          'lapses',
          'last_review_time',
          'next_review_time',
          'last_lapse_time',
        },
      );
    });
  });

  group('D: choice identity', () {
    test('optionIds are saved, not labels, and reload keeps the identity',
        () async {
      final helper = newFileHelper('p5d.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);

      final current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
      );

      final typed = await _reloadTyped(db, _storageId);
      expect(
        typed.draft.answer,
        ChoiceAnswer(optionIds: <String>['opt_b']),
      );
      final standardAnswer = await _standardAnswer(db, _storageId);
      expect(standardAnswer, '乙|||Explanation.');
      expect(standardAnswer, isNot(contains('opt_b')));
      final view = PersistedQuestionViewAdapter.fromPersisted(typed);
      expect((view.typedAnswer!.nodes.single as TextNode).text, '乙');
    });
  });

  group('F: clear answer', () {
    test('null answer clears without placeholder or legacy fallback', () async {
      final helper = newFileHelper('p5f.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ContentAnswer(content: _text('old'))),
        storageId: _storageId,
      );

      final current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: null,
      );

      final typed = await _reloadTyped(db, _storageId);
      expect(typed.draft.answer, isNull);
      final standardAnswer = await _standardAnswer(db, _storageId);
      expect(standardAnswer, '|||Explanation.');
      expect(standardAnswer, isNot(contains('暂无答案')));
      expect(standardAnswer, isNot(contains('无')));
      final view = PersistedQuestionViewAdapter.fromPersisted(typed);
      expect(view.isTyped, isTrue);
      expect(view.typedAnswer, isNull);
      expect(view.legacyAnswer, isEmpty);
    });
  });

  group('G: stale guard', () {
    test('stale attempt writes zero rows and keeps draft B and V1 B intact',
        () async {
      final helper = newFileHelper('p5g.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      final draftA = (await _reloadTyped(db, _storageId)).draft;

      // B commits first.
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: draftA,
        newAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
      );
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      // A tries its stale commit.
      await expectLater(
        repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: draftA,
          newAnswer: ChoiceAnswer(optionIds: <String>['opt_c']),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.stale,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);

      final draftB = _draftWithAnswer(
        draftA,
        ChoiceAnswer(optionIds: <String>['opt_b']),
      );
      final typed = await _reloadTyped(db, _storageId);
      expect(typed.draft, draftB);
      expect(await _standardAnswer(db, _storageId), '乙|||Explanation.');
    });
  });

  group('H: corrupt and partial sidecars', () {
    test('corrupt JSON sidecar fails with corruptPayload and zero writes',
        () async {
      final helper = newFileHelper('p5h_corrupt.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await db.insert('questions', <String, Object?>{
        'id': _storageId,
        'type': 3,
        'content': 'Corrupt synthetic parent.',
        'options': '[]',
        'standard_answer': 'x|||',
        'created_at': 1,
        'bank_name': _bankName,
      });
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': _storageId,
        'payload_schema_version': QuestionDraftV2Codec.schemaVersion,
        'payload_json': '{corrupt',
      });
      final standardBefore = await _standardAnswer(db, _storageId);
      final payloadBefore = await _payloadJson(db, _storageId);

      try {
        await repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: _choiceDraft(),
          newAnswer: ContentAnswer(content: _text('C')),
        );
        fail('expected corruptPayload');
      } on TypedAnswerMutationException catch (error) {
        expect(error.failure, TypedAnswerMutationFailure.corruptPayload);
        expect(
            error.toString(),
            _fixedMutationMessage(
              TypedAnswerMutationFailure.corruptPayload,
            ));
        expect(error.toString(), isNot(contains('{corrupt')));
      }
      expect(await _standardAnswer(db, _storageId), standardBefore);
      expect(await _payloadJson(db, _storageId), payloadBefore);
    });

    test('partial sidecar fails with corruptPayload and zero writes', () async {
      // The frozen schema cannot express a partial sidecar, so the synthetic
      // in-memory singleton gets a nullable payload_json table exactly like
      // the R6D partial-alias scenario.
      final repository = QuestionRepository();
      final db = await DatabaseHelper.instance.database;
      await db.execute('DROP TABLE question_v2_payloads');
      await db.execute('''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL,
          payload_json TEXT
        )
      ''');
      await db.insert('questions', <String, Object?>{
        'id': _storageId,
        'type': 3,
        'content': 'Partial synthetic parent.',
        'options': '[]',
        'standard_answer': 'x|||',
        'created_at': 1,
        'bank_name': _bankName,
      });
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': _storageId,
        'payload_schema_version': QuestionDraftV2Codec.schemaVersion,
        'payload_json': null,
      });
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: _choiceDraft(),
          newAnswer: null,
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.corruptPayload,
          ),
        ),
      );
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });
  });

  group('I: transaction rollback', () {
    test('questions UPDATE failure rolls back the sidecar too', () async {
      final helper = newFileHelper('p5i_question.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      await db.execute('''
        CREATE TRIGGER p5_block_question
        BEFORE UPDATE OF standard_answer ON questions
        BEGIN
          SELECT RAISE(ABORT, 'p5_synthetic_question_failure');
        END;
      ''');
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final current = await _reloadTyped(db, _storageId);
      try {
        await repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: current.draft,
          newAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
        );
        fail('expected transactionFailed');
      } on TypedAnswerMutationException catch (error) {
        expect(
          error.failure,
          TypedAnswerMutationFailure.transactionFailed,
        );
        expect(
          error.toString(),
          _fixedMutationMessage(TypedAnswerMutationFailure.transactionFailed),
        );
        expect(error.toString(), isNot(contains('p5_synthetic_question')));
      }
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
      final typed = await _reloadTyped(db, _storageId);
      expect(
        typed.draft.answer,
        ChoiceAnswer(optionIds: <String>['opt_a']),
      );
    });

    test('sidecar UPDATE failure rolls back the V1 projection too', () async {
      final helper = newFileHelper('p5i_payload.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      await db.execute('''
        CREATE TRIGGER p5_block_payload
        BEFORE UPDATE ON question_v2_payloads
        BEGIN
          SELECT RAISE(ABORT, 'p5_synthetic_payload_failure');
        END;
      ''');
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final current = await _reloadTyped(db, _storageId);
      await expectLater(
        repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: current.draft,
          newAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.transactionFailed,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
      final typed = await _reloadTyped(db, _storageId);
      expect(
        typed.draft.answer,
        ChoiceAnswer(optionIds: <String>['opt_a']),
      );
    });
  });

  group('J: legacy regression', () {
    test('legacy updateQuestion still works and typed mutation is notTyped',
        () async {
      final repository = QuestionRepository();
      final db = await DatabaseHelper.instance.database;
      const legacyId = 'p5_legacy_001';
      await _insertLegacyRow(db, id: legacyId);

      final row = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>[legacyId],
      ))
          .single;
      await repository.updateQuestion(
        Map<String, Object?>.from(row)..['content'] = 'Updated legacy content.',
      );
      final updated = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>[legacyId],
      ))
          .single;
      expect(updated['content'], 'Updated legacy content.');

      final snapshot = jsonEncode(updated);
      try {
        await repository.updateTypedAnswer(
          storageId: legacyId,
          expectedDraft: _choiceDraft(),
          newAnswer: null,
        );
        fail('expected notTyped');
      } on TypedAnswerMutationException catch (error) {
        expect(error.failure, TypedAnswerMutationFailure.notTyped);
        expect(
          error.toString(),
          _fixedMutationMessage(TypedAnswerMutationFailure.notTyped),
        );
      }
      final after = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>[legacyId],
      ))
          .single;
      expect(jsonEncode(after), snapshot);
    });
  });

  group('K: three-consumer visibility', () {
    test('repository reload, list view, and practice view read the new answer',
        () async {
      final helper = newFileHelper('p5k.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );

      final current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
      );

      final reloaded = await repository.getPersistedQuestionsByBank(_bankName);
      expect(reloaded, hasLength(1));
      final typed = reloaded.single as TypedPersistedQuestion;
      expect(
        typed.draft.answer,
        ChoiceAnswer(optionIds: <String>['opt_b']),
      );

      final listView = PersistedQuestionViewAdapter.fromPersisted(typed);
      expect((listView.typedAnswer!.nodes.single as TextNode).text, '乙');

      final practiceView = PracticeQuestionViewAdapter.fromPersisted(typed);
      expect(practiceView.answerOptionIds, <String>['opt_b']);
      expect(
        (practiceView.typedAnswer!.nodes.single as TextNode).text,
        '乙',
      );
    });
  });

  group('L: explicit typed empty', () {
    test('null and empty RichContent stay typed without V1 fallback', () async {
      final helper = newFileHelper('p5l.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ContentAnswer(content: _text('old'))),
        storageId: _storageId,
      );

      var current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: null,
      );
      var typed = await _reloadTyped(db, _storageId);
      expect(typed.draft.answer, isNull);
      expect(await _standardAnswer(db, _storageId), '|||Explanation.');

      current = typed;
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: ContentAnswer(
          content: RichContent(nodes: const <ContentNode>[]),
        ),
      );
      typed = await _reloadTyped(db, _storageId);
      final emptyAnswer = typed.draft.answer as ContentAnswer;
      expect(emptyAnswer.content.nodes, isEmpty);
      expect(await _standardAnswer(db, _storageId), '|||Explanation.');
      final view = PersistedQuestionViewAdapter.fromPersisted(typed);
      expect(view.isTyped, isTrue);
      expect(view.typedAnswer, isNotNull);
      expect(view.typedAnswer!.nodes, isEmpty);
      expect(view.legacyAnswer, isEmpty);
    });
  });

  group('mutation failure taxonomy', () {
    test('notFound fails without writes', () async {
      final helper = newFileHelper('p5_not_found.db');
      final repository = QuestionRepository(databaseHelper: helper);
      await expectLater(
        repository.updateTypedAnswer(
          storageId: 'b4f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
          expectedDraft: _choiceDraft(),
          newAnswer: null,
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.notFound,
          ),
        ),
      );
    });

    test('unknown choice identity fails with invalidAnswer and zero writes',
        () async {
      final helper = newFileHelper('p5_invalid.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final current = await _reloadTyped(db, _storageId);
      try {
        await repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: current.draft,
          newAnswer: ChoiceAnswer(optionIds: <String>['opt_a', 'ghost_opt']),
        );
        fail('expected invalidAnswer');
      } on TypedAnswerMutationException catch (error) {
        expect(error.failure, TypedAnswerMutationFailure.invalidAnswer);
        expect(
          error.toString(),
          _fixedMutationMessage(TypedAnswerMutationFailure.invalidAnswer),
        );
        expect(error.toString(), isNot(contains('ghost_opt')));
      }
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('duplicate choice optionIds fail with invalidAnswer and zero writes',
        () async {
      final helper = newFileHelper('p5_duplicate_ids.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);
      final statesBefore = await db.query('review_states',
          where: 'question_id = ?', whereArgs: <Object?>[_storageId]);

      final current = await _reloadTyped(db, _storageId);
      try {
        await repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: current.draft,
          newAnswer: ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
        );
        fail('expected invalidAnswer');
      } on TypedAnswerMutationException catch (error) {
        expect(error.failure, TypedAnswerMutationFailure.invalidAnswer);
        expect(
          error.toString(),
          _fixedMutationMessage(TypedAnswerMutationFailure.invalidAnswer),
        );
      }
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
      expect(
        await db.query('review_states',
            where: 'question_id = ?', whereArgs: <Object?>[_storageId]),
        statesBefore,
      );
    });

    test('no-op duplicate choice answer is accepted and rewrites nothing',
        () async {
      final helper = newFileHelper('p5_noop_duplicate.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(
          answer: ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
        ),
        storageId: _storageId,
      );
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final current = await _reloadTyped(db, _storageId);
      await repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: current.draft,
        newAnswer: ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
      );

      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
      final reloaded = await _reloadTyped(db, _storageId);
      expect(
        reloaded.draft.answer,
        ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
      );
    });

    test('unsafe replacement content fails with unsafePayload and zero writes',
        () async {
      final helper = newFileHelper('p5_unsafe.db');
      final repository = QuestionRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ContentAnswer(content: _text('old'))),
        storageId: _storageId,
      );
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final current = await _reloadTyped(db, _storageId);
      try {
        await repository.updateTypedAnswer(
          storageId: _storageId,
          expectedDraft: current.draft,
          newAnswer: ContentAnswer(
            content: RichContent(nodes: <ContentNode>[
              RawFallbackNode(<Object?, Object?>{
                'type': 'future_diagram',
                'providerResponse': <Object?, Object?>{'status': 'synthetic'},
              }),
            ]),
          ),
        );
        fail('expected unsafePayload');
      } on TypedAnswerMutationException catch (error) {
        expect(error.failure, TypedAnswerMutationFailure.unsafePayload);
        expect(
          error.toString(),
          _fixedMutationMessage(TypedAnswerMutationFailure.unsafePayload),
        );
        expect(error.toString(), isNot(contains('providerResponse')));
      }
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });
  });
}
