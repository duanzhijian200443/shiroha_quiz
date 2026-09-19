import '../../domain/ai_config/ai_config_contracts.dart';
import '../../domain/ai_config/shiroha_capability_registry.dart';
import 'ai_config_ports.dart';

final class AiModelCompatibility {
  const AiModelCompatibility({
    required this.model,
    required this.provider,
    required this.capabilities,
    required this.compatible,
    required this.reasonCodes,
  });

  final AiModelRecord model;
  final AiProviderRecord provider;
  final Map<AiModelCapability, AiCapabilitySupport> capabilities;
  final bool compatible;
  final List<String> reasonCodes;
}

final class AiCapabilityBindingSummary {
  const AiCapabilityBindingSummary({
    required this.binding,
    required this.model,
    required this.provider,
  });

  final AiCapabilityBinding binding;
  final AiModelRecord model;
  final AiProviderRecord provider;
}

final class AiProviderOverview {
  const AiProviderOverview({
    required this.provider,
    required this.credentialState,
    required this.modelCount,
    required this.hasModelAuthority,
  });

  final AiProviderRecord provider;
  final AiCredentialState credentialState;
  final int modelCount;
  final bool hasModelAuthority;
}

abstract interface class AiConfigPresentationService {
  Future<AiCapabilityBindingSummary?> bindingSummary(AiCapabilitySlot slot);
  Future<List<AiModelCompatibility>> listModelsForSlot(AiCapabilitySlot slot);
  Future<List<AiProviderOverview>> listProviders();
  Future<String> createProvider({
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    required String credential,
  });
  Future<void> updateProvider({
    required String providerId,
    required int expectedRevision,
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    String? replacementCredential,
  });
  Future<void> deleteProvider(String providerId);
  Future<void> testConnection(String providerId);
  Future<void> testConnectionDraft({
    String? providerId,
    required AiProviderKind kind,
    required String baseUrl,
    String? credential,
  });
  Future<void> syncModels(String providerId);
  Future<void> applyBinding({
    required AiCapabilitySlot slot,
    required String modelRef,
    required int? expectedRevision,
    double temperature = 0.7,
    String reasoningEffort = '',
  });
}

final class UnavailableAiConfigPresentationService
    implements AiConfigPresentationService {
  const UnavailableAiConfigPresentationService();

  Future<Never> _unavailable() => Future<Never>.error(
        const AiConfigException(AiConfigFailure.temporarilyUnavailable),
      );

  @override
  Future<AiCapabilityBindingSummary?> bindingSummary(AiCapabilitySlot slot) =>
      _unavailable();
  @override
  Future<List<AiModelCompatibility>> listModelsForSlot(
    AiCapabilitySlot slot,
  ) =>
      _unavailable();
  @override
  Future<List<AiProviderOverview>> listProviders() => _unavailable();
  @override
  Future<String> createProvider({
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    required String credential,
  }) =>
      _unavailable();
  @override
  Future<void> updateProvider({
    required String providerId,
    required int expectedRevision,
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    String? replacementCredential,
  }) =>
      _unavailable();
  @override
  Future<void> deleteProvider(String providerId) => _unavailable();
  @override
  Future<void> testConnection(String providerId) => _unavailable();
  @override
  Future<void> testConnectionDraft({
    String? providerId,
    required AiProviderKind kind,
    required String baseUrl,
    String? credential,
  }) =>
      _unavailable();
  @override
  Future<void> syncModels(String providerId) => _unavailable();
  @override
  Future<void> applyBinding({
    required AiCapabilitySlot slot,
    required String modelRef,
    required int? expectedRevision,
    double temperature = 0.7,
    String reasoningEffort = '',
  }) =>
      _unavailable();
}

final class AiConfigService implements AiConfigPresentationService {
  const AiConfigService({
    required AiConfigServiceRepositoryPort repository,
    required AiProviderConnectionPort providerConnection,
    required String Function() modelRefFactory,
    required int Function() clock,
  })  : _repository = repository,
        _providerConnection = providerConnection,
        _modelRefFactory = modelRefFactory,
        _clock = clock;

  final AiConfigServiceRepositoryPort _repository;
  final AiProviderConnectionPort _providerConnection;
  final String Function() _modelRefFactory;
  final int Function() _clock;

