import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/practice/subjective_answer_recognition.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/llm_api_client.dart';
import 'package:shiroha_quiz/services/llm_providers/llm_provider_client.dart';
import 'package:shiroha_quiz/services/practice/subjective_answer_recognition_adapter.dart';
import 'package:shiroha_quiz/services/vision_asset_builder.dart';

const _ocrProfile = AiEngineProfile(
  id: 'ocr-profile',
  engineType: AiEngineType.ocr,
  name: 'OCR',
  apiKey: 'synthetic-key',
  baseUrl: 'https://example.invalid',
  modelName: 'glm-ocr',
  temperature: 0,
  reasoningEffort: '',
  isActive: true,
);

const _visionProfile = AiEngineProfile(
  id: 'vision-profile',
  engineType: AiEngineType.vision,
  name: 'Vision',
  apiKey: 'synthetic-key',
  baseUrl: 'https://example.invalid',
  modelName: 'synthetic-vision',
  temperature: 0.7,
  reasoningEffort: '',
  isActive: true,
);

final class _FakeEngineRepository extends Fake implements AiEngineRepository {
  _FakeEngineRepository({this.ocrProfile, this.visionProfile});

  final AiEngineProfile? ocrProfile;
  final AiEngineProfile? visionProfile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => ocrProfile;

  @override
  Future<AiEngineProfile?> getActiveVisionEngine() async => visionProfile;
}

final class _FakeOcrClient implements OcrDocumentClient {
  _FakeOcrClient({required this.response, this.failure});

  final OcrDocument response;
  final Object? failure;
  int calls = 0;

  @override
  String get modelId => 'synthetic-ocr';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    calls++;
    if (failure != null) throw failure!;
    return response;
  }
}

final class _FakeVisionAssetBuilder extends Fake implements VisionAssetBuilder {
  int calls = 0;

  @override
  Future<LlmVisionAsset> buildInlineFileAsset(
    String filePath, {
    required String mimeType,
    required bool compressImage,
  }) async {
    calls++;
    return LlmVisionAsset.inline(
      mimeType: mimeType,
      base64Data: 'c3ludGhldGlj',
    );
  }
}

final class _FakeLlmApiClient extends Fake implements LlmApiClient {
  _FakeLlmApiClient({required this.response, this.failure});

  final String response;
  final Object? failure;
  int calls = 0;
  String? prompt;
  double? temperature;

  @override
  Future<String> callVision({
    required AiEngineProfile profile,
    required String prompt,
    required List<LlmVisionAsset> assets,
    double? temperature,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    calls++;
    this.prompt = prompt;
    this.temperature = temperature;
    if (failure != null) throw failure!;
    return response;
  }
}

OcrDocument _document(String markdown) {
  return OcrDocument(
    sourceName: 'synthetic.png',
    pages: const <OcrPage>[],
    markdown: markdown,
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

SubjectiveAnswerRecognitionRequest _request(
  SubjectiveAnswerRecognitionMode mode,
) {
  return SubjectiveAnswerRecognitionRequest(
    imagePath: 'synthetic.png',
    imageName: 'synthetic.png',
    mode: mode,
  );
}

void main() {
  test('answer OCR waits behind a document OCR call on the shared scheduler',
      () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final releaseDocument = Completer<void>();
    final documentCall = scheduler.run(
      taskId: 'document-import',
      operation: () => releaseDocument.future,
    );
    final ocr = _FakeOcrClient(response: _document('answer'));
    final adapter = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(ocrProfile: _ocrProfile),
      ocrClient: ocr,
      requestScheduler: scheduler,
    );

    final answerCall = adapter.recognize(
      _request(SubjectiveAnswerRecognitionMode.ocr),
    );
    await Future<void>.delayed(Duration.zero);
    expect(ocr.calls, 0);
    releaseDocument.complete();
    await documentCall;
    expect((await answerCall).isSuccess, isTrue);
    expect(ocr.calls, 1);
  });

  test('OCR returns bounded editable text without invoking Vision', () async {
    final ocr = _FakeOcrClient(response: _document('  answer from OCR  '));
    final vision = _FakeLlmApiClient(response: 'unused');
    final adapter = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(
        ocrProfile: _ocrProfile,
        visionProfile: _visionProfile,
      ),
      ocrClient: ocr,
      apiClient: vision,
      assetBuilder: _FakeVisionAssetBuilder(),
    );

    final result = await adapter.recognize(
      _request(SubjectiveAnswerRecognitionMode.ocr),
    );

    expect(result.isSuccess, isTrue);
    expect(result.recognizedText, 'answer from OCR');
    expect(ocr.calls, 1);
    expect(vision.calls, 0);
  });

