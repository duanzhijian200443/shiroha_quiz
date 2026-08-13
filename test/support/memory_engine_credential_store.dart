import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';

final class MemoryEngineCredentialStore implements EngineCredentialStore {
  MemoryEngineCredentialStore([Map<String, String>? initial])
      : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> readCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    return _values[engineId];
  }

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    validatedEngineCredentialId(engineId);
    validatedEngineCredentialSecret(secret);
    _values[engineId] = secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    _values.remove(engineId);
  }
}
