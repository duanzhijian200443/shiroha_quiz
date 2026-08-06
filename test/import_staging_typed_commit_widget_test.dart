// R7C staging wiring contract: route resolution, strict typed inputs by
// originalIndex, no legacy fallback, fixed error text, and success
// notification ordering. Synthetic fixtures only; no Provider, Replay,
// network, real database, filesystem or application call site.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/bank_update_notifier.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

const _taskId = 'typed-widget-task';
const _attemptToken = 'typed-widget-attempt';

const _reviewItemIdA = '44444444-4444-4444-8444-000000000001';
const _questionIdA = '22222222-2222-4222-8222-000000000001';
const _sourceIdA = '11111111-1111-4111-8111-000000000001';
const _reviewItemIdB = '44444444-4444-4444-8444-000000000002';
const _questionIdB = '22222222-2222-4222-8222-000000000002';
const _sourceIdB = '11111111-1111-4111-8111-000000000002';

class _FakeRepo extends Fake implements QuestionRepository {
  int legacySaveCalls = 0;
  int typedSaveCalls = 0;
  Object? typedFailure;
  List<QuestionDraft>? savedLegacy;
  List<QuestionDraftV2>? savedTyped;

  @override
  Future<List<String>> getAvailableFolders() async => const <String>['Math'];

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    legacySaveCalls++;
    savedLegacy = List<QuestionDraft>.unmodifiable(questions);
  }

  @override
  Future<void> saveQuestionDraftsV2ToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraftV2> questions,
  }) async {
    typedSaveCalls++;
    savedTyped = List<QuestionDraftV2>.unmodifiable(questions);
    if (typedFailure != null) throw typedFailure!;
  }
}

Map<String, Object?> _envelope({
  required String reviewItemId,
  required String questionId,
  required String sourceId,
  required int questionNumber,
  String content = 'Synthetic stem',
  String standardAnswer = 'Conclusion',
  String explanation = 'Subjective explanation',
}) {
  final draft = QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: questionNumber,
    stem: RichContent(nodes: <ContentNode>[TextNode(content)]),
    answer: ContentAnswer(
      content: RichContent(nodes: <ContentNode>[TextNode(standardAnswer)]),
    ),
    explanation: RichContent(
      nodes: <ContentNode>[TextNode(explanation)],
    ),
    sourceRefs: <SourceRef>[
      SourceRef.document(sourceId: sourceId, displayLabel: null),
    ],
  );
  return const TypedReviewSnapshotCodec().encode(
    TypedReviewSnapshot(
      reviewItemId: reviewItemId,
      questionId: questionId,
      draft: draft,
      baselineLegacy: LegacyReviewBaseline(
        type: 3,
        questionNumber: questionNumber,
        content: content,
        options: const <String>[],
        standardAnswer: standardAnswer,
        explanation: explanation,
      ),
    ),
  );
}

Map<String, dynamic> _typedQuestion({
  required int number,
  String content = 'Synthetic stem',
  String standardAnswer = 'Conclusion',
  String explanation = 'Subjective explanation',
  bool withMarker = true,
  Map<String, Object?>? envelope,
  Map<String, dynamic>? reviewMetadata,
}) {
  final isA = number == 1;
  return <String, dynamic>{
    'q_num': number.toString(),
    'question_number': number,
    'type': 3,
    'content': content,
    'options': <String>[],
    'standard_answer': standardAnswer,
    'explanation': explanation,
    'raw_explanation': explanation,
    if (withMarker)
      TaskManager.keyReviewItemId: isA ? _reviewItemIdA : _reviewItemIdB,
    if (reviewMetadata != null) '_import_review': reviewMetadata,
    TypedReviewSnapshotCodec.mapKey: envelope ??
        (isA
            ? _envelope(
                reviewItemId: _reviewItemIdA,
                questionId: _questionIdA,
                sourceId: _sourceIdA,
                questionNumber: 1,
                content: content,
                standardAnswer: standardAnswer,
                explanation: explanation,
              )
            : _envelope(
                reviewItemId: _reviewItemIdB,
                questionId: _questionIdB,
                sourceId: _sourceIdB,
                questionNumber: 2,
                content: content,
                standardAnswer: standardAnswer,
                explanation: explanation,
              )),
  };
}

