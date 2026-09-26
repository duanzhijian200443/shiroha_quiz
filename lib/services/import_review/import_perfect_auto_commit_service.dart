import '../../application/import/import_advanced_preferences.dart';
import '../../application/import/import_perfect_auto_commit_policy.dart';
import '../../application/import/import_target_catalog_service.dart';
import '../../application/import/import_target_selection.dart';
import '../../application/import_review/typed_review_snapshot.dart';
import '../import_pipeline/final_question_latex_audit.dart';
import '../import_pipeline/import_attempt_context.dart';
import '../import_pipeline/import_question_field_policy.dart';
import '../import_pipeline/ocr_typed_candidate.dart';
import '../task_manager.dart';
import 'explanation_edit_provenance.dart';
import 'import_commit_service.dart';
import 'import_review_analyzer.dart';
import 'import_review_blocking_policy.dart';
import 'import_review_item.dart';
import 'import_review_report_builder.dart';
import 'typed_review_result_builder.dart';

enum ImportPerfectAutoCommitStatus {
  committed,
  notEligible,
  reviewFallback,
  lifecycleRegression,
}

final class ImportPerfectAutoCommitOutcome {
  const ImportPerfectAutoCommitOutcome(this.status, {this.questionCount = 0});
  final ImportPerfectAutoCommitStatus status;
  final int questionCount;
}

/// Runs after RD0. It never creates a ReviewDraft or writes questions itself.
final class ImportPerfectAutoCommitService {
  /// RD0 materializes exactly one revision. Auto commit owns that snapshot
  /// only: once Review saves a later revision its manual workflow has
  /// authority, and the commit lease/CAS must see this exact expected value.
  static const int _rd0ReviewDraftRevision = 1;

  ImportPerfectAutoCommitService({
    required TaskManager taskManager,
    required ImportCommitService commitService,
    required ImportAdvancedPreferencesLoader preferencesLoader,
    ImportTargetCatalogService? targetCatalog,
    TypedReviewResultBuilder? resultBuilder,
    ImportPerfectAutoCommitPolicy policy =
        const ImportPerfectAutoCommitPolicy(),
  })  : _taskManager = taskManager,
        _commitService = commitService,
        _preferencesLoader = preferencesLoader,
        _targetCatalog = targetCatalog,
        _resultBuilder = resultBuilder ?? TypedReviewResultBuilder(),
        _policy = policy;

  final TaskManager _taskManager;
  final ImportCommitService _commitService;
  final ImportAdvancedPreferencesLoader _preferencesLoader;
  final ImportTargetCatalogService? _targetCatalog;
  final TypedReviewResultBuilder _resultBuilder;
  final ImportPerfectAutoCommitPolicy _policy;

