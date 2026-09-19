import 'agent_config.dart';
import '../ai_config/ai_config_ports.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../backup/backup_restore_gate.dart';

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
    AiProviderKind? modelProviderKind,
    String? providerDisplayName,
    Map<AiModelCapability, AiCapabilitySupport> capabilities = const {},
  }) {
    final normalizedId = profileId.trim();
    final normalizedName = displayName.trim();
    final normalizedModel = modelName.trim();
    final normalizedProviderName = providerDisplayName?.trim();
    if (!_isSafeValue(normalizedId, maxRunes: 128) ||
        !_isSafeValue(normalizedName, maxRunes: 200) ||
        !_isSafeValue(normalizedModel, maxRunes: 200) ||
        (normalizedProviderName != null &&
            !_isSafeValue(normalizedProviderName, maxRunes: 200))) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    return AgentProfileSummary._(
      profileId: normalizedId,
      displayName: normalizedName,
      modelName: normalizedModel,
      modelProviderKind: modelProviderKind,
      providerDisplayName: normalizedProviderName,
      capabilities: Map.unmodifiable(capabilities),
    );
  }

  const AgentProfileSummary._({
    required this.profileId,
    required this.displayName,
    required this.modelName,
    required this.modelProviderKind,
    required this.providerDisplayName,
    required this.capabilities,
  });

  final String profileId;

  /// Model-asset display name. [profileId] is the Model Registry modelRef.
  final String displayName;
  final String modelName;

  /// Owning provider display name from the Provider / Model Registry; null
  /// only for legacy projection sources.
  final String? providerDisplayName;
  final AiProviderKind? modelProviderKind;
  final Map<AiModelCapability, AiCapabilitySupport> capabilities;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentProfileSummary &&
          profileId == other.profileId &&
          displayName == other.displayName &&
          modelName == other.modelName &&
          providerDisplayName == other.providerDisplayName &&
          modelProviderKind == other.modelProviderKind;

  @override
  int get hashCode => Object.hash(
        profileId,
        displayName,
        modelName,
        providerDisplayName,
        modelProviderKind,
      );
}

final class AgentProviderProfile {
  factory AgentProviderProfile({
    required String profileId,
    required String apiKey,
    required String baseUrl,
    required String modelName,
    AiProviderKind? modelProviderKind,
    Map<AiModelCapability, AiCapabilitySupport> capabilities = const {},
  }) {
    final normalizedId = profileId.trim();
    final normalizedKey = apiKey.trim();
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = modelName.trim();
    if (!_isSafeValue(normalizedId, maxRunes: 128) ||
        normalizedKey.isEmpty ||
        normalizedKey.contains('\u0000') ||
        !_isSafeValue(normalizedBaseUrl, maxRunes: 2048) ||
        !_isSafeValue(normalizedModel, maxRunes: 200)) {
      throw const AgentProfileException(AgentProfileFailure.dataCorrupt);
    }
    return AgentProviderProfile._(
      profileId: normalizedId,
      apiKey: normalizedKey,
      baseUrl: normalizedBaseUrl,
      modelName: normalizedModel,
      modelProviderKind: modelProviderKind,
      capabilities: Map.unmodifiable(capabilities),
    );
  }

  const AgentProviderProfile._({
    required this.profileId,
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    required this.modelProviderKind,
    required this.capabilities,
  });

  final String profileId;
  final String apiKey;
  final String baseUrl;
  final String modelName;
  final AiProviderKind? modelProviderKind;
  final Map<AiModelCapability, AiCapabilitySupport> capabilities;

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
    this.selectedFallbackProfile,
    this.fallbackUnavailable = false,
    required List<AgentProfileSummary> availableProfiles,
    List<AgentProfileSummary> incompatibleProfiles = const [],
    Map<String, String> incompatibilityReasons = const {},
  })  : availableProfiles = List<AgentProfileSummary>.unmodifiable(
          availableProfiles,
        ),
        incompatibleProfiles = List<AgentProfileSummary>.unmodifiable(
          incompatibleProfiles,
        ),
        incompatibilityReasons = Map<String, String>.unmodifiable(
          incompatibilityReasons,
        );

  final AgentSettingsState state;
  final AgentConfig? config;
  final AgentProfileSummary? selectedProfile;
  final AgentProfileSummary? selectedFallbackProfile;
  final bool fallbackUnavailable;
  final List<AgentProfileSummary> availableProfiles;
  final List<AgentProfileSummary> incompatibleProfiles;
  final Map<String, String> incompatibilityReasons;
}

final class AgentSettingsService {
  const AgentSettingsService({
    required AgentConfigStorePort configStore,
    required AgentProfileCatalogPort profileCatalog,
    AgentTransportCompatibilityPort? transportCompatibility,
    AgentConfigCodec codec = const AgentConfigCodec(),
  })  : _configStore = configStore,
        _profileCatalog = profileCatalog,
        _transportCompatibility = transportCompatibility,
        _codec = codec;

  final AgentConfigStorePort _configStore;
  final AgentProfileCatalogPort _profileCatalog;
  final AgentTransportCompatibilityPort? _transportCompatibility;
  final AgentConfigCodec _codec;

