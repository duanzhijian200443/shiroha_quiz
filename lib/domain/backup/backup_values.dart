/// Frozen B0 v0 constants. Keep these in one place; service and test code
/// must not duplicate or weaken them.
abstract final class BackupValues {
  static const String format = 'shiroha-backup';

  /// Frozen B0 v0 package version. Version 1 remains readable for existing
  /// packages and continues to use the original library-only layout.
  static const int packageVersion = 1;

  /// Additive package version for source-qualified durable content assets.
  static const int currentPackageVersion = 2;
  static const int contentAssetPackageVersion = 2;
  static const int currentSchemaVersion = 25;

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

  static String contentAssetArchivePath({
    required String sourceId,
    required String localAssetId,
  }) =>
      'files/content_assets/$sourceId/$localAssetId';
}
