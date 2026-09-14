import '../../domain/ai_config/ai_config_contracts.dart';

abstract interface class AiConfigStorePort {
  Future<List<AiProviderRecord>> listProviders();
  Future<AiProviderRecord?> readProvider(String providerId);
  Future<void> insertProvider(AiProviderRecord provider);
  Future<void> updateProvider(AiProviderRecord provider, int expectedRevision);
  Future<void> deleteProvider(String providerId);

  Future<List<AiModelRecord>> listModels({String? providerId});
  Future<AiModelRecord?> readModel(String modelRef);
  Future<void> saveModel(AiModelRecord model);
  Future<void> deleteModel(String modelRef);
  Future<List<AiCapabilityClaim>> listClaims(String modelRef);
  Future<void> replaceModelSnapshot({
    required String providerId,
    required int expectedProviderRevision,
    required List<AiModelRecord> models,
    required List<AiCapabilityClaim> officialClaims,
    required int syncedAt,
  });
  Future<void> saveClaims(
    String modelRef,
    AiCapabilityClaimSource source,
    List<AiCapabilityClaim> claims,
  );

  Future<AiCapabilityBinding?> readBinding(AiCapabilitySlot slot);
  Future<List<AiCapabilityBinding>> listBindings();
  Future<void> saveBinding(
    AiCapabilityBinding binding, {
    required int? expectedRevision,
  });
  Future<void> deleteBinding(
    AiCapabilitySlot slot, {
    required int expectedRevision,
  });

  /// Temporary legacy UI bridge. This is one SQLite transaction and never
  /// writes the retained `ai_engines` table.
  Future<void> saveLegacyProjection({
    required AiProviderRecord provider,
    required AiModelRecord model,
    required AiCapabilityBinding binding,
    required int? expectedProviderRevision,
    required int? expectedBindingRevision,
  });

  Future<void> deleteLegacyProjection(String providerId);
}

/// Application-facing AI configuration repository operations.
///
/// The store remains an application port; concrete credential and SQLite
/// adapters stay below this boundary.
abstract interface class AiConfigServiceRepositoryPort {
  AiConfigStorePort get store;

  Future<String> credentialForProvider(String providerId);

  Future<void> updateProviderMetadata(
    AiProviderRecord provider, {
    required int expectedRevision,
  });
}

abstract interface class AiProviderConnectionPort {
  Future<void> testConnection({
    required AiProviderKind providerKind,
    required String baseUrl,
    required String credential,
  });

  Future<AiDiscoveredModelSnapshot> discoverModels({
    required AiProviderKind providerKind,
    required String baseUrl,
    required String credential,
  });
}

final class AiDiscoveredModelSnapshot {
  AiDiscoveredModelSnapshot({
    required List<AiDiscoveredModel> models,
  }) : models = List<AiDiscoveredModel>.unmodifiable(models);

  final List<AiDiscoveredModel> models;
}

final class AiDiscoveredModel {
  AiDiscoveredModel({
    required String canonicalModelId,
    String? displayName,
    Map<AiModelCapability, AiCapabilitySupport> officialCapabilities = const {},
  })  : canonicalModelId = validateCanonicalModelId(canonicalModelId),
        displayName = displayName ?? canonicalModelId,
        officialCapabilities = Map.unmodifiable(officialCapabilities);

  final String canonicalModelId;
  final String displayName;
  final Map<AiModelCapability, AiCapabilitySupport> officialCapabilities;
}

abstract interface class AgentModelReferencePort {
  Future<Set<String>> referencedModelRefs();
}

abstract interface class AgentTransportCompatibilityPort {
  AgentTransportCompatibilityResult evaluate({
    required String transportProviderKind,
    required AiProviderKind? modelProviderKind,
    required String canonicalModelId,
    required Map<AiModelCapability, AiCapabilitySupport> capabilities,
  });
}

final class AgentTransportCompatibilityResult {
  const AgentTransportCompatibilityResult.compatible()
      : compatible = true,
        reasonCode = null;

  const AgentTransportCompatibilityResult.incompatible(this.reasonCode)
      : compatible = false;

  final bool compatible;
  final String? reasonCode;
}
