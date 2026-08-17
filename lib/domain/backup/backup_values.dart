/// Frozen B0 v0 constants. Keep these in one place; service and test code
/// must not duplicate or weaken them.
abstract final class BackupValues {
  static const String format = 'shiroha-backup';
  static const int packageVersion = 1;
  static const int currentSchemaVersion = 23;

  static const String manifestArchivePath = 'manifest.json';
  static const String databaseArchivePath = 'database/shiroha.db';

  static const int maxArchiveEntries = 65536;
  static const int manifestEntryMaxBytes = 16 * 1024 * 1024;
  static const int databaseMaxDeclaredSizeBytes = 4 * 1024 * 1024 * 1024;
  static const int singleManagedFileMaxDeclaredSizeBytes =
      8 * 1024 * 1024 * 1024;
  static const int packageMaxDeclaredUncompressedBytes =
      16 * 1024 * 1024 * 1024;
  static const int freeSpaceWorkingReserveBytes = 512 * 1024 * 1024;

  static String managedArchivePath(String fileId) => 'files/library/$fileId';
  static String managedArchivePathForStorageKey(String storageKey) =>
      'files/$storageKey';
}
