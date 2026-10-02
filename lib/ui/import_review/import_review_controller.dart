import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../application/import/import_advanced_preferences.dart';
import '../../application/import_review/typed_review_snapshot.dart';
import '../../application/questions/folder_query_port.dart';
import '../../data/models/question_draft.dart';
import '../../domain/content/rich_content_text_projection.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../services/import_pipeline/final_question_latex_audit.dart';
import '../../services/import_pipeline/import_diagnostic_formatter.dart';
import '../../services/import_pipeline/import_diagnostic_message.dart';
import '../../services/import_pipeline/import_parse_result.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/ocr_typed_candidate.dart';
import '../../services/import_pipeline/subjective_answer_distillation_policy.dart';
import '../../services/import_pipeline/subjective_answer_distillation_service.dart';
import '../../services/import_pipeline/subjective_answer_distillation_snapshot_policy.dart';
import '../../services/import_pipeline/subjective_answer_expectation.dart';
import '../../services/import_pipeline/subjective_answer_extractor.dart';
import '../../services/import_review/explanation_edit_provenance.dart';
import '../../services/import_review/import_commit_service.dart';
import '../../services/import_review/import_review_analyzer.dart';
import '../../services/import_review/import_review_batch_controller.dart';
import '../../services/import_review/import_review_blocking_policy.dart';
import '../../services/import_review/import_review_filter.dart';
import '../../services/import_review/import_review_item.dart';
import '../../services/import_review/import_review_metadata.dart';
import '../../services/import_review/import_review_report.dart';
import '../../services/import_review/import_review_report_builder.dart';
import '../../services/import_review/review_legacy_field_content.dart';
import '../../services/import_review/review_repair_edit.dart';
import '../../services/import_review/review_repair_policy.dart';
import '../../services/import_review/review_repair_service.dart';
import '../../services/import_review/typed_review_result_builder.dart';
import '../../services/task_manager.dart';
import 'import_review_view_state.dart';

/// Presentation effects the review page binds to the controller.
///
/// The controller decides what happened; the page decides how it is shown.
/// Every callback is invoked only while the flow believes the page is alive,
/// and the page itself re-checks its own mount state before touching the UI.
class ImportReviewEffects {
  const ImportReviewEffects({
    required this.showMessage,
    required this.showError,
    required this.confirmRepairProposal,
    required this.showCommitSuccess,
  });

  /// Neutral informational message (SnackBar).
  final void Function(String message) showMessage;

  /// Fixed failure message (SnackBar).
  final void Function(String message) showError;

  /// Renders the AI repair proposal dialog; resolves to the user's choice.
  final Future<bool?> Function(ReviewRepairProposal proposal)
      confirmRepairProposal;

  /// Renders the post-commit report and closes the staging page.
  final void Function(
    ImportReviewReport report,
    String bankName,
    String folderName,
  ) showCommitSuccess;
}

/// Presentation controller for the import review page.
///
/// It owns the review page's business state and business orchestration: review
/// items, the review draft persistence queue, AI answer distillation, review
/// repair and the legacy/typed commit flow. It composes the existing
/// import/review service implementations and TaskManager; it is deliberately a
/// presentation-layer controller, not an application use case.
///
/// The page renders [state] and forwards user events here through the explicit
/// entry points; dialogs, SnackBars and other build-context work stay bound to
/// the page through [ImportReviewEffects].
class ImportReviewController extends ChangeNotifier {
  ImportReviewController({
    required List<Map<String, dynamic>> parsedQuestions,
    required this.effects,
    String? taskId,
    List<String>? warnings,
    Map<String, dynamic>? diagnostics,
    FolderQueryPort? folderQuery,
    ImportCommitService? commitService,
    SubjectiveAnswerDistiller? answerDistiller,
    ReviewRepairGenerator? reviewRepairGenerator,
    TaskManager? taskManager,
    ExplanationRetentionMode initialExplanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
    SubjectiveAnswerDistiller Function()? answerDistillerFactory,
    ReviewRepairGenerator Function()? repairGeneratorFactory,
  })  : _parsedQuestions = parsedQuestions,
        _taskId = taskId,
        _warnings = warnings,
        _diagnostics = diagnostics,
        _folderQuery = folderQuery,
        _commitService = commitService ?? ImportCommitService(),
        _taskManager = taskManager ?? TaskManager.instance,
        _answerDistiller = answerDistiller,
        _repairGenerator = reviewRepairGenerator,
        _initialExplanationRetentionMode = initialExplanationRetentionMode,
        _answerDistillerFactory = answerDistillerFactory,
        _repairGeneratorFactory = repairGeneratorFactory;

  static const _explanationOverrideKey = '_explanation_override';
  static const _typedCommitBlockedText = '结构化题目缺少必要的审核信息，无法入库，请检查后重试';
  static const _typedCommitFailedText = '结构化题库入库失败，题目保持待审状态，请检查后重试';
  static const _typedOptionsBlockedText = '当前结构化题目暂不支持修改选项数量、顺序或标签，请恢复后再入库';
  static const _invalidStorageRouteText = '当前任务的存储路线无效，无法入库';
  static const _reviewDraftUnsafeText = '校对结果尚未安全保存，无法入库，请重试';
  static const _answerDistillationInProgressText = '答案仍在生成中，请等待完成后再入库';
  static const _reviewRepairInProgressText = '仍有题目正在生成 AI 修补建议，请等待完成后再入库';
  static const _reviewRepairStaleText = '题目已发生变化，请重新执行 AI 修补';
  static const _reviewRepairSaveFailedText = 'AI 修补已生成，但校对结果保存失败，请重试';
  static const _typedTaskExpiredText = '任务已过期或已被替换，请检查后重试';
  static const _typedCommitInProgressText = '已有入库操作正在进行，请稍后重试';
  static const _proposedTargetExistsText = '目标题库已存在，本次未入库；请返回选择已有题库后重新导入';
  static const _legacyCommitFailedText = '题库入库失败，题目保持待审状态，请检查后重试';
  static const _legacyTaskExpiredText = '任务已过期或已被替换，请检查后重试';
  static const _safeSnapshotProvenanceKeys = {
    'q_num',
    'question_number',
    'source_page_indices',
    'source_block_ids',
    '_import_diagnostics',
    TypedReviewSnapshotCodec.mapKey,
    // Carried verbatim so an explicit edit provenance survives every draft
    // save and reload; it is never inferred from the explanation text.
    TaskManager.keyExplanationEditProvenance,
  };

  /// Presentation effects; the page owns the actual dialogs and SnackBars.
  final ImportReviewEffects effects;

  final List<Map<String, dynamic>> _parsedQuestions;
  final String? _taskId;
  final List<String>? _warnings;
  final Map<String, dynamic>? _diagnostics;
  final FolderQueryPort? _folderQuery;
  final ImportCommitService _commitService;
  final TaskManager _taskManager;
  final ExplanationRetentionMode _initialExplanationRetentionMode;
  final SubjectiveAnswerDistiller Function()? _answerDistillerFactory;
  final ReviewRepairGenerator Function()? _repairGeneratorFactory;

  late ImportReviewViewState _state;
  bool _disposed = false;

  late Map<int, Map<String, dynamic>> _snapshotProvenance;
  late Map<int, String> _reviewItemIds;
  late Map<int, QuestionExplanationOverride> _explanationOverrides;
  late Map<int, String> _answerDistillationReasons;
  late Map<int, ReviewRepairEdit> _repairEdits;
  final Map<int, ReviewRepairProposal> _autoRepairProposals = {};

  /// Questions the automatic walk already handled: prepared, skipped because
  /// they are not an auto-repairable LaTeX target, or opened by the user.
  final Set<int> _autoRepairSettled = <int>{};

  Future<void> _reviewDraftOperationTail = Future<void>.value();

  final SubjectiveAnswerDistillationPolicy _answerDistillationPolicy =
      const SubjectiveAnswerDistillationPolicy();
  SubjectiveAnswerDistiller? _answerDistiller;
  bool _answerDistillationCancellationRequested = false;
  int _answerDistillationOperationId = 0;

  final ReviewRepairPolicy _reviewRepairPolicy = const ReviewRepairPolicy();
  ReviewRepairGenerator? _repairGenerator;
  int _repairOperationId = 0;
  bool _autoRepairEnabled = false;
  bool _autoRepairPreparing = false;

  // ---------------------------------------------------------------------------
  // Presentation state
  // ---------------------------------------------------------------------------

