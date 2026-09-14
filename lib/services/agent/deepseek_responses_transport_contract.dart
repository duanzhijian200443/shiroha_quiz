abstract final class DeepSeekResponsesTransportContract {
  static const Set<String> supportedModelIds = <String>{
    'deepseek-v4-flash',
  };

  static bool supportsModel(String canonicalModelId) =>
      supportedModelIds.contains(canonicalModelId);
}
