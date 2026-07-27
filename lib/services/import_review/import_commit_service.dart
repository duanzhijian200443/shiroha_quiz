import '../../data/models/question_draft.dart';
import '../../data/repositories/question_repository.dart';
import '../import_pipeline/final_question_latex_audit.dart';
import '../import_pipeline/import_question_field_policy.dart';
import '../task_manager.dart';
import 'import_review_analyzer.dart';
import 'import_review_blocking_policy.dart';
import 'import_review_item.dart';

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
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
    List<QuestionExplanationOverride>? explanationOverrides,
  }) async {
    final gate = diagnostics['qualityGate'];
    if (gate is Map && gate['blocked'] == true) {
      final rawReason = gate['reason'];
      final reason = rawReason is String && rawReason.trim().isNotEmpty
          ? rawReason.trim()
          : null;
      throw ImportCommitBlockedException(reason);
    }

    final finalizedMaps = finalizeAndAuditImportQuestions(
      questions.map((question) => question.toMap()),
      mode: explanationRetentionMode,
      overrides: explanationOverrides,
      preserveRawExplanation: false,
    );
    final finalizedItems = finalizedMaps
        .asMap()
        .entries
        .map((entry) => ImportReviewItem.fromMap(entry.value, entry.key))
        .toList(growable: false);
    final finalizedQuestions =
        finalizedItems.map((item) => item.draft).toList(growable: false);
    final review = ImportReviewAnalyzer.analyzeItems(finalizedItems);
    if (ImportReviewBlockingPolicy.isBlocked(review)) {
      throw const ImportCommitBlockedException(
        ImportReviewBlockingPolicy.reasonCode,
      );
    }

    await _questionRepository.saveQuestionDraftsToBank(
      bankName: bankName,
      folderName: folderName,
      questions: finalizedQuestions,
    );

    if (taskId != null) {
      _taskManager.completeTask(taskId, '已成功导入题库: $bankName');
    }

    return ImportCommitResult(questionCount: finalizedQuestions.length);
  }
}
