import '../../application/agent/agent_config_service.dart';
import '../models/ai_engine_profile.dart';
import 'ai_engine_repository.dart';

final class AiEngineAgentProfileRepository
    implements AgentProfileCatalogPort, AgentProviderProfileResolverPort {
  const AiEngineAgentProfileRepository({
    required AiEngineRepository engineRepository,
  }) : _engineRepository = engineRepository;

  final AiEngineRepository _engineRepository;

  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async {
    final profiles = (await _loadProfiles())
        .where((profile) => profile.isComplete)
        .toList(growable: false);
    return List<AgentProfileSummary>.unmodifiable(
      profiles.map(
        (profile) => AgentProfileSummary(
          profileId: profile.id,
          displayName: profile.name,
          modelName: profile.modelName,
        ),
      ),
    );
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
    return AgentProviderProfile(
      profileId: profile.id,
      apiKey: profile.apiKey,
      baseUrl: profile.baseUrl,
      modelName: profile.modelName,
      temperature: profile.temperature,
      reasoningEffort: profile.reasoningEffort,
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
