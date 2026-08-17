import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

const _uuidA = '0d8b7a3e-7f1c-4b2a-9d3e-5a6b7c8d9e0f';
const _uuidB = '1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d';
const _secretMarker = 'SYNTHETIC_R7A_SECRET_MARKER_9f3a';

class _QuestionRepository extends Fake implements QuestionRepository {
  @override
  Future<List<String>> getAvailableFolders() async => const <String>[];
}

class _FakeDistiller implements SubjectiveAnswerDistiller {
  @override
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return const SubjectiveAnswerDistillationResult.applied(
      'Generated concise answer',
    );
  }
}

Map<String, Object?> _envelope({bool withMarker = false}) {
  const codec = TypedReviewSnapshotCodec();
  final encoded = codec.encode(
    TypedReviewSnapshot(
      reviewItemId: _uuidA,
      questionId: _uuidB,
      draft: QuestionDraftV2(
        questionId: _uuidB,
        kind: QuestionKind.singleChoice,
        questionNumber: 1,
        stem: RichContent(nodes: const <ContentNode>[
          TextNode('Synthetic typed stem'),
        ]),
        options: <QuestionOption>[
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: RichContent(nodes: const <ContentNode>[
              TextNode('Synthetic option A'),
            ]),
          ),
        ],
        answer: ChoiceAnswer(optionIds: <String>['option_a']),
      ),
      baselineLegacy: LegacyReviewBaseline(
        type: 0,
        questionNumber: 1,
        content: 'Synthetic baseline',
        options: <String>['A'],
        standardAnswer: 'A',
        explanation: 'Synthetic explanation',
      ),
    ),
  );
  if (withMarker) {
    encoded['syntheticMarker'] = _secretMarker;
  }
  return encoded;
}

Map<String, dynamic> _question({
  required int number,
  int type = 0,
  String content = '',
  List<String> options = const <String>[],
  String standardAnswer = '',
  bool includeReviewItemId = true,
  bool withSecretMarker = false,
}) {
  return <String, dynamic>{
    'q_num': number,
    'question_number': number,
    'source_page_indices': <int>[number - 1],
    'source_block_ids': <String>['synthetic-block-$number'],
    'type': type,
    'content': content.isEmpty ? 'Synthetic question $number' : content,
    'options': options,
    'standard_answer': standardAnswer,
    'explanation': 'Synthetic explanation $number',
    if (includeReviewItemId) TaskManager.keyReviewItemId: 'review-item-$number',
    TypedReviewSnapshotCodec.mapKey: _envelope(withMarker: withSecretMarker),
  };
}

Widget _screen({
  required List<Map<String, dynamic>> questions,
  required TaskManager taskManager,
  SubjectiveAnswerDistiller? distiller,
}) {
  return MaterialApp(
    home: ImportStagingScreen(
      parsedQuestions: questions,
      taskId: 'synthetic-task',
      questionRepository: _QuestionRepository(),
      answerDistiller: distiller,
      taskManager: taskManager,
    ),
  );
}

TaskManager _taskManagerWith(
  List<Map<String, dynamic>> questions,
  List<Map<String, dynamic>> saved,
) {
  final taskManager = TaskManager.forTesting(
    saveTask: (taskMap) async {
      saved.add(Map<String, dynamic>.from(taskMap));
    },
  );
  taskManager.addTask(
    ImportTask(
      id: 'synthetic-task',
      title: 'Synthetic typed task',
      status: TaskStatus.pendingReview,
      parsedData: questions,
    ),
  );
  return taskManager;
}

