import '../../application/agent/agent_config_service.dart';
import '../../application/ai_config/ai_config_ports.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../../domain/ai_config/shiroha_capability_registry.dart';
import '../models/ai_engine_profile.dart';
import 'ai_engine_repository.dart';

final class AiEngineAgentProfileRepository
    implements AgentProfileCatalogPort, AgentProviderProfileResolverPort {
  const AiEngineAgentProfileRepository({
    required AiEngineRepository engineRepository,
    AiConfigStorePort? aiConfigStore,
  })  : _engineRepository = engineRepository,
        _aiConfigStore = aiConfigStore;

  final AiEngineRepository _engineRepository;
  final AiConfigStorePort? _aiConfigStore;

  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async {
    final profiles = (await _loadProfiles())
        .where((profile) => profile.isComplete)
        .toList(growable: false);
    final summaries = <AgentProfileSummary>[];
    for (final profile in profiles) {
      final (providerKind, capabilities) =
          await _registryMetadataFor(profile.id);
      summaries.add(
        AgentProfileSummary(
          profileId: profile.id,
          displayName: profile.name,
          modelName: profile.modelName,
          modelProviderKind: providerKind,
          capabilities: capabilities,
        ),
      );
    }
    return List<AgentProfileSummary>.unmodifiable(summaries);
  }

  Future<(AiProviderKind?, Map<AiModelCapability, AiCapabilitySupport>)>
      _registryMetadataFor(
    String modelRef,
  ) async {
    final store = _aiConfigStore;
    if (store == null) {
      return (
        null,
        const <AiModelCapability, AiCapabilitySupport>{},
      );
    }
    final model = await store.readModel(modelRef);
    if (model == null) {
      return (
        null,
        const <AiModelCapability, AiCapabilitySupport>{},
      );
    }
    final provider = await store.readProvider(model.providerId);
    if (provider == null) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    try {
      return (
        provider.kind,
        resolveModelCapabilities(
          providerKind: provider.kind,
          canonicalModelId: model.canonicalModelId,
          claims: await store.listClaims(modelRef),
        ),
      );
    } on AiConfigException {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
  }

  @override
  Future<AgentProviderProfile?> resolveMainProfile(String profileId) async {
    final normalizedId = profileId.trim();
    final profiles = await _loadProfiles();
    final matches = profiles
        .where((profile) => profile.id == normalizedId)
        .toList(growable: false);
    if (matches.isEmpty) return null;
    if (matches.length != 1) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    final profile = matches.single;
    if (!profile.isComplete) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    final (providerKind, capabilities) = await _registryMetadataFor(profile.id);
    return AgentProviderProfile(
      profileId: profile.id,
      apiKey: profile.apiKey,
      baseUrl: profile.baseUrl,
      modelName: profile.modelName,
      modelProviderKind: providerKind,
      capabilities: capabilities,
    );
  }

  Future<List<AiEngineProfile>> _loadProfiles() async {
    try {
      final profiles = await _engineRepository.getEngines(AiEngineType.text);
      final mainProfiles = profiles
          .where((profile) => profile.engineType != AiEngineType.ocr)
          .toList(growable: false)
        ..sort((left, right) {
          final byName = left.name.compareTo(right.name);
          return byName != 0 ? byName : left.id.compareTo(right.id);
        });
      final seenIds = <String>{};
      for (final profile in mainProfiles) {
        if (profile.id.trim().isEmpty ||
            profile.name.trim().isEmpty ||
            !seenIds.add(profile.id)) {
          throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
        }
      }
      return mainProfiles;
    } on AgentProfileException {
      rethrow;
    } catch (_) {
      throw const AgentProfileException(
        AgentProfileFailure.temporarilyUnavailable,
      );
    }
  }
}
