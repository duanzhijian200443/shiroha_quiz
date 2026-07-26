import '../models/ai_engine_profile.dart';

abstract interface class AiEngineStore {
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type);

  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type);

  Future<void> saveAiEngine(AiEngineProfile profile);

  Future<void> setActiveAiEngine(String id, AiEngineType type);

  Future<void> deleteAiEngine(String id);
}
