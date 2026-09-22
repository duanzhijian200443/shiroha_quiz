import 'package:shiroha_quiz/application/practice/photo_answer_history.dart';
import 'package:shiroha_quiz/application/practice/photo_answer_submission.dart';
import 'package:shiroha_quiz/application/practice/record_answer_attempt_command.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/file_library/library_file_deletion.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
// Synthetic/offline Practice wiring only: no database, ImportTask, OCR,
// Provider, Replay, network, or private content is used.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/photo_answer_judgement.dart';
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

final class _UnusedPhotoAnswerJudgement implements PhotoAnswerJudgementPort {
  @override
  Future<PhotoAnswerJudgementResult> judge(
    PhotoAnswerJudgementRequest request,
  ) async {
    return PhotoAnswerJudgementResult.failed(
      PhotoAnswerJudgementFailure.providerFailure,
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

class _Ingest implements FileIngestionPort {
  int calls = 0;
  @override
  Future<LibraryFile> ingest(
      {required String externalPath,
      required String displayName,
      String? mimeType}) async {
    calls++;
    return LibraryFile(
        fileId: 'file-1',
        displayName: 'synthetic',
        mimeType: 'image/png',
        sizeBytes: 3,
        sha256: 'a' * 64,
        storageKey: 'library/file-1',
        createdAt: DateTime.utc(2026));
  }
}

class _Attempts
    implements AnswerAttemptPersistencePort, AnswerAttemptHistoryPort {
  @override
  Future<List<AnswerAttempt>> getAttemptsForQuestion(String id) async => values;
  final values = <AnswerAttempt>[];
  @override
  Future<void> recordAttempt(AnswerAttempt attempt) async {
    values.add(attempt);
  }
}

class _MissingFiles extends Fake implements LibraryFileRepositoryPort {
  @override
  Future<LibraryFile?> findById(String id) async => null;
}

class _UnusedDelete extends Fake implements LibraryFileDeletionPort {}

void main() {
  Future<_RecordingAiService> pumpPractice(
    WidgetTester tester, {
    PhotoAnswerCaptureLauncher? launcher,
    QuestionKind? typedKind,
    bool missingTypedAnswer = false,
    PhotoAnswerSubmissionCommand? submission,
    PhotoAnswerHistoryQuery? history,
    Future<void> Function(String, int)? grade,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    if (typedKind != null) {
      final content =
          RichContent(nodes: [TextNode('synthetic no underscores')]);
      ReviewEngineService().initPreparedStudySession([
        TypedPersistedQuestion(
            storageId: 'q',
            bankName: 'synthetic',
            createdAt: 1,
            draft: QuestionDraftV2(
                questionId: 'q',
                kind: typedKind,
                stem: content,
                options: typedKind == QuestionKind.singleChoice
                    ? [
                        QuestionOption(
                            optionId: 'a', label: 'A', content: content)
                      ]
                    : [],
                answer: missingTypedAnswer
                    ? null
                    : typedKind == QuestionKind.singleChoice
                        ? ChoiceAnswer(optionIds: ['a'])
                        : ContentAnswer(content: content)))
      ]);
    }
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
        photoAnswerJudgement: _UnusedPhotoAnswerJudgement(),
        photoAnswerSubmission: submission,
        photoAnswerHistory: history,
        child: MaterialApp(
          home: PracticePage(
            initialQuestions: typedKind == null
                ? const <Question>[_subjectiveQuestion]
                : null,
            usePreparedStudySession: typedKind != null,
            submitReviewOverride: grade,
            photoAnswerCaptureLauncher: launcher,
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

    expect(find.text('拍照作答'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('subjective-answer-photo-action')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PhotoCaptureScreen), findsOneWidget);
    expect(find.text('拍照作答'), findsNWidgets(2));
    final capture =
        tester.widget<PhotoCaptureScreen>(find.byType(PhotoCaptureScreen));
    expect(capture.question,
        RichContent(nodes: [TextNode(_subjectiveQuestion.content)]));
    expect(capture.standardAnswer,
        RichContent(nodes: [TextNode(_subjectiveQuestion.answer)]));
  });

  testWidgets('photo judgement bypasses text AI; preview does not persist',
      (tester) async {
    final ai = await pumpPractice(tester,
        launcher: (context, recognition, view) async => ConfirmedPhotoAnswer(
            request: PhotoAnswerJudgementRequest(
                imagePath: 'synthetic',
                imageName: 'synthetic',
                kind: PhotoAnswerQuestionKind.shortAnswer,
                question: RichContent(nodes: [TextNode('q')]),
                standardAnswer: RichContent(nodes: [TextNode('a')])),
            result: const PhotoAnswerJudgementResult(
                decision: PhotoAnswerDecision.correct,
                transcription: 'photo answer',
                feedback: 'vision feedback')));
    await tester.tap(
        find.byKey(const ValueKey<String>('subjective-answer-photo-action')));
    await tester.pumpAndSettle();
    expect(ai.submittedAnswer, isNull);
    expect(find.textContaining('vision feedback'), findsOneWidget);
  });
  for (final kind in [QuestionKind.fillBlank, QuestionKind.shortAnswer]) {
    testWidgets('$kind missing typed ContentAnswer fails closed before capture',
        (tester) async {
      await pumpPractice(tester, typedKind: kind, missingTypedAnswer: true);
      await tester.tap(
          find.byKey(const ValueKey<String>('subjective-answer-photo-action')));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoCaptureScreen), findsNothing);
      expect(find.text('题目或标准答案无效，暂时无法进行拍照判题。'), findsOneWidget);
    });
    testWidgets('$kind production capture receives authoritative RichContent',
        (tester) async {
      await pumpPractice(tester, typedKind: kind);
      await tester.tap(
          find.byKey(const ValueKey<String>('subjective-answer-photo-action')));
      await tester.pumpAndSettle();
      final capture =
          tester.widget<PhotoCaptureScreen>(find.byType(PhotoCaptureScreen));
      expect(capture.question,
          RichContent(nodes: [const TextNode('synthetic no underscores')]));
      expect(capture.standardAnswer, capture.question);
    });
  }
  testWidgets('manual text retains existing AI judging', (tester) async {
    final ai = await pumpPractice(tester);
    await tester.enterText(find.byType(TextField).first, 'manual answer');
    await tester.tap(find.text('呼叫 AI 助教判卷'));
    await tester.pumpAndSettle();
    expect(ai.submittedAnswer, 'manual answer');
  });

  testWidgets('cancel or failed recognition preserves the existing answer',
      (tester) async {
    await pumpPractice(
      tester,
      launcher: (context, recognition, view) async {
        return null;
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
  for (final kind in [QuestionKind.fillBlank, QuestionKind.shortAnswer]) {
    for (final decision in PhotoAnswerDecision.values) {
      testWidgets(
          '$kind photo $decision records once without text judge or FSRS',
          (tester) async {
        final ingestion = _Ingest();
        final attempts = _Attempts();
        var grades = 0;
        final ai = await pumpPractice(tester,
            typedKind: kind,
            grade: (_, __) async {
              grades++;
            },
            submission: PhotoAnswerSubmissionCommand(
                ingestion: ingestion,
                attempts: RecordAnswerAttemptCommand(attempts),
                deletion: _UnusedDelete(),
                diagnostic: (_) => fail('diagnostic')),
            launcher: (context, port, view) async => ConfirmedPhotoAnswer(
                request: PhotoAnswerJudgementRequest(
                    imagePath: 'synthetic',
                    imageName: 'synthetic',
                    kind: kind == QuestionKind.fillBlank
                        ? PhotoAnswerQuestionKind.fillBlank
                        : PhotoAnswerQuestionKind.shortAnswer,
                    question: view.photoAnswerQuestion!,
                    standardAnswer: view.photoAnswerStandardAnswer!),
                result: PhotoAnswerJudgementResult(
                    decision: decision,
                    transcription: '',
                    feedback: 'synthetic')));
        expect(tester.widget<TextField>(find.byType(TextField).first).maxLines,
            kind == QuestionKind.fillBlank ? 1 : 5);
        final action = find
            .byKey(const ValueKey<String>('subjective-answer-photo-action'));
        await tester.tap(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(attempts.values, hasLength(1));
        expect(ingestion.calls, 1);
        expect(attempts.values.single.sessionKind,
            AnswerAttemptSessionKind.focused);
        expect(
            attempts.values.single.correctness,
            decision == PhotoAnswerDecision.uncertain
                ? null
                : decision == PhotoAnswerDecision.correct);
        expect(ai.submittedAnswer, isNull);
        expect(grades, 0);
      });
    }
  }
  testWidgets('typed choice has no photo action', (tester) async {
    await pumpPractice(tester, typedKind: QuestionKind.singleChoice);
    expect(find.byKey(const ValueKey<String>('subjective-answer-photo-action')),
        findsNothing);
  });
  testWidgets('missing evidence remains readable in practice history',
      (tester) async {
    final attempts = _Attempts();
    attempts.values.add(AnswerAttempt(
        attemptId: 'old',
        questionId: 'q',
        sessionKind: AnswerAttemptSessionKind.normal,
        modality: AnswerAttemptModality.image,
        answerPayloadJson: AnswerAttemptPayload.image(
            sourceFileId: 'missing',
            transcription: 'historic answer',
            feedback: 'historic feedback'),
        correctness: false,
        answeredAt: 1));
    await pumpPractice(tester,
        typedKind: QuestionKind.shortAnswer,
        history: PhotoAnswerHistoryQuery(
            attempts: attempts, files: _MissingFiles()));
    await tester.tap(find.text('跳过 AI，直接看答案自评'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('拍照作答记录'));
    await tester.tap(find.text('拍照作答记录'));
    await tester.pumpAndSettle();
    expect(find.text('原始作答图片已清理'), findsOneWidget);
    expect(find.text('historic feedback'), findsOneWidget);
    expect(attempts.values, hasLength(1));
  });
}