  Future<ImportPerfectAutoCommitOutcome> tryCommit(
      ImportAttemptRef attempt) async {
    await _taskManager.ready;
    final task = _currentTask(attempt);
    if (task == null) {
      return const ImportPerfectAutoCommitOutcome(
          ImportPerfectAutoCommitStatus.notEligible);
    }
    final isTypedDocument =
        isDocumentImportEntryDiagnostics(task.diagnostics) &&
            task.diagnostics?[TaskManager.keyImportStorageRoute] ==
                importStorageRouteSerialization(ImportStorageRoute.typedV2) &&
            task.diagnostics?[TaskManager.keyImportStorageReason] ==
                ocrTypedCandidateReadyReason &&
            task.status == TaskStatus.pendingReview &&
            task.attemptState == ImportAttemptState.readyForReview;
    if (isTypedDocument && _taskManager.reviewDraftRevision(task.id) == 0) {
      // RD0 is the only authority for initial materialization. Never repair
      // this lifecycle regression with a second initial save here.
      return const ImportPerfectAutoCommitOutcome(
          ImportPerfectAutoCommitStatus.lifecycleRegression);
    }
    if (!isTypedDocument || task.bankName?.trim().isNotEmpty != true) {
      return const ImportPerfectAutoCommitOutcome(
          ImportPerfectAutoCommitStatus.notEligible);
    }
    // Auto commit belongs to the just-materialized RD0 snapshot. A later
    // positive revision means Review has already begun editing this task.
    if (_taskManager.reviewDraftRevision(task.id) != _rd0ReviewDraftRevision) {
      return const ImportPerfectAutoCommitOutcome(
          ImportPerfectAutoCommitStatus.notEligible);
    }

    try {
      final preferences = await _preferencesLoader();
      if (!preferences.autoCommitPerfectImports) {
        return const ImportPerfectAutoCommitOutcome(
            ImportPerfectAutoCommitStatus.notEligible);
      }
      if (!_holdsAutoCommitScope(attempt)) {
        return const ImportPerfectAutoCommitOutcome(
            ImportPerfectAutoCommitStatus.reviewFallback);
      }
      if (task.diagnostics?[importTargetKindMarkerKey] ==
          ImportTargetKind.existing.name) {
        final catalog = _targetCatalog;
        if (catalog == null ||
            !(await catalog.listTargets()).any((bank) =>
                bank.bankName == task.bankName &&
                bank.folderName == _folderOrNull(task.folderName))) {
          return const ImportPerfectAutoCommitOutcome(
              ImportPerfectAutoCommitStatus.reviewFallback);
        }
      }
      if (task.diagnostics?[importTargetKindMarkerKey] ==
          ImportTargetKind.proposedNew.name) {
        final catalog = _targetCatalog;
        if (catalog != null &&
            (await catalog.listTargets())
                .any((bank) => bank.bankName == task.bankName)) {
          return const ImportPerfectAutoCommitOutcome(
              ImportPerfectAutoCommitStatus.reviewFallback);
        }
      }

      // Every await above is a window in which Review can save a new revision.
      // The frozen revision-1 snapshot is copied only while the scope is still
      // intact, and the commit below keeps expecting revision 1 so a save that
      // lands later fails the lease CAS instead of being committed.
      if (!_holdsAutoCommitScope(attempt)) {
        return const ImportPerfectAutoCommitOutcome(
            ImportPerfectAutoCommitStatus.reviewFallback);
      }

      final source = task.parsedData;
      if (source == null || source.isEmpty) {
        return const ImportPerfectAutoCommitOutcome(
            ImportPerfectAutoCommitStatus.notEligible);
      }
      final immutableSource = source
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList(growable: false);
      final overrides = <QuestionExplanationOverride>[
        for (final question in immutableSource)
          QuestionExplanationOverride.values
                  .where((entry) =>
                      entry.name == question['_explanation_override'])
                  .firstOrNull ??
              QuestionExplanationOverride.inherit,
      ];
      final finalized = finalizeAndAuditImportQuestions(
        immutableSource,
        mode: task.reviewExplanationRetentionMode,
        overrides: overrides,
        preserveRawExplanation: false,
      );
      final reviewItems = <ImportReviewItem>[
        for (var i = 0; i < finalized.length; i++)
          ImportReviewItem.fromMap(finalized[i], i),
      ];
      final analysis = ImportReviewAnalyzer.analyzeItems(reviewItems);
      final report = ImportReviewReportBuilder.build(reviewItems, analysis);
      final revision = _taskManager.reviewDraftRevision(task.id);
      final candidateInputs = <TypedReviewCommitInput>[];
      var snapshotValid = true;
      if (report.qualityScore == 100 &&
          report.errorCount == 0 &&
          report.warningCount == 0 &&
          report.totalCount > 0) {
        try {
          const codec = TypedReviewSnapshotCodec();
          for (var i = 0; i < reviewItems.length; i++) {
            final raw = immutableSource[i];
            final envelope = raw[TypedReviewSnapshotCodec.mapKey];
            final snapshot = codec.decodeRequired(envelope);
            final marker = raw[TaskManager.keyReviewItemId];
            final reviewItemId = marker is String && marker.isNotEmpty
                ? marker
                : snapshot.reviewItemId;
            candidateInputs.add(TypedReviewCommitInput(
              reviewItemId: reviewItemId,
              envelope: envelope,
              currentDraft: reviewItems[i].draft,
              explanationRetained:
                  const ImportQuestionFieldPolicy().shouldRetainExplanation(
                type: reviewItems[i].draft.type.code,
                mode: task.reviewExplanationRetentionMode,
                override: overrides[i],
              ),
              explanationEditProvenance: decodeExplanationEditProvenance(
                  raw[TaskManager.keyExplanationEditProvenance]),
            ));
          }
          _resultBuilder.build(
            inputs: candidateInputs,
            taskId: task.id,
            attemptToken: attempt.attemptToken,
            attemptNumber: attempt.attemptNumber,
          );
        } on TypedReviewCommitException {
          snapshotValid = false;
        } on TypedReviewSnapshotException {
          snapshotValid = false;
        }
      }
      final eligible = _policy.isEligible(ImportPerfectAutoCommitFacts(
        enabled: preferences.autoCommitPerfectImports,
        documentImportEntry: isDocumentImportEntryDiagnostics(task.diagnostics),
        hasFrozenTarget: task.bankName?.trim().isNotEmpty == true,
        pendingReview: task.status == TaskStatus.pendingReview,
        readyForReview: task.attemptState == ImportAttemptState.readyForReview,
        typedCandidateReady: isTypedDocument,
        itemCount: report.totalCount,
        qualityScore: report.qualityScore,
        errorCount: report.errorCount,
        warningCount: report.warningCount,
        qualityGateBlocked: ImportReviewBlockingPolicy.isBlocked(analysis),
        reviewDraftRevision: revision,
        commitInProgress: _taskManager.hasActiveTypedCommitLease(task.id),
        typedSnapshotValid: snapshotValid,
      ));
      if (!eligible) {
        return const ImportPerfectAutoCommitOutcome(
            ImportPerfectAutoCommitStatus.notEligible);
      }
      final committed = await _commitService.commitTyped(
        bankName: task.bankName!,
        folderName: task.folderName ?? '',
        items: candidateInputs,
        taskId: task.id,
        attemptToken: attempt.attemptToken,
        attemptNumber: attempt.attemptNumber,
        expectedReviewDraftRevision: _rd0ReviewDraftRevision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: task.reviewExplanationRetentionMode,
        explanationOverrides: overrides,
      );
      return ImportPerfectAutoCommitOutcome(
          ImportPerfectAutoCommitStatus.committed,
          questionCount: committed.questionCount);
    } catch (_) {
      return const ImportPerfectAutoCommitOutcome(
          ImportPerfectAutoCommitStatus.reviewFallback);
    }
  }

  ImportTask? _currentTask(ImportAttemptRef attempt) {
    if (!_taskManager.isCurrentAttempt(attempt)) return null;
    return _taskManager.tasks
        .where((task) => task.id == attempt.taskId)
        .firstOrNull;
  }

  /// Re-reads the live task after an await and rechecks the exact scope auto
  /// commit froze at entry: same attempt, still `pendingReview` /
  /// `readyForReview`, and still RD0's revision 1. Any drift means Review took
  /// authority while auto commit was waiting, so the attempt must be abandoned
  /// without writing questions.
  bool _holdsAutoCommitScope(ImportAttemptRef attempt) {
    final task = _currentTask(attempt);
    return task != null &&
        task.status == TaskStatus.pendingReview &&
        task.attemptState == ImportAttemptState.readyForReview &&
        _taskManager.reviewDraftRevision(task.id) == _rd0ReviewDraftRevision;
  }

  String? _folderOrNull(String? value) =>
      value?.trim().isEmpty == true ? null : value;
}
