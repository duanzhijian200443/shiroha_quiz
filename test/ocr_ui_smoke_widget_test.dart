import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
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
            'bank_name': bankName,
            'type': question.type.code,
            'content': question.content,
            'options': jsonEncode(question.options),
            'standard_answer':
                '${question.standardAnswer}|||${question.explanation}',
          }));
  }

  @override
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    return [
      for (final saved in savedQuestions)
        if (saved['bank_name'] == bankName)
          LegacyPersistedQuestion(
            question: Question.fromMap(saved),
          ),
    ];
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

Map<String, dynamic> _questionWithNumber(
  int number, {
  String? content,
  List<Object> options = const <Object>['A', 'B'],
}) {
  return <String, dynamic>{
    'q_num': '$number',
    'type': 0,
    'content': content ?? 'Synthetic question $number',
    'options': options,
    'standard_answer': 'A',
    'explanation': '',
  };
}

class _ThrowingStringValue {
  const _ThrowingStringValue();

  @override
  String toString() => throw StateError('Synthetic staging build failure.');
}

Iterable<Map<String, dynamic>> _events(List<String> lines) {
  return lines.map((line) => jsonDecode(line) as Map<String, dynamic>);
}

bool _hasUiReadySuccess(List<String> lines) {
  return _events(lines).any(
    (event) => event['stage'] == 'ui_ready' && event['status'] == 'success',
  );
}

