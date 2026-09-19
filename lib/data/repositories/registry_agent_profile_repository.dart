import '../../application/agent/agent_config_service.dart';
import '../../application/ai_config/ai_config_ports.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../../domain/ai_config/shiroha_capability_registry.dart';

/// Agent catalog and runtime resolution backed directly by the
/// Provider / Model Registry. This is the model-asset authority for Agent
/// configuration: it never reads the capability text binding and never goes
/// through the legacy `ai_engines` projection.
///
/// `AgentProfileSummary.profileId` / `AgentConfig.mainProfileId` are the
/// Model Registry `modelRef` — the id space is identical, so stored agent
/// configurations keep resolving without a codec migration.
final class RegistryAgentProfileRepository
    implements AgentProfileCatalogPort, AgentProviderProfileResolverPort {
  const RegistryAgentProfileRepository({
    required AiConfigServiceRepositoryPort aiConfigRepository,
  }) : _aiConfigRepository = aiConfigRepository;

  final AiConfigServiceRepositoryPort _aiConfigRepository;

  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async {
    final summaries = <AgentProfileSummary>[];
    for (final model in await _aiConfigRepository.store.listModels()) {
      if (model.availability != AiModelAvailability.available) continue;
      summaries.add(await _summaryFor(model));
    }
    summaries.sort((left, right) {
      final byProvider = (left.providerDisplayName ?? '')
          .compareTo(right.providerDisplayName ?? '');
      if (byProvider != 0) return byProvider;
      final byModel = left.displayName.compareTo(right.displayName);
      return byModel != 0 ? byModel : left.profileId.compareTo(right.profileId);
    });
    return List<AgentProfileSummary>.unmodifiable(summaries);
  }

  Future<AgentProfileSummary> _summaryFor(AiModelRecord model) async {
    final provider =
        await _aiConfigRepository.store.readProvider(model.providerId);
    if (provider == null) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    return AgentProfileSummary(
      profileId: model.modelRef,
      displayName: model.displayName,
      modelName: model.canonicalModelId,
      modelProviderKind: provider.kind,
      providerDisplayName: provider.displayName,
      capabilities: await _capabilitiesFor(model, provider),
    );
  }

  Future<Map<AiModelCapability, AiCapabilitySupport>> _capabilitiesFor(
    AiModelRecord model,
    AiProviderRecord provider,
  ) async {
    try {
      return resolveModelCapabilities(
        providerKind: provider.kind,
        canonicalModelId: model.canonicalModelId,
        claims: await _aiConfigRepository.store.listClaims(model.modelRef),
      );
    } on AiConfigException {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
  }

  @override
  Future<AgentProviderProfile?> resolveMainProfile(String profileId) async {
    final modelRef = profileId.trim();
    final model = await _aiConfigRepository.store.readModel(modelRef);
    if (model == null || model.availability != AiModelAvailability.available) {
      return null;
    }
    final provider =
        await _aiConfigRepository.store.readProvider(model.providerId);
    if (provider == null) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    // Runtime-only credential hydration from the S0 authority; the plaintext
    // never enters any DTO, log, or persisted value outside this bounded
    // profile value whose string representation is REDACTED.
    final String credential;
    try {
      credential = await _aiConfigRepository.credentialForProvider(
        provider.providerId,
      );
    } on AiConfigException catch (error) {
      if (error.failure == AiConfigFailure.credentialMissing) {
        throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
      }
      throw const AgentProfileException(
        AgentProfileFailure.temporarilyUnavailable,
      );
    }
    return AgentProviderProfile(
      profileId: model.modelRef,
      apiKey: credential,
      baseUrl: provider.baseUrl,
      modelName: model.canonicalModelId,
      modelProviderKind: provider.kind,
      capabilities: await _capabilitiesFor(model, provider),
    );
  }
}
