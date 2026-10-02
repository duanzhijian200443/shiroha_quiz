import '../../application/practice/practice_session_mutation_command.dart';
import '../../application/practice/record_answer_attempt_command.dart';
import '../../application/questions/question_mutation_command.dart';
import '../../application/questions/question_write_mutation_command.dart';

/// Presentation dependency bundle for the practice surfaces.
///
/// It only aggregates already-assembled Application mutation commands so the
/// practice screens never need to know which concrete repository backs them.
/// The composition root (main.dart) assembles the commands from the real
/// repositories; tests inject bundles over fake persistence ports instead.
///
/// The bundle must never hold business state, wrap business flows, act as a
/// service locator, or expose a repository.
final class PracticeCommandDependencies {
  const PracticeCommandDependencies({
    required this.questionMutation,
    required this.practiceSessionMutation,
    required this.questionWriteMutation,
    required this.recordAttempt,
  });

  /// Legacy question delete/update authority.
  final QuestionMutationCommand questionMutation;

  /// Pomodoro session summary write authority.
  final PracticeSessionMutationCommand practiceSessionMutation;

  /// Standalone question persistence authority (preview saves).
  final QuestionWriteMutationCommand questionWriteMutation;

  /// Durable answer-attempt append authority.
  final RecordAnswerAttemptCommand recordAttempt;
}
