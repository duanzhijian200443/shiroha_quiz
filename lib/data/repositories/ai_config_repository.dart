import '../../application/ai_config/ai_config_ports.dart';
import '../../application/backup/backup_restore_gate.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../../domain/ai_config/shiroha_capability_registry.dart';
import '../persistence/engine_credential_store.dart';

sealed class AiCredentialUpdate {
  const AiCredentialUpdate();
}

final class PreserveAiCredential extends AiCredentialUpdate {
  const PreserveAiCredential();
}

final class ReplaceAiCredential extends AiCredentialUpdate {
  ReplaceAiCredential(String secret)
      : secret = validatedEngineCredentialSecret(secret);

  final String secret;

  @override
  String toString() => 'ReplaceAiCredential(REDACTED)';
}

final class AiProviderSnapshot {
  const AiProviderSnapshot({required this.provider, required this.credential});

  final AiProviderRecord provider;
  final AiCredentialState credential;
}

final class AiResolvedModel {
  const AiResolvedModel({
    required this.provider,
    required this.model,
    required this.credential,
    required this.capabilities,
  });

  final AiProviderRecord provider;
  final AiModelRecord model;
  final String credential;
  final Map<AiModelCapability, AiCapabilitySupport> capabilities;

  @override
  String toString() => 'AiResolvedModel(REDACTED)';
}

final class AiConfigRepository implements AiConfigServiceRepositoryPort {
  AiConfigRepository({
    required AiConfigStorePort store,
    required EngineCredentialStore credentialStore,
    AgentModelReferencePort? agentReferences,
  })  : _store = store,
        _credentialStore = credentialStore,
        _agentReferences = agentReferences;

  final AiConfigStorePort _store;
  final EngineCredentialStore _credentialStore;
  final AgentModelReferencePort? _agentReferences;
  final Map<String, Future<void>> _providerMutexes = <String, Future<void>>{};

  @override
  AiConfigStorePort get store => _store;

  @override
  Future<void> updateProviderMetadata(
    AiProviderRecord provider, {
    required int expectedRevision,
  }) {
    return updateProvider(provider, expectedRevision: expectedRevision);
  }

  Future<List<AiProviderSnapshot>> listProviders() async {
    final providers = await _store.listProviders();
    final result = <AiProviderSnapshot>[];
    for (final provider in providers) {
      result.add(
        AiProviderSnapshot(
          provider: provider,
          credential: await _credentialState(provider.providerId),
        ),
      );
    }
    return List<AiProviderSnapshot>.unmodifiable(result);
  }