  @override
  Future<AiCapabilityBindingSummary?> bindingSummary(
    AiCapabilitySlot slot,
  ) async {
    final binding = await _repository.store.readBinding(slot);
    if (binding == null) return null;
    final model = await _repository.store.readModel(binding.modelRef);
    if (model == null) {
      throw const AiConfigException(AiConfigFailure.dataCorrupt);
    }
    final provider = await _repository.store.readProvider(model.providerId);
    if (provider == null) {
      throw const AiConfigException(AiConfigFailure.dataCorrupt);
    }
    return AiCapabilityBindingSummary(
      binding: binding,
      model: model,
      provider: provider,
    );
  }

  @override
  Future<List<AiProviderOverview>> listProviders() async {
    final result = <AiProviderOverview>[];
    for (final snapshot in await _repository.listProviderAccess()) {
      final models = await _repository.store.listModels(
        providerId: snapshot.provider.providerId,
      );
      result.add(
        AiProviderOverview(
          provider: snapshot.provider,
          credentialState: snapshot.credentialState,
          modelCount: models
              .where(
                (model) => model.availability == AiModelAvailability.available,
              )
              .length,
          hasModelAuthority: models.isNotEmpty,
        ),
      );
    }
    result.sort(
      (left, right) => left.provider.displayName.compareTo(
        right.provider.displayName,
      ),
    );
    return List<AiProviderOverview>.unmodifiable(result);
  }

  @override
  Future<String> createProvider({
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    required String credential,
  }) async {
    if (displayName.trim().isEmpty || baseUrl.trim().isEmpty) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    final now = _clock();
    final providerId = validateAiConfigId(_modelRefFactory());
    await _repository.createProviderWithCredential(
      AiProviderRecord(
        providerId: providerId,
        kind: kind,
        displayName: displayName.trim(),
        baseUrl: baseUrl.trim(),
        state: AiProviderState.ready,
        revision: 0,
        createdAt: now,
        updatedAt: now,
      ),
      credential,
    );
    return providerId;
  }

  @override
  Future<void> updateProvider({
    required String providerId,
    required int expectedRevision,
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    String? replacementCredential,
  }) async {
    final normalizedBaseUrl = baseUrl.trim();
    if (displayName.trim().isEmpty || normalizedBaseUrl.isEmpty) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    final current = await _repository.store.readProvider(providerId);
    if (current == null) {
      throw const AiConfigException(AiConfigFailure.providerNotFound);
    }
    if (kind != current.kind) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    if (normalizedBaseUrl != current.baseUrl &&
        (await _repository.store.listModels(providerId: providerId))
            .isNotEmpty) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    await _repository.updateProviderWithCredential(
      AiProviderRecord(
        providerId: current.providerId,
        kind: current.kind,
        displayName: displayName.trim(),
        baseUrl: normalizedBaseUrl,
        state: AiProviderState.ready,
        revision: current.revision + 1,
        createdAt: current.createdAt,
        updatedAt: _clock(),
        lastConnectionStatus: current.lastConnectionStatus,
        lastConnectionAt: current.lastConnectionAt,
        lastSyncStatus: current.lastSyncStatus,
        lastSyncAt: current.lastSyncAt,
      ),
      expectedRevision: expectedRevision,
      replacementCredential: replacementCredential,
    );
  }

  @override
  Future<void> deleteProvider(String providerId) {
    return _repository.deleteProviderAuthority(providerId);
  }