  ImportReviewViewState get state => _state;

  String? get traceId {
    final value = _diagnostics?[TaskManager.keyTraceId]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  bool get isBlockedByQualityGate =>
      ImportReviewBlockingPolicy.isBlocked(_state.reviewResult);

  /// The frozen document-import target, when this task fixes the destination.
  ImportTask? get frozenDocumentTarget {
    final id = _taskId;
    if (id == null || id.isEmpty) return null;
    final task =
        _taskManager.tasks.where((entry) => entry.id == id).firstOrNull;
    if (task == null ||
        !isDocumentImportEntryDiagnostics(task.diagnostics) ||
        task.bankName?.trim().isNotEmpty != true) {
      return null;
    }
    return task;
  }

  bool get hasLowQualityVision {
    final summary = _diagnostics?['visionQualitySummary'];
    if (summary is! Map) return false;
    return summary['hasLowQualityVisionParse'] == true;
  }

  bool get hasUnsupportedStructure {
    final summary = _diagnostics?['unsupportedStructureSummary'];
    if (summary is! Map) return false;
    final imageBlockCount = summary['imageBlockCount'];
    final tableBlockCount = summary['tableBlockCount'];
    return (imageBlockCount is int && imageBlockCount > 0) ||
        (tableBlockCount is int && tableBlockCount > 0);
  }

  String get confirmButtonText {
    final reason = _qualityGateReason;
    if (reason != null) return '解析不完整，禁止入库：$reason';
    if (isBlockedByQualityGate) return '解析不完整，禁止入库';
    return '确认无误，收入题库';
  }

  String? get _qualityGateReason {
    if (ImportReviewBlockingPolicy.isBlocked(_state.reviewResult)) {
      return '题目结构错误，请修正或删除后再入库';
    }
    return null;
  }

  bool get _isStemOnlyDocument =>
      _diagnostics?['documentRole']?.toString() == 'stemOnly';

  /// Builds the report the save flow and the success dialog use.
  ImportReviewReport buildCommitReport() =>
      ImportReviewReportBuilder.build(_state.allItems, _state.reviewResult);

  /// Per-filter item counts for the review toolbar.
  Map<ImportReviewFilter, int> get filterCounts =>
      ImportReviewFilterService.countByFilter(
        items: _state.allItems,
        analysis: _state.reviewResult,
      );

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Builds the initial review state.
  ///
  /// Returns whether the page must schedule a follow-up review-draft persist
  /// after the first frame (locally extracted answers or normalized markers).
  bool initialize() {
    final retentionMode = _readReviewExplanationRetentionMode();
    final isDocumentImportEntryTaskMode = _isDocumentImportEntryTask();
    final formatted = ImportDiagnosticFormatter.format(
      warnings: _warnings,
      diagnostics: _diagnostics,
    );
    final List<ImportDiagnosticMessage> diagnosticMessages;
    if (formatted.isNotEmpty) {
      diagnosticMessages = formatted;
    } else {
      diagnosticMessages = _readImportDiagnostics(_parsedQuestions)
          .map((warning) => ImportDiagnosticMessage(
                severity: ImportDiagnosticSeverity.warning,
                title: '导入警告',
                message: warning,
              ))
          .toList();
    }
    final historicalGateMessage = _historicalQualityGateMessage();

    final allItems = _parsedQuestions
        .asMap()
        .entries
        .map((entry) => ImportReviewItem.fromMap(entry.value, entry.key))
        .toList();
    final restored = _restoreReviewDraftMarkers(_parsedQuestions);
    final snapshots = _decodePresentationSnapshots(restored);
    final analysis = ImportReviewAnalyzer.analyzeItems(allItems);
    _state = ImportReviewViewState(
      allItems: allItems,
      visibleItems: ImportReviewFilterService.apply(
        items: allItems,
        analysis: analysis,
        filter: ImportReviewFilter.all,
        sort: ImportReviewSort.originalOrder,
      ),
      reviewResult: analysis,
      activeFilter: ImportReviewFilter.all,
      activeSort: ImportReviewSort.originalOrder,
      isSaving: false,
      selectionMode: false,
      selectedOriginalIndices: const <int>{},
      explanationRetentionMode: retentionMode,
      isDocumentImportEntryTask: isDocumentImportEntryTaskMode,
      diagnosticMessages: historicalGateMessage == null
          ? List<ImportDiagnosticMessage>.unmodifiable(diagnosticMessages)
          : List<ImportDiagnosticMessage>.unmodifiable(
              <ImportDiagnosticMessage>[
                ...diagnosticMessages,
                historicalGateMessage,
              ],
            ),
      existingFolders: const <String>[],
      presentationSnapshots: snapshots,
      explanationProvenance: restored.explanationProvenance,
      answerDistillationStatuses: restored.answerDistillationStatuses,
      isDistillingAnswers: false,
      answerDistillationCancellationRequested: false,
      answerDistillationCompletedCount: 0,
      answerDistillationTotalCount: 0,
      activeAnswerDistillationIndex: null,
      activeRepairIndex: null,
      autoRepairProposalIndices: const <int>{},
    );
    _snapshotProvenance = restored.snapshotProvenance;
    _reviewItemIds = restored.reviewItemIds;
    _explanationOverrides = restored.explanationOverrides;
    _answerDistillationReasons = restored.answerDistillationReasons;
    _repairEdits = restored.repairEdits;

    final extractedLocally = _applyLocalSubjectiveAnswers();
    _reapplyExplanationPolicy();
    unawaited(loadExistingFolders());
    return extractedLocally || restored.normalizationNeeded;
  }

  /// Loads the folder names offered by the save-location dialog.
  Future<void> loadExistingFolders() async {
    final folders =
        await _folderQuery?.listAvailableFolders() ?? const <String>[];
    _setState(
      _state.copyWith(existingFolders: List<String>.unmodifiable(folders)),
    );
  }

  /// Reads the fixed selection advanced preferences, then prepares at most the
  /// next eligible automatic LaTeX repair proposal.
  Future<void> initializeAutoLatexRepair(
    ImportAdvancedPreferencesLoader loader,
  ) async {
    final ImportAdvancedPreferences preferences;
    try {
      preferences = await loader();
    } catch (_) {
      return;
    }
    if (_disposed || !preferences.effectiveLatexRepairEnabled) return;
    _autoRepairEnabled = true;
    await _prepareNextAutoLatexProposal();
  }

  /// Prepares at most the next eligible question, then waits for the user.
  ///
  /// Preparing every eligible question up front saved the draft after each
  /// proposal, and every save advances the draft-wide revision, so all but the
  /// last prepared proposal went stale and had to be regenerated when opened
  /// (~2N provider calls for N questions). A ready proposal therefore anchors
  /// to the revision the user is about to act on; the walk resumes once that
  /// question is applied or skipped.
  Future<void> _prepareNextAutoLatexProposal() async {
    if (!_autoRepairEnabled || _autoRepairPreparing) return;
    for (final item in List<ImportReviewItem>.of(_state.allItems)) {
      if (_disposed) return;
      if (_autoRepairSettled.contains(item.originalIndex)) continue;
      final target = _reviewRepairTargetFor(item);
      if (target == null || !_isAutoLatexRepairTarget(target)) {
        _autoRepairSettled.add(item.originalIndex);
        continue;
      }
      final cached = _autoRepairProposals[item.originalIndex];
      if (cached != null && _isRepairProposalReusable(item, cached)) {
        _autoRepairSettled.add(item.originalIndex);
        continue;
      }
      _autoRepairSettled.add(item.originalIndex);
      _autoRepairPreparing = true;
      try {
        await requestReviewRepair(item, automatic: true);
      } finally {
        _autoRepairPreparing = false;
      }
      if (_disposed) return;
      // A ready proposal waits for the user. A generation that produced
      // nothing lets the walk continue with the next eligible question.
      if (_autoRepairProposals.containsKey(item.originalIndex)) return;
    }
  }

  /// Whether [target] is the LaTeX anomaly the automatic walk prepares.
  bool _isAutoLatexRepairTarget(ReviewRepairTarget target) =>
      target.strategy == ReviewRepairStrategy.latexFragment ||
      (target.triggerCodes.length == 1 &&
          target.triggerCodes.single == 'dangling_latex');

  ExplanationRetentionMode _readReviewExplanationRetentionMode() {
    final value =
        _diagnostics?[TaskManager.keyReviewExplanationRetentionMode] ??
            _diagnostics?[TaskManager.keyExplanationRetentionMode];
    if (value == null) return _initialExplanationRetentionMode;
    return parseExplanationRetentionMode(value);
  }

  /// Whether this task fixes explanation retention, i.e. came from the
  /// document import entry.
  ///
  /// This reads explicit entry provenance, never the retention state. Photo
  /// capture also dispatches through the import task coordinator, so it
  /// records retention diagnostics too while still running at subjectiveOnly;
  /// judging the entry by retention would hide the only control that can
  /// restore a recognized objective explanation on a photo-capture task. A
  /// task without the marker keeps the controls that describe its own recorded
  /// policy.
  bool _isDocumentImportEntryTask() {
    return isDocumentImportEntryDiagnostics(_diagnostics);
  }

  ImportDiagnosticMessage? _historicalQualityGateMessage() {
    final gate = _diagnostics?['qualityGate'];
    if (gate is! Map || gate['blocked'] != true) return null;
    return ImportDiagnosticMessage(
      severity: ImportDiagnosticSeverity.warning,
      title: '初始质量门禁',
      message: '初始解析曾被质量门禁标记为阻断；最终门禁以当前校对结果为准。',
      source: 'quality_gate',
      code: 'HISTORICAL_GATE_BLOCKED',
    );
  }

  List<String> _readImportDiagnostics(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) return const [];

    final raw = questions.first['_import_diagnostics'];
    if (raw is List) {
      return raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    return const [];
  }

  _RestoredReviewMarkers _restoreReviewDraftMarkers(
    List<Map<String, dynamic>> questions,
  ) {
    var normalizationNeeded = false;
    final snapshotProvenance = <int, Map<String, dynamic>>{};
    final reviewItemIds = <int, String>{};
    final explanationOverrides = <int, QuestionExplanationOverride>{};
    final explanationProvenance = <int, ExplanationEditProvenance>{};
    final answerDistillationStatuses = <int, String>{};
    final answerDistillationReasons = <int, String>{};
    final repairEdits = <int, ReviewRepairEdit>{};
    for (var index = 0; index < questions.length; index++) {
      final source = questions[index];
      snapshotProvenance[index] = <String, dynamic>{
        for (final key in _safeSnapshotProvenanceKeys)
          if (source.containsKey(key)) key: source[key],
      };
      final storedItemId = source[TaskManager.keyReviewItemId]?.toString();
      String? envelopeReviewItemId;
      final envelope = source[TypedReviewSnapshotCodec.mapKey];
      if (envelope is Map && envelope['reviewItemId'] is String) {
        envelopeReviewItemId = envelope['reviewItemId'] as String;
      }
      reviewItemIds[index] = storedItemId ??
          envelopeReviewItemId ??
          '${_taskId ?? 'local'}:${source['question_number'] ?? source['q_num'] ?? 'unknown'}:$index';
      normalizationNeeded |= storedItemId == null;
      final override = questions[index][_explanationOverrideKey]?.toString();
      for (final value in QuestionExplanationOverride.values) {
        if (value.name == override) {
          explanationOverrides[index] = value;
          break;
        }
      }
      // Missing or unrecognized marker reads as legacyUnknown: an older draft
      // may have been edited before provenance existed, and absence must never
      // be upgraded to "untouched".
      explanationProvenance[index] = decodeExplanationEditProvenance(
        questions[index][TaskManager.keyExplanationEditProvenance],
      );
      final status = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeStatus(
        questions[index][TaskManager.keyAnswerDistillationStatus],
      );
      if (status != null) {
        answerDistillationStatuses[index] = status;
      }
      final repairEdit = ReviewRepairEdit.fromMap(
        questions[index][TaskManager.keyReviewRepairEdit],
      );
      if (repairEdit != null) {
        repairEdits[index] = repairEdit;
      }
      final reason = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
        status: status,
        value: questions[index][TaskManager.keyAnswerDistillationReason],
      );
      if (reason != null) {
        answerDistillationReasons[index] = reason;
      }
    }
    return _RestoredReviewMarkers(
      normalizationNeeded: normalizationNeeded,
      snapshotProvenance: snapshotProvenance,
      reviewItemIds: reviewItemIds,
      explanationOverrides: explanationOverrides,
      explanationProvenance: Map<int, ExplanationEditProvenance>.unmodifiable(
        explanationProvenance,
      ),
      answerDistillationStatuses: Map<int, String>.unmodifiable(
        answerDistillationStatuses,
      ),
      answerDistillationReasons: answerDistillationReasons,
      repairEdits: repairEdits,
    );
  }

