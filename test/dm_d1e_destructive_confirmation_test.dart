import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_bank_mutation_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/ui/pages/import_screen.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _questionId = 'd1e-question';
const _bankName = 'd1e-bank';

final class _QuestionConfirmationRepository extends Fake
    implements QuestionRepository {
  _QuestionConfirmationRepository({required this.failDelete})
      : persisted = <PersistedQuestion>[_question()];

  final bool failDelete;
  List<PersistedQuestion> persisted;
  int deleteCalls = 0;

  @override
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    return List<PersistedQuestion>.from(persisted);
  }

  @override
  Future<void> deleteQuestion(String id) async {
    deleteCalls++;
    if (failDelete) throw StateError('d1e synthetic question delete failure');
    persisted = persisted
        .where((question) => question.storageId != id)
        .toList(growable: false);
  }
}

final class _QuestionBankConfirmationPersistence extends Fake
    implements QuestionBankMutationPersistencePort {
  _QuestionBankConfirmationPersistence({required this.failDelete})
      : banks = <Map<String, dynamic>>[
          <String, dynamic>{
            'bank_name': _bankName,
            'total_count': 1,
          },
        ];

  final bool failDelete;
  List<Map<String, dynamic>> banks;
  int deleteCalls = 0;

  @override
  Future<void> deleteQuestionBank(String bankName) async {
    deleteCalls++;
    if (failDelete) {
      throw StateError('d1e synthetic question-bank delete failure');
    }
    banks = banks
        .where((bank) => bank['bank_name'] != bankName)
        .toList(growable: false);
  }
}

LegacyPersistedQuestion _question() {
  return LegacyPersistedQuestion(
    question: Question(
      id: _questionId,
      type: 0,
      content: 'D1E question',
      options: '["A. option"]',
      answer: 'A',
      createdAt: 1,
      bankName: _bankName,
      explanation: 'D1E explanation',
    ),
  );
}

