abstract final class DeepSeekResponsesTransportContract {
  /// Exact model ids officially documented to support the DeepSeek Responses
  /// API and tool calls (evidence 2026-09-20:
  /// api-docs.deepseek.com/quick_start/pricing feature matrix;
  /// api-docs.deepseek.com/updates — 2026-07-31 V4-Flash native Responses,
  /// 2026-08-13 API-wide native Responses; /guides/tool_calls).
  static const Set<String> currentModelIds = <String>{
    'deepseek-flash',
    'deepseek-v4-pro',
  };

  /// Migration compatibility only. `deepseek-v4-flash` was retired
  /// 2026-09-10; requests are served by DeepSeek-V4.1-Flash and the alias
  /// stays accepted by the API, so historical bindings keep working.
  /// Legacy compatibility is NOT a current-model recommendation.
  static const Set<String> legacyCompatibilityModelIds = <String>{
    'deepseek-v4-flash',
  };

  static const Set<String> supportedModelIds = <String>{
    ...currentModelIds,
    ...legacyCompatibilityModelIds,
  };

  static bool supportsModel(String canonicalModelId) =>
      supportedModelIds.contains(canonicalModelId);

  static bool isCurrentModel(String canonicalModelId) =>
      currentModelIds.contains(canonicalModelId);
}
