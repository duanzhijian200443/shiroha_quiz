import 'package:flutter/foundation.dart';

import '../data/repositories/ai_engine_repository.dart';
import 'ai_prompts.dart';
import 'llm_api_client.dart';
import 'llm_providers/llm_provider_client.dart';
import 'llm_providers/llm_provider_registry.dart';
import 'question_parse_pipeline.dart';
import 'vision_asset_builder.dart';

class AiVisionParseService {
  AiVisionParseService({
    LlmApiClient apiClient = const LlmApiClient(),
    AiEngineRepository? engineRepository,
    QuestionParsePipeline parsePipeline = const QuestionParsePipeline(),
    VisionAssetBuilder assetBuilder = const VisionAssetBuilder(),
  })  : _apiClient = apiClient,
        _engineRepository = engineRepository ?? AiEngineRepository.instance,
        _parsePipeline = parsePipeline,
        _assetBuilder = assetBuilder;

  final LlmApiClient _apiClient;
  final AiEngineRepository _engineRepository;
  final QuestionParsePipeline _parsePipeline;
  final VisionAssetBuilder _assetBuilder;

  Future<List<Map<String, dynamic>>> parseImages(
    List<String> imagePaths,
  ) async {
    final profile = await _engineRepository.getActiveVisionEngine();
    if (profile == null) throw Exception("未激活视觉 AI 引擎");

    final prompt = AiPrompts.visionParseWithConstraints();

    try {
      final assets = await _assetBuilder.buildInlineImageAssets(imagePaths);

      debugPrint(
          "🚀 正在组装 ${imagePaths.length} 张图片并向视觉大模型发起请求，请耐心等待 (约需几十秒到一分钟)...");
      final startTime = DateTime.now();

      final responseText = await _apiClient.callVision(
        profile: profile,
        prompt: prompt,
        assets: assets,
        temperature: profile.temperature,
        timeout: const Duration(minutes: 8),
      );
      debugPrint(
          "✅ Vision API 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
      return _parsePipeline.parseVisionQuestions(
        responseText,
        strictContentQuality: true,
      );
    } catch (e) {
      throw Exception("多图视觉解析异常: $e");
    }
  }

  Future<List<Map<String, dynamic>>> parseFile(String filePath) async {
    final profile = await _engineRepository.getActiveVisionEngine();
    if (profile == null) throw Exception("未激活视觉引擎");

    if (!profile.isComplete) {
      throw Exception("视觉引擎配置不完整: ${profile.missingFields.join(', ')}");
    }

    final providerKind = LlmProviderRegistry.kindForBaseUrl(profile.baseUrl);
    final isGemini = providerKind == LlmProviderKind.gemini;
    final isZhipu = providerKind == LlmProviderKind.zhipu;
    final lowerPath = filePath.toLowerCase();
    final isPdf = lowerPath.endsWith('.pdf');
    final isDocx = lowerPath.endsWith('.docx');

    if (isDocx) throw Exception("视觉模型无法直接看懂 Word，请先另存为 PDF 或截图！");
    if (isPdf && !isGemini && !isZhipu) {
      throw Exception("标准 OpenAI 协议不支持直传 PDF，请切换回 Gemini 或 智谱！");
    }

    try {
      debugPrint("🚀 正在向视觉大模型发起文件/单图解析请求，请耐心等待...");
      final startTime = DateTime.now();

      final asset = isZhipu && isPdf
          ? LlmVisionAsset.uploadFile(
              mimeType: 'application/pdf',
              filePath: filePath,
            )
          : await _assetBuilder.buildInlineFileAsset(
              filePath,
              mimeType: isPdf ? 'application/pdf' : 'image/jpeg',
              compressImage: !isPdf,
            );

      final responseText = await _apiClient.callVision(
        profile: profile,
        prompt: AiPrompts.visionParsePrompt,
        assets: [asset],
        temperature: profile.temperature,
        timeout: isZhipu && isPdf
            ? const Duration(minutes: 5)
            : isGemini
                ? const Duration(minutes: 3)
                : const Duration(seconds: 90),
      );

      _logFileParseSuccess(
        isZhipu: isZhipu,
        isGemini: isGemini,
        elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
      );
      return _parsePipeline.parseVisionQuestions(responseText);
    } catch (e) {
      if (e.toString().contains('SocketException')) {
        throw Exception("连接中断。请检查网络代理，或尝试体积较小的文件。");
      }
      throw Exception("解析异常: $e");
    }
  }

  void _logFileParseSuccess({
    required bool isZhipu,
    required bool isGemini,
    required int elapsedSeconds,
  }) {
    if (isZhipu) {
      debugPrint("✅ 智谱 Vision 解析成功，耗时 $elapsedSeconds 秒。");
    } else if (isGemini) {
      debugPrint("✅ Gemini Vision 返回成功，耗时 $elapsedSeconds 秒。");
    } else {
      debugPrint("✅ Vision API 解析成功，耗时 $elapsedSeconds 秒。");
    }
  }
}