Map<String, dynamic> _typedDiagnostics() {
  return <String, dynamic>{
    TaskManager.keyImportStorageRoute: 'typedV2',
    TaskManager.keyImportStorageReason: 'typed_candidate_ready',
    TaskManager.keyAttemptToken: _attemptToken,
    TaskManager.keyAttemptNumber: 1,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRepo repo;
  late TaskManager manager;

  setUp(() {
    repo = _FakeRepo();
    manager = TaskManager.forTesting();
  });

  tearDown(() {
    manager.tasks.clear();
  });

  Widget buildScreen({
    required List<Map<String, dynamic>> questions,
    Map<String, dynamic>? diagnostics,
    String? taskId,
  }) {
    if (taskId != null) {
      manager.tasks.add(ImportTask(
        id: taskId,
        title: 'Synthetic typed import',
        status: TaskStatus.pendingReview,
        diagnostics: diagnostics ?? _typedDiagnostics(),
      ));
    }
    return MaterialApp(
      home: Scaffold(
        body: ImportStagingScreen(
          parsedQuestions: questions,
          taskId: taskId,
          diagnostics: diagnostics,
          questionRepository: repo,
          taskManager: manager,
          commitService: ImportCommitService(
            questionRepository: repo,
            taskManager: manager,
          ),
        ),
      ),
    );
  }

  Future<void> commitThroughDialog(WidgetTester tester) async {
    await tester.tap(find.textContaining('收入题库'));
    await tester.pumpAndSettle();
    if (find.text('继续').evaluate().isNotEmpty) {
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(
      find.widgetWithText(TextField, '目标题库名称'),
      'Typed Bank',
    );
    await tester.tap(find.text('确定入库'));
    await tester.pumpAndSettle();
  }

  testWidgets('missing route uses the legacy commit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: const <String, dynamic>{},
      taskId: null,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(repo.legacySaveCalls, 1);
    expect(repo.typedSaveCalls, 0);
    expect(find.text('本次导入报告'), findsOneWidget);
  });

  testWidgets('legacyV1 route uses the legacy commit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: const <String, dynamic>{
        TaskManager.keyImportStorageRoute: 'legacyV1',
      },
      taskId: null,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(repo.legacySaveCalls, 1);
    expect(repo.typedSaveCalls, 0);
  });

  testWidgets('historical legacyV1 + shadow_ready uses the legacy commit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: const <String, dynamic>{
        TaskManager.keyImportStorageRoute: 'legacyV1',
        TaskManager.keyImportStorageReason: 'typed_candidate_shadow_ready',
      },
      taskId: null,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(repo.legacySaveCalls, 1);
    expect(repo.typedSaveCalls, 0);
  });

  testWidgets('typedV2 + ready uses the typed commit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    final notifierBefore = globalBankUpdateNotifier.value;
    await commitThroughDialog(tester);

    expect(repo.typedSaveCalls, 1);
    expect(repo.legacySaveCalls, 0);
    expect(repo.savedTyped, hasLength(1));
    expect(repo.savedTyped!.single.questionId, _questionIdA);
    expect(globalBankUpdateNotifier.value, notifierBefore + 1);
    expect(manager.tasks.single.status, TaskStatus.completed);
    expect(find.text('本次导入报告'), findsOneWidget);
  });

  testWidgets('typedV2 without a reason blocks the commit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: const <String, dynamic>{
        TaskManager.keyImportStorageRoute: 'typedV2',
        TaskManager.keyAttemptToken: _attemptToken,
        TaskManager.keyAttemptNumber: 1,
      },
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(find.text('当前任务的存储路线无效，无法入库'), findsOneWidget);
    expect(repo.typedSaveCalls, 0);
    expect(repo.legacySaveCalls, 0);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  testWidgets('typedV2 without an envelope blocks the commit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final question = _typedQuestion(number: 1)
      ..remove(
        TypedReviewSnapshotCodec.mapKey,
      );
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[question],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(
      find.text('结构化题目缺少必要的审核信息，无法入库，请检查后重试'),
      findsOneWidget,
    );
    expect(repo.typedSaveCalls, 0);
    expect(repo.legacySaveCalls, 0);
  });

  testWidgets('corrupt envelope blocks before any repository call',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final question = _typedQuestion(
      number: 1,
      envelope: <String, Object?>{
        'schemaVersion': 1,
        'route': 'typedV2',
        'reviewItemId': _reviewItemIdA,
        'questionId': _questionIdA,
        'draft': <String, Object?>{'broken': true},
        'baselineLegacy': <String, Object?>{'broken': true},
        'unexpected': 'extra',
      },
    );
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[question],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(find.text('结构化题库入库失败，题目保持待审状态，请检查后重试'), findsOneWidget);
    expect(repo.typedSaveCalls, 0);
    expect(repo.legacySaveCalls, 0);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  testWidgets('typed repository error never calls the legacy commit',
      (tester) async {
    repo.typedFailure = StateError('synthetic-db-error');
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    final notifierBefore = globalBankUpdateNotifier.value;
    await commitThroughDialog(tester);

    expect(repo.typedSaveCalls, 1);
    expect(repo.legacySaveCalls, 0,
        reason: 'typed failure must never fall back to the legacy writer');
    expect(find.text('结构化题库入库失败，题目保持待审状态，请检查后重试'), findsOneWidget);
    expect(globalBankUpdateNotifier.value, notifierBefore);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  testWidgets('typed errors never render raw exception text', (tester) async {
    repo.typedFailure = StateError('private-secret-db-payload');
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(find.textContaining('private-secret-db-payload'), findsNothing);
    expect(find.textContaining('入库失败:'), findsNothing);
    expect(find.textContaining('schemaVersion'), findsNothing);
  });

  testWidgets('typed error keeps the staging page open', (tester) async {
    repo.typedFailure = StateError('synthetic');
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(find.textContaining('收入题库'), findsOneWidget,
        reason: 'the page must stay open after a typed failure');
    expect(find.text('本次导入报告'), findsNothing);
  });

  testWidgets('current visible sort never changes originalIndex association',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    final riskySecond = _typedQuestion(
      number: 2,
      content: 'Risky second stem',
      standardAnswer: 'Conclusion B',
      explanation: 'Explanation B',
      reviewMetadata: <String, dynamic>{
        'source': 'vision',
        'sources': <String>['doc.pdf'],
        'fragmentKinds': <String>['fullQuestion'],
        'originalIndices': <int>[1],
        'riskHints': <String>['answer_conflict'],
      },
    );
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(number: 1),
        riskySecond,
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    // Flip the visible order to risk-first so the snapshot association can
    // only survive through originalIndex, never through visible position.
    await tester.tap(find.text('原始顺序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('风险优先').last);
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(repo.typedSaveCalls, 1);
    expect(
      repo.savedTyped!.map((draft) => draft.questionId).toList(),
      <String>[_questionIdA, _questionIdB],
      reason: 'the commit set must follow originalIndex, not the sort order',
    );
    expect(repo.savedTyped![1].stem.nodes.single, isA<TextNode>());
  });

  testWidgets('deleting one question commits only the remaining items',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(number: 1),
        _typedQuestion(
          number: 2,
          content: 'Second synthetic stem',
          standardAnswer: 'Conclusion B',
          explanation: 'Explanation B',
        ),
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(repo.typedSaveCalls, 1);
    expect(repo.savedTyped, hasLength(1));
    expect(repo.savedTyped!.single.questionId, _questionIdA,
        reason: 'the deleted question must not enter the commit set');
  });

  testWidgets('restarted tasks can still construct typed inputs',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    // A restarted attempt has fresh parsed data: envelopes are present but
    // no persisted _reviewItemId marker exists yet.
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(number: 1, withMarker: false),
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(repo.typedSaveCalls, 1);
    expect(repo.legacySaveCalls, 0);
    expect(repo.savedTyped!.single.questionId, _questionIdA);
    expect(manager.tasks.single.status, TaskStatus.completed);
  });
}
