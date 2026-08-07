// R7C.1 final-review-snapshot closure: the typed commit payload must be
// rebuilt from the POST-flush staging state and bound to the flush-returned
// revision, distillation must gate both the UI and any bypassed save flow,
// and the legacy writer stays untouched. Synthetic fixtures only; no
// Provider, Replay, network, real database, filesystem or application call.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/bank_update_notifier.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

const _taskId = 'typed-closure-task';
const _attemptToken = 'typed-closure-attempt';

const _reviewItemIdA = '44444444-4444-4444-8444-000000000001';
const _questionIdA = '22222222-2222-4222-8222-000000000001';
const _sourceIdA = '11111111-1111-4111-8111-000000000001';

/// Shared event log across the save hook, the recording commit service and
/// the recording repository so the race order can be asserted strictly.
class _FlushGate {
  _FlushGate(this.events);

  final List<String> events;
  final Completer<void> gate = Completer<void>();
  bool armed = false;
  int saveCount = 0;

  Future<void> onSave(Map<String, dynamic> taskMap) async {
    saveCount++;
    final revision = _readRevision(taskMap);
    if (armed && saveCount == 1) {
      events.add('final_flush_started');
      await gate.future;
      events.add('final_flush_saved_revision_$revision');
      return;
    }
    events.add('review_save_revision_$revision');
  }

  static int? _readRevision(Map<String, dynamic> taskMap) {
    final raw = taskMap['diagnostics'];
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded[TypedImportCommitPersistence.keyReviewDraftRevision]
            as int?;
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

class _RecordingRepo extends Fake implements QuestionRepository {
  _RecordingRepo(this.events);

  final List<String> events;
  int legacySaveCalls = 0;
  int typedSaveCalls = 0;
  List<QuestionDraftV2>? savedTyped;
  TypedImportCommitGuard? lastGuard;
  String? lastScreenPayloadAnswer;

  @override
  Future<List<String>> getAvailableFolders() async => const <String>['Math'];

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    legacySaveCalls++;
  }

  @override
  Future<void> saveQuestionDraftsV2ToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraftV2> questions,
  }) async {
    typedSaveCalls++;
    savedTyped = List<QuestionDraftV2>.unmodifiable(questions);
  }

  @override
  Future<TypedImportCommitPersistenceResult> commitQuestionDraftsV2ForImport({
    required String bankName,
    String? folderName,
    required List<QuestionDraftV2> questions,
    required TypedImportCommitGuard guard,
    required String completionText,
  }) async {
    typedSaveCalls++;
    savedTyped = List<QuestionDraftV2>.unmodifiable(questions);
    lastGuard = guard;
    return TypedImportCommitPersistenceResult(
      questionCount: questions.length,
      completedAt: 1700000000,
    );
  }

  /// Fake repository-write step used by the recording service's
  /// record-only path so the event log keeps a strict input -> commit order.
  void recordTypedCommitFromScreen(List<TypedReviewCommitInput> items) {
    typedSaveCalls++;
    lastScreenPayloadAnswer =
        items.isEmpty ? null : items.first.currentDraft.standardAnswer;
    events.add('repository_commit');
  }
}

class _RecordingCommitService extends ImportCommitService {
  _RecordingCommitService({
    required super.questionRepository,
    required super.taskManager,
    required this.repo,
    required List<String> events,
  }) : _events = events;

  final List<String> _events;
  final _RecordingRepo repo;
  int commitTypedCalls = 0;
  int? lastExpectedReviewDraftRevision;
  String? lastObservedAnswer;
  String? lastObservedExplanation;

  /// When true the commit is recorded without delegating to the frozen
  /// service lease/repository chain (used only to probe the screen contract).
  bool recordOnly = false;

