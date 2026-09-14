import '../../application/backup/backup_restore_gate.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../../domain/ai_config/shiroha_capability_registry.dart';
import '../models/ai_engine_profile.dart';
import '../persistence/ai_engine_store.dart';
import '../persistence/engine_credential_store.dart';
import 'ai_config_repository.dart';

class AiEngineDependencyException implements Exception {
  const AiEngineDependencyException();

  @override
  String toString() => 'AiEngineDependencyException';
}

/// AI engine repository.
///
/// SQLite is metadata-only. Credentials always come from [credentialStore];
/// legacy SQLite plaintext is ignored even while it remains migration input.
class AiEngineRepository {
  const AiEngineRepository({
    required AiEngineStore store,
    required EngineCredentialStore credentialStore,
    AiConfigRepository? configRepository,
  })  : _store = store,
        _credentialStore = credentialStore,
        _configRepository = configRepository;

  final AiEngineStore _store;
  final EngineCredentialStore _credentialStore;
  final AiConfigRepository? _configRepository;

  /// Per-engineId serialization for activated-path credential/metadata
  /// mutations. Different engineIds never share a lock; completed chains are
  /// removed so the map does not leak entries.
  static final Map<String, Future<void>> _credentialMutexes =
      <String, Future<void>>{};

  Future<List<AiEngineProfile>> getEngines(AiEngineType type) async {
    if (_configRepository case final config?) {
      return _getProjectedEngines(config, type);
    }
    final profiles = await _store.listAiEngines(type);
    final selected = (type == AiEngineType.ocr
            ? profiles
                .where((profile) => profile.engineType == AiEngineType.ocr)
            : profiles
                .where((profile) => profile.engineType != AiEngineType.ocr))
        .toList(growable: false);
    final hydrated = <AiEngineProfile>[];
    for (final profile in selected) {
      hydrated.add(await _hydrate(profile));
    }
    return List<AiEngineProfile>.unmodifiable(hydrated);
  }

  Future<AiEngineProfile?> getActiveEngine(AiEngineType type) async {
    if (_configRepository case final config?) {
      return _getProjectedActiveEngine(config, type);
    }
    final profile = await _store.getActiveAiEngine(type);
    if (profile == null) return null;
    final matches = type == AiEngineType.ocr
        ? profile.engineType == AiEngineType.ocr
        : profile.engineType != AiEngineType.ocr;
    if (!matches) return null;
    return _hydrate(profile);
  }

  Future<AiEngineProfile?> getActiveTextEngine() {
    return getActiveEngine(AiEngineType.text);
  }

  Future<AiEngineProfile?> getActiveVisionEngine() {
    return getActiveEngine(AiEngineType.vision);
  }

  Future<AiEngineProfile?> getActiveOcrEngine() async {
    final profile = await getActiveEngine(AiEngineType.ocr);
    if (profile == null || profile.engineType != AiEngineType.ocr) {
      return null;
    }
    return profile;
  }

