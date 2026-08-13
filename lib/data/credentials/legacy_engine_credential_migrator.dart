import '../persistence/engine_credential_store.dart';
import '../persistence/legacy_engine_credential_migration_store.dart';

enum LegacyMigrationResult { done }

/// Secure-wins, verification-before-scrub S0 legacy migration.
final class LegacyEngineCredentialMigrator {
  const LegacyEngineCredentialMigrator({
    required LegacyEngineCredentialMigrationStore legacyStore,
    required EngineCredentialStore credentialStore,
  })  : _legacyStore = legacyStore,
        _credentialStore = credentialStore;

  final LegacyEngineCredentialMigrationStore _legacyStore;
  final EngineCredentialStore _credentialStore;

  Future<LegacyMigrationResult> migrate() async {
    try {
      // Orphan legacy profiles have no stable production credential reader.
      await _legacyStore.scrubLegacyAiProfileCredentials();
      final rows = await _legacyStore.listLegacyEngineCredentials();
      for (final row in rows) {
        final secureValue = await _readSecure(row.engineId);
        if (secureValue == null) {
          await _writeSecure(row.engineId, row.secret);
          if (await _readSecure(row.engineId) != row.secret) {
            throw const LegacyMigrationException(
              LegacyMigrationFailure.verificationFailed,
            );
          }
        }
        final scrubbed = await _legacyStore.scrubLegacyEngineCredential(
          row.engineId,
          row.secret,
        );
        if (!scrubbed) {
          throw const LegacyMigrationException(
            LegacyMigrationFailure.verificationFailed,
          );
        }
      }
      if (await _legacyStore.countLegacyPlaintextCredentials() != 0) {
        throw const LegacyMigrationException(
          LegacyMigrationFailure.verificationFailed,
        );
      }
      return LegacyMigrationResult.done;
    } on LegacyMigrationException {
      rethrow;
    } catch (_) {
      throw const LegacyMigrationException(
        LegacyMigrationFailure.verificationFailed,
      );
    }
  }

  Future<String?> _readSecure(String engineId) async {
    try {
      return await _credentialStore.readCredential(engineId);
    } on EngineCredentialException catch (error) {
      throw LegacyMigrationException(_mapFailure(error.failure));
    } catch (_) {
      throw const LegacyMigrationException(
        LegacyMigrationFailure.storeUnavailable,
      );
    }
  }

  Future<void> _writeSecure(String engineId, String secret) async {
    try {
      await _credentialStore.writeCredential(engineId, secret);
    } on EngineCredentialException catch (error) {
      throw LegacyMigrationException(_mapFailure(error.failure));
    } on ArgumentError {
      throw const LegacyMigrationException(
        LegacyMigrationFailure.verificationFailed,
      );
    } catch (_) {
      throw const LegacyMigrationException(
        LegacyMigrationFailure.storeUnavailable,
      );
    }
  }

  LegacyMigrationFailure _mapFailure(EngineCredentialFailure failure) {
    return switch (failure) {
      EngineCredentialFailure.dataCorrupt =>
        LegacyMigrationFailure.secureCorrupt,
      EngineCredentialFailure.temporarilyUnavailable =>
        LegacyMigrationFailure.storeUnavailable,
      EngineCredentialFailure.missing =>
        LegacyMigrationFailure.verificationFailed,
    };
  }
}
