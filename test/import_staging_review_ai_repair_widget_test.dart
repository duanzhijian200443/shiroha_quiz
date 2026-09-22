// Review-time AI repair staging contract: proposal-first generation, zero
// mutation on generate/cancel/failure/staleness, CAS-guarded apply, and durable
// marker persistence. Synthetic fixtures only; no Provider, Replay, network,
// real database or filesystem.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/application/import_review/latex_fragment_repair.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/review_draft_cas.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_review/review_legacy_field_content.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_edit.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_policy.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/widgets/review_repair_proposal_dialog.dart';

const String _taskId = 'review-ai-repair-task';
const String _reviewItemId = '44444444-4444-4444-8444-000000000021';
const String _questionId = '22222222-2222-4222-8222-000000000021';
const String _secondReviewItemId = '44444444-4444-4444-8444-000000000022';
const String _secondQuestionId = '22222222-2222-4222-8222-000000000022';
const String _brokenExplanation = r'推导 $$\begin{array}{l}x_1=1\\x_2=2$$';
const String _repairedExplanation =
    r'推导 $$\begin{array}{l}x_1=1\\x_2=2\end{array}$$';
const String _brokenFragment = r'\begin{array}{l}x_1=1\\x_2=2';
const String _repairedFragment = r'\begin{array}{l}x_1=1\\x_2=2\end{array}';

class _FakeRepairGenerator implements ReviewRepairGenerator {
  _FakeRepairGenerator({this.respond});

  Future<ReviewRepairResult> Function(ReviewRepairRequest request)? respond;
  int calls = 0;
  ReviewRepairRequest? lastRequest;

  @override
  Future<ReviewRepairResult> generateProposal({
    required ReviewRepairRequest request,
    TypedReviewSnapshot? snapshot,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    calls++;
    lastRequest = request;
    final responder = respond;
    if (responder != null) return responder(request);
    return _ready(request, _repairedExplanation);
  }
}

ReviewRepairResult _ready(ReviewRepairRequest request, String explanation) {
  final isFragment =
      request.target.strategy == ReviewRepairStrategy.latexFragment;
  final start = request.inputDraft.explanation.indexOf(_brokenFragment);
  return ReviewRepairResult.ready(
    ReviewRepairProposal(
      request: request,
      proposedDraft: request.inputDraft.copyWith(explanation: explanation),
      changedFields: const <ReviewRepairField>[ReviewRepairField.explanation],
      validation: const ReviewRepairValidation(
        structuralValid: true,
        latexValid: true,
        fieldsInScope: true,
      ),
      fragment: isFragment
          ? LatexFragmentProposal(
              target: LatexFragmentTarget(
                reviewItemId: request.reviewItemId,
                expectedRevision: request.expectedRevision,
                field: LatexFragmentField.explanation,
                optionId: null,
                nodeIndex: 1,
                nodeKind: LatexFragmentNodeKind.blockMath,
                originalFieldDigest:
                    fieldDigest(request.inputDraft.explanation),
                originalLatexDigest: fieldDigest(_brokenFragment),
                legacyStart: start,
                legacyEnd: start + _brokenFragment.length,
                originalLatex: _brokenFragment,
                precedingContext: '推导 ',
                followingContext: '',
              ),
              correctedLatex: _repairedFragment,
            )
          : null,
    ),
  );
}

class _RecordingTaskManager {
  final List<List<Map<String, dynamic>>> saves = <List<Map<String, dynamic>>>[];
  bool staleNextSave = false;

  List<Map<String, dynamic>> get lastSave => saves.last;

  Map<String, dynamic> get lastQuestion => lastSave.single;

  Map<String, dynamic> savedQuestion(String reviewItemId) {
    return lastSave.firstWhere(
      (question) => question[TaskManager.keyReviewItemId] == reviewItemId,
    );
  }