Future<void> _pumpQuestionList(
  WidgetTester tester,
  _QuestionConfirmationRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: QuestionListScreen(
        bankName: _bankName,
        questionRepository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<Database> _database() => DatabaseHelper.instance.database;

Future<void> _seedQuestionData() async {
  final db = await _database();
  await db.insert('questions', <String, Object?>{
    'id': _questionId,
    'type': 0,
    'content': 'D1E question',
    'options': '["A. option"]',
    'standard_answer': 'A',
    'explanation': 'D1E explanation',
    'raw_explanation': 'D1E raw explanation',
    'created_at': 1,
    'bank_name': _bankName,
  });
  await db.insert('review_states', <String, Object?>{
    'question_id': _questionId,
    'state': 0,
    'next_review_time': 1,
    'lapses': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'reps': 0,
    'last_lapse_time': null,
    'last_review_time': null,
  });
  await db.insert('review_logs', <String, Object?>{
    'id': 'd1e-review-log',
    'question_id': _questionId,
    'grade': 3,
    'review_time': 1,
    'duration_ms': 1000,
    'user_answer': 'A',
    'ai_evaluation': null,
  });
  await db.insert('answer_attempts', <String, Object?>{
    'attempt_id': 'd1e-answer-attempt',
    'question_id': _questionId,
    'session_kind': 'normal',
    'modality': 'choice',
    'answer_payload_json': '{"version":1,"kind":"choice","option_ids":["A"]}',
    'correctness': 1,
    'answered_at': 1,
    'duration_ms': 1000,
  });
}

Future<void> _pumpImportScreen(
  WidgetTester tester,
  _QuestionBankConfirmationPersistence persistence,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ImportScreen(
        loadBanks: () async => List<Map<String, dynamic>>.from(
          persistence.banks,
        ),
        questionBankMutation: QuestionBankMutationCommand(persistence),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectAllClearDataToRemain() async {
  final db = await _database();
  expect(await db.query('questions'), hasLength(1));
  expect(await db.query('review_states'), hasLength(1));
  expect(await db.query('review_logs'), hasLength(1));
  expect(await db.query('answer_attempts'), hasLength(1));
}

final class _ExamDeletePersistence extends Fake
    implements ExamMutationPersistencePort {
  bool paperExists = true;
  Object? deleteFailure;
  int deleteCalls = 0;

  @override
  Future<void> deleteExamPaper(String id) async {
    deleteCalls++;
    final failure = deleteFailure;
    if (failure != null) throw failure;
    paperExists = false;
  }
}

Future<void> _deleteExamAfterConfirmation(
  ExamMutationCommand command, {
  required bool confirmed,
}) async {
  if (!confirmed) return;
  await command.deleteExamPaper('d1e-paper');
}

Future<bool> _clearAllAfterConfirmation({required bool confirmed}) async {
  if (!confirmed) return false;
  await ReviewEngineService().clearAllData();
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  group('Question confirmation entry', () {
    testWidgets('cancel leaves the question untouched and never calls command',
        (tester) async {
      final repository = _QuestionConfirmationRepository(failDelete: false);
      await _pumpQuestionList(tester, repository);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 0);
      expect(find.byType(PersistedQuestionCard), findsOneWidget);
      expect(find.text('删除失败，请稍后重试'), findsNothing);
    });

    testWidgets('confirmation crosses the command boundary exactly once',
        (tester) async {
      final repository = _QuestionConfirmationRepository(failDelete: false);
      await _pumpQuestionList(tester, repository);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 1);
      expect(find.byType(PersistedQuestionCard), findsNothing);
      expect(find.text('删除失败，请稍后重试'), findsNothing);
    });

    testWidgets('delete failure keeps the question and shows no success state',
        (tester) async {
      final repository = _QuestionConfirmationRepository(failDelete: true);
      await _pumpQuestionList(tester, repository);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 1);
      expect(find.byType(PersistedQuestionCard), findsOneWidget);
      expect(find.text('删除失败，请稍后重试'), findsOneWidget);
      expect(find.textContaining('已删除'), findsNothing);
    });
  });

  group('QuestionBank confirmation entry', () {
    testWidgets('cancel leaves the bank and its question untouched',
        (tester) async {
      final persistence =
          _QuestionBankConfirmationPersistence(failDelete: false);
      await _pumpImportScreen(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 0);
      expect(persistence.banks, hasLength(1));
      expect(find.textContaining('已删除'), findsNothing);
    });

    testWidgets('confirmation executes the bank command and reports success',
        (tester) async {
      final persistence =
          _QuestionBankConfirmationPersistence(failDelete: false);
      await _pumpImportScreen(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 1);
      expect(persistence.banks, isEmpty);
      expect(find.text('题库 "$_bankName" 已删除'), findsOneWidget);
      expect(find.textContaining('删除失败'), findsNothing);
    });

    testWidgets('bank delete failure preserves data and avoids success state',
        (tester) async {
      final persistence =
          _QuestionBankConfirmationPersistence(failDelete: true);
      await _pumpImportScreen(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 1);
      expect(persistence.banks, hasLength(1));
      expect(find.textContaining('删除失败'), findsOneWidget);
      expect(find.textContaining('已删除'), findsNothing);
    });
  });

  group('ExamPaper command boundary', () {
    test('cancel stays before the ExamPaper command boundary', () async {
      final persistence = _ExamDeletePersistence();
      final command = ExamMutationCommand(persistence);

      await _deleteExamAfterConfirmation(command, confirmed: false);

      expect(persistence.deleteCalls, 0);
      expect(persistence.paperExists, isTrue);
    });

    test('explicit confirmation executes the ExamPaper command once', () async {
      final persistence = _ExamDeletePersistence();
      final command = ExamMutationCommand(persistence);

      await _deleteExamAfterConfirmation(command, confirmed: true);

      expect(persistence.deleteCalls, 1);
      expect(persistence.paperExists, isFalse);
    });

    test(
        'ExamPaper delete failure preserves the paper and does not report success',
        () async {
      final persistence = _ExamDeletePersistence()
        ..deleteFailure = StateError('d1e synthetic exam delete failure');
      final command = ExamMutationCommand(persistence);

      await expectLater(
        _deleteExamAfterConfirmation(command, confirmed: true),
        throwsA(isA<StateError>()),
      );

      expect(persistence.deleteCalls, 1);
      expect(persistence.paperExists, isTrue);
    });
  });

  group('clear-all application boundary', () {
    test('cancel stays before the clear-all service boundary', () async {
      await _seedQuestionData();

      final executed = await _clearAllAfterConfirmation(confirmed: false);

      await _expectAllClearDataToRemain();
      expect(executed, isFalse);
    });

    test('confirmation executes clear-all and reports success', () async {
      await _seedQuestionData();

      final executed = await _clearAllAfterConfirmation(confirmed: true);

      final db = await _database();
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('review_logs'), isEmpty);
      expect(await db.query('answer_attempts'), isEmpty);
      expect(executed, isTrue);
    });

    test('clear-all failure rolls back data and does not report success',
        () async {
      await _seedQuestionData();
      final db = await _database();
      await db.execute('''
        CREATE TRIGGER d1e_block_clear_all
        BEFORE DELETE ON review_logs
        BEGIN
          SELECT RAISE(ABORT, 'd1e synthetic clear-all failure');
        END;
      ''');

      var successReported = false;
      await expectLater(
        _clearAllAfterConfirmation(confirmed: true).then((executed) {
          successReported = executed;
          return executed;
        }),
        throwsA(isA<Exception>()),
      );

      await _expectAllClearDataToRemain();
      expect(successReported, isFalse);
    });
  });
}
