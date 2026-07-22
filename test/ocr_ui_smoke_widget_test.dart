import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/main_ocr_ui_smoke.dart';

class _SmokeQuestionRepository extends Fake implements QuestionRepository {
  var saveCalls = 0;
  final List<Map<String, dynamic>> savedQuestions = [];

  @override
  Future<List<String>> getAvailableFolders() async => const [];

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    saveCalls++;
    savedQuestions
      ..clear()
      ..addAll(questions.map((question) => {
            'id': 'fixture-${savedQuestions.length}',
            'type': question.type.code,
            'content': question.content,
            'options': jsonEncode(question.options),
            'standard_answer':
                '${question.standardAnswer}|||${question.explanation}',
          }));
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestionsByBank(String bankName) async {
    return savedQuestions.map(Map<String, dynamic>.from).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> searchQuestions(
    String bankName,
    String query,
  ) async {
    return getQuestionsByBank(bankName);
  }
}

const _question = <String, dynamic>{
  'q_num': '1',
  'type': 0,
  'content': 'Synthetic question',
  'options': ['A', 'B'],
  'standard_answer': 'A',
  'explanation': '',
};

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw StateError('Expected widget was not rendered.');
}

OcrUiSmokeConfig _config({
  bool commit = false,
  int? expectedQuestionCount,
}) {
  return OcrUiSmokeConfig(
    relativePdfPath: 'math/single/fixture.pdf',
    resolvedPdfPath: 'fixture.pdf',
    fileName: 'fixture.pdf',
    commit: commit,
    expectedQuestionCount: expectedQuestionCount,
    expectedNumbers: const [1],
    closeOnSuccess: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final manager = TaskManager.forTesting();
  var sequence = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await manager.ready;
    manager.tasks.clear();
    sequence++;
  });

  tearDown(() {
    manager.tasks.clear();
  });

  testWidgets('review mode opens the real staging screen without committing',
      (tester) async {
    final repository = _SmokeQuestionRepository();
    final lines = <String>[];
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: [_question],
      ),
      taskIdFactory: () => 'task-review-$sequence',
      traceIdFactory: () => 'trace-review-$sequence',
    );

    await tester.pumpWidget(OcrUiSmokeApp(
      config: _config(),
      taskCoordinator: coordinator,
      commitService: ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      ),
      taskManager: manager,
      eventWriter: OcrUiSmokeEventWriter(lines.add),
      questionRepository: repository,
    ));
    await _pumpUntil(tester, find.byType(ImportStagingScreen));

    expect(repository.saveCalls, 0);
    expect(
      lines.map((line) => jsonDecode(line)).where(
            (event) =>
                event['stage'] == 'ui_ready' &&
                event['screen'] == 'import_review',
          ),
      isNotEmpty,
    );
  });

  testWidgets('commit mode uses the shared service and opens question list',
      (tester) async {
    final repository = _SmokeQuestionRepository();
    final lines = <String>[];
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: [_question],
      ),
      taskIdFactory: () => 'task-commit-$sequence',
      traceIdFactory: () => 'trace-commit-$sequence',
    );

    await tester.pumpWidget(OcrUiSmokeApp(
      config: _config(commit: true, expectedQuestionCount: 1),
      taskCoordinator: coordinator,
      commitService: ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      ),
      taskManager: manager,
      eventWriter: OcrUiSmokeEventWriter(lines.add),
      questionRepository: repository,
    ));
    await _pumpUntil(tester, find.byType(QuestionListScreen));
    await tester.pump();

    expect(repository.saveCalls, 1);
    expect(
      lines.map((line) => jsonDecode(line)).where(
            (event) =>
                event['stage'] == 'ui_ready' &&
                event['screen'] == 'question_list' &&
                event['questionCount'] == 1,
          ),
      isNotEmpty,
    );
  });

  testWidgets('hard quality gate remains on review and prevents auto commit',
      (tester) async {
    final repository = _SmokeQuestionRepository();
    final lines = <String>[];
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: [_question],
        diagnostics: {
          'qualityGate': {'blocked': true, 'reason': 'synthetic gate'},
        },
      ),
      taskIdFactory: () => 'task-blocked-$sequence',
      traceIdFactory: () => 'trace-blocked-$sequence',
    );

    await tester.pumpWidget(OcrUiSmokeApp(
      config: _config(commit: true),
      taskCoordinator: coordinator,
      commitService: ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      ),
      taskManager: manager,
      eventWriter: OcrUiSmokeEventWriter(lines.add),
      questionRepository: repository,
    ));
    await _pumpUntil(tester, find.byType(ImportStagingScreen));
    await tester.pump(const Duration(milliseconds: 50));

    expect(repository.saveCalls, 0);
    expect(find.byType(QuestionListScreen), findsNothing);
    expect(
      lines.map((line) => jsonDecode(line)).where(
            (event) => event['status'] == 'quality_gate_blocked',
          ),
      isNotEmpty,
    );
  });
}
