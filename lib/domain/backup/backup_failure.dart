/// Fixed enum-like B0 failure taxonomy. UI and OBS map only these values;
/// raw exceptions, SQL, paths, and OS errno never cross the seam.
enum BackupFailure {
  invalidPackage,
  unsupportedPackageVersion,
  unsupportedSchemaVersion,
  unsafeArchivePath,
  duplicateArchiveEntry,
  manifestInvalid,
  integrityMismatch,
  resourceLimitExceeded,
  unsupportedCompression,
  databaseInvalid,
  snapshotUnavailable,
  storageUnavailable,
  restoreBusy,
  rollbackFailed,
  journalInvalid,
  restoreBlocked,
  canceled,
  internalError,
}
