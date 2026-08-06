import '../../application/import_review/typed_review_snapshot.dart';
import '../../data/models/question_draft.dart';
import '../../data/repositories/question_repository.dart';
import '../import_pipeline/import_parse_result.dart';
import '../import_pipeline/final_question_latex_audit.dart';
import '../import_pipeline/import_question_field_policy.dart';
import '../import_pipeline/ocr_typed_candidate.dart';
import '../task_manager.dart';
import 'import_review_analyzer.dart';
import 'import_review_blocking_policy.dart';
import 'import_review_item.dart';
import 'typed_review_result_builder.dart';

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
    TypedReviewResultBuilder? typedResultBuilder,
  })  : _questionRepository = questionRepository ?? QuestionRepository.instance,
        _taskManager = taskManager ?? TaskManager.instance,
        _typedResultBuilder = typedResultBuilder ?? TypedReviewResultBuilder();

  final QuestionRepository _questionRepository;
  final TaskManager _taskManager;
  final TypedReviewResultBuilder _typedResultBuilder;

  /// Legacy V1 compatibility writer. Behavior is frozen by the R7B baseline:
  /// finalize -> analyzer -> blocking policy -> `saveQuestionDraftsToBank` ->
  /// complete task.
  Future<ImportCommitResult> commitLegacy({
    required String bankName,
    required String folderName,
    required List<QuestionDraft> questions,
    String? taskId,
    required Map<String, dynamic> diagnostics,
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
    List<QuestionExplanationOverride>? explanationOverrides,
  }) async {
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

  /// Compatibility alias that only delegates to [commitLegacy].
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
    return commitLegacy(
      bankName: bankName,
      folderName: folderName,
      questions: questions,
      taskId: taskId,
      diagnostics: diagnostics,
      explanationRetentionMode: explanationRetentionMode,
      explanationOverrides: explanationOverrides,
    );
  }

  /// Typed V2 writer activated for eligible new OCR tasks only.
  ///
  /// Validates the storage metadata strictly, finalizes the current legacy
  /// drafts through the existing quality gate, builds the typed ReviewResult
  /// through [TypedReviewResultBuilder], and calls only
  /// `saveQuestionDraftsV2ToBank`. Repository failure never completes the
  /// task, never falls back to the legacy writer, and maps to the fixed safe
  /// [TypedReviewCommitException].
  Future<ImportCommitResult> commitTyped({
    required String bankName,
    required String folderName,
    required List<TypedReviewCommitInput> items,
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
    required ImportStorageRoute storageRoute,
    required String storageReason,
    required ExplanationRetentionMode explanationRetentionMode,
    List<QuestionExplanationOverride>? explanationOverrides,
  }) async {
    final ValidatedImportStorageMetadata validated;
    try {
      validated = validateImportStorageMetadata(
        route: storageRoute,
        reason: storageReason,
      );
    } on TypedReviewSnapshotException {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.invalidRoute,
      );
    }
    if (validated.route != ImportStorageRoute.typedV2 ||
        validated.reason != ocrTypedCandidateReadyReason) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.invalidRoute,
      );
    }
    if (items.isEmpty) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.emptyCommit,
      );
    }
    if (taskId.trim().isEmpty ||
        attemptToken.trim().isEmpty ||
        attemptNumber <= 0) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.invalidOrigin,
      );
    }

    final finalizedMaps = finalizeAndAuditImportQuestions(
      items.map((input) => input.currentDraft.toMap()),
      mode: explanationRetentionMode,
      overrides: explanationOverrides,
      preserveRawExplanation: false,
    );
    final finalizedItems = finalizedMaps
        .asMap()
        .entries
        .map((entry) => ImportReviewItem.fromMap(entry.value, entry.key))
        .toList(growable: false);
    final review = ImportReviewAnalyzer.analyzeItems(finalizedItems);
    if (ImportReviewBlockingPolicy.isBlocked(review)) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.qualityBlocked,
      );
    }

    final buildInputs = <TypedReviewCommitInput>[
      for (var index = 0; index < items.length; index++)
        TypedReviewCommitInput(
          reviewItemId: items[index].reviewItemId,
          envelope: items[index].envelope,
          currentDraft: finalizedItems[index].draft,
        ),
    ];
    final built = _typedResultBuilder.build(
      inputs: buildInputs,
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
    );
    if (built.acceptedDrafts.isEmpty) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.emptyCommit,
      );
    }

    try {
      await _questionRepository.saveQuestionDraftsV2ToBank(
        bankName: bankName,
        folderName: folderName,
        questions: built.acceptedDrafts,
      );
    } catch (_) {
      throw const TypedReviewCommitException(
        TypedReviewCommitFailure.persistenceFailed,
      );
    }

    _taskManager.completeTask(taskId, '已成功导入题库: $bankName');
    return ImportCommitResult(questionCount: built.acceptedDrafts.length);
  }
}