  Future<AgentSettingsSnapshot> load() async {
    try {
      final allProfiles = await _profileCatalog.listMainProfiles();
      final encoded = await _configStore.readAgentConfig();
      if (encoded == null) {
        final (profiles, incompatible, reasons) = _partitionProfiles(
          allProfiles,
          AgentProviderKind.deepSeekResponses,
        );
        return AgentSettingsSnapshot(
          state: AgentSettingsState.unconfigured,
          config: null,
          selectedProfile: null,
          availableProfiles: profiles,
          incompatibleProfiles: incompatible,
          incompatibilityReasons: reasons,
        );
      }
      final config = _codec.decode(encoded);
      final (profiles, incompatible, reasons) =
          _partitionProfiles(allProfiles, config.providerKind);
      final selected = profiles
          .where((profile) => profile.profileId == config.mainProfileId)
          .firstOrNull;
      final fallbackId = config.fallbackProfileId;
      final selectedFallback = fallbackId == null
          ? null
          : profiles
              .where((profile) => profile.profileId == fallbackId)
              .firstOrNull;
      final fallbackUnavailable =
          fallbackId != null && selectedFallback == null;
      return AgentSettingsSnapshot(
        state: selected == null
            ? AgentSettingsState.profileUnavailable
            : AgentSettingsState.ready,
        config: config,
        selectedProfile: selected,
        selectedFallbackProfile: selectedFallback,
        fallbackUnavailable: fallbackUnavailable,
        availableProfiles: profiles,
        incompatibleProfiles: incompatible,
        incompatibilityReasons: reasons,
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

  Future<void> save(AgentConfig config) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _saveUnchecked(config),
    );
  }

  Future<void> _saveUnchecked(AgentConfig config) async {
    try {
      final profiles = await _profileCatalog.listMainProfiles();
      final selected = profiles
          .where((profile) => profile.profileId == config.mainProfileId)
          .firstOrNull;
      if (selected == null) {
        throw const AgentConfigException(AgentConfigFailure.profileNotFound);
      }
      if (!_compatibility(selected, config.providerKind).compatible) {
        throw const AgentConfigException(AgentConfigFailure.profileNotFound);
      }
      if (config.fallbackProfileId case final fallbackId?) {
        final fallback = profiles
            .where((profile) => profile.profileId == fallbackId)
            .firstOrNull;
        if (fallback == null) {
          throw const AgentConfigException(AgentConfigFailure.profileNotFound);
        }
        if (!_compatibility(fallback, config.providerKind).compatible) {
          throw const AgentConfigException(AgentConfigFailure.profileNotFound);
        }
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

  (List<AgentProfileSummary>, List<AgentProfileSummary>, Map<String, String>)
      _partitionProfiles(
    List<AgentProfileSummary> profiles,
    AgentProviderKind providerKind,
  ) {
    if (_transportCompatibility == null) {
      return (profiles, const [], const {});
    }
    final compatible = <AgentProfileSummary>[];
    final incompatible = <AgentProfileSummary>[];
    final reasons = <String, String>{};
    for (final profile in profiles) {
      final result = _compatibility(profile, providerKind);
      (result.compatible ? compatible : incompatible).add(profile);
      if (!result.compatible) {
        final reason = result.reasonCode;
        if (reason != null) reasons[profile.profileId] = reason;
      }
    }
    return (
      List.unmodifiable(compatible),
      List.unmodifiable(incompatible),
      Map.unmodifiable(reasons),
    );
  }

  AgentTransportCompatibilityResult _compatibility(
    AgentProfileSummary profile,
    AgentProviderKind providerKind,
  ) {
    return _transportCompatibility?.evaluate(
          transportProviderKind: providerKind.storageValue,
          modelProviderKind: profile.modelProviderKind,
          canonicalModelId: profile.modelName,
          capabilities: profile.capabilities,
        ) ??
        const AgentTransportCompatibilityResult.compatible();
  }
}

final class ResolvedAgentConfig {
  const ResolvedAgentConfig({
    required this.config,
    required this.profile,
    this.fallbackProfile,
  });

  final AgentConfig config;
  final AgentProviderProfile profile;
  final AgentProviderProfile? fallbackProfile;

  @override
  String toString() => 'ResolvedAgentConfig(REDACTED)';
}

final class AgentRuntimeConfigResolver {
  const AgentRuntimeConfigResolver({
    required AgentConfigStorePort configStore,
    required AgentProviderProfileResolverPort profileResolver,
    AgentTransportCompatibilityPort? transportCompatibility,
    AgentConfigCodec codec = const AgentConfigCodec(),
  })  : _configStore = configStore,
        _profileResolver = profileResolver,
        _transportCompatibility = transportCompatibility,
        _codec = codec;

  final AgentConfigStorePort _configStore;
  final AgentProviderProfileResolverPort _profileResolver;
  final AgentTransportCompatibilityPort? _transportCompatibility;
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
      final compatibility = _transportCompatibility?.evaluate(
        transportProviderKind: config.providerKind.storageValue,
        modelProviderKind: profile.modelProviderKind,
        canonicalModelId: profile.modelName,
        capabilities: profile.capabilities,
      );
      if (compatibility != null && !compatibility.compatible) {
        throw const AgentConfigException(AgentConfigFailure.profileNotFound);
      }
      AgentProviderProfile? fallbackProfile;
      if (config.fallbackProfileId case final fallbackId?) {
        try {
          fallbackProfile =
              await _profileResolver.resolveMainProfile(fallbackId);
          if (fallbackProfile case final resolvedFallback?) {
            final fallbackCompatibility = _transportCompatibility?.evaluate(
              transportProviderKind: config.providerKind.storageValue,
              modelProviderKind: resolvedFallback.modelProviderKind,
              canonicalModelId: resolvedFallback.modelName,
              capabilities: resolvedFallback.capabilities,
            );
            if (fallbackCompatibility != null &&
                !fallbackCompatibility.compatible) {
              fallbackProfile = null;
            }
          }
        } on AgentProfileException {
          // If the optional fallback profile has corrupt data or error,
          // treat as unavailable without failing the primary.
          fallbackProfile = null;
        }
      }
      return ResolvedAgentConfig(
        config: config,
        profile: profile,
        fallbackProfile: fallbackProfile,
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
