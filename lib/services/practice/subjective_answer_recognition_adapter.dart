import '../../application/practice/subjective_answer_recognition.dart';
import '../../data/models/ai_engine_profile.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../import_pipeline/ocr_document.dart';
import '../import_pipeline/ocr_document_client.dart';
import '../import_pipeline/ocr_request_scheduler.dart';
import '../import_pipeline/ocr_request_executor.dart';
import '../../application/import/import_advanced_preferences.dart';
import '../llm_api_client.dart';
import '../llm_providers/llm_provider_client.dart';
import '../llm_providers/zhipu_ocr_client.dart';
import '../vision_asset_builder.dart';

final class SubjectiveAnswerRecognitionAdapter
    implements SubjectiveAnswerRecognitionPort {
  SubjectiveAnswerRecognitionAdapter({
    required AiEngineRepository engineRepository,
    OcrDocumentClient ocrClient = const ZhipuOcrClient(),
    OcrRequestScheduler? requestScheduler,
    OcrRequestExecutor? requestExecutor,
    LlmApiClient apiClient = const LlmApiClient(),
    VisionAssetBuilder assetBuilder = const VisionAssetBuilder(),
  })  : _engineRepository = engineRepository,
        _ocrClient = ocrClient,
        _requestExecutor = requestExecutor ??
            OcrRequestExecutor(
              scheduler: requestScheduler ?? OcrRequestScheduler(),
              preferencesLoader: () async => ImportAdvancedPreferences.defaults,
            ),
        _apiClient = apiClient,
        _assetBuilder = assetBuilder;

  static const int maxRecognizedScalars = 20000;

  static const String _visionPrompt = '''
请准确转写图片中的学生主观题作答内容。
只返回可编辑的答案文本，不要评价、评分、补充解题步骤或使用 Markdown 代码围栏。
保留原有段落和数学含义；数学公式可使用 LaTeX。
''';

  final AiEngineRepository _engineRepository;
  final OcrDocumentClient _ocrClient;
  final OcrRequestExecutor _requestExecutor;
  final LlmApiClient _apiClient;
  final VisionAssetBuilder _assetBuilder;

  @override
  Future<SubjectiveAnswerRecognitionResult> recognize(
    SubjectiveAnswerRecognitionRequest request,
  ) async {
    if (request.imagePath.trim().isEmpty || request.imageName.trim().isEmpty) {
      return SubjectiveAnswerRecognitionResult.failure(
        SubjectiveAnswerRecognitionClassification.invalidInput,
      );
    }

    try {
      final text = switch (request.mode) {
        SubjectiveAnswerRecognitionMode.ocr => await _recognizeWithOcr(request),
        SubjectiveAnswerRecognitionMode.vision =>
          await _recognizeWithVision(request),
      };
      return _validated(text);
    } on _RecognitionEngineUnavailable {
      return SubjectiveAnswerRecognitionResult.failure(
        SubjectiveAnswerRecognitionClassification.engineUnavailable,
      );
    } catch (_) {
      return SubjectiveAnswerRecognitionResult.failure(
        SubjectiveAnswerRecognitionClassification.providerFailure,
      );
    }
  }

  Future<String> _recognizeWithOcr(
    SubjectiveAnswerRecognitionRequest request,
  ) async {
    final profile = await _engineRepository.getActiveOcrEngine();
    _requireComplete(profile);
    final document = await _requestExecutor.run(
      taskId: 'subjective-answer-${_nextOcrRequestId++}',
      operation: (timeout) => _ocrClient.parseFile(
        profile: profile!,
        filePath: request.imagePath,
        sourceName: request.imageName,
        timeout: timeout,
      ),
    );
    return _projectOcrText(document);
  }

  int _nextOcrRequestId = 0;

  Future<String> _recognizeWithVision(
    SubjectiveAnswerRecognitionRequest request,
  ) async {
    final profile = await _engineRepository.getActiveVisionEngine();
    _requireComplete(profile);
    final asset = await _assetBuilder.buildInlineFileAsset(
      request.imagePath,
      // buildInlineFileAsset normalizes decoded images to JPEG when
      // compression is requested.
      mimeType: 'image/jpeg',
      compressImage: true,
    );
    return _apiClient.callVision(
      profile: profile!,
      prompt: _visionPrompt,
      assets: <LlmVisionAsset>[asset],
      temperature: 0,
      timeout: const Duration(seconds: 90),
    );
  }

  void _requireComplete(AiEngineProfile? profile) {
    if (profile == null || !profile.isComplete) {
      throw const _RecognitionEngineUnavailable();
    }
  }

  SubjectiveAnswerRecognitionResult _validated(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      return SubjectiveAnswerRecognitionResult.failure(
        SubjectiveAnswerRecognitionClassification.emptyResult,
      );
    }
    if (text.runes.length > maxRecognizedScalars) {
      return SubjectiveAnswerRecognitionResult.failure(
        SubjectiveAnswerRecognitionClassification.outputTooLong,
      );
    }
    return SubjectiveAnswerRecognitionResult.success(text);
  }

  String _projectOcrText(OcrDocument document) {
    final blockText = document.flattenedBlocks
        .where((block) => block.imagePayload == null)
        .map((block) => block.text.trim())
        .where((text) => text.isNotEmpty && text != '[图片]')
        .join('\n');
    if (blockText.isNotEmpty) return blockText;
    return document.markdown.trim();
  }
}

final class _RecognitionEngineUnavailable implements Exception {
  const _RecognitionEngineUnavailable();
}