  Future<void> createProvider(
    AiProviderRecord provider,
    ReplaceAiCredential credential,
  ) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runProviderExclusive(
        provider.providerId,
        () async {
          if (await _store.readProvider(provider.providerId) != null) {
            throw const AiConfigException(
              AiConfigFailure.providerAlreadyExists,
            );
          }
          await _saveWithCredential(
            provider: provider,
            credential: credential,
            expectedRevision: null,
          );
        },
      ),
    );
  }

  Future<void> updateProvider(
    AiProviderRecord provider, {
    required int expectedRevision,
    AiCredentialUpdate credential = const PreserveAiCredential(),
  }) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runProviderExclusive(provider.providerId, () async {
        if (credential is PreserveAiCredential) {
          await _store.updateProvider(provider, expectedRevision);
          return;
        }
        await _saveWithCredential(
          provider: provider,
          credential: credential as ReplaceAiCredential,
          expectedRevision: expectedRevision,
        );
      }),
    );
  }

  Future<void> deleteProvider(String providerId) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runProviderExclusive(providerId, () async {
        validateAiConfigId(providerId);
        final models = await _store.listModels(providerId: providerId);
        final modelRefs = models.map((model) => model.modelRef).toSet();
        final bound = (await _store.listBindings())
            .any((binding) => modelRefs.contains(binding.modelRef));
        final agentRefs =
            await _agentReferences?.referencedModelRefs() ?? const {};
        if (bound || modelRefs.any(agentRefs.contains)) {
          throw const AiConfigException(AiConfigFailure.providerInUse);
        }
        final (oldCredential, oldCorrupt) =
            await _readOldCredential(providerId);
        await _credentialCall(
          () => _credentialStore.deleteCredential(providerId),
        );
        try {
          await _store.deleteProvider(providerId);
        } catch (_) {
          if (oldCorrupt) {
            await _compensateCredentialAbsent(providerId, normalized: true);
          } else if (oldCredential case final secret?) {
            await _restoreOldCredential(providerId, secret);
          }
          await _compensateCredentialAbsent(providerId, normalized: false);
        }
      }),
    );
  }

  Future<void> saveLegacyProjection({
    required AiProviderRecord provider,
    required AiModelRecord model,
    required AiCapabilityBinding binding,
    required ReplaceAiCredential credential,
    required int? expectedProviderRevision,
    required int? expectedBindingRevision,
  }) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runProviderExclusive(
        provider.providerId,
        () => _saveMetadataWithCredential(
          providerId: provider.providerId,
          secret: credential.secret,
          saveMetadata: () => _store.saveLegacyProjection(
            provider: provider,
            model: model,
            binding: binding,
            expectedProviderRevision: expectedProviderRevision,
            expectedBindingRevision: expectedBindingRevision,
          ),
        ),
      ),
    );
  }

  Future<void> deleteLegacyProjection(String providerId) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runProviderExclusive(providerId, () async {
        validateAiConfigId(providerId);
        final models = await _store.listModels(providerId: providerId);
        final modelRefs = models.map((model) => model.modelRef).toSet();
        final bound = (await _store.listBindings())
            .any((binding) => modelRefs.contains(binding.modelRef));
        final agentRefs =
            await _agentReferences?.referencedModelRefs() ?? const {};
        if (bound || modelRefs.any(agentRefs.contains)) {
          throw const AiConfigException(AiConfigFailure.providerInUse);
        }
        final (oldCredential, oldCorrupt) =
            await _readOldCredential(providerId);
        await _credentialCall(
          () => _credentialStore.deleteCredential(providerId),
        );
        try {
          await _store.deleteLegacyProjection(providerId);
        } catch (_) {
          if (oldCorrupt) {
            await _compensateCredentialAbsent(providerId, normalized: true);
          } else if (oldCredential case final secret?) {
            await _restoreOldCredential(providerId, secret);
          }
          await _compensateCredentialAbsent(providerId, normalized: false);
        }
      }),
    );
  }

  Future<AiResolvedModel> resolveModel(String modelRef) async {
    final model = await _store.readModel(modelRef);
    if (model == null) {
      throw const AiConfigException(AiConfigFailure.modelNotFound);
    }
    if (model.availability != AiModelAvailability.available) {
      throw const AiConfigException(AiConfigFailure.modelUnavailable);
    }
    final provider = await _store.readProvider(model.providerId);
    if (provider == null) {
      throw const AiConfigException(AiConfigFailure.dataCorrupt);
    }
    final credential = await _credentialCall(
      () => _credentialStore.readCredential(provider.providerId),
    );
    if (credential == null) {
      throw const AiConfigException(AiConfigFailure.credentialMissing);
    }
    final claims = await _store.listClaims(modelRef);
    return AiResolvedModel(
      provider: provider,
      model: model,
      credential: credential,
      capabilities: resolveModelCapabilities(
        providerKind: provider.kind,
        canonicalModelId: model.canonicalModelId,
        claims: claims,
      ),
    );
  }

  @override
  Future<String> credentialForProvider(String providerId) async {
    final value = await _credentialCall(
      () => _credentialStore.readCredential(providerId),
    );
    if (value == null) {
      throw const AiConfigException(AiConfigFailure.credentialMissing);
    }
    return value;
  }

  Future<void> _saveWithCredential({
    required AiProviderRecord provider,
    required ReplaceAiCredential credential,
    required int? expectedRevision,
  }) async {
    return _saveMetadataWithCredential(
      providerId: provider.providerId,
      secret: credential.secret,
      saveMetadata: () async {
        if (expectedRevision == null) {
          await _store.insertProvider(provider);
        } else {
          await _store.updateProvider(provider, expectedRevision);
        }
      },
    );
  }

  Future<void> _saveMetadataWithCredential({
    required String providerId,
    required String secret,
    required Future<void> Function() saveMetadata,
  }) async {
    final (oldCredential, oldCorrupt) = await _readOldCredential(providerId);
    if (oldCredential != secret) {
      await _credentialCall(
        () => _credentialStore.writeCredential(providerId, secret),
      );
    }
    try {
      await saveMetadata();
    } catch (_) {
      if (oldCorrupt) {
        await _compensateCredentialAbsent(providerId, normalized: true);
      } else if (oldCredential case final oldSecret?) {
        await _restoreOldCredential(providerId, oldSecret);
      }
      await _compensateCredentialAbsent(providerId, normalized: false);
    }
  }

  Future<(String?, bool)> _readOldCredential(String providerId) async {
    try {
      return (
        await _credentialCall(
          () => _credentialStore.readCredential(providerId),
        ),
        false,
      );
    } on EngineCredentialException catch (error) {
      if (error.failure == EngineCredentialFailure.dataCorrupt) {
        return (null, true);
      }
      rethrow;
    }
  }

  Future<Never> _restoreOldCredential(
    String providerId,
    String oldSecret,
  ) async {
    try {
      await _credentialCall(
        () => _credentialStore.writeCredential(providerId, oldSecret),
      );
    } on EngineCredentialException catch (error) {
      throw EngineCredentialPartialException(error.failure);
    }
    throw const EngineCredentialCompensatedException();
  }

  Future<Never> _compensateCredentialAbsent(
    String providerId, {
    required bool normalized,
  }) async {
    try {
      await _credentialCall(
        () => _credentialStore.deleteCredential(providerId),
      );
    } on EngineCredentialException catch (error) {
      throw EngineCredentialPartialException(error.failure);
    }
    if (normalized) {
      throw const EngineCredentialNormalizedException();
    }
    throw const EngineCredentialCompensatedException();
  }

  Future<T> _credentialCall<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on EngineCredentialException {
      rethrow;
    } catch (_) {
      throw const EngineCredentialException(
        EngineCredentialFailure.temporarilyUnavailable,
      );
    }
  }

  Future<T> _runProviderExclusive<T>(
    String providerId,
    Future<T> Function() action,
  ) {
    final previous = _providerMutexes[providerId] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>((_) {}, onError: (_) {});
    _providerMutexes[providerId] = tail;
    tail.whenComplete(() {
      if (identical(_providerMutexes[providerId], tail)) {
        _providerMutexes.remove(providerId);
      }
    });
    return result;
  }

  Future<AiCredentialState> _credentialState(String providerId) async {
    try {
      return await _credentialCall(
                () => _credentialStore.readCredential(providerId),
              ) ==
              null
          ? AiCredentialState.missing
          : AiCredentialState.present;
    } on EngineCredentialException {
      return AiCredentialState.unavailable;
    }
  }
}
