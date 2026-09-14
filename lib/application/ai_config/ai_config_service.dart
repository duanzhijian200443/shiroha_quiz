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

final class AiConfigService {
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
