import '../models/ai_engine_profile.dart';

/// Persists AI engine metadata only.
///
/// S0 contract: this store must never persist the runtime credential.
/// Post-activation the repository passes metadata-only profiles (apiKey
/// scrubbed) to [saveAiEngine]; implementations must not write the secret,
/// and callers must never treat a stored `api_key` value as credential
/// authority (legacy rows may retain plaintext only as migrator retry input).
abstract interface class AiEngineStore {
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type);

  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type);

  Future<void> saveAiEngine(AiEngineProfile profile);

  Future<void> setActiveAiEngine(String id, AiEngineType type);

  Future<void> deleteAiEngine(String id);
}
