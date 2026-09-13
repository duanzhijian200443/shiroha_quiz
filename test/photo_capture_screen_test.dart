import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/subjective_answer_recognition.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/ui/dependencies/ai_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/photo_capture_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

final class _RecordingImportPipelineService extends Fake
    implements ImportPipelineService {
  final List<ImportParseRequest> requests = <ImportParseRequest>[];

  @override
  Future<ImportParseResult> parseFiles(ImportParseRequest request) async {
    requests.add(request);
    return const ImportParseResult(questions: <Map<String, dynamic>>[]);
  }
}

final class _RecordingImportTaskCoordinator extends Fake
    implements ImportTaskCoordinator {
  final List<String> sourceDescriptions = <String>[];
  final List<ImportParseMode> modes = <ImportParseMode>[];
  final List<ExplanationRetentionMode> retentionModes =
      <ExplanationRetentionMode>[];

  @override
  Future<ImportTaskHandle> dispatch({
    required String sourceDescription,
    required ImportParseMode mode,
    required ImportTaskParseAction parse,
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
  }) async {
    final callNumber = sourceDescriptions.length + 1;
    final taskId = 'synthetic-photo-task-$callNumber';
    sourceDescriptions.add(sourceDescription);
    modes.add(mode);
    retentionModes.add(explanationRetentionMode);
    await parse(taskId);
    return ImportTaskHandle(
      taskId: taskId,
      traceId: 'synthetic-photo-trace-$callNumber',
      attemptNumber: 1,
      attemptToken: 'synthetic-photo-attempt-$callNumber',
    );
  }
}

final class _UnusedEngineRepository extends Fake
    implements AiEngineRepository {}

final class _UnusedAiService extends Fake implements AiService {}

final class _UnusedStudyQuestionQuery extends Fake
    implements StudyQuestionQueryPort {}

final class _UnusedAiAnswerProvider extends Fake
    implements AiAnswerProviderPort {}

final class _UnusedAiAnswerCommitPersistence extends Fake
    implements AiAnswerCommitPersistencePort {}

final class _UnusedExamMutationPersistence extends Fake
    implements ExamMutationPersistencePort {}

final class _FakeSubjectiveAnswerRecognition
    implements SubjectiveAnswerRecognitionPort {
  _FakeSubjectiveAnswerRecognition(this.result);

  final SubjectiveAnswerRecognitionResult result;
  final List<SubjectiveAnswerRecognitionRequest> requests =
      <SubjectiveAnswerRecognitionRequest>[];

  @override
  Future<SubjectiveAnswerRecognitionResult> recognize(
    SubjectiveAnswerRecognitionRequest request,
  ) async {
    requests.add(request);
    return result;
  }
}

