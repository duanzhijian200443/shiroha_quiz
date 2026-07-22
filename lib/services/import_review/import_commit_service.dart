import '../../data/models/question_draft.dart';
import '../../data/repositories/question_repository.dart';
import '../task_manager.dart';

class ImportCommitBlockedException implements Exception {
  const ImportCommitBlockedException([this.reason]);

  final String? reason;

  @override
  String toString() => reason == null
      ? 'Import commit blocked by quality gate.'
      : 'Import commit blocked by quality gate: $reason';
}

class ImportCommitResult {
  const ImportCommitResult({required this.questionCount});

  final int questionCount;
}

class ImportCommitService {
  ImportCommitService({
    QuestionRepository? questionRepository,
    TaskManager? taskManager,
  })  : _questionRepository = questionRepository ?? QuestionRepository.instance,
        _taskManager = taskManager ?? TaskManager.instance;

  final QuestionRepository _questionRepository;
  final TaskManager _taskManager;

  Future<ImportCommitResult> commit({
    required String bankName,
    required String folderName,
    required List<QuestionDraft> questions,
    String? taskId,
    required Map<String, dynamic> diagnostics,
  }) async {
    final gate = diagnostics['qualityGate'];
    if (gate is Map && gate['blocked'] == true) {
      final rawReason = gate['reason'];
      final reason = rawReason is String && rawReason.trim().isNotEmpty
          ? rawReason.trim()
          : null;
      throw ImportCommitBlockedException(reason);
    }

    await _questionRepository.saveQuestionDraftsToBank(
      bankName: bankName,
      folderName: folderName,
      questions: questions,
    );

    if (taskId != null) {
      _taskManager.completeTask(taskId, '已成功导入题库: $bankName');
    }

    return ImportCommitResult(questionCount: questions.length);
  }
}