  Map<int, TypedReviewSnapshot> _decodePresentationSnapshots(
    _RestoredReviewMarkers restored,
  ) {
    // Presentation decoding never repairs metadata or changes commit routing.
    const snapshotCodec = TypedReviewSnapshotCodec();
    final snapshots = <int, TypedReviewSnapshot>{};
    for (final entry in restored.snapshotProvenance.entries) {
      try {
        // Read exactly the value the commit path reads. Canonical persistence
        // stores the envelope itself under the reserved key, so accepting a
        // second nested layer here would let the preview render typed content
        // that the commit then rejects, and would widen a fail-closed contract
        // in the UI only.
        final snapshot = snapshotCodec.decodeRequired(
          entry.value[TypedReviewSnapshotCodec.mapKey],
        );
        // Mirror TypedReviewResultBuilder's static identity/baseline checks.
        // Compare the frozen baseline, not the user's editable current type.
        final baselineType = switch (snapshot.draft.kind) {
          QuestionKind.singleChoice => 0,
          QuestionKind.fillBlank => 2,
          QuestionKind.shortAnswer => 3,
        };
        if (restored.reviewItemIds[entry.key] != snapshot.reviewItemId ||
            snapshot.baselineLegacy.questionNumber !=
                snapshot.draft.questionNumber ||
            snapshot.baselineLegacy.type != baselineType) {
          continue;
        }
        snapshots[entry.key] = snapshot;
      } on TypedReviewSnapshotException {
        // Keep the original envelope for the existing fail-closed commit gate.
      }
    }
    return Map<int, TypedReviewSnapshot>.unmodifiable(snapshots);
  }