String _json(Object? value) => jsonEncode(value);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('ImportStagingScreen typed envelope preservation', () {
    testWidgets('opens a pending-review task carrying a typed envelope',
        (tester) async {
      final saved = <Map<String, dynamic>>[];
      final questions = <Map<String, dynamic>>[_question(number: 1)];
      final taskManager = _taskManagerWith(questions, saved);
      await tester.pumpWidget(
        _screen(
          questions: questions,
          taskManager: taskManager,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Synthetic question 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('automatic review-draft persistence keeps the envelope',
        (tester) async {
      final saved = <Map<String, dynamic>>[];
      final questions = <Map<String, dynamic>>[
        _question(number: 1, includeReviewItemId: false),
      ];
      final taskManager = _taskManagerWith(questions, saved);
      await tester.pumpWidget(
        _screen(
          questions: questions,
          taskManager: taskManager,
        ),
      );
      await tester.pumpAndSettle();

      expect(saved, isNotEmpty);
      final persisted = ImportTask.fromMap(saved.last);
      final question = persisted.parsedData!.single;
      expect(
        _json(question[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
    });

    testWidgets('question modification keeps the envelope', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      final saved = <Map<String, dynamic>>[];
      final questions = <Map<String, dynamic>>[_question(number: 1)];
      final taskManager = _taskManagerWith(questions, saved);
      await tester.pumpWidget(
        _screen(
          questions: questions,
          taskManager: taskManager,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选当前'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('改题型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('填空题'));
      await tester.pumpAndSettle();

      final persisted = ImportTask.fromMap(saved.last);
      final question = persisted.parsedData!.single;
      expect(question['type'], 2);
      expect(
        _json(question[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
    });

    testWidgets('explanation retention mode change keeps the envelope',
        (tester) async {
      final saved = <Map<String, dynamic>>[];
      final questions = <Map<String, dynamic>>[_question(number: 1)];
      final taskManager = _taskManagerWith(questions, saved);
      await tester.pumpWidget(
        _screen(
          questions: questions,
          taskManager: taskManager,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('同时导入选择题、填空题解析'));
      await tester.pumpAndSettle();

      final persisted = ImportTask.fromMap(saved.last);
      final question = persisted.parsedData!.single;
      expect(
        persisted.diagnostics![TaskManager.keyExplanationRetentionMode],
        ExplanationRetentionMode.allQuestionTypes.name,
      );
      expect(
        _json(question[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
    });

    testWidgets('answer distillation state update keeps the envelope',
        (tester) async {
      final saved = <Map<String, dynamic>>[];
      final questions = <Map<String, dynamic>>[
        _question(
          number: 1,
          type: 3,
          options: const <String>[],
          standardAnswer: '',
        ),
      ];
      final taskManager = _taskManagerWith(questions, saved);
      await tester.pumpWidget(
        _screen(
          questions: questions,
          taskManager: taskManager,
          distiller: _FakeDistiller(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('answer-distillation-single-0')),
      );
      await tester.pumpAndSettle();

      final persisted = ImportTask.fromMap(saved.last);
      final question = persisted.parsedData!.single;
      expect(
        question[TaskManager.keyAnswerDistillationStatus],
        'ai_applied',
      );
      expect(
        _json(question[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
    });

    testWidgets('deleting one question removes only its envelope',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      final saved = <Map<String, dynamic>>[];
      final questions = <Map<String, dynamic>>[
        _question(number: 1),
        _question(number: 2),
      ];
      final taskManager = _taskManagerWith(questions, saved);
      await tester.pumpWidget(
        _screen(
          questions: questions,
          taskManager: taskManager,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Synthetic question 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      final persisted = ImportTask.fromMap(saved.last);
      expect(persisted.parsedData, hasLength(1));
      final remaining = persisted.parsedData!.single;
      expect(remaining['content'], 'Synthetic question 1');
      expect(
        _json(remaining[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope()),
      );
    });

    testWidgets('the UI never surfaces envelope keys, raw JSON or markers',
        (tester) async {
      final saved = <Map<String, dynamic>>[];
      final questions = <Map<String, dynamic>>[
        _question(number: 1, withSecretMarker: true),
      ];
      final taskManager = _taskManagerWith(questions, saved);
      await tester.pumpWidget(
        _screen(
          questions: questions,
          taskManager: taskManager,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('_typed_review_v1'), findsNothing);
      expect(find.textContaining(_secretMarker), findsNothing);
      expect(find.textContaining('"schemaVersion"'), findsNothing);

      final persisted = ImportTask.fromMap(saved.last);
      final question = persisted.parsedData!.single;
      expect(
        _json(question[TypedReviewSnapshotCodec.mapKey]),
        _json(_envelope(withMarker: true)),
      );
    });
  });

  group('R7A boundary proofs', () {
    test('ImportCommitService keeps the legacy writer and adds typed writer',
        () {
      final source =
          File('lib/services/import_review/import_commit_service.dart')
              .readAsStringSync();
      expect(source, contains('saveQuestionDraftsToBank'));
      expect(source, contains('saveQuestionDraftsV2ToBank'));
    });

    test('saveQuestionDraftsV2ToBank is called only by the typed commit', () {
      final libFiles = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList();
      final callSites = <String>[];
      for (final file in libFiles) {
        final source = file.readAsStringSync();
        if (source.contains('saveQuestionDraftsV2ToBank')) {
          callSites.add(file.path);
        }
      }
      callSites.sort();
      expect(callSites, <String>[
        'lib${Platform.pathSeparator}data${Platform.pathSeparator}repositories${Platform.pathSeparator}question_repository.dart',
        'lib${Platform.pathSeparator}services${Platform.pathSeparator}import_review${Platform.pathSeparator}import_commit_service.dart',
      ]);
    });

    test('OcrImportService has no typed candidate wiring', () {
      final source =
          File('lib/services/import_pipeline/ocr_import_service.dart')
              .readAsStringSync();
      expect(source, isNot(contains('TypedReviewSnapshot')));
      expect(source, isNot(contains('_typed_review_v1')));
    });

    test('database version follows the current answer attempt schema', () {
      final source =
          File('lib/core/database/database_helper.dart').readAsStringSync();
      expect(source,
          contains('static const int _dbVersion = answerAttemptSchemaVersion'));
    });

    test('v15 sidecar DDL sentinels remain unchanged', () {
      final source =
          File('lib/core/database/database_helper.dart').readAsStringSync();
      expect(
        source,
        contains('payload_schema_version INTEGER NOT NULL CHECK'),
      );
      expect(
        source,
        contains(
            'payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0)'),
      );
    });

    test('typed route corruption blocks instead of falling back to V1', () {
      const codec = TypedReviewSnapshotCodec();
      final legacyQuestion = <String, dynamic>{
        'type': 0,
        'content': 'Synthetic legacy question',
        'options': <String>['A', 'B'],
        'standard_answer': 'A',
      };

      expect(
        () => codec.requireTypedEnvelope(
          ImportStorageRoute.typedV2,
          legacyQuestion,
        ),
        throwsA(
          isA<TypedReviewSnapshotException>().having(
            (error) => error.failure,
            'failure',
            TypedReviewSnapshotFailure.routeMismatch,
          ),
        ),
      );
      expect(
        () => codec.requireTypedEnvelope(
          ImportStorageRoute.legacyV1,
          legacyQuestion,
        ),
        returnsNormally,
      );
    });
  });
}
