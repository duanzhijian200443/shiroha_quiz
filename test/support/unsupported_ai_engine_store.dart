import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';

class UnsupportedAiEngineStore implements AiEngineStore {
  const UnsupportedAiEngineStore();

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      const [];

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async => null;

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    throw UnsupportedError('Unsupported test AI engine store operation');
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    throw UnsupportedError('Unsupported test AI engine store operation');
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    throw UnsupportedError('Unsupported test AI engine store operation');
  }
}