  @override
  Future<ImportCommitResult> commitTyped({
    required String bankName,
    required String folderName,
    required List<TypedReviewCommitInput> items,
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
    required int expectedReviewDraftRevision,
    required ImportStorageRoute storageRoute,
    required String storageReason,
    required ExplanationRetentionMode explanationRetentionMode,
    List<QuestionExplanationOverride>? explanationOverrides,
  }) async {
    commitTypedCalls++;
    lastExpectedReviewDraftRevision = expectedReviewDraftRevision;
    lastObservedAnswer =
        items.isEmpty ? null : items.first.currentDraft.standardAnswer;
    lastObservedExplanation =
        items.isEmpty ? null : items.first.currentDraft.explanation;
    final payloadLabel =
        (lastObservedExplanation == null || lastObservedExplanation!.isEmpty)
            ? 'B'
            : 'A';
    _events.add('commit_input_observed:$payloadLabel');
    _events.add('commit_called');
    if (recordOnly) {
      repo.recordTypedCommitFromScreen(items);
      return const ImportCommitResult(questionCount: 1);
    }
    return super.commitTyped(
      bankName: bankName,
      folderName: folderName,
      items: items,
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
      expectedReviewDraftRevision: expectedReviewDraftRevision,
      storageRoute: storageRoute,
      storageReason: storageReason,
      explanationRetentionMode: explanationRetentionMode,
      explanationOverrides: explanationOverrides,
    );
  }
}

class _GatedDistiller implements SubjectiveAnswerDistiller {
  _GatedDistiller({required this.answer});

  final String answer;
  final Completer<void> gate = Completer<void>();
  int distillCalls = 0;

