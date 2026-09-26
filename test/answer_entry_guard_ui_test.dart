import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_entry_guard.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/ui/dependencies/ai_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/question_edit_screen.dart';

/// Counts every legacy AI answer call so the typed/unknown cases can prove
/// zero provider egress rather than merely asserting a message.
final class _SpyAiService extends Fake implements AiService {
  int answerSingleQuestionCalls = 0;
  Map<String, dynamic>? lastQuestion;

  @override
  Future<Map<String, String>> answerSingleQuestion(
    Map<String, dynamic> question,
  ) async {
    answerSingleQuestionCalls++;
    lastQuestion = question;
    return <String, String>{
      'standard_answer': 'LEGACY_AI_ANSWER',
      'explanation': '',
    };
  }
}

final class _RoutePort extends Fake implements StudyQuestionQueryPort {
  _RoutePort({this.read, this.failure});

  final StudyQuestionRead? read;
  final StudyQueryRepositoryFailure? failure;
  final List<String> detailCalls = <String>[];

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async {
    detailCalls.add(questionId);
    final failure = this.failure;
    if (failure != null) throw StudyQueryRepositoryException(failure);
    return read;
  }
}

final class _FakeEngineRepository extends Fake implements AiEngineRepository {}

final class _FakeImportPipelineService extends Fake
    implements ImportPipelineService {}

final class _FakeImportTaskCoordinator extends Fake
    implements ImportTaskCoordinator {}

final class _FakeAiAnswerProviderPort extends Fake
    implements AiAnswerProviderPort {}

final class _FakeAiAnswerCommitPersistencePort extends Fake
    implements AiAnswerCommitPersistencePort {}

final class _FakeExamMutationPersistence extends Fake
    implements ExamMutationPersistencePort {}

RichContent _text(String text) => RichContent(nodes: [TextNode(text)]);

StudyQuestionReviewState _review() => const StudyQuestionReviewState(
      due: false,
      lapseCount: 0,
      difficulty: 0,
      lastLapseTime: null,
    );

StudyQuestionRead _typedRead(String questionId) => TypedStudyQuestionRead(
      questionId: questionId,
      bankName: 'bank_math',
      createdAt: 1,
      draft: QuestionDraftV2(
        questionId: questionId,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: _text('solve for x'),
      ),
      review: _review(),
    );

StudyQuestionRead _legacyRead(String questionId) => LegacyStudyQuestionRead(
      questionId: questionId,
      bankName: 'bank_math',
      createdAt: 1,
      stemText: 'solve for x',
      optionsText: '[]',
      answerText: '',
      explanationText: null,
      legacyType: 1,
      review: _review(),
    );

/// A V1 `questions` row projection of the shape every `QuestionEditScreen`
/// navigation site passes, keyed by the real persisted `storageId`.
Map<String, dynamic> _questionRow({String? id}) => <String, dynamic>{
      if (id != null) 'id': id,
      'type': 1,
      'content': 'solve for x',
      'options': '[]',
      'standard_answer': '',
      'explanation': '',
    };

Widget _wrap({
  required AiService aiService,
  required StudyQuestionQueryPort port,
  required Map<String, dynamic> question,
}) {
  return MaterialApp(
    home: AiDependenciesScope(
      engineRepository: _FakeEngineRepository(),
      aiConfigService: const UnavailableAiConfigPresentationService(),
      aiService: aiService,
      importPipelineService: _FakeImportPipelineService(),
      importTaskCoordinator: _FakeImportTaskCoordinator(),
      answerGenerationService: AiAnswerGenerationService(
        questionPort: port,
        providerPort: _FakeAiAnswerProviderPort(),
        idFactory: () => 'unused-generation',
        clock: () => DateTime.utc(2026, 9, 27),
      ),
      answerCommitCommand: AiAnswerCommitCommand(
        persistencePort: _FakeAiAnswerCommitPersistencePort(),
      ),
      answerEntryGuard: AiAnswerEntryGuard(
        questionPort: port,
        clock: () => DateTime.utc(2026, 9, 27),
      ),
      examMutationCommand: ExamMutationCommand(_FakeExamMutationPersistence()),
      child: QuestionEditScreen(question: question),
    ),
  );
}

Future<void> _tapAskAi(WidgetTester tester) async {
  await tester.tap(find.text('AI解答'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('typed question: legacy answerSingleQuestion calls == 0',
      (tester) async {
    final aiService = _SpyAiService();
    final port = _RoutePort(read: _typedRead('q_typed_1'));

    await tester.pumpWidget(
      _wrap(
        aiService: aiService,
        port: port,
        question: _questionRow(id: 'q_typed_1'),
      ),
    );
    await _tapAskAi(tester);

    expect(aiService.answerSingleQuestionCalls, 0);
    expect(port.detailCalls, ['q_typed_1']);
    expect(
      find.text('结构化题目请使用题库列表的「AI 生成答案」入口'),
      findsOneWidget,
    );
  });

  testWidgets('legacy question: existing legacy AI path still works',
      (tester) async {
    final aiService = _SpyAiService();
    final port = _RoutePort(read: _legacyRead('q_legacy_1'));

    await tester.pumpWidget(
      _wrap(
        aiService: aiService,
        port: port,
        question: _questionRow(id: 'q_legacy_1'),
      ),
    );
    await _tapAskAi(tester);

    expect(port.detailCalls, ['q_legacy_1']);
    expect(aiService.answerSingleQuestionCalls, 1);
    expect(aiService.lastQuestion?['id'], 'q_legacy_1');
    expect(find.text('AI 解答已填入，请核实'), findsOneWidget);
  });

  testWidgets('unknown question (absent row) fails closed', (tester) async {
    final aiService = _SpyAiService();
    final port = _RoutePort(read: null);

    await tester.pumpWidget(
      _wrap(
        aiService: aiService,
        port: port,
        question: _questionRow(id: 'q_absent'),
      ),
    );
    await _tapAskAi(tester);

    expect(aiService.answerSingleQuestionCalls, 0);
    expect(find.text('无法确认题目类型，已阻止 AI 解答'), findsOneWidget);
  });

  testWidgets('corrupt typed sidecar fails closed', (tester) async {
    final aiService = _SpyAiService();
    final port = _RoutePort(
      failure: StudyQueryRepositoryFailure.corruptPayload,
    );

    await tester.pumpWidget(
      _wrap(
        aiService: aiService,
        port: port,
        question: _questionRow(id: 'q_typed_1'),
      ),
    );
    await _tapAskAi(tester);

    expect(aiService.answerSingleQuestionCalls, 0);
    expect(find.text('无法确认题目类型，已阻止 AI 解答'), findsOneWidget);
  });

  testWidgets('missing persisted identity fails closed without any read',
      (tester) async {
    final aiService = _SpyAiService();
    final port = _RoutePort(read: _legacyRead('q_legacy_1'));

    await tester.pumpWidget(
      _wrap(aiService: aiService, port: port, question: _questionRow()),
    );
    await _tapAskAi(tester);

    expect(aiService.answerSingleQuestionCalls, 0);
    expect(port.detailCalls, isEmpty);
    expect(find.text('无法确认题目类型，已阻止 AI 解答'), findsOneWidget);
  });
}
