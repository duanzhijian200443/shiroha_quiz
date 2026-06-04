import 'llm_providers/llm_provider_client.dart';
import 'llm_providers/llm_provider_registry.dart';
import 'llm_providers/openai_compatible_provider_client.dart';
import 'llm_providers/zhipu_provider_client.dart';

class LlmApiClient {
  const LlmApiClient();

  static String buildChatUrl(String baseUrl, bool isZhipu) {
    if (isZhipu) {
      return ZhipuProviderClient.buildZhipuChatUrl(baseUrl);
    }
    return OpenAiCompatibleProviderClient.buildChatUrl(baseUrl);
  }

  static String extractContent(String responseBody) {
    return OpenAiCompatibleProviderClient.extractContent(responseBody);
  }

  Future<String> callText({
    required Map<String, dynamic> profile,
    required String prompt,
    double? temperature,
    String? reasoningEffort,
    int maxTokens = 8192,
    bool jsonResponse = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final request = LlmTextRequest.fromProfile(
      profile: profile,
      prompt: prompt,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      maxTokens: maxTokens,
      jsonResponse: jsonResponse,
      timeout: timeout,
    );
    if (!request.isComplete) {
      throw Exception(
        'AI engine profile is incomplete: ${request.missingProfileFields.join(', ')}',
      );
    }

    final provider = LlmProviderRegistry.clientForBaseUrl(request.baseUrl);
    return provider.callText(request);
  }

  Future<String> callVision({
    required Map<String, dynamic> profile,
    required String prompt,
    required List<LlmVisionAsset> assets,
    double? temperature,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final request = LlmVisionRequest.fromProfile(
      profile: profile,
      prompt: prompt,
      assets: assets,
      temperature: temperature,
      timeout: timeout,
    );
    if (!request.isComplete) {
      throw Exception(
        'AI vision profile is incomplete: ${request.missingProfileFields.join(', ')}',
      );
    }

    final provider = LlmProviderRegistry.clientForBaseUrl(request.baseUrl);
    return provider.callVision(request);
  }
}
