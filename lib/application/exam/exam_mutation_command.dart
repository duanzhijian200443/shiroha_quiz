import '../backup/backup_restore_gate.dart';

/// Persistence seam for the durable Exam lifecycle.
abstract interface class ExamMutationPersistencePort {
  Future<String> createExamPaper(
    String title,
    int sourceType,
    List<Map<String, dynamic>> questions,
  );

  Future<void> deleteExamPaper(String id);

  Future<List<Map<String, dynamic>>> submitExamPaper(
    String paperId,
    Map<int, dynamic> userAnswers,
    List<Map<String, dynamic>> questions,
  );

  Future<void> updateExamAiScore(
    String paperId,
    String questionId,
    String aiFeedback,
    double scoreRatio,
  );

  Future<void> finishExamGrading(String paperId);
}

final class ExamSubjectiveTask {
  const ExamSubjectiveTask({
    required this.questionId,
    required this.question,
    required this.standardAnswer,
    required this.userAnswer,
  });

  final String questionId;
  final String question;
  final String standardAnswer;
  final String userAnswer;
}

final class ExamSubjectiveGrade {
  const ExamSubjectiveGrade({
    required this.feedback,
    required this.scoreRatio,
  });

  final String feedback;
  final double scoreRatio;
}

typedef ExamSubjectiveJudge = Future<ExamSubjectiveGrade?> Function(
  ExamSubjectiveTask task,
);

/// Holds a B0 mutation lease while a future Exam creation is still being
/// generated. If restore maintenance is requested during this provider wait,
/// quiescence cannot pass early; the follow-up gated create is then rejected
/// before persistence while maintenance remains asserted.
Future<T> runExamGeneration<T>(Future<T> Function() generate) {
  return BackupRestoreMutationGate.instance.runMutation(generate);
}

/// Application authority for every production Exam mutation.
final class ExamMutationCommand {
  const ExamMutationCommand(this._persistence);

  final ExamMutationPersistencePort _persistence;

  Future<String> createExamPaper(
    String title,
    int sourceType,
    List<Map<String, dynamic>> questions,
  ) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.createExamPaper(title, sourceType, questions),
    );
  }

  Future<void> deleteExamPaper(String id) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.deleteExamPaper(id),
    );
  }

  Future<List<Map<String, dynamic>>> submitExamPaper(
    String paperId,
    Map<int, dynamic> userAnswers,
    List<Map<String, dynamic>> questions,
  ) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.submitExamPaper(paperId, userAnswers, questions),
    );
  }

  Future<void> updateExamAiScore(
    String paperId,
    String questionId,
    String aiFeedback,
    double scoreRatio,
  ) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.updateExamAiScore(
        paperId,
        questionId,
        aiFeedback,
        scoreRatio,
      ),
    );
  }

  Future<void> finishExamGrading(String paperId) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _persistence.finishExamGrading(paperId),
    );
  }

  /// Keeps the lease across every provider wait and every grading write.
  /// Returning null from [judge] skips one failed subjective item while still
  /// allowing the terminal grading marker to be persisted.
  Future<void> gradeSubjectiveAnswers({
    required String paperId,
    required List<ExamSubjectiveTask> tasks,
    required ExamSubjectiveJudge judge,
  }) {
    return BackupRestoreMutationGate.instance.runMutation(() async {
      for (final task in tasks) {
        final grade = await judge(task);
        if (grade == null) continue;
        await _persistence.updateExamAiScore(
          paperId,
          task.questionId,
          grade.feedback,
          grade.scoreRatio,
        );
      }
      await _persistence.finishExamGrading(paperId);
    });
  }
}
