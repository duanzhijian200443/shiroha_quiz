import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_bank_mutation_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:shiroha_quiz/ui/pages/bank_detail_screen.dart';
import 'package:shiroha_quiz/ui/pages/import_screen.dart';
import 'package:shiroha_quiz/ui/pages/mock_center_screen.dart';
import 'package:shiroha_quiz/ui/pages/profile_page.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/memory_engine_credential_store.dart';

const _questionId = 'd1e-question';
const _bankName = 'd1e-bank';
const _paperId = 'd1e-paper';

const _transparentPng = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xd7,
  0x63,
  0xf8,
  0xcf,
  0xc0,
  0xf0,
  0x1f,
  0x00,
  0x05,
  0x00,
  0x01,
  0xff,
  0x89,
  0x99,
  0x3d,
  0x1d,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

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

Future<void> _pumpBankDetailScreen(
  WidgetTester tester,
  _QuestionBankConfirmationPersistence persistence,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BankDetailScreen(
        bankName: _bankName,
        questionBankMutation: QuestionBankMutationCommand(persistence),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpMockCenter(
  WidgetTester tester,
  _ExamDeletePersistence persistence, {
  int status = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MockCenterScreen(
        loadPapers: () async => persistence.paperExists
            ? <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': _paperId,
                  'title': 'D1E paper',
                  'source_type': 0,
                  'status': status,
                  'score': 0.0,
                  'total_score': 1.0,
                  'created_at': 1,
                },
              ]
            : <Map<String, dynamic>>[],
        examMutationCommand: ExamMutationCommand(persistence),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpProfilePage(
  WidgetTester tester,
  Future<void> Function() clearAllDataAction,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ProfilePage(
        clearAllDataAction: clearAllDataAction,
        avatarImage: MemoryImage(Uint8List.fromList(_transparentPng)),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpProfileTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _expectAllClearDataEmpty() async {
  final db = await _database();
  expect(await db.query('questions'), isEmpty);
  expect(await db.query('review_states'), isEmpty);
  expect(await db.query('review_logs'), isEmpty);
  expect(await db.query('answer_attempts'), isEmpty);
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

final class _ClearAllConfirmationState {
  bool hasData = true;
  bool failClear = false;
  int clearCalls = 0;

  Future<void> clear() async {
    clearCalls++;
    if (failClear) throw StateError('d1e synthetic clear-all failure');
    hasData = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final reviewEngine = ReviewEngineService();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await reviewEngine.flushPending();
    reviewEngine.resetTransientStateForRestore();
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    await reviewEngine.flushPending();
    reviewEngine.resetTransientStateForRestore();
    SettingsRepository.instance.clearCache();
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

  group('ExamPaper confirmation entry', () {
    testWidgets('active grading has no delete confirmation entry',
        (tester) async {
      final persistence = _ExamDeletePersistence();
      await _pumpMockCenter(tester, persistence, status: 1);

      expect(find.text('批改中'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(persistence.deleteCalls, 0);
    });

    testWidgets('cancel leaves the paper untouched and never calls command',
        (tester) async {
      final persistence = _ExamDeletePersistence();
      await _pumpMockCenter(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 0);
      expect(persistence.paperExists, isTrue);
      expect(find.text('D1E paper'), findsOneWidget);
      expect(find.text('试卷已删除'), findsNothing);
    });

    testWidgets('confirmation executes the ExamPaper command once',
        (tester) async {
      final persistence = _ExamDeletePersistence();
      await _pumpMockCenter(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 1);
      expect(persistence.paperExists, isFalse);
      expect(find.text('D1E paper'), findsNothing);
      expect(find.text('试卷已删除'), findsOneWidget);
    });

    testWidgets(
        'delete failure preserves the paper and does not report success',
        (tester) async {
      final persistence = _ExamDeletePersistence()
        ..deleteFailure = StateError('d1e synthetic exam delete failure');
      await _pumpMockCenter(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 1);
      expect(persistence.paperExists, isTrue);
      expect(find.text('D1E paper'), findsOneWidget);
      expect(find.textContaining('删除试卷失败'), findsOneWidget);
      expect(find.text('试卷已删除'), findsNothing);
    });
  });

  group('BankDetailScreen confirmation entry', () {
    testWidgets('cancel leaves the bank untouched and never calls command',
        (tester) async {
      final persistence =
          _QuestionBankConfirmationPersistence(failDelete: false);
      await _pumpBankDetailScreen(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 0);
      expect(persistence.banks, hasLength(1));
      expect(find.textContaining('题库已删除'), findsNothing);
    });

    testWidgets('confirmation executes the bank command once', (tester) async {
      final persistence =
          _QuestionBankConfirmationPersistence(failDelete: false);
      await _pumpBankDetailScreen(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('彻底删除'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 1);
      expect(persistence.banks, isEmpty);
      expect(find.textContaining('题库已删除'), findsNothing);
    });

    testWidgets('delete failure preserves the bank and avoids success state',
        (tester) async {
      final persistence =
          _QuestionBankConfirmationPersistence(failDelete: true);
      await _pumpBankDetailScreen(tester, persistence);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('彻底删除'));
      await tester.pumpAndSettle();

      expect(persistence.deleteCalls, 1);
      expect(persistence.banks, hasLength(1));
      expect(find.textContaining('删除失败'), findsOneWidget);
      expect(find.textContaining('题库已删除'), findsNothing);
    });
  });

  group('ProfilePage clear-all confirmation entry', () {
    testWidgets('cancel leaves clear-all data untouched', (tester) async {
      final state = _ClearAllConfirmationState();
      await _pumpProfilePage(tester, state.clear);

      await tester.tap(find.text('清除缓存 / 重置数据库'));
      await _pumpProfileTransition(tester);
      await tester.tap(find.text('取消'));
      await _pumpProfileTransition(tester);

      expect(state.clearCalls, 0);
      expect(state.hasData, isTrue);
      expect(find.text('数据已清空'), findsNothing);
    });

    testWidgets('confirmation executes clear-all and reports success',
        (tester) async {
      final state = _ClearAllConfirmationState();
      await _pumpProfilePage(tester, state.clear);

      await tester.tap(find.text('清除缓存 / 重置数据库'));
      await _pumpProfileTransition(tester);
      await tester.tap(find.text('确认清除'));
      await _pumpProfileTransition(tester);

      expect(state.clearCalls, 1);
      expect(state.hasData, isFalse);
      expect(find.text('数据已清空'), findsOneWidget);
    });

    testWidgets('clear-all failure preserves data and avoids success state',
        (tester) async {
      final state = _ClearAllConfirmationState()..failClear = true;
      await _pumpProfilePage(tester, state.clear);

      await tester.tap(find.text('清除缓存 / 重置数据库'));
      await _pumpProfileTransition(tester);
      await tester.tap(find.text('确认清除'));
      await _pumpProfileTransition(tester);

      expect(state.clearCalls, 1);
      expect(state.hasData, isTrue);
      expect(find.textContaining('清除失败'), findsOneWidget);
      expect(find.text('数据已清空'), findsNothing);
    });

    test('clear-all drains an accepted pending review before purging',
        () async {
      await _seedQuestionData();
      final repository = AiEngineRepository(
        store: DatabaseHelper.instance,
        credentialStore: MemoryEngineCredentialStore(),
      );

      await reviewEngine.submitReviewResult(
        _questionId,
        3,
        1200,
        engineRepository: repository,
      );
      await reviewEngine.clearAllData();
      await reviewEngine.flushPending();

      await _expectAllClearDataEmpty();
    });
  });
}
