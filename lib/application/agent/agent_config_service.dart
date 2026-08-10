import 'agent_config.dart';

abstract interface class AgentConfigStorePort {
  Future<String?> readAgentConfig();

  Future<void> writeAgentConfig(String encodedConfig);
}

enum AgentConfigStoreFailure { temporarilyUnavailable }

final class AgentConfigStoreException implements Exception {
  const AgentConfigStoreException(this.failure);

  final AgentConfigStoreFailure failure;

  @override
  String toString() => 'AgentConfigStoreException(${failure.name})';
}

final class AgentProfileSummary {
  factory AgentProfileSummary({
    required String profileId,
    required String displayName,
    required String modelName,
  }) {
    final normalizedId = profileId.trim();
    final normalizedName = displayName.trim();
    final normalizedModel = modelName.trim();
    if (!_isSafeValue(normalizedId, maxRunes: 128) ||
        !_isSafeValue(normalizedName, maxRunes: 200) ||
        !_isSafeValue(normalizedModel, maxRunes: 200)) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    return AgentProfileSummary._(
      profileId: normalizedId,
      displayName: normalizedName,
      modelName: normalizedModel,
    );
  }

  const AgentProfileSummary._({
    required this.profileId,
    required this.displayName,
    required this.modelName,
  });

  final String profileId;
  final String displayName;
  final String modelName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentProfileSummary &&
          profileId == other.profileId &&
          displayName == other.displayName &&
          modelName == other.modelName;

  @override
  int get hashCode => Object.hash(profileId, displayName, modelName);
}

final class AgentProviderProfile {
  factory AgentProviderProfile({
    required String profileId,
    required String apiKey,
    required String baseUrl,
    required String modelName,
    required double temperature,
    required String reasoningEffort,
  }) {
    final normalizedId = profileId.trim();
    final normalizedKey = apiKey.trim();
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = modelName.trim();
    if (!_isSafeValue(normalizedId, maxRunes: 128) ||
        normalizedKey.isEmpty ||
        normalizedKey.contains('\u0000') ||
        !_isSafeValue(normalizedBaseUrl, maxRunes: 2048) ||
        !_isSafeValue(normalizedModel, maxRunes: 200) ||
        !temperature.isFinite) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    return AgentProviderProfile._(
      profileId: normalizedId,
      apiKey: normalizedKey,
      baseUrl: normalizedBaseUrl,
      modelName: normalizedModel,
      temperature: temperature,
      reasoningEffort: reasoningEffort.trim(),
    );
  }

  const AgentProviderProfile._({
    required this.profileId,
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    required this.temperature,
    required this.reasoningEffort,
  });

  final String profileId;
  final String apiKey;
  final String baseUrl;
  final String modelName;
  final double temperature;
  final String reasoningEffort;

  @override
  String toString() => 'AgentProviderProfile(REDACTED)';
}

abstract interface class AgentProfileCatalogPort {
  Future<List<AgentProfileSummary>> listMainProfiles();
}

abstract interface class AgentProviderProfileResolverPort {
  Future<AgentProviderProfile?> resolveMainProfile(String profileId);
}

enum AgentProfileFailure { dataCorrupt, temporarilyUnavailable }

final class AgentProfileException implements Exception {
  const AgentProfileException(this.failure);

  final AgentProfileFailure failure;

  @override
  String toString() => 'AgentProfileException(${failure.name})';
}

enum AgentSettingsState { unconfigured, ready, profileUnavailable }

final class AgentSettingsSnapshot {
  AgentSettingsSnapshot({
    required this.state,
    required this.config,
    required this.selectedProfile,
    required List<AgentProfileSummary> availableProfiles,
  }) : availableProfiles = List<AgentProfileSummary>.unmodifiable(
          availableProfiles,
        );

  final AgentSettingsState state;
  final AgentConfig? config;
  final AgentProfileSummary? selectedProfile;
  final List<AgentProfileSummary> availableProfiles;
}

final class AgentSettingsService {
  const AgentSettingsService({
    required AgentConfigStorePort configStore,
    required AgentProfileCatalogPort profileCatalog,
    AgentConfigCodec codec = const AgentConfigCodec(),
  })  : _configStore = configStore,
        _profileCatalog = profileCatalog,
        _codec = codec;

