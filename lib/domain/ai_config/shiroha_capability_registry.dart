import 'ai_config_contracts.dart';

/// Exact-key curated capability evidence. Never infer capabilities from model
/// name fragments, prefixes, suffixes, or display labels.
abstract final class ShirohaCapabilityRegistry {
  static const Map<(AiProviderKind, String),
      Map<AiModelCapability, AiCapabilitySupport>> _claims = {
    (AiProviderKind.deepseek, 'deepseek-v4-flash'): {
      AiModelCapability.textInput: AiCapabilitySupport.supported,
      AiModelCapability.textOutput: AiCapabilitySupport.supported,
      AiModelCapability.reasoning: AiCapabilitySupport.supported,
      AiModelCapability.toolCalling: AiCapabilitySupport.supported,
    },
    (AiProviderKind.deepseek, 'deepseek-flash'): {
      AiModelCapability.textInput: AiCapabilitySupport.supported,
      AiModelCapability.textOutput: AiCapabilitySupport.supported,
    },
    (AiProviderKind.zhipu, 'glm-ocr'): {
      AiModelCapability.ocr: AiCapabilitySupport.supported,
      AiModelCapability.textOutput: AiCapabilitySupport.supported,
    },
    (AiProviderKind.zhipu, 'glm-5.3'): {
      AiModelCapability.textInput: AiCapabilitySupport.supported,
      AiModelCapability.textOutput: AiCapabilitySupport.supported,
    },
  };

  static Map<AiModelCapability, AiCapabilitySupport> claimsFor(
    AiProviderKind providerKind,
    String canonicalModelId,
  ) {
    return Map.unmodifiable(
      _claims[(providerKind, canonicalModelId)] ?? const {},
    );
  }
}

Map<AiModelCapability, AiCapabilitySupport> resolveModelCapabilities({
  required AiProviderKind providerKind,
  required String canonicalModelId,
  required List<AiCapabilityClaim> claims,
}) {
  final curated = ShirohaCapabilityRegistry.claimsFor(
    providerKind,
    canonicalModelId,
  );
  final resolved = <AiModelCapability, AiCapabilitySupport>{};
  for (final capability in AiModelCapability.values) {
    AiCapabilitySupport? selected;
    for (final source in AiCapabilityClaimSource.values) {
      final values = claims
          .where(
            (claim) => claim.capability == capability && claim.source == source,
          )
          .map((claim) => claim.support)
          .toSet();
      if (source == AiCapabilityClaimSource.shirohaRegistry) {
        final curatedValue = curated[capability];
        if (curatedValue != null) values.add(curatedValue);
      }
      if (values.length > 1) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      if (values.isNotEmpty) {
        selected = values.single;
        break;
      }
    }
    resolved[capability] = selected ?? AiCapabilitySupport.unknown;
  }
  return Map.unmodifiable(resolved);
}