  TaskManager create() {
    return TaskManager.forTesting(
      saveReviewDraftCas: ({
        required String taskId,
        required ReviewDraftAttemptIdentity expectedAttempt,
        required int expectedRevision,
        required List<Map<String, dynamic>> questions,
        required String explanationRetentionMode,
      }) async {
        if (staleNextSave) {
          staleNextSave = false;
          return const ReviewDraftCasResult(
            ReviewDraftCasStatus.staleRevision,
            durableRevision: 0,
          );
        }
        saves.add(<Map<String, dynamic>>[
          for (final question in questions) Map<String, dynamic>.from(question),
        ]);
        return ReviewDraftCasResult(
          ReviewDraftCasStatus.saved,
          durableRevision: expectedRevision + 1,
        );
      },
    );
  }
}

Map<String, dynamic> _question({
  int type = 3,
  String content = 'Synthetic stem',
  List<String> options = const <String>[],
  String standardAnswer = 'Synthetic answer',
  String explanation = _brokenExplanation,
  String? rawExplanation = _brokenExplanation,
  List<String> riskHints = const <String>['latex_unrenderable'],
  List<String> latexInvalidFields = const <String>['explanation'],
  bool withTypedSnapshot = true,
  int questionNumber = 21,
  int originalIndex = 20,
  String reviewItemId = _reviewItemId,
  String questionId = _questionId,
}) {
  final question = <String, dynamic>{
    'q_num': questionNumber,
    'question_number': questionNumber,
    'type': type,
    'content': content,
    'options': options,
    'standard_answer': standardAnswer,
    'explanation': explanation,
    if (rawExplanation != null) 'raw_explanation': rawExplanation,
    TaskManager.keyReviewItemId: reviewItemId,
    '_import_review': <String, dynamic>{
      'source': 'ocr',
      'sources': <String>['ocr'],
      'fragmentKinds': <String>[],
      'originalIndices': <int>[originalIndex],
      'riskHints': riskHints,
      'latexInvalidFields': latexInvalidFields,
    },
  };
  if (withTypedSnapshot) {
    question[TypedReviewSnapshotCodec.mapKey] =
        const TypedReviewSnapshotCodec().encode(
      TypedReviewSnapshot(
        reviewItemId: reviewItemId,
        questionId: questionId,
        draft: QuestionDraftV2(
          questionId: questionId,
          kind: switch (type) {
            0 => QuestionKind.singleChoice,
            2 => QuestionKind.fillBlank,
            _ => QuestionKind.shortAnswer,
          },
          questionNumber: questionNumber,
          stem: _contentFor(content),
          options: <QuestionOption>[
            for (var index = 0; index < options.length; index++)
              QuestionOption(
                optionId: <Object>['option_', index + 1].join(),
                label: optionLabel(options[index]),
                content: _contentFor(optionBody(options[index])),
              ),
          ],
          answer: ContentAnswer(content: _contentFor(standardAnswer)),
          explanation: explanation.isEmpty ? null : _contentFor(explanation),
        ),
        baselineLegacy: LegacyReviewBaseline(
          type: type,
          questionNumber: questionNumber,
          content: content,
          options: options,
          standardAnswer: standardAnswer,
          explanation: explanation,
        ),
      ),
    );
  }
  return question;
}

RichContent _contentFor(String value) {
  return reviewFieldContentFromLegacyText(value) ??
      RichContent(nodes: <ContentNode>[TextNode(value)]);
}

ImportTask _task(Map<String, dynamic> question) =>
    _taskWithQuestions(<Map<String, dynamic>>[question]);

ImportTask _taskWithQuestions(List<Map<String, dynamic>> questions) {
  return ImportTask(
    id: _taskId,
    title: 'AI repair',
    status: TaskStatus.pendingReview,
    parsedData: questions,
    diagnostics: <String, dynamic>{
      ReviewDraftCasPersistence.keyReviewDraftRevision: 1,
      ReviewDraftCasPersistence.keyReviewExplanationRetentionMode:
          'allQuestionTypes',
    },
  );
}

Widget _host({
  required Map<String, dynamic> question,
  required _FakeRepairGenerator generator,
  required TaskManager taskManager,
  ImportAdvancedPreferencesLoader? preferencesLoader,
  ExplanationRetentionMode mode = ExplanationRetentionMode.allQuestionTypes,
}) {
  final task = taskManager.tasks.single;
  return MaterialApp(
    home: ImportStagingScreen(
      parsedQuestions: task.parsedData ?? <Map<String, dynamic>>[question],
      taskId: task.id,
      warnings: const <String>[],
      diagnostics: task.diagnostics,
      taskManager: taskManager,
      reviewRepairGenerator: generator,
      importPreferencesLoader: preferencesLoader,
      initialExplanationRetentionMode: mode,
    ),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 40 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('an eligible item offers the AI repair entry point',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    manager.tasks.add(_task(_question()));
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: _question(),
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('review-ai-repair-0')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('question-repair-review-only-0')),
      findsNothing,
    );
  });

  testWidgets('automatic LaTeX repair is off by default', (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final question = _question();
    manager.tasks.add(_task(question));
    final generator = _FakeRepairGenerator();
    await tester.pumpWidget(_host(
      question: question,
      generator: generator,
      taskManager: manager,
      preferencesLoader: () async => ImportAdvancedPreferences.defaults,
    ));
    await tester.pumpAndSettle();
    expect(generator.calls, 0);
  });

  testWidgets('automatic LaTeX repair prepares a proposal without applying',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final question = _question();
    manager.tasks.add(_task(question));
    final generator = _FakeRepairGenerator();
    await tester.pumpWidget(_host(
      question: question,
      generator: generator,
      taskManager: manager,
      preferencesLoader: () async =>
          const ImportAdvancedPreferences(autoRepairLatexEnabled: true),
    ));
    await tester.pumpAndSettle();
    expect(generator.calls, 1);
    expect(find.text('查看 AI 修补建议'), findsOneWidget);
    expect(manager.tasks.single.parsedData!.single['explanation'],
        _brokenExplanation);
    expect(recorder.lastQuestion['explanation'], _brokenExplanation);
    expect(find.byType(ReviewRepairProposalDialog), findsNothing);
  });

  testWidgets('a still-current automatic proposal opens without regenerating',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final question = _question();
    manager.tasks.add(_task(question));
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: question,
      generator: generator,
      taskManager: manager,
      preferencesLoader: () async =>
          const ImportAdvancedPreferences(autoRepairLatexEnabled: true),
    ));
    await tester.pumpAndSettle();

    expect(generator.calls, 1);
    expect(find.text('查看 AI 修补建议'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await tester.pumpAndSettle();

    // The revision anchor still holds, so the prepared proposal is presented
    // as-is instead of spending a second provider call. Opening it is not an
    // acceptance and must not touch the question.
    expect(generator.calls, 1);
    expect(find.byKey(ReviewRepairProposalDialog.dialogKey), findsOneWidget);
    expect(find.text(_repairedFragment), findsOneWidget);
    expect(recorder.lastQuestion['explanation'], _brokenExplanation);
  });

  testWidgets('sequential preparation spends one provider call per question',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final first = _question();
    final second = _question(
      content: 'Second synthetic stem',
      questionNumber: 22,
      originalIndex: 21,
      reviewItemId: _secondReviewItemId,
      questionId: _secondQuestionId,
    );
    manager.tasks.add(
      _taskWithQuestions(<Map<String, dynamic>>[first, second]),
    );
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: first,
      generator: generator,
      taskManager: manager,
      preferencesLoader: () async =>
          const ImportAdvancedPreferences(autoRepairLatexEnabled: true),
    ));
    await tester.pumpAndSettle();

    // Only the first eligible question is prepared: preparing every question up
    // front saved the draft after each proposal, and every save advanced the
    // draft-wide revision past the earlier anchors.
    expect(generator.calls, 1);
    expect(find.text('查看 AI 修补建议'), findsOneWidget);
    expect(find.text('AI 修补'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await tester.pumpAndSettle();
    // The prepared proposal still anchors to the current revision, so opening
    // it spends no second provider call.
    expect(generator.calls, 1);
    await tester.tap(find.byKey(ReviewRepairProposalDialog.applyKey));
    await tester.pumpAndSettle();

    expect(find.text('题目已发生变化，请重新执行 AI 修补'), findsNothing);
    expect(
      recorder.savedQuestion(_reviewItemId)['explanation'],
      _repairedExplanation,
    );
    // Applying settled the revision and advanced preparation to the second
    // question, whose proposal is ready without a regeneration.
    expect(generator.calls, 2);
    expect(find.text('查看 AI 修补建议'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-1')));
    await tester.pumpAndSettle();
    expect(generator.calls, 2);
    await tester.tap(find.byKey(ReviewRepairProposalDialog.applyKey));
    await tester.pumpAndSettle();

    expect(find.text('题目已发生变化，请重新执行 AI 修补'), findsNothing);
    expect(find.text('AI 修补已应用，请复核后入库'), findsWidgets);
    expect(
      recorder.savedQuestion(_secondReviewItemId)['explanation'],
      _repairedExplanation,
    );
    expect(
      recorder.savedQuestion(_reviewItemId)['explanation'],
      _repairedExplanation,
    );
    // Two questions cost two provider calls instead of about four.
    expect(generator.calls, 2);
  });

  testWidgets('automatic LaTeX repair skips non-LaTeX metadata and failure',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final nonLatex = _question(
      riskHints: const <String>['empty_content'],
      latexInvalidFields: const <String>[],
      explanation: 'Synthetic explanation',
      rawExplanation: 'Synthetic explanation',
    );
    manager.tasks.add(_task(nonLatex));
    final generator = _FakeRepairGenerator();
    await tester.pumpWidget(_host(
      question: nonLatex,
      generator: generator,
      taskManager: manager,
      preferencesLoader: () async =>
          const ImportAdvancedPreferences(autoRepairLatexEnabled: true),
    ));
    await tester.pumpAndSettle();
    expect(generator.calls, 0);

    final latex = _question();
    manager.tasks.single.parsedData = [latex];
    generator.respond = (_) async =>
        const ReviewRepairResult.rejected(ReviewRepairOutcome.providerFailure);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host(
      question: latex,
      generator: generator,
      taskManager: manager,
      preferencesLoader: () async =>
          const ImportAdvancedPreferences(autoRepairLatexEnabled: true),
    ));
    await tester.pumpAndSettle();
    expect(generator.calls, 1);
    expect(manager.tasks.single.parsedData!.single['explanation'],
        _brokenExplanation);
    expect(find.text('查看 AI 修补建议'), findsNothing);
  });

  testWidgets('pure LaTeX issue without typed snapshot stays review-only',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final question = _question(withTypedSnapshot: false);
    manager.tasks.add(_task(question));
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: question,
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('review-ai-repair-0')), findsNothing);
    expect(
      find.byKey(const ValueKey('question-repair-review-only-0')),
      findsOneWidget,
    );
    expect(generator.calls, 0);
  });

  testWidgets('a non-repairable risk keeps the review-only notice',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final question = _question(
      explanation: '正文 <table>单元格</table> 结尾',
      rawExplanation: '正文 <table>单元格</table> 结尾',
      riskHints: const <String>['raw_html_tag'],
      latexInvalidFields: const <String>[],
    );
    manager.tasks.add(_task(question));
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: question,
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('review-ai-repair-0')), findsNothing);
    expect(
      find.byKey(const ValueKey('question-repair-review-only-0')),
      findsOneWidget,
    );
  });

  testWidgets('cancel never mutates the item', (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    manager.tasks.add(_task(_question()));
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: _question(),
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await tester.pumpAndSettle();

    expect(generator.calls, 1);
    expect(find.byKey(ReviewRepairProposalDialog.dialogKey), findsOneWidget);
    expect(find.textContaining('修改字段：解析'), findsOneWidget);
    expect(find.text('解析 · LaTeX 片段'), findsOneWidget);
    expect(find.text(_brokenFragment), findsAtLeastNWidgets(1));
    expect(find.text(_repairedFragment), findsOneWidget);

    await tester.tap(find.byKey(ReviewRepairProposalDialog.cancelKey));
    await tester.pumpAndSettle();

    expect(find.byKey(ReviewRepairProposalDialog.dialogKey), findsNothing);
    expect(find.text(_repairedExplanation), findsNothing);
    expect(recorder.lastQuestion['explanation'], _brokenExplanation);
    expect(
      recorder.lastQuestion.containsKey(TaskManager.keyReviewRepairEdit),
      isFalse,
    );
  });

  testWidgets('a rejected generation never mutates the item', (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    manager.tasks.add(_task(_question()));
    final generator = _FakeRepairGenerator(
      respond: (request) async => const ReviewRepairResult.rejected(
        ReviewRepairOutcome.latexStillInvalid,
      ),
    );

    await tester.pumpWidget(_host(
      question: _question(),
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await tester.pumpAndSettle();

    expect(generator.calls, 1);
    expect(find.byKey(ReviewRepairProposalDialog.dialogKey), findsNothing);
    expect(find.text('LaTeX 仍无法可靠渲染，已拒绝'), findsOneWidget);
    expect(
      recorder.lastQuestion.containsKey(TaskManager.keyReviewRepairEdit),
      isFalse,
    );
  });

  testWidgets('apply persists the repaired text and the repair marker',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    manager.tasks.add(_task(_question()));
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: _question(),
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();
    final savesBefore = recorder.saves.length;

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ReviewRepairProposalDialog.applyKey));
    await tester.pumpAndSettle();

    expect(recorder.saves.length, greaterThan(savesBefore));
    expect(recorder.lastQuestion['explanation'], _repairedExplanation);
    final marker = ReviewRepairEdit.fromMap(
      recorder.lastQuestion[TaskManager.keyReviewRepairEdit],
    );
    expect(marker, isNotNull);
    expect(marker!.isLatexFragment, isTrue);
    expect(
      marker.digests.keys,
      <ReviewRepairField>[ReviewRepairField.explanation],
    );
    expect(
      marker.isSatisfiedBy(
        ReviewRepairField.explanation,
        recorder.lastQuestion['explanation'] as String,
      ),
      isTrue,
    );
    expect(find.text('AI 修补已应用，请复核后入库'), findsOneWidget);
  });

  testWidgets('a CAS failure reports failure and never mutates the item',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    manager.tasks.add(_task(_question()));
    final generator = _FakeRepairGenerator();

    await tester.pumpWidget(_host(
      question: _question(),
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await tester.pumpAndSettle();

    recorder.staleNextSave = true;
    await tester.tap(find.byKey(ReviewRepairProposalDialog.applyKey));
    await tester.pumpAndSettle();

    expect(find.text('题目已发生变化，请重新执行 AI 修补'), findsOneWidget);
    expect(find.text('AI 修补已应用，请复核后入库'), findsNothing);
    expect(recorder.lastQuestion['explanation'], _brokenExplanation);
    expect(
      recorder.lastQuestion.containsKey(TaskManager.keyReviewRepairEdit),
      isFalse,
    );
  });

  testWidgets('a proposal from a changed item cannot be applied',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    final question = _question(
      type: 2,
      content: 'Fill blank stem',
      options: const <String>[],
      standardAnswer: 'Synthetic answer',
    );
    manager.tasks.add(_task(question));
    final gate = Completer<void>();
    final generator = _FakeRepairGenerator(
      respond: (request) async {
        await gate.future;
        return _ready(request, _repairedExplanation);
      },
    );

    await tester.pumpWidget(_host(
      question: question,
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await _pumpUntil(tester, () => generator.calls == 1);
    expect(generator.calls, 1);

    // The user changes the same question while the proposal is in flight.
    // A new import retains every explanation, so the mutation is the review
    // page's own explanation edit rather than a removed retention chip.
    // The repair action is still in flight, so this must not settle-wait.
    final editOpen = find.byKey(const ValueKey('explanation-edit-open'));
    await tester.ensureVisible(editOpen);
    await tester.pump();
    await tester.tap(editOpen);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final editField = find.byKey(const ValueKey('explanation-edit-field'));
    expect(editField, findsOneWidget);
    await tester.enterText(editField, 'Edited while the repair proposal flew');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('explanation-edit-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(ReviewRepairProposalDialog.dialogKey), findsOneWidget);
    await tester.tap(find.byKey(ReviewRepairProposalDialog.applyKey));
    await tester.pumpAndSettle();

    expect(find.text('题目已发生变化，请重新执行 AI 修补'), findsOneWidget);
    expect(find.text('AI 修补已应用，请复核后入库'), findsNothing);
    expect(recorder.lastQuestion['explanation'], isNot(_repairedExplanation));
    expect(
      recorder.lastQuestion.containsKey(TaskManager.keyReviewRepairEdit),
      isFalse,
    );
  });

  testWidgets('the same question cannot start a second concurrent repair',
      (tester) async {
    final recorder = _RecordingTaskManager();
    final manager = recorder.create();
    manager.tasks.add(_task(_question()));
    final gate = Completer<void>();
    final generator = _FakeRepairGenerator(
      respond: (request) async {
        await gate.future;
        return _ready(request, _repairedExplanation);
      },
    );

    await tester.pumpWidget(_host(
      question: _question(),
      generator: generator,
      taskManager: manager,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('review-ai-repair-0')));
    await _pumpUntil(tester, () => generator.calls == 1);
    await tester.pump();

    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('review-ai-repair-0')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('正在生成修补建议'), findsOneWidget);
    expect(generator.calls, 1);

    gate.complete();
    await tester.pumpAndSettle();
  });
}
