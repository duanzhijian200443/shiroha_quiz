import 'gemini_provider_client.dart';
import 'llm_provider_client.dart';
import 'openai_compatible_provider_client.dart';
import 'zhipu_provider_client.dart';

enum LlmProviderKind { gemini, zhipu, openAiCompatible }

class LlmProviderRegistry {
  const LlmProviderRegistry._();

  static LlmProviderKind kindForBaseUrl(String baseUrl) {
    if (baseUrl.contains('generativelanguage.googleapis.com')) {
      return LlmProviderKind.gemini;
    }
    if (baseUrl.contains('bigmodel.cn')) {
      return LlmProviderKind.zhipu;
    }
    return LlmProviderKind.openAiCompatible;
  }

  static LlmProviderClient clientForBaseUrl(String baseUrl) {
    return switch (kindForBaseUrl(baseUrl)) {
      LlmProviderKind.gemini => const GeminiProviderClient(),
      LlmProviderKind.zhipu => const ZhipuProviderClient(),
      LlmProviderKind.openAiCompatible =>
        const OpenAiCompatibleProviderClient(),
    };
  }
}
