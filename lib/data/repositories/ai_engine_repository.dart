import '../models/ai_engine_profile.dart';
import '../persistence/ai_engine_store.dart';
import '../persistence/engine_credential_store.dart';

class AiEngineDependencyException implements Exception {
  const AiEngineDependencyException();

  @override
  String toString() => 'AiEngineDependencyException';
}

/// AI engine repository.
///
/// S0 transitional bridge: [credentialStore] is optional. When `null` the
/// repository is PRE-ACTIVATION and behaves exactly like the pre-S0 master
/// (SQLite is the only store). When non-null the repository enforces S0
/// target semantics: SQLite `apiKey` values are ignored and credentials come
/// only from the credential store. S0-D2 removes the null bridge; D0 never
/// activates production secure storage.
class AiEngineRepository {
  const AiEngineRepository({
    required AiEngineStore store,
    EngineCredentialStore? credentialStore,
  })  : _store = store,
        _credentialStore = credentialStore;

  final AiEngineStore _store;
  final EngineCredentialStore? _credentialStore;

  bool get _isActivated => _credentialStore != null;

  Future<List<AiEngineProfile>> getEngines(AiEngineType type) async {
    final profiles = await _store.listAiEngines(type);
    final selected = (type == AiEngineType.ocr
            ? profiles
                .where((profile) => profile.engineType == AiEngineType.ocr)
            : profiles
                .where((profile) => profile.engineType != AiEngineType.ocr))
        .toList(growable: false);
    if (!_isActivated) {
      return selected;
    }
    final hydrated = <AiEngineProfile>[];
    for (final profile in selected) {
      hydrated.add(await _hydrate(profile));
    }
    return List<AiEngineProfile>.unmodifiable(hydrated);
  }

  Future<AiEngineProfile?> getActiveEngine(AiEngineType type) async {
    final profile = await _store.getActiveAiEngine(type);
    if (profile == null) return null;
    final matches = type == AiEngineType.ocr
        ? profile.engineType == AiEngineType.ocr
        : profile.engineType != AiEngineType.ocr;
    if (!matches) return null;
    return _isActivated ? _hydrate(profile) : profile;
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

  Future<void> saveEngine(AiEngineProfile profile) async {
    final credentialStore = _credentialStore;
    if (credentialStore == null) {
      await _store.saveAiEngine(profile);
      return;
    }
    await _saveEngineActivated(credentialStore, profile);
  }

  Future<void> setActiveEngine(String id, AiEngineType type) =>
      _store.setActiveAiEngine(id, type);

  Future<void> deleteEngine(String id) async {
    final credentialStore = _credentialStore;
    if (credentialStore == null) {
      await _store.deleteAiEngine(id);
      return;
    }
    await _deleteEngineActivated(credentialStore, id);
  }

  Future<void> renameEngine(
      String id, String newName, AiEngineType type) async {
    final engines = await getEngines(type);
    final target = engines.where((e) => e.id == id).firstOrNull;
    if (target != null) {
      final updatedMap = target.toMap();
      updatedMap['name'] = newName;
      final updatedProfile =
          AiEngineProfile.fromMap(updatedMap, fallbackType: type);
      await saveEngine(updatedProfile);
    }
  }

  // --- activated-path internals (S0 target semantics) ---

  /// Hydrates [profile] with the credential from the secure store. A missing
  /// credential yields `apiKey == ''` (incomplete); unavailable/corrupt
  /// credential failures propagate as typed [EngineCredentialException] and
  /// are never folded into missing. The store-provided `apiKey` is always
  /// ignored on the activated path.
  Future<AiEngineProfile> _hydrate(AiEngineProfile profile) async {
    final store = _credentialStore!;
    final secret = await _credentialCall(
      () => store.readCredential(profile.id),
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