  bool _applyLocalSubjectiveAnswers() {
    if (_isStemOnlyDocument) return false;
    const extractor = SubjectiveAnswerExtractor();
    const expectationPolicy = SubjectiveAnswerExpectationPolicy();
    var changed = false;
    final items = List<ImportReviewItem>.of(_state.allItems);
    final statuses = Map<int, String>.of(_state.answerDistillationStatuses);
    final reasons = Map<int, String>.of(_answerDistillationReasons);

    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final question = item.draft;
      if (question.type != QuestionType.shortAnswer) continue;

      final expectation = expectationPolicy.classify(question);
      if (expectation == SubjectiveAnswerExpectation.proofExplanation &&
          question.explanation.trim().isNotEmpty) {
        if (statuses[item.originalIndex] != 'proof_explanation_recognized') {
          statuses[item.originalIndex] = 'proof_explanation_recognized';
          reasons.remove(item.originalIndex);
          changed = true;
        }
        continue;
      }

      final result = extractor.extract(
        questionNumber: item.originalIndex + 1,
        content: question.content,
        standardAnswer: question.standardAnswer,
        explanation: question.explanation,
      );
      if (!result.matched || result.answer == null) continue;

      items[index] = item.copyWith(
        draft: question.copyWith(standardAnswer: result.answer),
      );
      statuses[item.originalIndex] = 'local_extracted';
      reasons.remove(item.originalIndex);
      changed = true;
    }
    if (changed) {
      _answerDistillationReasons = reasons;
      _setItems(items, answerDistillationStatuses: statuses);
    }
    return changed;
  }

  /// Finalizes one review item under the current retention policy.
  ///
  /// This is the single finalization path shared by the document retention
  /// toggle and the AI repair apply step, so an applied repair produces exactly
  /// the values that a policy re-apply would produce.
  ImportReviewItem _finalizeReviewItem(ImportReviewItem item) {
    final question = <String, dynamic>{
      ...item.draft.toMap(),
    };
    final persistedMetadata = item.toPersistedMetadata();
    if (persistedMetadata != null) {
      question[ImportReviewMetadata.key] = persistedMetadata;
    }
    final finalized = finalizeAndAuditImportQuestion(
      question,
      mode: _state.explanationRetentionMode,
      override: _explanationOverrides[item.originalIndex] ??
          QuestionExplanationOverride.inherit,
    );
    final finalizedItem =
        ImportReviewItem.fromMap(finalized, item.originalIndex);
    final projectionState = switch (item.metadataProjectionState) {
      ImportReviewMetadataProjectionState.unavailable =>
        ImportReviewMetadataProjectionState.unavailable,
      ImportReviewMetadataProjectionState.available =>
        finalizedItem.metadataProjectionState,
      ImportReviewMetadataProjectionState.notProvided =>
        finalizedItem.metadata.hasMeaningfulReviewMetadata
            ? ImportReviewMetadataProjectionState.available
            : ImportReviewMetadataProjectionState.notProvided,
    };
    return finalizedItem.copyWith(metadataProjectionState: projectionState);
  }

  void _reapplyExplanationPolicy() {
    _setItems(_state.allItems.map(_finalizeReviewItem).toList());
  }

  // ---------------------------------------------------------------------------
  // State plumbing
  // ---------------------------------------------------------------------------

  void _setState(ImportReviewViewState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  /// Replaces the working item list and recomputes the derived review state
  /// (analysis plus the visible projection under the active filter/sort).
  void _setItems(
    List<ImportReviewItem> items, {
    Map<int, TypedReviewSnapshot>? snapshots,
    Map<int, ExplanationEditProvenance>? explanationProvenance,
    Map<int, String>? answerDistillationStatuses,
    Set<int>? autoRepairProposalIndices,
    ImportReviewFilter? filter,
    ImportReviewSort? sort,
  }) {
    final nextFilter = filter ?? _state.activeFilter;
    final nextSort = sort ?? _state.activeSort;
    final analysis = ImportReviewAnalyzer.analyzeItems(items);
    _setState(
      _state.copyWith(
        allItems: items,
        visibleItems: ImportReviewFilterService.apply(
          items: items,
          analysis: analysis,
          filter: nextFilter,
          sort: nextSort,
        ),
        reviewResult: analysis,
        activeFilter: nextFilter,
        activeSort: nextSort,
        presentationSnapshots: snapshots,
        explanationProvenance: explanationProvenance,
        answerDistillationStatuses: answerDistillationStatuses,
        autoRepairProposalIndices: autoRepairProposalIndices,
      ),
    );
  }

  void _publishAutoRepairProposals() {
    _setState(
      _state.copyWith(
        autoRepairProposalIndices:
            Set<int>.unmodifiable(_autoRepairProposals.keys),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Selection and batch actions
  // ---------------------------------------------------------------------------

  void enterSelectionMode() {
    if (_state.isSaving) return;
    _setState(
      _state.copyWith(
        selectionMode: true,
        selectedOriginalIndices: const <int>{},
      ),
    );
  }

  void exitSelectionMode() {
    _setState(
      _state.copyWith(
        selectionMode: false,
        selectedOriginalIndices: const <int>{},
      ),
    );
  }

  void toggleSelection(ImportReviewItem item) {
    final next = Set<int>.of(_state.selectedOriginalIndices);
    if (!next.remove(item.originalIndex)) {
      next.add(item.originalIndex);
    }
    _setState(_state.copyWith(selectedOriginalIndices: next));
  }

  void selectAllVisible() {
    final next = Set<int>.of(_state.selectedOriginalIndices);
    for (final visible in _state.visibleItems) {
      next.add(visible.item.originalIndex);
    }
    _setState(_state.copyWith(selectedOriginalIndices: next));
  }

  void deleteSelected() {
    final nextItems = ImportReviewBatchController.deleteSelected(
      items: _state.allItems,
      selectedOriginalIndices: _state.selectedOriginalIndices,
    );
    _applyBatchResult(nextItems);
  }

  void changeSelectedType(QuestionType targetType) {
    if (_state.isSaving) return;
    final nextItems = ImportReviewBatchController.changeTypeSelected(
      items: _state.allItems,
      selectedOriginalIndices: _state.selectedOriginalIndices,
      targetType: targetType,
    );
    _applyBatchResult(nextItems);
  }

  /// Removes one item (swipe-to-dismiss), keeping every other association.
  void removeReviewItem(ImportReviewItem item) {
    if (_state.isSaving) return;
    final nextItems = _state.allItems
        .where((candidate) => candidate.originalIndex != item.originalIndex)
        .toList();
    _setItems(nextItems);
    unawaited(persistReviewDraft());
  }

  void _applyBatchResult(List<ImportReviewItem> nextItems) {
    if (_state.isSaving) return;
    final finalized = nextItems.map(_finalizeReviewItem).toList();
    _setItems(finalized);
    _setState(
      _state.copyWith(
        selectionMode: false,
        selectedOriginalIndices: const <int>{},
      ),
    );
    unawaited(persistReviewDraft());
  }

  // ---------------------------------------------------------------------------
  // Filter and sort
  // ---------------------------------------------------------------------------

  void setFilter(ImportReviewFilter filter) {
    _setItems(_state.allItems, filter: filter);
    _setState(
      _state.copyWith(
        selectionMode: false,
        selectedOriginalIndices: const <int>{},
      ),
    );
  }

  void setSort(ImportReviewSort sort) {
    _setItems(_state.allItems, sort: sort);
    _setState(
      _state.copyWith(
        selectionMode: false,
        selectedOriginalIndices: const <int>{},
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Explanation retention and editing
  // ---------------------------------------------------------------------------

  void setDocumentExplanationRetention(bool retainObjectiveExplanations) {
    if (_state.isSaving) return;
    _setState(
      _state.copyWith(
        explanationRetentionMode: retainObjectiveExplanations
            ? ExplanationRetentionMode.allQuestionTypes
            : ExplanationRetentionMode.subjectiveOnly,
      ),
    );
    _reapplyExplanationPolicy();
    unawaited(persistReviewDraft());
  }

  void setQuestionExplanationRetention(ImportReviewItem item, bool retain) {
    if (_state.isSaving) return;
    _explanationOverrides[item.originalIndex] = retain
        ? QuestionExplanationOverride.keep
        : QuestionExplanationOverride.discard;
    _reapplyExplanationPolicy();
    unawaited(persistReviewDraft());
  }

  bool isQuestionExplanationRetained(ImportReviewItem item) {
    return const ImportQuestionFieldPolicy().shouldRetainExplanation(
      type: item.draft.type.code,
      mode: _state.explanationRetentionMode,
      override: _explanationOverrides[item.originalIndex] ??
          QuestionExplanationOverride.inherit,
    );
  }

  /// The text the explanation editor must be seeded with for one item.
  ///
  /// The typed and legacy explanations are different representations of the
  /// same visible content, so the seed is the resolved review content, never
  /// the raw stored text.
  String explanationEditorSeed(ImportReviewItem item) {
    final snapshot = _state.presentationSnapshots[item.originalIndex];
    final provenance = _state.explanationProvenance[item.originalIndex] ??
        ExplanationEditProvenance.legacyUnknown;
    final typed = resolveExplanationReviewContent(
      originalContent: snapshot?.draft.explanation,
      baselineText: snapshot?.baselineLegacy.explanation ?? '',
      currentText: item.draft.explanation,
      retained: isQuestionExplanationRetained(item),
      provenance: provenance,
    );
    return typed == null
        ? item.draft.explanation
        : const RichContentTextProjection().project(typed);
  }

  /// Records one direct user edit of the explanation content.
  ///
  /// Calling this means a real manual edit has already been confirmed: the
  /// caller established that the interaction changed the editor's seed. It must
  /// not re-derive that from text, because the typed and legacy explanations are
  /// different representations and a user edit whose result happens to equal
  /// the stored legacy text would otherwise be silently discarded.
  ///
  /// The edited value is kept as exact literal text and is never reparsed into
  /// typed nodes.
  void saveManualExplanationEdit(ImportReviewItem item, String edited) {
    if (_state.isSaving) return;
    final items = _state.allItems
        .map(
          (candidate) => identical(candidate, item)
              ? candidate.copyWith(
                  draft: candidate.draft.copyWith(explanation: edited),
                )
              : candidate,
        )
        .toList();
    final provenance =
        Map<int, ExplanationEditProvenance>.of(_state.explanationProvenance)
          ..[item.originalIndex] = markExplanationManuallyEdited();
    _setItems(
      items,
      explanationProvenance: Map<int, ExplanationEditProvenance>.unmodifiable(
        provenance,
      ),
    );
    unawaited(persistReviewDraft());
  }

  // ---------------------------------------------------------------------------
  // Review draft persistence
  // ---------------------------------------------------------------------------

  Future<T> _enqueueReviewDraftOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _reviewDraftOperationTail = _reviewDraftOperationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Persists the current review draft through the task manager.
  ///
  /// Returns the save result, or null when the page has no durable task.
  Future<ReviewDraftSaveResult?> persistReviewDraft({
    bool showFailurePrompt = true,
  }) {
    final taskId = _taskId;
    if (taskId == null || taskId.trim().isEmpty) {
      return Future<ReviewDraftSaveResult?>.value();
    }

    return _enqueueReviewDraftOperation(() async {
      final questions = _state.allItems.map((item) {
        final question = <String, dynamic>{
          ...?_snapshotProvenance[item.originalIndex],
          ...item.draft.toMap(),
          TaskManager.keyReviewItemId: _reviewItemIds[item.originalIndex],
          _explanationOverrideKey: (_explanationOverrides[item.originalIndex] ??
                  QuestionExplanationOverride.inherit)
              .name,
        };
        final persistedMetadata = item.toPersistedMetadata();
        if (persistedMetadata != null) {
          question[ImportReviewMetadata.key] = persistedMetadata;
        }
        // legacyUnknown has no persisted token, so an old draft keeps its
        // unknown state instead of being silently upgraded on the next save.
        final provenance = encodeExplanationEditProvenance(
          _state.explanationProvenance[item.originalIndex] ??
              ExplanationEditProvenance.legacyUnknown,
        );
        if (provenance != null) {
          question[TaskManager.keyExplanationEditProvenance] = provenance;
        }

        final status =
            SubjectiveAnswerDistillationSnapshotPolicy.sanitizeStatus(
          _state.answerDistillationStatuses[item.originalIndex],
        );
        if (status != null) {
          question[TaskManager.keyAnswerDistillationStatus] = status;
        }
        final reason =
            SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
          status: status,
          value: _answerDistillationReasons[item.originalIndex],
        );
        if (reason != null) {
          question[TaskManager.keyAnswerDistillationReason] = reason;
        }
        final repairEdit = _repairEdits[item.originalIndex];
        if (repairEdit != null && repairEdit.isNotEmpty) {
          question[TaskManager.keyReviewRepairEdit] = repairEdit.toMap();
        }
        return question;
      }).toList(growable: false);

      final result = await _taskManager.saveReviewDraft(
        taskId,
        questions: questions,
        explanationRetentionMode: _state.explanationRetentionMode,
      );
      if (!result.saved && showFailurePrompt) {
        effects.showMessage('校对结果尚未保存，请重试');
      }
      return result;
    });
  }

  // ---------------------------------------------------------------------------
  // AI answer distillation
  // ---------------------------------------------------------------------------

  List<ImportReviewItem> get _answerDistillationCandidates {
    return _state.allItems
        .where(
          (item) => _answerDistillationPolicy.isCandidate(
            item.draft,
            isStemOnly: _isStemOnlyDocument,
          ),
        )
        .toList(growable: false);
  }

  int get answerDistillationCandidateCount =>
      _answerDistillationCandidates.length;

  bool isAnswerDistillationCandidate(ImportReviewItem item) {
    return _answerDistillationPolicy.isCandidate(
      item.draft,
      isStemOnly: _isStemOnlyDocument,
    );
  }

  SubjectiveAnswerDistiller get _resolvedAnswerDistiller {
    final resolved = _answerDistiller;
    if (resolved != null) return resolved;
    final factory = _answerDistillerFactory;
    if (factory == null) {
      throw StateError('No answer distiller available for this review page.');
    }
    return _answerDistiller = factory();
  }

  ReviewRepairGenerator get _resolvedRepairGenerator {
    final resolved = _repairGenerator;
    if (resolved != null) return resolved;
    final factory = _repairGeneratorFactory;
    if (factory == null) {
      throw StateError('No review repair generator available for this page.');
    }
    return _repairGenerator = factory();
  }

  Future<SubjectiveAnswerDistillationResult> _distillAnswer(
    ImportReviewItem item, {
    required Duration timeout,
  }) async {
    try {
      return await _resolvedAnswerDistiller.distill(
        questionNumber: item.originalIndex + 1,
        question: item.draft,
        isStemOnly: _isStemOnlyDocument,
        timeout: timeout,
      );
    } catch (error) {
      return SubjectiveAnswerDistillationResult.failed(
        diagnostics: [
          'answer_distillation_failed',
          'answer_distillation_failure_type:${error.runtimeType}',
        ],
      );
    }
  }

  bool _applyDistillationResult(
    int originalIndex,
    SubjectiveAnswerDistillationResult result,
  ) {
    final answer = result.standardAnswer?.trim();
    if (result.applied && (answer == null || answer.isEmpty)) return false;

    final itemIndex = _state.allItems.indexWhere(
      (item) => item.originalIndex == originalIndex,
    );
    if (itemIndex < 0) return false;
    final items = List<ImportReviewItem>.of(_state.allItems);
    final statuses = Map<int, String>.of(_state.answerDistillationStatuses);
    final reasons = Map<int, String>.of(_answerDistillationReasons);
    if (result.applied) {
      final current = items[itemIndex];
      items[itemIndex] = current.copyWith(
        draft: current.draft.copyWith(standardAnswer: answer),
      );
      reasons.remove(originalIndex);
    } else {
      final reason = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
        status: result.snapshotStatus,
        value: result.safeReasonCode,
      );
      if (reason == null) {
        reasons.remove(originalIndex);
      } else {
        reasons[originalIndex] = reason;
      }
    }
    statuses[originalIndex] = result.snapshotStatus;
    _answerDistillationReasons = reasons;
    _setItems(items, answerDistillationStatuses: statuses);
    return true;
  }

  Future<bool> _mergeDistillationResult(
    ImportReviewItem item,
    SubjectiveAnswerDistillationResult result, {
    required int? expectedRevision,
  }) async {
    final answer = result.standardAnswer?.trim();
    if (result.applied && (answer == null || answer.isEmpty)) return false;

    final taskId = _taskId;
    if (taskId == null || taskId.trim().isEmpty) {
      if (_disposed) return false;
      return _applyDistillationResult(item.originalIndex, result);
    }
    if (expectedRevision == null) return false;

    return _enqueueReviewDraftOperation(() async {
      final saveResult = await _taskManager.mergeReviewDraftAnswerDistillation(
        taskId,
        reviewItemId: _reviewItemIds[item.originalIndex]!,
        expectedRevision: expectedRevision,
        standardAnswer: result.applied ? answer : null,
        status: result.snapshotStatus,
        reasonCode: result.safeReasonCode,
      );
      if (!saveResult.saved) {
        if (!_disposed && saveResult.status == ReviewDraftSaveStatus.failed) {
          effects.showMessage('答案已生成，但校对快照保存失败');
        }
        return false;
      }
      return _applyDistillationResult(item.originalIndex, result);
    });
  }

  Future<void> distillSingleAnswer(ImportReviewItem item) async {
    if (_state.isSaving ||
        _state.isDistillingAnswers ||
        !isAnswerDistillationCandidate(item)) {
      return;
    }
    final operationId = ++_answerDistillationOperationId;
    _answerDistillationCancellationRequested = false;
    _setState(
      _state.copyWith(
        isDistillingAnswers: true,
        answerDistillationCancellationRequested: false,
        answerDistillationCompletedCount: 0,
        answerDistillationTotalCount: 1,
        activeAnswerDistillationIndex: item.originalIndex,
      ),
    );

    final baseSnapshot = await persistReviewDraft();
    if (_taskId != null && baseSnapshot?.saved != true) {
      if (_disposed || operationId != _answerDistillationOperationId) return;
      _setState(
        _state.copyWith(
          isDistillingAnswers: false,
          clearActiveAnswerDistillationIndex: true,
        ),
      );
      return;
    }
    final result = await _distillAnswer(
      item,
      timeout: const Duration(seconds: 30),
    );
    if (!_disposed && operationId != _answerDistillationOperationId) return;

    final recorded = await _mergeDistillationResult(
      item,
      result,
      expectedRevision: baseSnapshot?.revision,
    );
    if (_disposed || operationId != _answerDistillationOperationId) return;
    _setState(
      _state.copyWith(
        answerDistillationCompletedCount: 1,
        isDistillingAnswers: false,
        clearActiveAnswerDistillationIndex: true,
      ),
    );
    effects.showMessage(
      _answerDistillationOutcomeMessage(
        single: true,
        appliedCount: recorded && result.applied ? 1 : 0,
        rejectedCount: recorded &&
                result.outcome == SubjectiveAnswerDistillationOutcome.rejected
            ? 1
            : 0,
        failedCount: !recorded ||
                result.outcome == SubjectiveAnswerDistillationOutcome.failed
            ? 1
            : 0,
      ),
    );
  }

  Future<void> distillAllAnswers() async {
    if (_state.isSaving || _state.isDistillingAnswers) return;
    final candidates = _answerDistillationCandidates;
    if (candidates.isEmpty) return;

    final operationId = ++_answerDistillationOperationId;
    final stopwatch = Stopwatch()..start();
    var appliedCount = 0;
    var rejectedCount = 0;
    var failedCount = 0;
    _answerDistillationCancellationRequested = false;
    _setState(
      _state.copyWith(
        isDistillingAnswers: true,
        answerDistillationCancellationRequested: false,
        answerDistillationCompletedCount: 0,
        answerDistillationTotalCount: candidates.length,
        clearActiveAnswerDistillationIndex: true,
      ),
    );

    for (var index = 0; index < candidates.length; index++) {
      if (_answerDistillationCancellationRequested) break;
      final remaining = const Duration(seconds: 90) - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      final timeout = remaining.compareTo(const Duration(seconds: 30)) < 0
          ? remaining
          : const Duration(seconds: 30);
      final candidate = candidates[index];
      if (_disposed || operationId != _answerDistillationOperationId) return;
      _setState(
        _state.copyWith(
          activeAnswerDistillationIndex: candidate.originalIndex,
        ),
      );

      final baseSnapshot = await persistReviewDraft();
      if (_taskId != null && baseSnapshot?.saved != true) break;
      final result = await _distillAnswer(candidate, timeout: timeout);
      // The merge below is intentionally still attempted when the page is gone:
      // it only persists the already-generated answer through the existing CAS.
      if (!_disposed && operationId != _answerDistillationOperationId) return;
      final recorded = await _mergeDistillationResult(
        candidate,
        result,
        expectedRevision: baseSnapshot?.revision,
      );
      if (recorded) {
        switch (result.outcome) {
          case SubjectiveAnswerDistillationOutcome.applied:
            appliedCount++;
            break;
          case SubjectiveAnswerDistillationOutcome.rejected:
            rejectedCount++;
            break;
          case SubjectiveAnswerDistillationOutcome.failed:
            failedCount++;
            break;
        }
      } else {
        failedCount++;
      }
      if (_disposed || operationId != _answerDistillationOperationId) return;
      _setState(
        _state.copyWith(answerDistillationCompletedCount: index + 1),
      );
      if (_answerDistillationCancellationRequested) break;
    }
    stopwatch.stop();
    if (_disposed || operationId != _answerDistillationOperationId) return;
    final cancelled = _answerDistillationCancellationRequested;
    _setState(
      _state.copyWith(
        isDistillingAnswers: false,
        clearActiveAnswerDistillationIndex: true,
      ),
    );
    effects.showMessage(
      _answerDistillationOutcomeMessage(
        cancelled: cancelled,
        appliedCount: appliedCount,
        rejectedCount: rejectedCount,
        failedCount: failedCount,
      ),
    );
  }

  void cancelAnswerDistillation() {
    if (!_state.isDistillingAnswers) return;
    _answerDistillationCancellationRequested = true;
    _setState(
      _state.copyWith(answerDistillationCancellationRequested: true),
    );
  }

  String _answerDistillationOutcomeMessage({
    required int appliedCount,
    required int rejectedCount,
    required int failedCount,
    bool cancelled = false,
    bool single = false,
  }) {
    return cancelled
        ? '已停止生成：补全 $appliedCount 道，未提炼 $rejectedCount 道，失败 $failedCount 道'
        : single && appliedCount == 1
            ? '标准答案已生成'
            : single && rejectedCount == 1
                ? '解析中未找到可安全提炼的明确答案'
                : single && failedCount == 1
                    ? '标准答案生成失败，可重试'
                    : '处理完成：补全 $appliedCount 道，未提炼 $rejectedCount 道，失败 $failedCount 道';
  }

  // ---------------------------------------------------------------------------
  // AI review repair
  // ---------------------------------------------------------------------------

  int _reviewItemPosition(ImportReviewItem item) {
    return _state.allItems
        .indexWhere((candidate) => identical(candidate, item));
  }

  ReviewRepairTarget? _reviewRepairTargetFor(ImportReviewItem item) {
    final position = _reviewItemPosition(item);
    if (position < 0) return null;
    return _reviewRepairPolicy.targetFor(
      originalIndex: item.originalIndex,
      questionNumber: item.originalIndex + 1,
      draft: item.draft,
      metadata: item.metadata,
      metadataProjectionState: item.metadataProjectionState,
      issues: _state.reviewResult.issues
          .where((issue) => issue.questionIndex == position)
          .toList(growable: false),
      hasTypedSnapshot:
          _state.presentationSnapshots.containsKey(item.originalIndex),
    );
  }

  bool isReviewRepairEligible(ImportReviewItem item) =>
      _reviewRepairTargetFor(item) != null;

  /// Whether a cached proposal can still be applied without regenerating.
  ///
  /// The revision anchor is draft-wide: saving or repairing any other question
  /// moves it, so a proposal kept across that change could only fail closed at
  /// the CAS. Regenerating is the only way it can still be applied.
  bool _isRepairProposalReusable(
    ImportReviewItem item,
    ReviewRepairProposal proposal,
  ) {
    if (proposal.isStaleFor(item.draft)) return false;
    final taskId = _taskId?.trim() ?? '';
    if (taskId.isEmpty) return true;
    return proposal.request.expectedRevision ==
        _taskManager.reviewDraftRevision(taskId);
  }

  /// Generates (or reuses) a proposal for one eligible item.
  ///
  /// Generating never mutates the review items: the item is only replaced after
  /// the user accepts a proposal. The proposal dialog is rendered by the page
  /// through [ImportReviewEffects.confirmRepairProposal].
  Future<void> requestReviewRepair(
    ImportReviewItem item, {
    bool automatic = false,
  }) async {
    if (_state.isSaving ||
        _state.activeRepairIndex != null ||
        _state.isDistillingAnswers) {
      return;
    }
    if (!automatic) _autoRepairSettled.add(item.originalIndex);
    final cached = _autoRepairProposals[item.originalIndex];
    if (!automatic &&
        cached != null &&
        _isRepairProposalReusable(item, cached)) {
      final apply = await effects.confirmRepairProposal(cached);
      if (!_disposed && apply == true) {
        await _applyReviewRepairProposal(item, cached);
        _autoRepairProposals.remove(item.originalIndex);
        _publishAutoRepairProposals();
      }
      unawaited(_prepareNextAutoLatexProposal());
      return;
    }
    _autoRepairProposals.remove(item.originalIndex);
    _publishAutoRepairProposals();
    final target = _reviewRepairTargetFor(item);
    if (target == null) return;

    _setState(_state.copyWith(activeRepairIndex: item.originalIndex));
    final operationId = ++_repairOperationId;
    try {
      // Durability anchor: the CAS revision must be captured before the model
      // is called so a stale proposal can never be applied silently.
      final baseSnapshot = await persistReviewDraft(showFailurePrompt: false);
      if (_taskId != null && baseSnapshot?.saved != true) {
        if (_disposed || operationId != _repairOperationId) return;
        effects.showError(_reviewDraftUnsafeText);
        return;
      }
      final reviewItemId = _reviewItemIds[item.originalIndex];
      if (reviewItemId == null) {
        if (_disposed || operationId != _repairOperationId) return;
        effects.showError(_typedCommitBlockedText);
        return;
      }

      final result = await _resolvedRepairGenerator.generateProposal(
        request: ReviewRepairRequest(
          target: target,
          reviewItemId: reviewItemId,
          inputDraft: item.draft,
          expectedRevision: baseSnapshot?.revision,
        ),
        snapshot: _state.presentationSnapshots[item.originalIndex],
      );
      if (_disposed || operationId != _repairOperationId) return;
      final proposal = result.proposal;
      if (!result.hasProposal || proposal == null || !proposal.applicable) {
        if (!automatic) {
          effects.showError(_reviewRepairFailureText(result.outcome));
        }
        return;
      }
      if (automatic) {
        _autoRepairProposals[item.originalIndex] = proposal;
        _publishAutoRepairProposals();
        return;
      }
      // Generation is finished: the card leaves its loading state before the
      // proposal is reviewed. The modal dialog owns the interaction from here.
      _setState(_state.copyWith(clearActiveRepairIndex: true));
      final apply = await effects.confirmRepairProposal(proposal);
      if (_disposed || operationId != _repairOperationId) return;
      if (apply != true) return;
      await _applyReviewRepairProposal(item, proposal);
    } finally {
      if (!_disposed && operationId == _repairOperationId) {
        _setState(_state.copyWith(clearActiveRepairIndex: true));
      }
      // The user handled this question: preparation may continue with the next
      // eligible one against the now settled revision.
      if (!automatic) unawaited(_prepareNextAutoLatexProposal());
    }
  }

  /// Applies an accepted proposal through the existing review draft CAS.
  ///
  /// Any staleness, missing item or failed save performs zero mutation and
  /// reports a fixed failure instead of a success state.
  Future<void> _applyReviewRepairProposal(
    ImportReviewItem item,
    ReviewRepairProposal proposal,
  ) async {
    final position = _reviewItemPosition(item);
    if (position < 0) {
      effects.showError(_reviewRepairStaleText);
      return;
    }
    final current = _state.allItems[position];
    if (proposal.isStaleFor(current.draft)) {
      effects.showError(_reviewRepairStaleText);
      return;
    }

    final repaired = _finalizeReviewItem(
      current.copyWith(draft: proposal.proposedDraft),
    );
    final ReviewRepairEdit repairEdit;
    try {
      final fragment = proposal.fragment;
      repairEdit = fragment == null
          ? ReviewRepairEdit.applied(
              before: current.draft,
              after: repaired.draft,
              fields: proposal.changedFields,
            )
          : ReviewRepairEdit.latexFragment(
              before: current.draft,
              after: repaired.draft,
              target: fragment.target,
              replacementLatex: fragment.correctedLatex,
            );
    } on FormatException {
      effects.showError(_reviewRepairSaveFailedText);
      return;
    }

    final taskId = _taskId?.trim() ?? '';
    final expectedRevision = proposal.request.expectedRevision;
    if (taskId.isEmpty) {
      _replaceRepairedItem(position, item.originalIndex, repaired, repairEdit);
      effects.showMessage('AI 修补已应用，请复核后入库');
      return;
    }
    if (expectedRevision == null) {
      effects.showError(_reviewRepairSaveFailedText);
      return;
    }

    final saveResult = await _enqueueReviewDraftOperation(
      () => _taskManager.mergeReviewDraftRepair(
        taskId,
        reviewItemId: proposal.request.reviewItemId,
        expectedRevision: expectedRevision,
        content: repaired.draft.content,
        options: repaired.draft.options,
        standardAnswer: repaired.draft.standardAnswer,
        explanation: repaired.draft.explanation,
        reviewMetadata: repaired.toPersistedMetadata(),
        repairEdit: repairEdit,
      ),
    );
    if (_disposed) return;
    if (saveResult.status == ReviewDraftSaveStatus.stale ||
        saveResult.status == ReviewDraftSaveStatus.itemMissing ||
        saveResult.status == ReviewDraftSaveStatus.taskMissing) {
      effects.showError(_reviewRepairStaleText);
      return;
    }
    if (!saveResult.saved) {
      effects.showError(_reviewRepairSaveFailedText);
      return;
    }
    _replaceRepairedItem(position, item.originalIndex, repaired, repairEdit);
    effects.showMessage('AI 修补已应用，请复核后入库');
  }

  void _replaceRepairedItem(
    int position,
    int originalIndex,
    ImportReviewItem repaired,
    ReviewRepairEdit repairEdit,
  ) {
    final items = List<ImportReviewItem>.of(_state.allItems);
    items[position] = repaired;
    _repairEdits[originalIndex] = repairEdit;
    _setItems(items);
  }

  String _reviewRepairFailureText(ReviewRepairOutcome outcome) {
    return switch (outcome) {
      ReviewRepairOutcome.proposalReady => 'AI 修补未生成有效结果',
      ReviewRepairOutcome.notEligible => '本题当前不支持 AI 修补',
      ReviewRepairOutcome.noActiveEngine => '未配置可用的文本模型，无法执行 AI 修补',
      ReviewRepairOutcome.providerFailure => 'AI 修补请求失败，请稍后重试',
      ReviewRepairOutcome.invalidJson => 'AI 返回格式不符合要求，未生成修补建议',
      ReviewRepairOutcome.questionIdentityChanged => 'AI 返回的题号与原题不一致，已拒绝',
      ReviewRepairOutcome.unexpectedFieldChange => 'AI 修改了不允许修改的字段，已拒绝',
      ReviewRepairOutcome.unsupportedOptionChange => 'AI 改动了选项数量或标签，已拒绝',
      ReviewRepairOutcome.emptyResult => 'AI 未提出有效修改',
      ReviewRepairOutcome.structuralInvalid => 'AI 修补未通过结构校验，已拒绝',
      ReviewRepairOutcome.latexStillInvalid => 'LaTeX 仍无法可靠渲染，已拒绝',
      ReviewRepairOutcome.unsupportedTargetField =>
        '本题字段包含无法安全重建的内容，暂不支持 AI 修补',
      ReviewRepairOutcome.staleInput => _reviewRepairStaleText,
      ReviewRepairOutcome.fragmentTargetUnavailable =>
        '未能唯一定位需要修补的 LaTeX，请继续人工审核',
      ReviewRepairOutcome.invalidFragmentOutput => 'AI 未返回有效的 LaTeX 修补建议',
      ReviewRepairOutcome.fragmentRenderabilityFailed =>
        'AI 返回的 LaTeX 仍无法可靠渲染，已拒绝',
      ReviewRepairOutcome.fieldReauditFailed => 'LaTeX 修补未通过完整字段校验，已拒绝',
    };
  }

  // ---------------------------------------------------------------------------
  // Commit
  // ---------------------------------------------------------------------------

  /// Commits the current review items to [bankName] / [folderName].
  ///
  /// Resolves the storage route strictly, flushes the review draft and routes
  /// to the legacy or typed writer. Success and every failure are reported
  /// through [ImportReviewEffects].
  Future<void> commit({
    required String bankName,
    required String folderName,
  }) async {
    if (isBlockedByQualityGate) return;
    final report = buildCommitReport();
    final route = _resolveStorageRoute();
    if (route == null) {
      effects.showError(_invalidStorageRouteText);
      return;
    }
    if (route == ImportStorageRoute.typedV2) {
      await _commitTyped(bankName, folderName, report);
      return;
    }
    await _commitLegacy(bankName, folderName, report);
  }

  List<TypedReviewCommitInput>? _buildCurrentTypedCommitInputs() {
    final items = <TypedReviewCommitInput>[];
    for (final item in _state.allItems) {
      final marker = _reviewItemIds[item.originalIndex];
      final provenance = _snapshotProvenance[item.originalIndex];
      if (marker == null ||
          provenance == null ||
          !provenance.containsKey(TypedReviewSnapshotCodec.mapKey)) {
        return null;
      }
      items.add(
        TypedReviewCommitInput(
          reviewItemId: marker,
          envelope: provenance[TypedReviewSnapshotCodec.mapKey],
          currentDraft: item.draft,
          repairEdit: _repairEdits[item.originalIndex],
          // Same resolved decisions the preview used, so a structure rendered
          // in Review is committed rather than flattened.
          explanationRetained: isQuestionExplanationRetained(item),
          explanationEditProvenance:
              _state.explanationProvenance[item.originalIndex] ??
                  ExplanationEditProvenance.legacyUnknown,
        ),
      );
    }
    if (items.isEmpty) return null;
    return items;
  }

  Future<void> _commitLegacy(
    String bankName,
    String folderName,
    ImportReviewReport report,
  ) async {
    _setState(_state.copyWith(isSaving: true));
    try {
      final taskId = _taskId?.trim();
      final questions = _state.allItems.map((item) => item.draft).toList();
      final overrides = _state.allItems
          .map(
            (item) =>
                _explanationOverrides[item.originalIndex] ??
                QuestionExplanationOverride.inherit,
          )
          .toList(growable: false);
      if (taskId == null || taskId.isEmpty) {
        await _commitService.commitLegacy(
          bankName: bankName,
          folderName: folderName,
          questions: questions,
          taskId: null,
          diagnostics: _diagnostics ?? const <String, dynamic>{},
          explanationRetentionMode: _state.explanationRetentionMode,
          explanationOverrides: overrides,
        );
      } else {
        final flushResult = await persistReviewDraft(showFailurePrompt: false);
        if (flushResult == null || !flushResult.saved) {
          effects.showError(_reviewDraftUnsafeText);
          return;
        }
        final matches = _taskManager.tasks.where((task) => task.id == taskId);
        if (matches.isEmpty) {
          effects.showError(_legacyTaskExpiredText);
          return;
        }
        final diagnostics = matches.single.diagnostics;
        final token = diagnostics?[TaskManager.keyAttemptToken];
        final number = diagnostics?[TaskManager.keyAttemptNumber];
        final trace = diagnostics?[TaskManager.keyTraceId];
        final reason = diagnostics?[TaskManager.keyImportStorageReason];
        if ((token != null && (token is! String || token.isEmpty)) ||
            (number != null && (number is! int || number <= 0)) ||
            (trace != null && (trace is! String || trace.isEmpty)) ||
            (reason != null && reason is! String)) {
          effects.showError(_legacyTaskExpiredText);
          return;
        }
        final ImportStorageRoute route;
        try {
          route = decodeImportStorageRoute(
            diagnostics?[TaskManager.keyImportStorageRoute],
          );
        } on TypedReviewSnapshotException {
          effects.showError(_invalidStorageRouteText);
          return;
        }
        await _commitService.commitLegacyForTask(
          bankName: bankName,
          folderName: folderName,
          questions: questions,
          taskId: taskId,
          attemptToken: token as String?,
          attemptNumber: number as int?,
          traceId: trace as String?,
          expectedReviewDraftRevision: flushResult.revision,
          storageRoute: route,
          storageReason: reason as String?,
          diagnostics: diagnostics ?? const <String, dynamic>{},
          explanationRetentionMode: _state.explanationRetentionMode,
          explanationOverrides: overrides,
        );
      }

      effects.showCommitSuccess(report, bankName, folderName);
    } on LegacyReviewCommitAttemptException catch (error) {
      effects.showError(
        switch (error.failure) {
          LegacyReviewCommitAttemptFailure.taskMissing ||
          LegacyReviewCommitAttemptFailure.taskNotPendingReview ||
          LegacyReviewCommitAttemptFailure.staleAttempt ||
          LegacyReviewCommitAttemptFailure.staleReviewDraft =>
            _legacyTaskExpiredText,
          LegacyReviewCommitAttemptFailure.commitInProgress =>
            _typedCommitInProgressText,
          LegacyReviewCommitAttemptFailure.proposedTargetExists =>
            _proposedTargetExistsText,
          LegacyReviewCommitAttemptFailure.persistenceFailed =>
            _legacyCommitFailedText,
        },
      );
    } catch (_) {
      effects.showError(_legacyCommitFailedText);
    } finally {
      _setState(_state.copyWith(isSaving: false));
    }
  }

  Future<void> _commitTyped(
    String bankName,
    String folderName,
    ImportReviewReport report,
  ) async {
    // Programmatic distillation gate: the disabled button must never be the
    // only protection. A bypassed save flow still blocks while answers are
    // being generated so the commit snapshot cannot race the distillation.
    if (_state.isDistillingAnswers) {
      effects.showError(_answerDistillationInProgressText);
      return;
    }
    if (_state.activeRepairIndex != null) {
      effects.showError(_reviewRepairInProgressText);
      return;
    }

    final taskId = _taskId?.trim() ?? '';
    final attemptToken =
        _diagnostics?[TaskManager.keyAttemptToken]?.toString().trim() ?? '';
    final attemptNumber = _readAttemptNumber();
    if (taskId.isEmpty || attemptToken.isEmpty || attemptNumber == null) {
      effects.showError(_typedCommitBlockedText);
      return;
    }

    _setState(_state.copyWith(isSaving: true));
    try {
      // Commit-time review draft flush: wait for the queued tail, persist the
      // latest draft, and require a successful save before committing. The
      // payload must be rebuilt afterwards so revision N is bound to the
      // post-flush snapshot, never to an entry-time capture.
      final flushResult = await persistReviewDraft(showFailurePrompt: false);
      if (flushResult == null || !flushResult.saved) {
        effects.showError(_reviewDraftUnsafeText);
        return;
      }
      final items = _buildCurrentTypedCommitInputs();
      if (items == null) {
        effects.showError(_typedCommitBlockedText);
        return;
      }
      await _commitService.commitTyped(
        bankName: bankName,
        folderName: folderName,
        items: items,
        taskId: taskId,
        attemptToken: attemptToken,
        attemptNumber: attemptNumber,
        expectedReviewDraftRevision: flushResult.revision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: _state.explanationRetentionMode,
        explanationOverrides: _state.allItems
            .map(
              (item) =>
                  _explanationOverrides[item.originalIndex] ??
                  QuestionExplanationOverride.inherit,
            )
            .toList(growable: false),
      );
      effects.showCommitSuccess(report, bankName, folderName);
    } on TypedReviewCommitException catch (error) {
      effects.showError(
        error.failure == TypedReviewCommitFailure.unsupportedOptionEdit
            ? _typedOptionsBlockedText
            : _typedCommitFailedText,
      );
    } on TypedReviewCommitAttemptException catch (error) {
      effects.showError(
        switch (error.failure) {
          TypedReviewCommitAttemptFailure.taskMissing ||
          TypedReviewCommitAttemptFailure.taskNotPendingReview ||
          TypedReviewCommitAttemptFailure.staleAttempt ||
          TypedReviewCommitAttemptFailure.staleReviewDraft =>
            _typedTaskExpiredText,
          TypedReviewCommitAttemptFailure.commitInProgress =>
            _typedCommitInProgressText,
          TypedReviewCommitAttemptFailure.proposedTargetExists =>
            _proposedTargetExistsText,
          TypedReviewCommitAttemptFailure.persistenceFailed =>
            _typedCommitFailedText,
        },
      );
    } catch (_) {
      effects.showError(_typedCommitFailedText);
    } finally {
      _setState(_state.copyWith(isSaving: false));
    }
  }

  /// Strict route resolution: missing route -> legacyV1, legacyV1 with any
  /// legal reason -> legacyV1, typedV2 + typed_candidate_ready -> typedV2,
  /// every other combination -> null (block).
  ImportStorageRoute? _resolveStorageRoute() {
    final value = _diagnostics?[TaskManager.keyImportStorageRoute];
    final ImportStorageRoute route;
    try {
      route = value == null
          ? ImportStorageRoute.legacyV1
          : decodeImportStorageRoute(value);
    } on TypedReviewSnapshotException {
      return null;
    }
    try {
      validateImportStorageMetadata(
        route: route,
        reason: _diagnostics?[TaskManager.keyImportStorageReason],
      );
    } on TypedReviewSnapshotException {
      return null;
    }
    return route;
  }

  int? _readAttemptNumber() {
    final value = _diagnostics?[TaskManager.keyAttemptNumber];
    if (value is int && value > 0) return value;
    if (value is num && value > 0) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _answerDistillationCancellationRequested = true;
    _answerDistillationOperationId++;
    super.dispose();
  }
}

/// Review markers restored from the persisted review draft.
class _RestoredReviewMarkers {
  const _RestoredReviewMarkers({
    required this.normalizationNeeded,
    required this.snapshotProvenance,
    required this.reviewItemIds,
    required this.explanationOverrides,
    required this.explanationProvenance,
    required this.answerDistillationStatuses,
    required this.answerDistillationReasons,
    required this.repairEdits,
  });

  final bool normalizationNeeded;
  final Map<int, Map<String, dynamic>> snapshotProvenance;
  final Map<int, String> reviewItemIds;
  final Map<int, QuestionExplanationOverride> explanationOverrides;
  final Map<int, ExplanationEditProvenance> explanationProvenance;
  final Map<int, String> answerDistillationStatuses;
  final Map<int, String> answerDistillationReasons;
  final Map<int, ReviewRepairEdit> repairEdits;
}
