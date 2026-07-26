import 'dart:convert';

import '../data/repositories/ai_engine_repository.dart';
import 'ai_vision_parse_service.dart';
import 'llm_api_client.dart';

class AiDirectCallService {
  AiDirectCallService({
    LlmApiClient apiClient = const LlmApiClient(),
    required AiEngineRepository engineRepository,
    AiVisionParseService? visionParseService,
  })  : _apiClient = apiClient,
        _engineRepository = engineRepository,
        _visionParseService = visionParseService ??
            AiVisionParseService(engineRepository: engineRepository);

  final LlmApiClient _apiClient;
  final AiEngineRepository _engineRepository;
  final AiVisionParseService _visionParseService;

  Future<String> call(String prompt, {List<String>? imagePaths}) async {
    if (imagePaths != null && imagePaths.isNotEmpty) {
      final questions = await _visionParseService.parseImages(imagePaths);
      return jsonEncode({'questions': questions});
    }

    final profile = await _engineRepository.getActiveTextEngine();
    if (profile == null) throw Exception("未激活文本引擎");
    return _apiClient.callText(profile: profile, prompt: prompt);
  }
}