  final AgentConfigStorePort _configStore;
  final AgentProfileCatalogPort _profileCatalog;
  final AgentConfigCodec _codec;

  Future<AgentSettingsSnapshot> load() async {
    try {
      final profiles = await _profileCatalog.listMainProfiles();
      final encoded = await _configStore.readAgentConfig();
      if (encoded == null) {
        return AgentSettingsSnapshot(
          state: AgentSettingsState.unconfigured,
          config: null,
          selectedProfile: null,
          availableProfiles: profiles,
        );
      }
      final config = _codec.decode(encoded);
      final selected = profiles
          .where((profile) => profile.profileId == config.mainProfileId)
          .firstOrNull;
      return AgentSettingsSnapshot(
        state: selected == null
            ? AgentSettingsState.profileUnavailable
            : AgentSettingsState.ready,
        config: config,
        selectedProfile: selected,
        availableProfiles: profiles,
      );
    } on AgentConfigException {
      rethrow;
    } on AgentProfileException catch (error) {
      throw _configFailureForProfile(error);
    } on AgentConfigStoreException {
      throw const AgentConfigException(
        AgentConfigFailure.temporarilyUnavailable,
      );
    }
  }

  Future<void> save(AgentConfig config) async {
    try {
      final profiles = await _profileCatalog.listMainProfiles();
      if (!profiles
          .any((profile) => profile.profileId == config.mainProfileId)) {
        throw const AgentConfigException(AgentConfigFailure.profileNotFound);
      }
      await _configStore.writeAgentConfig(_codec.encode(config));
    } on AgentConfigException {
      rethrow;
    } on AgentProfileException catch (error) {
      throw _configFailureForProfile(error);
    } on AgentConfigStoreException {
      throw const AgentConfigException(
        AgentConfigFailure.temporarilyUnavailable,
      );
    }
  }
}

final class ResolvedAgentConfig {
  const ResolvedAgentConfig({
    required this.config,
    required this.profile,
  });

  final AgentConfig config;
  final AgentProviderProfile profile;

  @override
  String toString() => 'ResolvedAgentConfig(REDACTED)';
}

final class AgentRuntimeConfigResolver {
  const AgentRuntimeConfigResolver({
    required AgentConfigStorePort configStore,
    required AgentProviderProfileResolverPort profileResolver,
    AgentConfigCodec codec = const AgentConfigCodec(),
  })  : _configStore = configStore,
        _profileResolver = profileResolver,
        _codec = codec;

  final AgentConfigStorePort _configStore;
  final AgentProviderProfileResolverPort _profileResolver;
  final AgentConfigCodec _codec;

  Future<ResolvedAgentConfig> resolve() async {
    try {
      final encoded = await _configStore.readAgentConfig();
      if (encoded == null) {
        throw const AgentConfigException(AgentConfigFailure.unconfigured);
      }
      final config = _codec.decode(encoded);
      final profile =
          await _profileResolver.resolveMainProfile(config.mainProfileId);
      if (profile == null) {
        throw const AgentConfigException(AgentConfigFailure.profileNotFound);
      }
      return ResolvedAgentConfig(config: config, profile: profile);
    } on AgentConfigException {
      rethrow;
    } on AgentProfileException catch (error) {
      throw _configFailureForProfile(error);
    } on AgentConfigStoreException {
      throw const AgentConfigException(
        AgentConfigFailure.temporarilyUnavailable,
      );
    }
  }
}

AgentConfigException _configFailureForProfile(AgentProfileException error) {
  return AgentConfigException(
    switch (error.failure) {
      AgentProfileFailure.dataCorrupt => AgentConfigFailure.profileIncomplete,
      AgentProfileFailure.temporarilyUnavailable =>
        AgentConfigFailure.temporarilyUnavailable,
    },
  );
}

bool _isSafeValue(String value, {required int maxRunes}) {
  final length = value.runes.length;
  return length >= 1 && length <= maxRunes && !value.contains('\u0000');
}