  @override
  Future<List<AiModelCompatibility>> listModelsForSlot(
    AiCapabilitySlot slot,
  ) async {
    final providers = {
      for (final provider in await _repository.store.listProviders())
        provider.providerId: provider,
    };
    final result = <AiModelCompatibility>[];
    for (final model in await _repository.store.listModels()) {
      final provider = providers[model.providerId];
      if (provider == null) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      final capabilities = await _resolvedCapabilities(model, provider);
      final reasons = <String>[];
      if (model.availability != AiModelAvailability.available) {
        reasons.add('modelUnavailable');
      }
      for (final required in slot.requiredCapabilities) {
        switch (capabilities[required] ?? AiCapabilitySupport.unknown) {
          case AiCapabilitySupport.supported:
            break;
          case AiCapabilitySupport.unsupported:
            reasons.add('unsupported:${required.storageValue}');
          case AiCapabilitySupport.unknown:
            reasons.add('unknown:${required.storageValue}');
        }
      }
      result.add(
        AiModelCompatibility(
          model: model,
          provider: provider,
          capabilities: capabilities,
          compatible: reasons.isEmpty,
          reasonCodes: List.unmodifiable(reasons),
        ),
      );
    }
    result.sort((left, right) {
      if (left.compatible != right.compatible) return left.compatible ? -1 : 1;
      final byProvider =
          left.provider.displayName.compareTo(right.provider.displayName);
      return byProvider != 0
          ? byProvider
          : left.model.displayName.compareTo(right.model.displayName);
    });
    return List.unmodifiable(result);
  }

  @override
  Future<void> applyBinding({
    required AiCapabilitySlot slot,
    required String modelRef,
    required int? expectedRevision,
    double temperature = 0.7,
    String reasoningEffort = '',
  }) async {
    final model = await _repository.store.readModel(modelRef);
    if (model == null) {
      throw const AiConfigException(AiConfigFailure.modelNotFound);
    }
    if (model.availability != AiModelAvailability.available) {
      throw const AiConfigException(AiConfigFailure.modelUnavailable);
    }
    final provider = await _repository.store.readProvider(model.providerId);
    if (provider == null) {
      throw const AiConfigException(AiConfigFailure.dataCorrupt);
    }
    final capabilities = await _resolvedCapabilities(model, provider);
    for (final required in slot.requiredCapabilities) {
      switch (capabilities[required] ?? AiCapabilitySupport.unknown) {
        case AiCapabilitySupport.supported:
          break;
        case AiCapabilitySupport.unsupported:
          throw const AiConfigException(AiConfigFailure.capabilityUnsupported);
        case AiCapabilitySupport.unknown:
          throw const AiConfigException(AiConfigFailure.capabilityUnknown);
      }
    }
    final current = await _repository.store.readBinding(slot);
    if ((current?.revision) != expectedRevision) {
      throw const AiConfigException(AiConfigFailure.staleRevision);
    }
    await _repository.store.saveBinding(
      AiCapabilityBinding(
        slot: slot,
        modelRef: modelRef,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
        validationMode: AiBindingValidationMode.verified,
        revision: (expectedRevision ?? -1) + 1,
        updatedAt: _clock(),
      ),
      expectedRevision: expectedRevision,
    );
  }

  @override
  Future<void> testConnection(String providerId) async {
    final provider = await _repository.store.readProvider(providerId);
    if (provider == null) {
      throw const AiConfigException(AiConfigFailure.providerNotFound);
    }
    final credential = await _repository.credentialForProvider(providerId);
    try {
      await _providerConnection.testConnection(
        providerKind: provider.kind,
        baseUrl: provider.baseUrl,
        credential: credential,
      );
    } on AiConfigException {
      await _markConnection(provider, AiOperationStatus.failed);
      rethrow;
    } catch (_) {
      await _markConnection(provider, AiOperationStatus.failed);
      throw const AiConfigException(AiConfigFailure.temporarilyUnavailable);
    }
    await _markConnection(provider, AiOperationStatus.succeeded);
  }

  @override
  Future<void> testConnectionDraft({
    String? providerId,
    required AiProviderKind kind,
    required String baseUrl,
    String? credential,
  }) async {
    final endpoint = baseUrl.trim();
    if (endpoint.isEmpty) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    final supplied = credential;
    final secret = supplied != null && supplied.isNotEmpty
        ? supplied
        : providerId == null
            ? (throw const AiConfigException(AiConfigFailure.credentialMissing))
            : await _repository.credentialForProvider(providerId);
    await _providerConnection.testConnection(
      providerKind: kind,
      baseUrl: endpoint,
      credential: secret,
    );
  }