  test('Vision uses the active profile and answer-only transcription prompt',
      () async {
    final vision = _FakeLlmApiClient(response: '  editable vision answer  ');
    final assets = _FakeVisionAssetBuilder();
    final adapter = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(
        ocrProfile: _ocrProfile,
        visionProfile: _visionProfile,
      ),
      ocrClient: _FakeOcrClient(response: _document('unused')),
      apiClient: vision,
      assetBuilder: assets,
    );

    final result = await adapter.recognize(
      _request(SubjectiveAnswerRecognitionMode.vision),
    );

    expect(result.classification,
        SubjectiveAnswerRecognitionClassification.success);
    expect(result.recognizedText, 'editable vision answer');
    expect(vision.calls, 1);
    expect(assets.calls, 1);
    expect(vision.temperature, 0);
    expect(vision.prompt, contains('只返回可编辑的答案文本'));
    expect(vision.prompt, isNot(contains('questions')));
  });

  test('missing engine fails safely before any provider call', () async {
    final ocr = _FakeOcrClient(response: _document('unused'));
    final vision = _FakeLlmApiClient(response: 'unused');
    final adapter = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(),
      ocrClient: ocr,
      apiClient: vision,
      assetBuilder: _FakeVisionAssetBuilder(),
    );

    final result = await adapter.recognize(
      _request(SubjectiveAnswerRecognitionMode.ocr),
    );

    expect(
      result.classification,
      SubjectiveAnswerRecognitionClassification.engineUnavailable,
    );
    expect(result.recognizedText, isEmpty);
    expect(ocr.calls, 0);
    expect(vision.calls, 0);
  });

  test('provider exception and empty output remain typed failures', () async {
    final failed = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(ocrProfile: _ocrProfile),
      ocrClient: _FakeOcrClient(
        response: _document('unused'),
        failure: StateError('synthetic failure'),
      ),
    );
    final empty = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(ocrProfile: _ocrProfile),
      ocrClient: _FakeOcrClient(response: _document('   ')),
    );

    expect(
      (await failed.recognize(_request(SubjectiveAnswerRecognitionMode.ocr)))
          .classification,
      SubjectiveAnswerRecognitionClassification.providerFailure,
    );
    expect(
      (await empty.recognize(_request(SubjectiveAnswerRecognitionMode.ocr)))
          .classification,
      SubjectiveAnswerRecognitionClassification.emptyResult,
    );
  });

  test('Vision provider exception remains a typed failure', () async {
    final vision = _FakeLlmApiClient(
      response: 'unused',
      failure: StateError('synthetic failure'),
    );
    final adapter = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(visionProfile: _visionProfile),
      ocrClient: _FakeOcrClient(response: _document('unused')),
      apiClient: vision,
      assetBuilder: _FakeVisionAssetBuilder(),
    );

    final result = await adapter.recognize(
      _request(SubjectiveAnswerRecognitionMode.vision),
    );

    expect(
      result.classification,
      SubjectiveAnswerRecognitionClassification.providerFailure,
    );
    expect(result.recognizedText, isEmpty);
    expect(vision.calls, 1);
  });

  test('oversized provider output is rejected', () async {
    final adapter = SubjectiveAnswerRecognitionAdapter(
      engineRepository: _FakeEngineRepository(ocrProfile: _ocrProfile),
      ocrClient: _FakeOcrClient(
        response: _document(
          List<String>.filled(
            SubjectiveAnswerRecognitionAdapter.maxRecognizedScalars + 1,
            'a',
          ).join(),
        ),
      ),
    );

    final result = await adapter.recognize(
      _request(SubjectiveAnswerRecognitionMode.ocr),
    );

    expect(
      result.classification,
      SubjectiveAnswerRecognitionClassification.outputTooLong,
    );
    expect(result.recognizedText, isEmpty);
  });

  test('adapter has no ImportTask or pending-review dependency', () async {
    final source = await File(
      'lib/services/practice/subjective_answer_recognition_adapter.dart',
    ).readAsString();

    expect(source, isNot(contains('ImportPipelineService')));
    expect(source, isNot(contains('ImportTaskCoordinator')));
    expect(source, isNot(contains('TaskManager')));
    expect(source, isNot(contains('pendingReview')));
  });
}