  Future<void> saveEngine(
    AiEngineProfile profile, {
    AiProviderKind? providerKind,
    String? providerDisplayName,
  }) {
    if (_configRepository case final config?) {
      return _saveProjectedEngine(
        config,
        profile,
        providerKind: providerKind,
        providerDisplayName: providerDisplayName,
      );
    }
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runEngineExclusive(
        profile.id,
        () => _saveEngineActivated(_credentialStore, profile),
      ),
    );
  }

  Future<void> setActiveEngine(String id, AiEngineType type) {
    if (_configRepository case final config?) {
      return _setProjectedActiveEngine(config, id, type);
    }
    return BackupRestoreMutationGate.instance.runMutation(
      () => _store.setActiveAiEngine(id, type),
    );
  }

  Future<void> deleteEngine(String id) {
    if (_configRepository case final config?) {
      return _deleteProjectedEngine(config, id);
    }
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runEngineExclusive(
        id,
        () => _deleteEngineActivated(_credentialStore, id),
      ),
    );
  }

  Future<void> renameEngine(String id, String newName, AiEngineType type) {
    if (_configRepository case final config?) {
      return _renameProjectedEngine(config, id, newName);
    }
    return BackupRestoreMutationGate.instance.runMutation(
      () => _runEngineExclusive(id, () async {
        final engines = await getEngines(type);
        final target = engines.where((e) => e.id == id).firstOrNull;
        if (target == null) return;
        final renamed = AiEngineProfile(
          id: target.id,
          engineType: target.engineType,
          name: newName,
          apiKey: target.apiKey,
          baseUrl: target.baseUrl,
          modelName: target.modelName,
          temperature: target.temperature,
          reasoningEffort: target.reasoningEffort,
          isActive: target.isActive,
        );
        // Metadata-only mutation: never create/delete/rewrite a credential.
        // A missing credential stays missing; a present one is preserved in the
        // secure store while the metadata write scrubs api_key.
        await _store.saveAiEngine(_withApiKey(renamed, ''));
      }),
    );
  }

  Future<List<AiEngineProfile>> _getProjectedEngines(
    AiConfigRepository config,
    AiEngineType type,
  ) async {
    final legacyRows = await _store.listAiEngines(type);
    final legacyTypes = {
      for (final row in legacyRows) row.id: row.engineType,
    };
    final bindings = await config.store.listBindings();
    final boundByModel = <String, List<AiCapabilityBinding>>{};
    for (final binding in bindings) {
      boundByModel.putIfAbsent(binding.modelRef, () => []).add(binding);
    }
    final result = <AiEngineProfile>[];
    for (final model in await config.store.listModels()) {
      final provider = await config.store.readProvider(model.providerId);
      if (provider == null) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      final claims = resolveModelCapabilities(
        providerKind: provider.kind,
        canonicalModelId: model.canonicalModelId,
        claims: await config.store.listClaims(model.modelRef),
      );
      final legacyType = legacyTypes[model.modelRef];
      final boundAsOcr = boundByModel[model.modelRef]?.any(
            (binding) => binding.slot == AiCapabilitySlot.documentRecognition,
          ) ??
          false;
      final ocr = legacyType == AiEngineType.ocr ||
          boundAsOcr ||
          claims[AiModelCapability.ocr] == AiCapabilitySupport.supported;
      if ((type == AiEngineType.ocr) != ocr) continue;
      String credential;
      try {
        credential = await config.credentialForProvider(provider.providerId);
      } on AiConfigException catch (error) {
        if (error.failure != AiConfigFailure.credentialMissing) rethrow;
        credential = '';
      }
      final matchingBinding = boundByModel[model.modelRef]
          ?.where((binding) => binding.slot == _slotFor(type))
          .firstOrNull;
      result.add(
        AiEngineProfile(
          id: model.modelRef,
          engineType: type,
          name: model.displayName,
          apiKey: credential,
          baseUrl: provider.baseUrl,
          modelName: model.canonicalModelId,
          temperature: matchingBinding?.temperature ??
              (type == AiEngineType.ocr ? 0.0 : 0.7),
          reasoningEffort: matchingBinding?.reasoningEffort ?? '',
          isActive: matchingBinding != null,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Future<AiEngineProfile?> _getProjectedActiveEngine(
    AiConfigRepository config,
    AiEngineType type,
  ) async {
    final binding = await config.store.readBinding(_slotFor(type));
    if (binding == null) return null;
    final resolved = await config.resolveModel(binding.modelRef);
    for (final capability in _slotFor(type).requiredCapabilities) {
      final support =
          resolved.capabilities[capability] ?? AiCapabilitySupport.unknown;
      if (support == AiCapabilitySupport.unsupported ||
          (support == AiCapabilitySupport.unknown &&
              binding.validationMode == AiBindingValidationMode.verified)) {
        throw AiConfigException(
          support == AiCapabilitySupport.unknown
              ? AiConfigFailure.capabilityUnknown
              : AiConfigFailure.capabilityUnsupported,
        );
      }
    }
    return AiEngineProfile(
      id: resolved.model.modelRef,
      engineType: type,
      name: resolved.model.displayName,
      apiKey: resolved.credential,
      baseUrl: resolved.provider.baseUrl,
      modelName: resolved.model.canonicalModelId,
      temperature: binding.temperature,
      reasoningEffort: binding.reasoningEffort,
      isActive: true,
    );
  }

  Future<void> _saveProjectedEngine(
    AiConfigRepository config,
    AiEngineProfile profile, {
    required AiProviderKind? providerKind,
    required String? providerDisplayName,
  }) async {
    final existingModel = await config.store.readModel(profile.id);
    final existing = existingModel == null
        ? await config.store.readProvider(profile.id)
        : await config.store.readProvider(existingModel.providerId);
    if (existingModel != null && existing == null) {
      throw const AiConfigException(AiConfigFailure.dataCorrupt);
    }
    if (existing == null &&
        (providerKind == null ||
            providerDisplayName == null ||
            providerDisplayName.trim().isEmpty)) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    final providerId =
        existingModel?.providerId ?? existing?.providerId ?? profile.id;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final provider = AiProviderRecord(
      providerId: providerId,
      kind: existing?.kind ?? providerKind!,
      displayName: existing?.displayName ?? providerDisplayName!.trim(),
      baseUrl: profile.baseUrl,
      state: profile.baseUrl.isNotEmpty && profile.modelName.isNotEmpty
          ? AiProviderState.ready
          : AiProviderState.legacyIncomplete,
      revision: (existing?.revision ?? -1) + 1,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      lastConnectionStatus:
          existing?.lastConnectionStatus ?? AiOperationStatus.never,
      lastConnectionAt: existing?.lastConnectionAt,
      lastSyncStatus: existing?.lastSyncStatus ?? AiOperationStatus.never,
      lastSyncAt: existing?.lastSyncAt,
    );
    final model = AiModelRecord(
      modelRef: profile.id,
      providerId: providerId,
      canonicalModelId: profile.modelName,
      displayName: profile.name,
      availability:
          existingModel?.availability ?? AiModelAvailability.available,
      firstSeenAt: existingModel?.firstSeenAt ?? now,
      lastSeenAt: now,
    );
    final currentBinding = await config.store.readBinding(
      _slotFor(profile.engineType),
    );
    final binding = AiCapabilityBinding(
      slot: _slotFor(profile.engineType),
      modelRef: profile.id,
      temperature: profile.temperature,
      reasoningEffort: profile.reasoningEffort,
      validationMode: AiBindingValidationMode.legacyPreserved,
      revision: (currentBinding?.revision ?? -1) + 1,
      updatedAt: now,
    );
    await config.saveLegacyProjection(
      provider: provider,
      model: model,
      binding: binding,
      credential: ReplaceAiCredential(profile.apiKey),
      expectedProviderRevision: existing?.revision,
      expectedBindingRevision: currentBinding?.revision,
    );
  }

  Future<void> _setProjectedActiveEngine(
    AiConfigRepository config,
    String id,
    AiEngineType type,
  ) async {
    final slot = _slotFor(type);
    final current = await config.store.readBinding(slot);
    final profiles = await _getProjectedEngines(config, type);
    final selected = profiles.where((profile) => profile.id == id).firstOrNull;
    await config.saveLegacyBinding(
      binding: AiCapabilityBinding(
        slot: slot,
        modelRef: id,
        temperature:
            selected?.temperature ?? (type == AiEngineType.ocr ? 0.0 : 0.7),
        reasoningEffort: selected?.reasoningEffort ?? '',
        validationMode: AiBindingValidationMode.legacyPreserved,
        revision: (current?.revision ?? -1) + 1,
        updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      ),
      expectedRevision: current?.revision,
    );
  }

  Future<void> _renameProjectedEngine(
    AiConfigRepository config,
    String id,
    String newName,
  ) async {
    await config.renameLegacyModel(id, newName);
  }

  Future<void> _deleteProjectedEngine(
    AiConfigRepository config,
    String modelRef,
  ) async {
    final model = await config.store.readModel(modelRef);
    if (model == null) {
      throw const AiConfigException(AiConfigFailure.modelNotFound);
    }
    final provider = await config.store.readProvider(model.providerId);
    if (provider == null) {
      throw const AiConfigException(AiConfigFailure.dataCorrupt);
    }
    final providerModels =
        await config.store.listModels(providerId: provider.providerId);
    if (providerModels.length != 1 ||
        providerModels.single.modelRef != modelRef) {
      throw const AiConfigException(AiConfigFailure.providerInUse);
    }
    await config.deleteLegacyProjection(provider.providerId);
  }

  static AiCapabilitySlot _slotFor(AiEngineType type) => switch (type) {
        AiEngineType.text => AiCapabilitySlot.textModel,
        AiEngineType.vision => AiCapabilitySlot.imageUnderstanding,
        AiEngineType.ocr => AiCapabilitySlot.documentRecognition,
      };

  /// Runs [action] exclusively for [engineId]: concurrent mutations of the
  /// same engine are serialized while different engineIds proceed
  /// independently.
  Future<T> _runEngineExclusive<T>(
    String engineId,
    Future<T> Function() action,
  ) {
    final previous = _credentialMutexes[engineId] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>((_) {}, onError: (_) {});
    _credentialMutexes[engineId] = tail;
    tail.whenComplete(() {
      if (identical(_credentialMutexes[engineId], tail)) {
        _credentialMutexes.remove(engineId);
      }
    });
    return result;
  }

  // --- activated-path internals (S0 target semantics) ---

  /// Hydrates [profile] with the credential from the secure store. A missing
  /// credential yields `apiKey == ''` (incomplete); unavailable/corrupt
  /// credential failures propagate as typed [EngineCredentialException] and
  /// are never folded into missing. The store-provided `apiKey` is always
  /// ignored on the activated path.
  Future<AiEngineProfile> _hydrate(AiEngineProfile profile) async {
    final secret = await _credentialCall(
      () => _credentialStore.readCredential(profile.id),
    );
    return _withApiKey(profile, secret ?? '');
  }

  /// Canonical S0 §5 save state machine.
  Future<void> _saveEngineActivated(
    EngineCredentialStore credentialStore,
    AiEngineProfile profile,
  ) async {
    validatedEngineCredentialId(profile.id);
    validatedEngineCredentialSecret(profile.apiKey);

    // S1: capture the old credential state before mutating anything.
    final (oldSecret, oldCorrupt) =
        await _readOldCredential(credentialStore, profile.id);

    // S2: write the new secret (idempotent skip when unchanged).
    if (oldSecret != profile.apiKey) {
      await _credentialCall(
        () => credentialStore.writeCredential(profile.id, profile.apiKey),
      );
    }

    // S3: metadata save with a scrubbed api_key; never persist the secret.
    try {
      await _store.saveAiEngine(_withApiKey(profile, ''));
    } catch (_) {
      if (oldCorrupt) {
        await _compensateCredentialAbsent(
          credentialStore,
          profile.id,
          normalized: true,
        );
      } else if (oldSecret != null) {
        await _restoreOldCredential(
          credentialStore,
          profile.id,
          oldSecret,
        );
      } else {
        await _compensateCredentialAbsent(
          credentialStore,
          profile.id,
          normalized: false,
        );
      }
    }
  }

  /// Canonical S0 §6 delete state machine (security-favoring).
  Future<void> _deleteEngineActivated(
    EngineCredentialStore credentialStore,
    String engineId,
  ) async {
    validatedEngineCredentialId(engineId);

    // D0: capture the old credential state.
    final (oldSecret, oldCorrupt) =
        await _readOldCredential(credentialStore, engineId);

    // D1: delete the credential first; failure is typed, leaves metadata
    // untouched, and is never reported as success.
    await _credentialCall(
      () => credentialStore.deleteCredential(engineId),
    );

    // D2: delete metadata; success means metadata absent AND credential
    // absent. On failure, compensate from the old state.
    try {
      await _store.deleteAiEngine(engineId);
    } catch (_) {
      if (oldCorrupt) {
        await _compensateCredentialAbsent(
          credentialStore,
          engineId,
          normalized: true,
        );
      } else if (oldSecret != null) {
        await _restoreOldCredential(credentialStore, engineId, oldSecret);
      } else {
        await _compensateCredentialAbsent(
          credentialStore,
          engineId,
          normalized: false,
        );
      }
    }
  }

  /// Reads the old credential state: `(secretOrNull, isCorrupt)`.
  ///
  /// `temporarilyUnavailable` propagates as a typed failure with zero
  /// mutation; `dataCorrupt` is reported as a corrupt old state.
  Future<(String?, bool)> _readOldCredential(
    EngineCredentialStore store,
    String engineId,
  ) async {
    try {
      return (
        await _credentialCall(
          () => store.readCredential(engineId),
        ),
        false
      );
    } on EngineCredentialException catch (error) {
      if (error.failure == EngineCredentialFailure.dataCorrupt) {
        return (null, true);
      }
      rethrow;
    }
  }

  /// Best-effort restore of a valid old credential after a failed metadata
  /// write; success reports FAILED(compensated), failure PARTIAL_FAILED.
  Future<Never> _restoreOldCredential(
    EngineCredentialStore store,
    String engineId,
    String oldSecret,
  ) async {
    try {
      await _credentialCall(
        () => store.writeCredential(engineId, oldSecret),
      );
    } on EngineCredentialException catch (error) {
      throw EngineCredentialPartialException(error.failure);
    }
    throw const EngineCredentialCompensatedException();
  }

  /// Best-effort removal of a credential after a failed metadata write;
  /// success reports FAILED(normalized) for a corrupt old state and
  /// FAILED(compensated) otherwise, failure PARTIAL_FAILED.
  Future<Never> _compensateCredentialAbsent(
    EngineCredentialStore store,
    String engineId, {
    required bool normalized,
  }) async {
    try {
      await _credentialCall(() => store.deleteCredential(engineId));
    } on EngineCredentialException catch (error) {
      throw EngineCredentialPartialException(error.failure);
    }
    if (normalized) {
      throw const EngineCredentialNormalizedException();
    }
    throw const EngineCredentialCompensatedException();
  }

  /// Runs a credential-store call, translating any non-typed failure into a
  /// fixed typed [EngineCredentialException.temporarilyUnavailable] so the
  /// application never receives a raw cause.
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

  AiEngineProfile _withApiKey(AiEngineProfile profile, String apiKey) {
    return AiEngineProfile(
      id: profile.id,
      engineType: profile.engineType,
      name: profile.name,
      apiKey: apiKey,
      baseUrl: profile.baseUrl,
      modelName: profile.modelName,
      temperature: profile.temperature,
      reasoningEffort: profile.reasoningEffort,
      isActive: profile.isActive,
    );
  }
}
