import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';

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

class UnsupportedEngineCredentialStore implements EngineCredentialStore {
  const UnsupportedEngineCredentialStore();

  @override
  Future<String?> readCredential(String engineId) async {
    throw UnsupportedError('Unsupported test credential store operation');
  }

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    throw UnsupportedError('Unsupported test credential store operation');
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    throw UnsupportedError('Unsupported test credential store operation');
  }
}
