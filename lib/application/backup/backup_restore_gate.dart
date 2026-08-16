import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';

/// Process-wide B0 mutation gate.
///
/// It is deliberately a single bounded singleton rather than a
/// repository-wide state machine. Any durable mutation authority that must
/// not run while a restore commit is in its SWAPPING window calls
/// [ensureMutationAllowed] at the entry point; B0 itself uses
/// [acquireExclusive] to prevent a second backup/restore.
abstract final class BackupRestoreMutationGate {
  static final BackupRestoreMutationGateState instance =
      BackupRestoreMutationGateState();

  static void resetForTesting() {
    instance.resetForTesting();
  }
}

final class BackupRestoreMutationGateState {
  bool _exclusive = false;
  bool _maintenance = false;

  bool get isExclusive => _exclusive;
  bool get isMaintenance => _maintenance;

  void acquireExclusive() {
    if (_exclusive) {
      throw const BackupException(BackupFailure.restoreBusy);
    }
    _exclusive = true;
  }

  void releaseExclusive() {
    _exclusive = false;
  }

  void enterQuiescence() {
    if (_maintenance) {
      throw const BackupException(BackupFailure.restoreBusy);
    }
    _maintenance = true;
  }

  void exitQuiescence() {
    _maintenance = false;
  }

  void ensureMutationAllowed() {
    if (_maintenance) {
      throw const BackupException(BackupFailure.restoreBlocked);
    }
  }

  void resetForTesting() {
    _exclusive = false;
    _maintenance = false;
  }
}
