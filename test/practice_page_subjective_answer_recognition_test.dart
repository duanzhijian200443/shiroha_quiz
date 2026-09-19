// Synthetic/offline Practice wiring only: no database, ImportTask, OCR,
// Provider, Replay, network, or private content is used.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/subjective_answer_recognition.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/ui/dependencies/ai_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/photo_capture_screen.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';

final class _UnusedEngineRepository extends Fake
    implements AiEngineRepository {}

final class _RecordingAiService extends Fake implements AiService {
  String? submittedAnswer;

  @override
  Future<String> judgeAnswer(
    String question,
    String standardAnswer,
    String userAnswer,
  ) async {
    submittedAnswer = userAnswer;
    return 'synthetic feedback';
  }
}

final class _UnusedImportPipelineService extends Fake
    implements ImportPipelineService {}

final class _UnusedImportTaskCoordinator extends Fake
    implements ImportTaskCoordinator {}

final class _UnusedStudyQuestionQuery extends Fake
    implements StudyQuestionQueryPort {}

final class _UnusedAiAnswerProvider extends Fake
    implements AiAnswerProviderPort {}

final class _UnusedAiAnswerCommitPersistence extends Fake
    implements AiAnswerCommitPersistencePort {}

final class _UnusedExamMutationPersistence extends Fake
    implements ExamMutationPersistencePort {}

final class _UnusedSubjectiveAnswerRecognition
    implements SubjectiveAnswerRecognitionPort {
  @override
  Future<SubjectiveAnswerRecognitionResult> recognize(
    SubjectiveAnswerRecognitionRequest request,
  ) async {
    return SubjectiveAnswerRecognitionResult.failure(
      SubjectiveAnswerRecognitionClassification.providerFailure,
    );
  }
}

const _subjectiveQuestion = Question(
  id: 'preview_synthetic-subjective',
  type: 3,
  content: 'Synthetic subjective question',
  options: '[]',
  answer: 'Synthetic standard answer',
  createdAt: 1,
  bankName: 'synthetic',
);

void main() {
  Future<_RecordingAiService> pumpPractice(
    WidgetTester tester, {
    SubjectiveAnswerCaptureLauncher? launcher,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final aiService = _RecordingAiService();
    final answerGeneration = AiAnswerGenerationService(
      questionPort: _UnusedStudyQuestionQuery(),
      providerPort: _UnusedAiAnswerProvider(),
      idFactory: () => 'unused-answer-generation',
      clock: () => DateTime.utc(2026, 9, 12),
    );
    await tester.pumpWidget(
      AiDependenciesScope(
        engineRepository: _UnusedEngineRepository(),
        aiConfigService: const UnavailableAiConfigPresentationService(),
        aiService: aiService,
        importPipelineService: _UnusedImportPipelineService(),
        importTaskCoordinator: _UnusedImportTaskCoordinator(),
        answerGenerationService: answerGeneration,
        answerCommitCommand: AiAnswerCommitCommand(
          persistencePort: _UnusedAiAnswerCommitPersistence(),
        ),
        examMutationCommand: ExamMutationCommand(
          _UnusedExamMutationPersistence(),
        ),
        subjectiveAnswerRecognition: _UnusedSubjectiveAnswerRecognition(),
        child: MaterialApp(
          home: PracticePage(
            initialQuestions: const <Question>[_subjectiveQuestion],
            subjectiveAnswerCaptureLauncher: launcher,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return aiService;
  }

  testWidgets('subjective question exposes production photo-answer route',
      (tester) async {
    await pumpPractice(tester);

    expect(find.text('拍照作答 / 图片识别'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('subjective-answer-photo-action')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PhotoCaptureScreen), findsOneWidget);
    expect(find.text('拍照作答'), findsOneWidget);
  });

  testWidgets('recognized text is editable and reuses existing AI judging',
      (tester) async {
    var launcherCalls = 0;
    final aiService = await pumpPractice(
      tester,
      launcher: (context, recognition) async {
        launcherCalls++;
        return 'recognized answer';
      },
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('subjective-answer-photo-action')),
    );
    await tester.pump();

    final answerField = find.byType(TextField).first;
    expect(launcherCalls, 1);
    expect(tester.widget<TextField>(answerField).controller!.text,
        'recognized answer');

    await tester.enterText(answerField, 'recognized answer edited');
    await tester.tap(find.text('呼叫 AI 助教判卷'));
    await tester.pumpAndSettle();

    expect(aiService.submittedAnswer, 'recognized answer edited');
    expect(find.text('synthetic feedback'), findsOneWidget);
  });

  testWidgets('cancel or failed recognition preserves the existing answer',
      (tester) async {
    var captureCalls = 0;
    await pumpPractice(
      tester,
      launcher: (context, recognition) async {
        captureCalls++;
        return captureCalls == 1 ? null : '   ';
      },
    );
    final answerField = find.byType(TextField).first;
    await tester.enterText(answerField, 'existing answer');

    await tester.tap(
      find.byKey(const ValueKey<String>('subjective-answer-photo-action')),
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(answerField).controller!.text,
      'existing answer',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('subjective-answer-photo-action')),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(answerField).controller!.text,
      'existing answer',
    );
  });
}
