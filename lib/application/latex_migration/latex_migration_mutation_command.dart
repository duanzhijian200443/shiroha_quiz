import '../backup/backup_restore_gate.dart';

/// Application authority for the complete historical LaTeX migration.
///
/// The callback is the already-composed migration workflow. Keeping the
/// workflow behind this narrow seam lets the lease cover provider waits,
/// durable updates, cooldowns, and terminal failure without making the data
/// repository aware of B0.
final class LatexMigrationMutationCommand {
  const LatexMigrationMutationCommand();

  Future<T> run<T>(Future<T> Function() migration) {
    return BackupRestoreMutationGate.instance.runMutation(migration);
  }
}
