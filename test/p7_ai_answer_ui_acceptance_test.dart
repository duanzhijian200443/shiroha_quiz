// P7-U0 AI answer review UI acceptance.
//
// Deterministic fakes only: no live provider, no real key, no database.
// The production Application services (AiAnswerGenerationService +
// AiAnswerCommitCommand) run over fake ports; Presentation never touches
// provider/SQLite types. Sentinel strings are fictional.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/ui/dependencies/ai_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';

const _bankName = 'synthetic_bank';
const _storageId = 'q_typed_1';

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

class _FakeQuestionRepository extends Fake implements QuestionRepository {
  _FakeQuestionRepository({List<PersistedQuestion> persisted = const []})
      : persisted = List<PersistedQuestion>.from(persisted);

  List<PersistedQuestion> persisted;
  int persistedCalls = 0;

  @override
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    persistedCalls++;
    return List<PersistedQuestion>.from(persisted);
  }
}

class _FakeQuestionQueryPort implements StudyQuestionQueryPort {
  _FakeQuestionQueryPort(this.read);

  StudyQuestionRead? read;
  final List<String> detailCalls = <String>[];

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async {
    detailCalls.add(questionId);
    return read;
  }

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<StudyPage<StudyQuestionRead>> searchStudyQuestions({
    required String bankName,
    required String query,
    required int nowUnixSeconds,
    required int limit,
    int? afterCreatedAt,
    String? afterId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<StudyPage<StudyQuestionRead>> listStudyWeakQuestions({
    required int nowUnixSeconds,
    required int limit,
    String? bankName,
    int? afterLastLapseTime,
    String? afterId,
  }) {
    throw UnimplementedError();
  }
}

class _FakeProviderPort implements AiAnswerProviderPort {
  _FakeProviderPort({
    required this.result,
    this.error,
    this.rawError,
    bool deferred = false,
  }) : _gate = deferred ? Completer<void>() : null;

  final AiAnswerProviderResult result;
  final AiAnswerProviderException? error;
  final Object? rawError;
  final Completer<void>? _gate;
  int calls = 0;

  void complete() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Future<AiAnswerProviderResult> generateAnswer(
    AiAnswerProviderRequest request,
  ) async {
    calls++;
    final gate = _gate;
    if (gate != null) await gate.future;
    final typed = error;
    if (typed != null) throw typed;
    final raw = rawError;
    if (raw != null) throw raw;
    return result;
  }
}

class _FakeCommitPort implements AiAnswerCommitPersistencePort {
  AiAnswerCommitException? error;
  final List<AnswerCandidate> committed = <AnswerCandidate>[];
  int calls = 0;

  @override
  Future<void> commitAnswer(AnswerCandidate candidate) async {
    calls++;
    final typed = error;
    if (typed != null) throw typed;
    committed.add(candidate);
  }
}

/// Commit persistence that stays pending until [complete] is called, so the
/// UI can be exercised while a durable commit is in flight.
class _DeferredCommitPort implements AiAnswerCommitPersistencePort {
  final Completer<void> _gate = Completer<void>();
  final List<AnswerCandidate> committed = <AnswerCandidate>[];
  int calls = 0;

  void complete() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<void> commitAnswer(AnswerCandidate candidate) async {
    calls++;
    committed.add(candidate);
    await _gate.future;
  }
}

/// Real production scope fields are faked only where the list screen never
/// touches them; the P7 seams are the REAL Application service classes over
/// fake ports (no network, no database).
class _Harness {
  _Harness({
    required QuestionDraftV2 draft,
    required AiAnswerProviderResult providerResult,
    AiAnswerProviderException? providerError,
    Object? rawProviderError,
    bool deferred = false,
    AiAnswerCommitException? commitError,
    bool deferredCommit = false,
    List<PersistedQuestion>? persisted,
  })  : questionPort = _FakeQuestionQueryPort(
          TypedStudyQuestionRead(
            questionId: _storageId,
            bankName: _bankName,
            createdAt: 2,
            draft: draft,
            review: const StudyQuestionReviewState(
              due: false,
              lapseCount: 0,
              difficulty: 5,
              lastLapseTime: null,
            ),
          ),
        ),
        provider = _FakeProviderPort(
          result: providerResult,
          error: providerError,
          rawError: rawProviderError,
          deferred: deferred,
        ) {
    var counter = 0;
    answerGenerationService = AiAnswerGenerationService(
      questionPort: questionPort,
      providerPort: provider,
      idFactory: () => 'SENTINEL_GENERATION_SECRET_${counter++}',
      clock: () => DateTime.utc(2026, 8, 20, 12),
    );
    if (deferredCommit) {
      deferredCommitPort = _DeferredCommitPort();
      answerCommitCommand = AiAnswerCommitCommand(
        persistencePort: deferredCommitPort,
      );
    } else {
      commitPort = _FakeCommitPort();
      if (commitError != null) {
        commitPort.error = commitError;
      }
      answerCommitCommand = AiAnswerCommitCommand(
        persistencePort: commitPort,
      );
    }
    repository = _FakeQuestionRepository(
      persisted: persisted ??
          [
            TypedPersistedQuestion(
              storageId: _storageId,
              bankName: _bankName,
              createdAt: 2,
              draft: draft,
            ),
          ],
    );
  }

  final _FakeQuestionQueryPort questionPort;
  final _FakeProviderPort provider;
  late final _FakeCommitPort commitPort;
  late final _DeferredCommitPort deferredCommitPort;
  late final AiAnswerGenerationService answerGenerationService;
  late final AiAnswerCommitCommand answerCommitCommand;
  late final _FakeQuestionRepository repository;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AiDependenciesScope(
          engineRepository: _FakeEngineRepository(),
          aiService: _FakeAiService(),
          importPipelineService: _FakeImportPipelineService(),
          importTaskCoordinator: _FakeImportTaskCoordinator(),
          answerGenerationService: answerGenerationService,
          answerCommitCommand: answerCommitCommand,
          examMutationCommand: ExamMutationCommand(
            _FakeExamMutationPersistence(),
          ),
          child: QuestionListScreen(
            bankName: _bankName,
            questionRepository: repository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

class _FakeEngineRepository extends Fake implements AiEngineRepository {
  _FakeEngineRepository();
}

class _FakeExamMutationPersistence extends Fake
    implements ExamMutationPersistencePort {}

class _FakeAiService extends Fake implements AiService {
  _FakeAiService();
}

class _FakeImportPipelineService extends Fake implements ImportPipelineService {
  _FakeImportPipelineService();
}

class _FakeImportTaskCoordinator extends Fake implements ImportTaskCoordinator {
  _FakeImportTaskCoordinator();
}

QuestionDraftV2 _contentDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'q_draft_1',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _text('solve for x'),
    answer: answer,
  );
}

QuestionDraftV2 _choiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'q_draft_1',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('choose'),
    options: [
      QuestionOption(
        optionId: 'opt_a',
        label: 'A',
        content: _text('x = 1'),
      ),
      QuestionOption(
        optionId: 'opt_b',
        label: 'B',
        content: _text('x = 2'),
      ),
    ],
    answer: answer,
  );
}

AiAnswerProviderResult _contentResult(String text) {
  return AiAnswerProviderResult(
    answer: ContentAnswer(content: _text(text)),
    providerProfileId: 'SENTINEL_PROVIDER_SECRET',
  );
}

Finder _typedCard() {
  return find.ancestor(
    of: find.text('结构化'),
    matching: find.byType(PersistedQuestionCard),
  );
}

Future<void> _tapAi(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: _typedCard(),
      matching: find.text('AI 生成答案'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'A. typed-only entry: typed card shows AI action, legacy does '
      'not, manual repair remains', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
      persisted: [
        TypedPersistedQuestion(
          storageId: _storageId,
          bankName: _bankName,
          createdAt: 2,
          draft: _contentDraft(),
        ),
        LegacyPersistedQuestion(
          question: Question(
            id: 'legacy_1',
            type: 3,
            content: 'legacy stem',
            options: '[]',
            answer: 'legacy answer',
            createdAt: 1,
            bankName: _bankName,
          ),
        ),
      ],
    );
    await harness.pump(tester);

    expect(
      find.descendant(
        of: _typedCard(),
        matching: find.text('AI 生成答案'),
      ),
      findsOneWidget,
    );
    final legacyCard = find.ancestor(
      of: find.text('legacy stem'),
      matching: find.byType(PersistedQuestionCard),
    );
    expect(
      find.descendant(
        of: legacyCard,
        matching: find.text('AI 生成答案'),
      ),
      findsNothing,
    );
    expect(find.text('暂无答案，点击手动补充'), findsOneWidget,
        reason: 'manual repair entry must remain');
  });

  testWidgets(
      'B. generation invocation passes the exact storage id and '
      'busy state blocks duplicate triggers', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
      deferred: true,
    );
    await harness.pump(tester);

    await tester.tap(
      find.descendant(
        of: _typedCard(),
        matching: find.text('AI 生成答案'),
      ),
    );
    await tester.pump();

    expect(harness.questionPort.detailCalls, [_storageId]);
    expect(harness.provider.calls, 1);
    // Busy state: the AI entry is replaced by a spinner, so a second tap is
    // impossible; the provider must not be called twice.
    expect(
      find.descendant(
        of: _typedCard(),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _typedCard(),
        matching: find.text('AI 生成答案'),
      ),
      findsNothing,
    );

    harness.provider.complete();
    await tester.pumpAndSettle();
    expect(harness.provider.calls, 1);
    expect(find.text('AI 建议答案'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'C. fill: dismiss is zero commit; explicit accept commits, '
      'closes, and reloads authoritative state', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
    );
    await harness.pump(tester);
    expect(harness.repository.persistedCalls, 1);

    // First run: dismiss -> zero commit.
    await _tapAi(tester);
    expect(find.text('AI 建议答案'), findsOneWidget);
    expect(find.text('当前答案为空，将填写 AI 建议答案。'), findsOneWidget);
    expect(find.text('x = 1'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(harness.commitPort.calls, 0);

    // Second run: explicit accept -> one commit -> reload.
    await _tapAi(tester);
    await tester.tap(find.text('采用答案'));
    await tester.pumpAndSettle();

    expect(harness.commitPort.calls, 1);
    expect(harness.commitPort.committed.single.candidateId,
        'SENTINEL_GENERATION_SECRET_3',
        reason: 'fresh candidate id from the second generation');
    expect(find.text('AI 建议答案'), findsNothing);
    expect(harness.repository.persistedCalls, 2,
        reason: 'authoritative reload after commit');
    expect(find.text('已保存 AI 答案'), findsOneWidget);
    // Expire the snackbar timer before the test ends.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'C2. singleChoice candidate renders option label and typed '
      'content as a display projection', (tester) async {
    final harness = _Harness(
      draft: _choiceDraft(),
      providerResult: AiAnswerProviderResult(
        answer: ChoiceAnswer(optionIds: ['opt_a']),
        providerProfileId: 'SENTINEL_PROVIDER_SECRET',
      ),
    );
    await harness.pump(tester);
    await _tapAi(tester);

    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('A.')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('x = 1')),
      findsOneWidget,
    );
    expect(find.textContaining('opt_a'), findsNothing,
        reason: 'option id is only a display projection, never raw text');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(harness.commitPort.calls, 0);
  });

  testWidgets('D. noOp is informational with zero commit', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(answer: ContentAnswer(content: _text('x = 1'))),
      providerResult: _contentResult('x = 1'),
    );
    await harness.pump(tester);

    await _tapAi(tester);

    expect(find.text('AI 建议与当前答案等价，无需修改。'), findsOneWidget);
    expect(find.text('采用答案'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(harness.commitPort.calls, 0);
  });

  testWidgets(
      'E. replace requires two explicit user decisions; the first '
      'action never commits', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(answer: ContentAnswer(content: _text('x = 9'))),
      providerResult: _contentResult('x = 1'),
    );
    await harness.pump(tester);

    await _tapAi(tester);
    expect(find.text('当前已有答案，AI 建议替换。'), findsOneWidget);

    // First explicit action: selectForReplace only.
    await tester.tap(find.text('确认替换'));
    await tester.pumpAndSettle();
    expect(harness.commitPort.calls, 0,
        reason: 'one click must never replace-commit directly');
    expect(find.text('二次确认替换'), findsOneWidget);
    expect(find.textContaining('是否确认替换'), findsOneWidget);

    // Second explicit reconfirmation: confirmReplace + commit.
    await tester.tap(find.text('二次确认替换'));
    await tester.pumpAndSettle();
    expect(harness.commitPort.calls, 1);
    expect(harness.commitPort.committed.single.writeIntent,
        CandidateWriteIntent.replace);
    expect(find.text('AI 建议答案'), findsNothing);
  });

  testWidgets(
      'F. stale commit shows a safe message and keeps the dialog '
      'open without raw text', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
      commitError: const AiAnswerCommitException(
        AiAnswerCommitFailure.staleTarget,
      ),
    );
    await harness.pump(tester);

    await _tapAi(tester);
    await tester.tap(find.text('采用答案'));
    await tester.pumpAndSettle();

    expect(find.text('题目已发生变化，请重新生成答案。'), findsOneWidget);
    expect(find.textContaining('AiAnswerCommitException'), findsNothing);
    expect(find.textContaining('staleTarget'), findsNothing);
    expect(find.text('AI 建议答案'), findsOneWidget,
        reason: 'dialog stays open so the user can retry or cancel');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(harness.commitPort.committed, isEmpty);
  });

  testWidgets(
      'P2-2a. fill commit pending blocks back/barrier dismissal and '
      'still completes with reload', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
      deferredCommit: true,
    );
    await harness.pump(tester);
    await _tapAi(tester);

    await tester.tap(find.text('采用答案'));
    await tester.pump();

    // Durable commit is still pending: the review must stay mounted.
    expect(find.text('AI 建议答案'), findsOneWidget);
    expect(harness.deferredCommitPort.calls, 1);

    // System/back route pop must not dismiss the review while pending.
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    await navigator.maybePop();
    await tester.pump();
    expect(find.text('AI 建议答案'), findsOneWidget,
        reason: 'back must not close the review during a pending commit');

    // Barrier dismissal must be impossible.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text('AI 建议答案'), findsOneWidget,
        reason: 'barrier must not close the review');

    // Complete the durable commit: dialog closes with success and the parent
    // performs the authoritative reload.
    harness.deferredCommitPort.complete();
    await tester.pumpAndSettle();
    expect(find.text('AI 建议答案'), findsNothing);
    expect(harness.repository.persistedCalls, 2,
        reason: 'authoritative reload must still happen');
    expect(harness.deferredCommitPort.committed, hasLength(1));
    expect(find.text('已保存 AI 答案'), findsOneWidget);
    // Expire the snackbar timer before the test ends.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'P2-2b. replace commit pending also blocks dismissal and '
      'completes with reload', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(answer: ContentAnswer(content: _text('x = 9'))),
      providerResult: _contentResult('x = 1'),
      deferredCommit: true,
    );
    await harness.pump(tester);
    await _tapAi(tester);

    // First explicit action only arms the replacement.
    await tester.tap(find.text('确认替换'));
    await tester.pumpAndSettle();
    expect(harness.deferredCommitPort.calls, 0,
        reason: 'arming must never start a durable commit');

    // Second explicit reconfirmation starts the deferred commit.
    await tester.tap(find.text('二次确认替换'));
    await tester.pump();
    expect(harness.deferredCommitPort.calls, 1);

    // Route pop is blocked while the commit is pending.
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    await navigator.maybePop();
    await tester.pump();
    expect(find.text('AI 建议答案'), findsOneWidget);

    harness.deferredCommitPort.complete();
    await tester.pumpAndSettle();
    expect(find.text('AI 建议答案'), findsNothing);
    expect(harness.repository.persistedCalls, 2,
        reason: 'authoritative reload must still happen');
    expect(harness.deferredCommitPort.committed, hasLength(1));
    expect(find.text('已保存 AI 答案'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('G. generation failures map to fixed safe messages',
      (tester) async {
    final cases = <(AiAnswerProviderException?, Object?, String)>[
      (
        const AiAnswerProviderException(
          AiAnswerProviderFailure.providerUnconfigured,
        ),
        null,
        '请先配置可用的文本模型。',
      ),
      (
        const AiAnswerProviderException(
          AiAnswerProviderFailure.providerTimeout,
        ),
        null,
        '模型响应超时，请稍后重试。',
      ),
      (
        const AiAnswerProviderException(
          AiAnswerProviderFailure.validationFailed,
        ),
        null,
        '模型返回的答案未通过校验。',
      ),
      (null, StateError('SENTINEL_RAW_GENERATION'), '生成失败，请稍后重试。'),
    ];
    for (final entry in cases) {
      final harness = _Harness(
        draft: _contentDraft(),
        providerResult: _contentResult('x = 1'),
        providerError: entry.$1,
        rawProviderError: entry.$2,
      );
      await harness.pump(tester);
      await _tapAi(tester);

      expect(find.text(entry.$3), findsOneWidget);
      expect(find.textContaining('SENTINEL_RAW'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
      // Expire the snackbar timer so the next case starts clean.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('G2. unsupported content maps to the fixed admission message',
      (tester) async {
    final harness = _Harness(
      draft: QuestionDraftV2(
        questionId: 'q_draft_1',
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(nodes: [
          TextNode('visible'),
          RawFallbackNode(<String, Object?>{
            'type': 'raw_fallback',
            'payload': <String, Object?>{'secret': 'SENTINEL_RAW_PAYLOAD'},
          }),
        ]),
      ),
      providerResult: _contentResult('x = 1'),
    );
    await harness.pump(tester);
    await _tapAi(tester);

    expect(
      find.text('此题包含当前 AI 解答暂不支持的内容（如图片或无法安全发送的结构）。'),
      findsOneWidget,
    );
    expect(harness.provider.calls, 0);
    expect(find.textContaining('SENTINEL_RAW_PAYLOAD'), findsNothing);
    // Expire the snackbar timer before the test ends.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'H. disposal cancels in-flight generation; late result opens '
      'no dialog and commits nothing', (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
      deferred: true,
    );
    await harness.pump(tester);

    await tester.tap(
      find.descendant(
        of: _typedCard(),
        matching: find.text('AI 生成答案'),
      ),
    );
    await tester.pump();

    // Dispose the screen while the generation is in flight.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    harness.provider.complete();
    await tester.pumpAndSettle();

    expect(find.text('AI 建议答案'), findsNothing);
    expect(harness.commitPort.calls, 0);
    expect(harness.commitPort.committed, isEmpty);
  });

  testWidgets('I. provenance secrets never appear anywhere in the UI',
      (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
    );
    await harness.pump(tester);

    await _tapAi(tester);
    expect(find.text('AI 建议答案'), findsOneWidget);

    expect(find.textContaining('SENTINEL_GENERATION'), findsNothing);
    expect(find.textContaining('SENTINEL_PROVIDER'), findsNothing);
    expect(find.textContaining('SENTINEL_CANDIDATE'), findsNothing);

    // Failure path: commit failure message must not leak provenance either.
    harness.commitPort.error = const AiAnswerCommitException(
      AiAnswerCommitFailure.persistenceFailed,
    );
    await tester.tap(find.text('采用答案'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请稍后重试。'), findsOneWidget);
    expect(find.textContaining('SENTINEL'), findsNothing);
    expect(find.textContaining('generationId'), findsNothing);
    expect(find.textContaining('providerProfileId'), findsNothing);
    expect(find.textContaining('sessionRevision'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('J. the scope exposes the real Application service classes',
      (tester) async {
    final harness = _Harness(
      draft: _contentDraft(),
      providerResult: _contentResult('x = 1'),
    );
    await harness.pump(tester);

    final scope =
        tester.widget<AiDependenciesScope>(find.byType(AiDependenciesScope));
    expect(scope.answerGenerationService, isA<AiAnswerGenerationService>());
    expect(scope.answerCommitCommand, isA<AiAnswerCommitCommand>());
    expect(
      harness.answerGenerationService,
      isA<AiAnswerGenerationService>(),
    );
    expect(harness.answerCommitCommand, isA<AiAnswerCommitCommand>());
  });
}
