abstract class LlmProviderClient {
  const LlmProviderClient();

  Future<String> callText(LlmTextRequest request);

  Future<String> callVision(LlmVisionRequest request);
}

class LlmProviderProfile {
  const LlmProviderProfile({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.temperature,
    required this.reasoningEffort,
  });

  final String apiKey;
  final String baseUrl;
  final String model;
  final double temperature;
  final String reasoningEffort;

  factory LlmProviderProfile.fromMap(Map<String, dynamic> profile) {
    return LlmProviderProfile(
      apiKey: (profile['api_key'] as String? ?? '').trim(),
      baseUrl: _normalizeBaseUrl(profile['base_url'] as String? ?? ''),
      model: (profile['model_name'] as String? ?? '').trim(),
      temperature: (profile['temperature'] as num?)?.toDouble() ?? 0.7,
      reasoningEffort: (profile['reasoning_effort'] as String? ?? '').trim(),
    );
  }

  bool get isComplete => missingFields.isEmpty;

  List<String> get missingFields {
    return [
      if (apiKey.isEmpty) 'api_key',
      if (baseUrl.isEmpty) 'base_url',
      if (model.isEmpty) 'model_name',
    ];
  }

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }
}

class LlmTextRequest {
  const LlmTextRequest({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
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
  final String prompt;
  final double temperature;
  final String reasoningEffort;
  final int maxTokens;
  final bool jsonResponse;
  final Duration timeout;

  factory LlmTextRequest.fromProfile({
    required Map<String, dynamic> profile,
    required String prompt,
    double? temperature,
    String? reasoningEffort,
    int maxTokens = 8192,
    bool jsonResponse = false,
    Duration timeout = const Duration(minutes: 5),
  }) {
    final providerProfile = LlmProviderProfile.fromMap(profile);
    return LlmTextRequest(
      apiKey: providerProfile.apiKey,
      baseUrl: providerProfile.baseUrl,
      model: providerProfile.model,
      prompt: prompt,
      temperature: temperature ?? providerProfile.temperature,
      reasoningEffort: reasoningEffort ?? providerProfile.reasoningEffort,
      maxTokens: maxTokens,
      jsonResponse: jsonResponse,
      timeout: timeout,
    );
  }

  bool get isComplete =>
      apiKey.isNotEmpty && baseUrl.isNotEmpty && model.isNotEmpty;

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
    required Map<String, dynamic> profile,
    required String prompt,
    required List<LlmVisionAsset> assets,
    double? temperature,
    Duration timeout = const Duration(minutes: 5),
  }) {
    final providerProfile = LlmProviderProfile.fromMap(profile);
    return LlmVisionRequest(
      apiKey: providerProfile.apiKey,
      baseUrl: providerProfile.baseUrl,
      model: providerProfile.model,
      prompt: prompt,
      temperature: temperature ?? providerProfile.temperature,
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
