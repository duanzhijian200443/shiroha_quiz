import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../persistence/engine_credential_store.dart';

/// Minimal bounded key/value backend seam for the secure adapter.
///
/// Exists only to keep real native secure-storage IO out of unit tests; it is
/// NOT a second application-level credential abstraction.
/// [EngineCredentialStore] remains the only business credential port.
abstract interface class SecureKeyValueBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Production backend backed by flutter_secure_storage (Windows: DPAPI via
/// flutter_secure_storage_windows).
final class FlutterSecureKeyValueBackend implements SecureKeyValueBackend {
  const FlutterSecureKeyValueBackend({
    this.storage = const FlutterSecureStorage(),
  });

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// Real [EngineCredentialStore] adapter over a secure key/value backend.
///
/// Keys are namespaced as `engine.<engineId>`; identity never uses engine
/// name, provider, model, index, or path. No secret ever enters `toString`,
/// exceptions, logs, or messages; backend/platform failures map to a fixed
/// typed [EngineCredentialException.temporarilyUnavailable] and never surface
/// a raw cause. Reads distinguish genuine missing (`null`) from corrupt
/// stored values (`dataCorrupt`) and backend failures
/// (`temporarilyUnavailable`).
final class SecureEngineCredentialStore implements EngineCredentialStore {
  SecureEngineCredentialStore({SecureKeyValueBackend? backend})
      : _backend = backend ?? const FlutterSecureKeyValueBackend();

  final SecureKeyValueBackend _backend;

  String _keyFor(String engineId) => 'engine.$engineId';

  @override
  Future<String?> readCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    final key = _keyFor(engineId);
    final String? value;
    try {
      value = await _backend.read(key);
    } catch (_) {
      throw const EngineCredentialException(
        EngineCredentialFailure.temporarilyUnavailable,
      );
    }
    if (value == null) {
      return null;
    }
    try {
      validatedEngineCredentialSecret(value);
    } on ArgumentError {
      throw const EngineCredentialException(
        EngineCredentialFailure.dataCorrupt,
      );
    }
    return value;
  }

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    validatedEngineCredentialId(engineId);
    validatedEngineCredentialSecret(secret);
    final key = _keyFor(engineId);
    try {
      await _backend.write(key, secret);
    } catch (_) {
      throw const EngineCredentialException(
        EngineCredentialFailure.temporarilyUnavailable,
      );
    }
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    final key = _keyFor(engineId);
    try {
      await _backend.delete(key);
    } catch (_) {
      throw const EngineCredentialException(
        EngineCredentialFailure.temporarilyUnavailable,
      );
    }
  }

  @override
  String toString() => 'SecureEngineCredentialStore';
}
