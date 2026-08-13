import '../persistence/ai_engine_store.dart';
import '../persistence/engine_credential_store.dart';
import '../persistence/legacy_engine_credential_migration_store.dart';
import '../repositories/ai_engine_repository.dart';
import 'legacy_engine_credential_migrator.dart';

/// Opens SQLite, creates the secure adapter, completes migration, and only
/// then exposes an activated runtime repository.
Future<AiEngineRepository> activateAiEngineRepository({
  required Future<void> Function() openDatabase,
  required AiEngineStore store,
  required LegacyEngineCredentialMigrationStore migrationStore,
  required EngineCredentialStore Function() createCredentialStore,
}) async {
  await openDatabase();
  final credentialStore = createCredentialStore();
  await LegacyEngineCredentialMigrator(
    legacyStore: migrationStore,
    credentialStore: credentialStore,
  ).migrate();
  return AiEngineRepository(
    store: store,
    credentialStore: credentialStore,
  );
}
