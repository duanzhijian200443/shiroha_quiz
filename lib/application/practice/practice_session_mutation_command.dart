import '../backup/backup_restore_gate.dart';

/// Persistence seam for the durable practice-session summary.
abstract interface class PracticeSessionMutationPersistencePort {
  Future<void> insertPomodoroSession(Map<String, dynamic> session);
}

/// Application authority for one completed Pomodoro session write.
final class PracticeSessionMutationCommand {
  const PracticeSessionMutationCommand(this._persistence);

  final PracticeSessionMutationPersistencePort _persistence;

  Future<void> insertPomodoroSession(Map<String, dynamic> session) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.insertPomodoroSession(session),
    );
  }
}
