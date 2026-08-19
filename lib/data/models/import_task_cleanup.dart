/// Persistence outcomes for the durable ImportTask cleanup boundary.
///
/// This value contains no database exception, SQL, task payload, or path. The
/// Application layer maps it to the user-facing cleanup result.
enum ImportTaskDeletePersistenceStatus {
  deleted,
  alreadyAbsent,
  busy,
}