  @override
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    distillCalls++;
    await gate.future;
    return SubjectiveAnswerDistillationResult.applied(answer);
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
  int type = 3,
  List<String> options = const <String>[],
  String content = 'Synthetic stem',
  String standardAnswer = 'Conclusion',
  String explanation = 'Subjective explanation',
}) {
  return <String, dynamic>{
    'q_num': number.toString(),
    'question_number': number,
    'type': type,
    'content': content,
    'options': options,
    'standard_answer': standardAnswer,
    'explanation': explanation,
    'raw_explanation': explanation,
    TaskManager.keyReviewItemId: _reviewItemIdA,
    TypedReviewSnapshotCodec.mapKey: _envelope(
      reviewItemId: _reviewItemIdA,
      questionId: _questionIdA,
      sourceId: _sourceIdA,
      questionNumber: number,
      content: content,
      standardAnswer: standardAnswer,
      explanation: explanation,
    ),
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

  late _RecordingRepo repo;
  late TaskManager manager;
  late _RecordingCommitService service;

  setUp(() {
    repo = _RecordingRepo(<String>[]);
  });

  tearDown(() {
    manager.tasks.clear();
  });

  Widget buildScreen({
    required List<Map<String, dynamic>> questions,
    Map<String, dynamic>? diagnostics,
    String? taskId,
    SubjectiveAnswerDistiller? answerDistiller,
    ExplanationRetentionMode retentionMode =
        ExplanationRetentionMode.subjectiveOnly,
    Future<void> Function(Map<String, dynamic> taskMap)? saveTask,
  }) {
    // The manager must be created inside the test body zone: a manager
    // created in setUp owns a `_reviewDraftWriteTail` completed in the real
    // zone, whose `.then` microtasks never run under the widget test's fake
    // async pump.
    manager = TaskManager.forTesting(saveTask: saveTask);
    if (taskId != null) {
      manager.tasks.add(ImportTask(
        id: taskId,
        title: 'Synthetic typed import',
        status: TaskStatus.pendingReview,
        parsedData: questions,
        diagnostics: diagnostics ?? _typedDiagnostics(),
      ));
    }
    service = _RecordingCommitService(
      questionRepository: repo,
      taskManager: manager,
      repo: repo,
      events: repo.events,
    );
    return MaterialApp(
      home: Scaffold(
        body: ImportStagingScreen(
          parsedQuestions: questions,
          taskId: taskId,
          diagnostics: diagnostics,
          questionRepository: repo,
          taskManager: manager,
          commitService: service,
          answerDistiller: answerDistiller,
          initialExplanationRetentionMode: retentionMode,
        ),
      ),
    );
  }

  /// Bounded frame pump for flows that hold an unresolved async gate (the
  /// saving spinner animates forever, so pumpAndSettle would time out).
  Future<void> pumpFrames(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  VoidCallback captureConfirmHandler(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.textContaining('收入题库'),
        matching: find.byType(ElevatedButton),
      ),
    );
    return button.onPressed!;
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

  testWidgets(
      '18.1 post-flush inputs: payload is rebuilt from the state mutated '
      'during the final flush', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final flushGate = _FlushGate(repo.events);
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(
          number: 1,
          type: 1,
          options: const <String>['A', 'B'],
          content: 'Synthetic choice stem',
          standardAnswer: 'A',
          explanation: 'Synthetic explanation',
        ),
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
      retentionMode: ExplanationRetentionMode.allQuestionTypes,
      saveTask: flushGate.onSave,
    ));
    await tester.pumpAndSettle();
    service.recordOnly = true;

    // Start the confirm chain; the final flush save is gated in-flight.
    flushGate.armed = true;
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
    await pumpFrames(tester);
    expect(repo.events, contains('final_flush_started'),
        reason: 'the final flush must be in-flight before the mutation');

    // A real review-draft mutation lands while the flush is still pending:
    // the per-item explanation retention chip rewrites `_allItems` and
    // enqueues its own (delayed) review save.
    await tester.tap(
      find.byKey(const ValueKey<String>('question-explanation-discard-0')),
    );
    await pumpFrames(tester);

    flushGate.gate.complete();
    await tester.pumpAndSettle();

    expect(service.commitTypedCalls, 1);
    expect(service.lastExpectedReviewDraftRevision, 1,
        reason: 'the payload revision must equal the final flush revision');
    expect(service.lastObservedExplanation, isEmpty,
        reason: 'the commit payload must reflect the post-flush state, not '
            'the entry-time capture');
    expect(service.lastObservedAnswer, 'A');
    expect(repo.lastScreenPayloadAnswer, 'A');
    expect(repo.typedSaveCalls, 1);
    expect(repo.legacySaveCalls, 0);
  });

  testWidgets(
      '18.2 distillation active: confirm disabled, no flush and no commit '
      'chain', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final distiller = _GatedDistiller(answer: 'Distilled B');
    var saveCalls = 0;
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(
            number: 1,
            standardAnswer: '',
            explanation: 'Subjective explanation'),
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
      answerDistiller: distiller,
      saveTask: (taskMap) async {
        saveCalls++;
      },
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('answer-distillation-batch')));
    await pumpFrames(tester);
    expect(find.text('正在生成答案 0/1'), findsOneWidget);

    final confirm = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.textContaining('收入题库'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(confirm.onPressed, isNull,
        reason: 'the confirm button must be disabled while answers generate');

    await tester.tap(find.textContaining('收入题库'), warnIfMissed: false);
    await pumpFrames(tester);
    expect(find.text('选择保存位置'), findsNothing);
    expect(service.commitTypedCalls, 0);
    expect(repo.typedSaveCalls, 0);
    expect(repo.legacySaveCalls, 0);
    expect(saveCalls, 1,
        reason: 'only the distillation base snapshot may save; the final '
            'flush must never start');
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  testWidgets(
      '18.3 programmatic bypass: save flow blocked while answers are '
      'generating', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final distiller = _GatedDistiller(answer: 'Distilled B');
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(
            number: 1,
            standardAnswer: '',
            explanation: 'Subjective explanation'),
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
      answerDistiller: distiller,
    ));
    await tester.pumpAndSettle();

    // Capture the real save handler while the button is still enabled, then
    // start distillation and invoke the handler directly: this simulates any
    // programmatic caller that bypasses the disabled button state.
    final validate = captureConfirmHandler(tester);
    await tester
        .tap(find.byKey(const ValueKey<String>('answer-distillation-batch')));
    await pumpFrames(tester);
    expect(find.text('正在生成答案 0/1'), findsOneWidget);

    validate();
    await pumpFrames(tester);
    if (find.text('继续').evaluate().isNotEmpty) {
      await tester.tap(find.text('继续'));
      await pumpFrames(tester);
    }
    await tester.enterText(
      find.widgetWithText(TextField, '目标题库名称'),
      'Typed Bank',
    );
    await tester.tap(find.text('确定入库'));
    await pumpFrames(tester);

    expect(find.text('答案仍在生成中，请等待完成后再入库'), findsOneWidget);
    expect(service.commitTypedCalls, 0);
    expect(repo.typedSaveCalls, 0);
    expect(repo.legacySaveCalls, 0);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  testWidgets(
      '18.4 final flush failure blocks the commit with the fixed prompt',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
      saveTask: (taskMap) async {
        throw StateError('synthetic-save-failure');
      },
    ));
    await tester.pumpAndSettle();

    await commitThroughDialog(tester);

    expect(find.text('校对结果尚未安全保存，无法入库，请重试'), findsOneWidget);
    expect(service.commitTypedCalls, 0);
    expect(repo.typedSaveCalls, 0);
    expect(repo.legacySaveCalls, 0);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  testWidgets(
      '18.5 post-flush provenance invalid: flush runs then blocks with the '
      'fixed text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final flushGate = _FlushGate(repo.events);
    final question = _typedQuestion(number: 1)
      ..remove(TypedReviewSnapshotCodec.mapKey);
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[question],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
      saveTask: flushGate.onSave,
    ));
    await tester.pumpAndSettle();
    service.recordOnly = true;

    flushGate.armed = true;
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
    await pumpFrames(tester);
    expect(repo.events, contains('final_flush_started'));
    flushGate.gate.complete();
    await tester.pumpAndSettle();

    expect(repo.events, contains('final_flush_saved_revision_1'),
        reason: 'the final flush must complete before the rebuild gate');
    expect(
      find.text('结构化题目缺少必要的审核信息，无法入库，请检查后重试'),
      findsOneWidget,
    );
    expect(service.commitTypedCalls, 0);
    expect(repo.typedSaveCalls, 0);
    expect(repo.legacySaveCalls, 0);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  testWidgets('18.6 normal typed path: flush, rebuild and typedV2 commit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[_typedQuestion(number: 1)],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
    ));
    await tester.pumpAndSettle();

    final notifierBefore = globalBankUpdateNotifier.value;
    await commitThroughDialog(tester);

    expect(service.commitTypedCalls, 1);
    expect(repo.typedSaveCalls, 1);
    expect(repo.legacySaveCalls, 0);
    expect(repo.lastGuard, isNotNull);
    expect(repo.lastGuard!.storageRoute,
        TypedImportCommitPersistence.typedV2RouteValue);
    expect(repo.lastGuard!.storageReason,
        TypedImportCommitPersistence.typedCandidateReadyReasonValue);
    expect(repo.lastGuard!.reviewDraftRevision, 1,
        reason: 'the persisted gate must carry the final flush revision');
    expect(repo.savedTyped!.single.questionId, _questionIdA);
    expect(globalBankUpdateNotifier.value, notifierBefore + 1);
    expect(manager.tasks.single.status, TaskStatus.completed);
    expect(find.text('本次导入报告'), findsOneWidget);
  });

  testWidgets('18.7a legacy path: untouched, no revision requirement',
      (tester) async {
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
    expect(service.commitTypedCalls, 0);
  });

  testWidgets(
      '18.7b legacy path: bypassed save during distillation still commits '
      'via legacy (no distillation typed gate)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final distiller = _GatedDistiller(answer: 'Distilled B');
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(
            number: 1,
            standardAnswer: '',
            explanation: 'Subjective explanation'),
      ],
      diagnostics: const <String, dynamic>{},
      taskId: null,
      answerDistiller: distiller,
    ));
    await tester.pumpAndSettle();

    final validate = captureConfirmHandler(tester);
    await tester
        .tap(find.byKey(const ValueKey<String>('answer-distillation-batch')));
    await pumpFrames(tester);
    validate();
    await pumpFrames(tester);
    if (find.text('继续').evaluate().isNotEmpty) {
      await tester.tap(find.text('继续'));
      await pumpFrames(tester);
    }
    await tester.enterText(
      find.widgetWithText(TextField, '目标题库名称'),
      'Legacy Bank',
    );
    await tester.tap(find.text('确定入库'));
    await pumpFrames(tester);

    expect(repo.legacySaveCalls, 1,
        reason: 'the legacy writer must never gain the distillation gate');
    expect(repo.typedSaveCalls, 0);
    expect(service.commitTypedCalls, 0);
  });

  testWidgets(
      '19 vertical race: delayed distillation completes first, then the '
      'commit binds B to the flush revision', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final distiller = _GatedDistiller(answer: 'Distilled B');
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(
            number: 1,
            standardAnswer: '',
            explanation: 'Subjective explanation'),
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
      answerDistiller: distiller,
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('answer-distillation-batch')));
    await pumpFrames(tester);
    expect(find.text('正在生成答案 0/1'), findsOneWidget);
    final disabledConfirm = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.textContaining('收入题库'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(disabledConfirm.onPressed, isNull,
        reason: 'confirm must be blocked while distillation is unfinished');

    distiller.gate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('处理完成：补全 1 道'), findsOneWidget);
    // Let the outcome snackbar expire so it no longer covers the confirm
    // button at the bottom of the surface.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ElevatedButton>(
            find.ancestor(
              of: find.textContaining('收入题库'),
              matching: find.byType(ElevatedButton),
            ),
          )
          .onPressed,
      isNotNull,
    );

    await commitThroughDialog(tester);

    expect(service.commitTypedCalls, 1);
    expect(service.lastObservedAnswer, 'Distilled B',
        reason: 'the saved typed answer must be B, never the pre-distillation '
            'state');
    expect(service.lastExpectedReviewDraftRevision, 3,
        reason: 'base snapshot 1 + distillation merge 2 + final flush 3');
    expect(repo.typedSaveCalls, 1);
    expect(repo.lastGuard!.reviewDraftRevision, 3);
    final savedAnswer = repo.savedTyped!.single.answer! as ContentAnswer;
    expect(savedAnswer.content.nodes.single, isA<TextNode>());
    expect((savedAnswer.content.nodes.single as TextNode).text, 'Distilled B');
    expect(manager.tasks.single.status, TaskStatus.completed);
  });

  testWidgets(
      '20 order probe: flush save < commit input observation < repository '
      'commit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    final flushGate = _FlushGate(repo.events);
    await tester.pumpWidget(buildScreen(
      questions: <Map<String, dynamic>>[
        _typedQuestion(
          number: 1,
          type: 1,
          options: const <String>['A', 'B'],
          content: 'Synthetic choice stem',
          standardAnswer: 'A',
          explanation: 'Synthetic explanation',
        ),
      ],
      diagnostics: _typedDiagnostics(),
      taskId: _taskId,
      retentionMode: ExplanationRetentionMode.allQuestionTypes,
      saveTask: flushGate.onSave,
    ));
    await tester.pumpAndSettle();
    service.recordOnly = true;

    flushGate.armed = true;
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
    await pumpFrames(tester);
    expect(repo.events, contains('final_flush_started'));

    await tester.tap(
      find.byKey(const ValueKey<String>('question-explanation-discard-0')),
    );
    await pumpFrames(tester);
    flushGate.gate.complete();
    await tester.pumpAndSettle();

    final events = repo.events;
    expect(events, contains('final_flush_started'));
    expect(events, contains('final_flush_saved_revision_1'));
    expect(events, contains('commit_input_observed:B'));
    expect(events, contains('repository_commit'));
    expect(
      events.indexOf('final_flush_started'),
      lessThan(events.indexOf('final_flush_saved_revision_1')),
      reason: 'the final flush must start before it saves',
    );
    expect(
      events.indexOf('final_flush_saved_revision_1'),
      lessThan(events.indexOf('commit_input_observed:B')),
      reason: 'commit inputs must be observed only after the flush revision '
          'is known',
    );
    expect(
      events.indexOf('commit_input_observed:B'),
      lessThan(events.indexOf('repository_commit')),
      reason: 'the repository commit must come after the input observation',
    );
    expect(service.lastExpectedReviewDraftRevision, 1);
    expect(service.lastObservedExplanation, isEmpty);
  });
}
