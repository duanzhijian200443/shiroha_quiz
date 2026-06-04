import '../../data/models/ai_engine_profile.dart';

abstract class LlmProviderClient {
  const LlmProviderClient();

  Future<String> callText(LlmTextRequest request);

  Future<String> callVision(LlmVisionRequest request);
}

class LlmTextRequest {
  const LlmTextRequest({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.systemPrompt,
    required this.prompt,
    required this.temperature,
    required this.reasoningEffort,
    required this.maxTokens,
    required this.jsonResponse,
    required this.timeout,
  });

  final String apiKey;
  final String baseUrl;
  final String model;
  final String systemPrompt;
  final String prompt;
  final double temperature;
  final String reasoningEffort;
  final int maxTokens;
  final bool jsonResponse;
  final Duration timeout;

  factory LlmTextRequest.fromProfile({
    required AiEngineProfile profile,
    required String prompt,
    String? systemPrompt,
    double? temperature,
    String? reasoningEffort,
    int maxTokens = 8192,
    bool jsonResponse = false,
    Duration timeout = const Duration(minutes: 5),
  }) {
    return LlmTextRequest(
      apiKey: profile.apiKey,
      baseUrl: profile.baseUrl,
      model: profile.modelName,
      systemPrompt: systemPrompt?.trim() ?? '',
      prompt: prompt,
      temperature: temperature ?? profile.temperature,
      reasoningEffort: reasoningEffort ?? profile.reasoningEffort,
      maxTokens: maxTokens,
      jsonResponse: jsonResponse,
      timeout: timeout,
    );
  }

  bool get isComplete =>
      apiKey.isNotEmpty && baseUrl.isNotEmpty && model.isNotEmpty;

  List<Map<String, String>> get chatMessages {
    return [
      if (systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': prompt},
    ];
  }

  String get combinedPrompt {
    if (systemPrompt.isEmpty) return prompt;
    return '$systemPrompt\n\n$prompt';
  }

  List<String> get missingProfileFields {
    return [
      if (apiKey.isEmpty) 'api_key',
      if (baseUrl.isEmpty) 'base_url',
      if (model.isEmpty) 'model_name',
    ];
  }
}

class LlmVisionAsset {
  const LlmVisionAsset._({
    required this.mimeType,
    this.base64Data,
    this.filePath,
    required this.uploadAsFile,
  });

  final String mimeType;
  final String? base64Data;
  final String? filePath;
  final bool uploadAsFile;

  factory LlmVisionAsset.inline({
    required String mimeType,
    required String base64Data,
  }) {
    return LlmVisionAsset._(
      mimeType: mimeType,
      base64Data: base64Data,
      uploadAsFile: false,
    );
  }

  factory LlmVisionAsset.uploadFile({
    required String mimeType,
    required String filePath,
  }) {
    return LlmVisionAsset._(
      mimeType: mimeType,
      filePath: filePath,
      uploadAsFile: true,
    );
  }

  bool get hasInlineData => base64Data != null && base64Data!.isNotEmpty;
}

class LlmVisionRequest {
  const LlmVisionRequest({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.prompt,
    required this.temperature,
    required this.assets,
    required this.timeout,
  });

  final String apiKey;
  final String baseUrl;
  final String model;
  final String prompt;
  final double temperature;
  final List<LlmVisionAsset> assets;
  final Duration timeout;

  factory LlmVisionRequest.fromProfile({
    required AiEngineProfile profile,
    required String prompt,
    required List<LlmVisionAsset> assets,
    double? temperature,
    Duration timeout = const Duration(minutes: 5),
  }) {
    return LlmVisionRequest(
      apiKey: profile.apiKey,
      baseUrl: profile.baseUrl,
      model: profile.modelName,
      prompt: prompt,
      temperature: temperature ?? profile.temperature,
      assets: List.unmodifiable(assets),
      timeout: timeout,
    );
  }

  bool get isComplete =>
      apiKey.isNotEmpty &&
      baseUrl.isNotEmpty &&
      model.isNotEmpty &&
      assets.isNotEmpty;

  List<String> get missingProfileFields {
    return [
      if (apiKey.isEmpty) 'api_key',
      if (baseUrl.isEmpty) 'base_url',
      if (model.isEmpty) 'model_name',
      if (assets.isEmpty) 'vision_assets',
    ];
  }
}
