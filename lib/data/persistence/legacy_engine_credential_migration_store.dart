final class LegacyEngineCredential {
  const LegacyEngineCredential({
    required this.engineId,
    required this.secret,
  });

  final String engineId;
  final String secret;
}

/// Bounded SQLite operations used only by the S0 legacy migrator.
abstract interface class LegacyEngineCredentialMigrationStore {
  Future<List<LegacyEngineCredential>> listLegacyEngineCredentials();

  Future<bool> scrubLegacyEngineCredential(
    String engineId,
    String expectedSecret,
  );

  Future<void> scrubLegacyAiProfileCredentials();

  Future<int> countLegacyPlaintextCredentials();
}
