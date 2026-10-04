import '../home_training_result.dart';
import 'study_activity_contracts.dart';
import 'study_activity_transition_engine.dart';

/// Atomic persistence boundary for immutable P4a proposals, not clock inputs.
abstract interface class StudyActivityPersistence {
  Future<HomeTrainingResult<StudyActivitySnapshot>> createSession(
      StudyActivityTransition proposal);
  Future<HomeTrainingResult<StudyActivitySnapshot>> commitTransition(
      StudyActivityRuntimeState previous, StudyActivityTransition proposal);
  Future<HomeTrainingResult<int>> recoverInterruptedSessions();
  Future<HomeTrainingResult<StudyActivityWeekSnapshot>> readWeek(
      String mondayLocalDate);
}