Iterable<Map<String, dynamic>> _terminalEvents(List<String> lines) {
  return _events(lines).where(
    (event) =>
        event['stage'] == 'validation' ||
        event['stage'] == 'failed' ||
        event['stage'] == 'ui_ready',
  );
}

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
  List<int> expectedNumbers = const <int>[1],
}) {
  return OcrUiSmokeConfig(
    relativePdfPath: 'math/single/fixture.pdf',
    resolvedPdfPath: 'fixture.pdf',
    fileName: 'fixture.pdf',
    commit: commit,
    expectedQuestionCount: expectedQuestionCount,
    expectedNumbers: expectedNumbers,
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
    final parseResult = Completer<ImportParseResult>();
    bool? reviewScreenPresentWhenReady;
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) => parseResult.future,
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
      eventWriter: OcrUiSmokeEventWriter((line) {
        lines.add(line);
        final event = jsonDecode(line) as Map<String, dynamic>;
        if (event['stage'] == 'ui_ready' &&
            event['screen'] == 'import_review') {
          reviewScreenPresentWhenReady =
              find.byType(ImportStagingScreen).evaluate().isNotEmpty;
        }
      }),
      questionRepository: repository,
    ));
    await tester.pump();

    expect(_hasUiReadySuccess(lines), isFalse);
    parseResult.complete(const ImportParseResult(questions: [_question]));
    await _pumpUntil(tester, find.byType(ImportStagingScreen));
    await tester.pump();

    expect(repository.saveCalls, 0);
    expect(_hasUiReadySuccess(lines), isTrue);
    expect(reviewScreenPresentWhenReady, isTrue);
  });

  testWidgets('commit mode uses the shared service and opens question list',
      (tester) async {
    final repository = _SmokeQuestionRepository();
    final lines = <String>[];
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: <Map<String, dynamic>>[
          _questionWithNumber(1),
          _questionWithNumber(2),
          _questionWithNumber(3),
        ],
      ),
      taskIdFactory: () => 'task-commit-$sequence',
      traceIdFactory: () => 'trace-commit-$sequence',
    );

    await tester.pumpWidget(OcrUiSmokeApp(
      config: _config(
        commit: true,
        expectedQuestionCount: 3,
        expectedNumbers: const <int>[],
      ),
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
      _events(lines).where(
        (event) =>
            event['stage'] == 'ui_ready' &&
            event['screen'] == 'question_list' &&
            event['questionCount'] == 3,
      ),
      isNotEmpty,
    );
  });

  testWidgets('quality gate blocks non-commit review without success output',
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
      config: _config(commit: false),
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
      _terminalEvents(lines),
      contains(predicate<Map<String, dynamic>>(
        (event) =>
            event['stage'] == 'validation' &&
            event['status'] == 'quality_gate_blocked' &&
            event['traceId'] == 'trace-blocked-$sequence' &&
            event['qualityGateBlocked'] == true,
      )),
    );
    expect(_hasUiReadySuccess(lines), isFalse);
    expect(_terminalEvents(lines), hasLength(1));
    expect(jsonEncode(lines), isNot(contains('synthetic gate')));
  });

  testWidgets('quality gate blocks commit mode before repository commit',
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
      taskIdFactory: () => 'task-commit-blocked-$sequence',
      traceIdFactory: () => 'trace-commit-blocked-$sequence',
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
      _terminalEvents(lines),
      contains(predicate<Map<String, dynamic>>(
        (event) =>
            event['stage'] == 'validation' &&
            event['status'] == 'quality_gate_blocked' &&
            event['traceId'] == 'trace-commit-blocked-$sequence',
      )),
    );
    expect(_hasUiReadySuccess(lines), isFalse);
    expect(_terminalEvents(lines), hasLength(1));
  });

  testWidgets('reordered question numbers fail validation before commit',
      (tester) async {
    final repository = _SmokeQuestionRepository();
    final lines = <String>[];
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: <Map<String, dynamic>>[
          _questionWithNumber(1),
          _questionWithNumber(3),
          _questionWithNumber(2),
        ],
      ),
      taskIdFactory: () => 'task-reordered-$sequence',
      traceIdFactory: () => 'trace-reordered-$sequence',
    );

    await tester.pumpWidget(OcrUiSmokeApp(
      config: _config(
        commit: true,
        expectedQuestionCount: 3,
        expectedNumbers: const <int>[1, 2, 3],
      ),
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
    await tester.pump();

    expect(repository.saveCalls, 0);
    expect(find.byType(QuestionListScreen), findsNothing);
    expect(
      _events(lines),
      contains(predicate<Map<String, dynamic>>(
        (event) =>
            event['stage'] == 'validation' &&
            event['status'] == 'unexpected_question_numbers' &&
            event['duplicateQuestionNumberCount'] == 0 &&
            event['missingQuestionNumberCount'] == 0,
      )),
    );
    expect(_hasUiReadySuccess(lines), isFalse);
  });

  testWidgets(
      'duplicate raw question numbers override final count and quality gate',
      (tester) async {
    final repository = _SmokeQuestionRepository();
    final lines = <String>[];
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: <Map<String, dynamic>>[
          _questionWithNumber(1),
          _questionWithNumber(2),
          _questionWithNumber(2),
          _questionWithNumber(3),
        ],
        diagnostics: const <String, dynamic>{
          'qualityGate': <String, dynamic>{'blocked': true},
        },
      ),
      taskIdFactory: () => 'task-duplicate-$sequence',
      traceIdFactory: () => 'trace-duplicate-$sequence',
    );

    await tester.pumpWidget(OcrUiSmokeApp(
      config: _config(
        commit: true,
        expectedQuestionCount: 3,
        expectedNumbers: const <int>[],
      ),
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
    await tester.pump();

    expect(repository.saveCalls, 0);
    expect(find.byType(QuestionListScreen), findsNothing);
    expect(
      _events(lines),
      contains(predicate<Map<String, dynamic>>(
        (event) =>
            event['stage'] == 'validation' &&
            event['status'] == 'duplicate_question_numbers' &&
            event['questionCount'] == 3 &&
            event['rawQuestionNumberCount'] == 4 &&
            event['finalQuestionCount'] == 3 &&
            event['duplicateQuestionNumberCount'] == 1 &&
            event['qualityGateBlocked'] == true,
      )),
    );
    expect(_hasUiReadySuccess(lines), isFalse);
    expect(_terminalEvents(lines), hasLength(1));
  });

  testWidgets('staging screen build failure never reports ui ready',
      (tester) async {
    final repository = _SmokeQuestionRepository();
    final lines = <String>[];
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: <Map<String, dynamic>>[
          _questionWithNumber(
            1,
            options: const <Object>[_ThrowingStringValue()],
          ),
        ],
      ),
      taskIdFactory: () => 'task-build-failure-$sequence',
      traceIdFactory: () => 'trace-build-failure-$sequence',
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

    Object? buildException;
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      buildException ??= tester.takeException();
      if (_events(lines).any(
        (event) => event['status'] == 'review_screen_build_failed',
      )) {
        break;
      }
    }

    expect(buildException, isA<StateError>());
    expect(_hasUiReadySuccess(lines), isFalse);
    expect(
      _events(lines),
      contains(predicate<Map<String, dynamic>>(
        (event) =>
            event['stage'] == 'failed' &&
            event['status'] == 'review_screen_build_failed' &&
            event['causeType'] == 'StateError',
      )),
    );
  });
}