void main() {
  final syntheticPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  Future<void> pumpLauncher(
    WidgetTester tester, {
    required PhotoPicker pickPhoto,
    required PhotoRecognitionDispatcher? dispatch,
    ThemeData? theme,
    Widget Function(Widget child)? wrapDependencies,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final launcher = Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey<String>('open-photo-capture'),
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => PhotoCaptureScreen(
                  pickPhoto: pickPhoto,
                  onRecognitionRequested: dispatch,
                ),
              ),
            ),
            child: const Text('打开拍照识题'),
          ),
        ),
      ),
    );
    final app = MaterialApp(
      theme: theme ?? AppTheme.lightTheme,
      home: launcher,
    );
    await tester.pumpWidget(
      switch (wrapDependencies) {
        final wrap? => wrap(app),
        null => app,
      },
    );
    await tester.tap(find.byKey(const ValueKey<String>('open-photo-capture')));
    await tester.pumpAndSettle();
  }

  XFile syntheticPhoto(Uint8List bytes) => XFile.fromData(
        bytes,
        name: 'synthetic.png',
        mimeType: 'image/png',
      );

  testWidgets('capture shell is presentation-only before a photo is chosen',
      (tester) async {
    var pickCalls = 0;
    var dispatchCalls = 0;
    await pumpLauncher(
      tester,
      pickPhoto: (source) async {
        pickCalls++;
        return null;
      },
      dispatch: (image, mode) async => dispatchCalls++,
    );

    expect(find.text('拍照识题'), findsOneWidget);
    expect(find.text('仅拍照，不识别'), findsOneWidget);
    expect(find.text('拍照后进入「确认照片与识别模式」'), findsOneWidget);
    expect(pickCalls, 0);
    expect(dispatchCalls, 0);

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-gallery-action')),
    );
    await tester.pumpAndSettle();

    expect(pickCalls, 1);
    expect(dispatchCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captured photo waits for explicit CTA and defaults to OCR',
      (tester) async {
    var dispatchCalls = 0;
    ImportParseMode? dispatchedMode;
    await pumpLauncher(
      tester,
      pickPhoto: (source) async {
        expect(source, ImageSource.camera);
        return syntheticPhoto(syntheticPng);
      },
      dispatch: (image, mode) async {
        dispatchCalls++;
        dispatchedMode = mode;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-shutter-action')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PhotoRecognitionConfirmationScreen), findsOneWidget);
    expect(find.text('确认照片'), findsOneWidget);
    expect(find.text('OCR'), findsOneWidget);
    expect(find.text('多模态'), findsOneWidget);
    expect(dispatchCalls, 0);
    final preview = tester.widget<Image>(
      find.descendant(
        of: find.byType(PhotoRecognitionConfirmationScreen),
        matching: find.byType(Image),
      ),
    );
    final resizedPreview = preview.image as ResizeImage;
    expect(resizedPreview.width, 1440);
    expect(resizedPreview.height, 1440);
    expect(resizedPreview.policy, ResizeImagePolicy.fit);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('photo-start-recognition-action'),
      ),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, 1);
    expect(dispatchedMode, ImportParseMode.ocr);
    expect(find.byKey(const ValueKey<String>('open-photo-capture')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vision mode is purple-themed and dispatches only after CTA',
      (tester) async {
    var dispatchCalls = 0;
    ImportParseMode? dispatchedMode;
    await pumpLauncher(
      tester,
      theme: AppTheme.darkTheme,
      pickPhoto: (source) async => syntheticPhoto(syntheticPng),
      dispatch: (image, mode) async {
        dispatchCalls++;
        dispatchedMode = mode;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-gallery-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('photo-mode-vision')),
    );
    await tester.pump();

    final visionMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('photo-mode-vision')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      visionMaterial.color,
      AppTheme.darkTheme.colorScheme.secondary.withValues(alpha: 0.12),
    );
    expect(dispatchCalls, 0);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('photo-start-recognition-action'),
      ),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, 1);
    expect(dispatchedMode, ImportParseMode.vision);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'default recognition wiring dispatches OCR and Vision through the production seams',
      (tester) async {
    final productionPhoto = syntheticPhoto(syntheticPng);
    final pipeline = _RecordingImportPipelineService();
    final coordinator = _RecordingImportTaskCoordinator();
    final answerGeneration = AiAnswerGenerationService(
      questionPort: _UnusedStudyQuestionQuery(),
      providerPort: _UnusedAiAnswerProvider(),
      idFactory: () => 'unused-answer-generation',
      clock: () => DateTime.utc(2026, 9, 4),
    );
    await pumpLauncher(
      tester,
      pickPhoto: (source) async => productionPhoto,
      dispatch: null,
      wrapDependencies: (child) => AiDependenciesScope(
        engineRepository: _UnusedEngineRepository(),
        aiService: _UnusedAiService(),
        importPipelineService: pipeline,
        importTaskCoordinator: coordinator,
        answerGenerationService: answerGeneration,
        answerCommitCommand: AiAnswerCommitCommand(
          persistencePort: _UnusedAiAnswerCommitPersistence(),
        ),
        examMutationCommand: ExamMutationCommand(
          _UnusedExamMutationPersistence(),
        ),
        subjectiveAnswerRecognition: _FakeSubjectiveAnswerRecognition(
          SubjectiveAnswerRecognitionResult.failure(
            SubjectiveAnswerRecognitionClassification.providerFailure,
          ),
        ),
        child: child,
      ),
    );

    Future<void> recognize({required bool vision}) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('photo-gallery-action')),
      );
      await tester.pumpAndSettle();
      if (vision) {
        await tester.tap(
          find.byKey(const ValueKey<String>('photo-mode-vision')),
        );
        await tester.pump();
      }
      await tester.tap(
        find.byKey(
          const ValueKey<String>('photo-start-recognition-action'),
        ),
      );
      await tester.pumpAndSettle();
    }

    await recognize(vision: false);
    await tester.tap(find.byKey(const ValueKey<String>('open-photo-capture')));
    await tester.pumpAndSettle();
    await recognize(vision: true);

    expect(coordinator.sourceDescriptions, <String>['图片识别', '图片识别']);
    expect(
      coordinator.modes,
      <ImportParseMode>[ImportParseMode.ocr, ImportParseMode.vision],
    );
    expect(
      coordinator.retentionModes,
      <ExplanationRetentionMode>[
        ExplanationRetentionMode.subjectiveOnly,
        ExplanationRetentionMode.subjectiveOnly,
      ],
    );
    expect(pipeline.requests, hasLength(2));
    expect(
      pipeline.requests.map((request) => request.mode),
      <ImportParseMode>[ImportParseMode.ocr, ImportParseMode.vision],
    );
    expect(
      pipeline.requests.map((request) => request.taskId),
      <String>['synthetic-photo-task-1', 'synthetic-photo-task-2'],
    );
    for (final request in pipeline.requests) {
      expect(request.fileNames, <String>[productionPhoto.name]);
      expect(request.filePaths, hasLength(1));
      expect(request.maxConcurrency, 3);
      expect(
        request.explanationRetentionMode,
        ExplanationRetentionMode.subjectiveOnly,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'subjective answer recognition returns editable text without import dispatch',
      (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final recognition = _FakeSubjectiveAnswerRecognition(
      SubjectiveAnswerRecognitionResult.success('recognized answer'),
    );
    String? returnedText;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            key: const ValueKey<String>('open-subjective-photo'),
            onPressed: () async {
              returnedText = await Navigator.of(context).push<String>(
                MaterialPageRoute<String>(
                  builder: (_) => PhotoCaptureScreen.subjectiveAnswer(
                    pickPhoto: (source) async => syntheticPhoto(syntheticPng),
                    subjectiveAnswerRecognition: recognition,
                  ),
                ),
              );
            },
            child: const Text('拍照作答'),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('open-subjective-photo')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('photo-gallery-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('photo-start-recognition-action')),
    );
    await tester.pumpAndSettle();

    expect(returnedText, 'recognized answer');
    expect(recognition.requests, hasLength(1));
    expect(
      recognition.requests.single.mode,
      SubjectiveAnswerRecognitionMode.ocr,
    );
    expect(
      find.byKey(const ValueKey<String>('open-subjective-photo')),
      findsOneWidget,
    );
  });

  testWidgets(
      'subjective answer failure stays on confirmation and returns no text',
      (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final recognition = _FakeSubjectiveAnswerRecognition(
      SubjectiveAnswerRecognitionResult.failure(
        SubjectiveAnswerRecognitionClassification.providerFailure,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoCaptureScreen.subjectiveAnswer(
          pickPhoto: (source) async => syntheticPhoto(syntheticPng),
          subjectiveAnswerRecognition: recognition,
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-gallery-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('photo-start-recognition-action')),
    );
    await tester.pump();

    expect(find.byType(PhotoRecognitionConfirmationScreen), findsOneWidget);
    expect(find.text('答案识别失败，请稍后重试。'), findsOneWidget);
    expect(recognition.requests, hasLength(1));
  });
}