  @override
  Future<void> syncModels(String providerId) async {
    final provider = await _repository.store.readProvider(providerId);
    if (provider == null) {
      throw const AiConfigException(AiConfigFailure.providerNotFound);
    }
    final credential = await _repository.credentialForProvider(providerId);
    try {
      final snapshot = await _providerConnection.discoverModels(
        providerKind: provider.kind,
        baseUrl: provider.baseUrl,
        credential: credential,
      );
      await _replaceModelSnapshot(provider, snapshot);
    } catch (_) {
      await _markSyncFailed(provider);
      throw const AiConfigException(AiConfigFailure.syncFailed);
    }
  }

  Future<void> _replaceModelSnapshot(
    AiProviderRecord provider,
    AiDiscoveredModelSnapshot snapshot,
  ) async {
    final seenIds = <String>{};
    final existing = {
      for (final model in await _repository.store
          .listModels(providerId: provider.providerId))
        model.canonicalModelId: model,
    };
    final now = _clock();
    final models = <AiModelRecord>[];
    final claims = <AiCapabilityClaim>[];
    for (final discovered in snapshot.models) {
      if (!seenIds.add(discovered.canonicalModelId)) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      final prior = existing[discovered.canonicalModelId];
      final modelRef =
          prior?.modelRef ?? validateAiConfigId(_modelRefFactory());
      models.add(
        AiModelRecord(
          modelRef: modelRef,
          providerId: provider.providerId,
          canonicalModelId: discovered.canonicalModelId,
          displayName: discovered.displayName,
          availability: AiModelAvailability.available,
          firstSeenAt: prior?.firstSeenAt ?? now,
          lastSeenAt: now,
        ),
      );
      for (final entry in discovered.officialCapabilities.entries) {
        if (entry.value == AiCapabilitySupport.unknown) continue;
        claims.add(
          AiCapabilityClaim(
            modelRef: modelRef,
            capability: entry.key,
            source: AiCapabilityClaimSource.providerOfficial,
            support: entry.value,
            assertedAt: now,
          ),
        );
      }
    }
    await _repository.store.replaceModelSnapshot(
      providerId: provider.providerId,
      expectedProviderRevision: provider.revision,
      models: models,
      officialClaims: claims,
      syncedAt: now,
    );
  }

  Future<Map<AiModelCapability, AiCapabilitySupport>> _resolvedCapabilities(
    AiModelRecord model,
    AiProviderRecord provider,
  ) async {
    return resolveModelCapabilities(
      providerKind: provider.kind,
      canonicalModelId: model.canonicalModelId,
      claims: await _repository.store.listClaims(model.modelRef),
    );
  }

  Future<void> _markSyncFailed(AiProviderRecord provider) async {
    final now = _clock();
    try {
      await _repository.updateProviderMetadata(
        AiProviderRecord(
          providerId: provider.providerId,
          kind: provider.kind,
          displayName: provider.displayName,
          baseUrl: provider.baseUrl,
          state: provider.state,
          revision: provider.revision + 1,
          createdAt: provider.createdAt,
          updatedAt: now,
          lastConnectionStatus: provider.lastConnectionStatus,
          lastConnectionAt: provider.lastConnectionAt,
          lastSyncStatus: AiOperationStatus.failed,
          lastSyncAt: now,
        ),
        expectedRevision: provider.revision,
      );
    } on AiConfigException {
      // The discovery failure remains the public failure. A concurrent edit
      // may legitimately win the status update without changing model rows.
    }
  }

  Future<void> _markConnection(
    AiProviderRecord provider,
    AiOperationStatus status,
  ) async {
    final now = _clock();
    try {
      await _repository.updateProviderMetadata(
        AiProviderRecord(
          providerId: provider.providerId,
          kind: provider.kind,
          displayName: provider.displayName,
          baseUrl: provider.baseUrl,
          state: provider.state,
          revision: provider.revision + 1,
          createdAt: provider.createdAt,
          updatedAt: now,
          lastConnectionStatus: status,
          lastConnectionAt: now,
          lastSyncStatus: provider.lastSyncStatus,
          lastSyncAt: provider.lastSyncAt,
        ),
        expectedRevision: provider.revision,
      );
    } on AiConfigException catch (error) {
      if (status == AiOperationStatus.succeeded) rethrow;
      if (error.failure != AiConfigFailure.staleRevision) rethrow;
    }
  }
}
