import 'package:flutter/foundation.dart';

import '../../application/import_review/typed_review_snapshot.dart';
import '../../services/import_pipeline/import_diagnostic_message.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_review/explanation_edit_provenance.dart';
import '../../services/import_review/import_review_analyzer.dart';
import '../../services/import_review/import_review_filter.dart';
import '../../services/import_review/import_review_item.dart';
import '../../services/import_review/import_review_visible_item.dart';

/// Immutable presentation state for the import review page.
///
/// It carries only what the page renders and what the user can currently
/// select: review items, filter/sort, selection, in-flight operation state and
/// safely projected review markers. It never holds a build context, a widget,
/// theme data, a messenger, a service handle or any writable business state.
///
/// The publish boundary is enforced here: every collection handed to the
/// constructor is copied into an unmodifiable view, so a published state can
/// never be mutated through its fields. Every change must go through the
/// controller and produce a new state value.
///
/// The controller replaces the whole value on every change; the page rebuilds
/// from it and forwards user events back to the controller.
@immutable
class ImportReviewViewState {
  ImportReviewViewState({
    required List<ImportReviewItem> allItems,
    required List<ImportReviewVisibleItem> visibleItems,
    required this.reviewResult,
    required this.activeFilter,
    required this.activeSort,
    required this.isSaving,
    required this.selectionMode,
    required Set<int> selectedOriginalIndices,
    required this.explanationRetentionMode,
    required this.isDocumentImportEntryTask,
    required List<ImportDiagnosticMessage> diagnosticMessages,
    required List<String> existingFolders,
    required Map<int, TypedReviewSnapshot> presentationSnapshots,
    required Map<int, ExplanationEditProvenance> explanationProvenance,
    required Map<int, String> answerDistillationStatuses,
    required this.isDistillingAnswers,
    required this.answerDistillationCancellationRequested,
    required this.answerDistillationCompletedCount,
    required this.answerDistillationTotalCount,
    required this.activeAnswerDistillationIndex,
    required this.activeRepairIndex,
    required Set<int> autoRepairProposalIndices,
  })  : allItems = List<ImportReviewItem>.unmodifiable(allItems),
        visibleItems = List<ImportReviewVisibleItem>.unmodifiable(visibleItems),
        selectedOriginalIndices =
            Set<int>.unmodifiable(selectedOriginalIndices),
        diagnosticMessages =
            List<ImportDiagnosticMessage>.unmodifiable(diagnosticMessages),
        existingFolders = List<String>.unmodifiable(existingFolders),
        presentationSnapshots =
            Map<int, TypedReviewSnapshot>.unmodifiable(presentationSnapshots),
        explanationProvenance =
            Map<int, ExplanationEditProvenance>.unmodifiable(
                explanationProvenance),
        answerDistillationStatuses =
            Map<int, String>.unmodifiable(answerDistillationStatuses),
        autoRepairProposalIndices =
            Set<int>.unmodifiable(autoRepairProposalIndices);

  /// Every item still staged for this import, in original order.
  final List<ImportReviewItem> allItems;

  /// The items currently visible under [activeFilter] / [activeSort].
  final List<ImportReviewVisibleItem> visibleItems;

  /// Current analysis of [allItems]; drives the summary bar and toolbar counts.
  final ImportReviewAnalyzerResult reviewResult;

  final ImportReviewFilter activeFilter;
  final ImportReviewSort activeSort;

  /// A commit or another page-level write is in flight.
  final bool isSaving;

  final bool selectionMode;
  final Set<int> selectedOriginalIndices;

  final ExplanationRetentionMode explanationRetentionMode;

  /// Whether this task fixes explanation retention (document import entry).
  final bool isDocumentImportEntryTask;

  final List<ImportDiagnosticMessage> diagnosticMessages;

  /// Folder names offered by the save-location dialog.
  final List<String> existingFolders;

  /// Decoded typed review snapshots used for structure-aware rendering.
  final Map<int, TypedReviewSnapshot> presentationSnapshots;

  /// Explanation edit provenance per original index.
  final Map<int, ExplanationEditProvenance> explanationProvenance;

  /// Answer-distillation status per original index.
  final Map<int, String> answerDistillationStatuses;

  final bool isDistillingAnswers;
  final bool answerDistillationCancellationRequested;
  final int answerDistillationCompletedCount;
  final int answerDistillationTotalCount;
  final int? activeAnswerDistillationIndex;

  /// The item whose AI repair proposal is currently being generated.
  final int? activeRepairIndex;

  /// Items with a prepared, not yet consumed AI repair proposal.
  final Set<int> autoRepairProposalIndices;

  ImportReviewViewState copyWith({
    List<ImportReviewItem>? allItems,
    List<ImportReviewVisibleItem>? visibleItems,
    ImportReviewAnalyzerResult? reviewResult,
    ImportReviewFilter? activeFilter,
    ImportReviewSort? activeSort,
    bool? isSaving,
    bool? selectionMode,
    Set<int>? selectedOriginalIndices,
    ExplanationRetentionMode? explanationRetentionMode,
    bool? isDocumentImportEntryTask,
    List<ImportDiagnosticMessage>? diagnosticMessages,
    List<String>? existingFolders,
    Map<int, TypedReviewSnapshot>? presentationSnapshots,
    Map<int, ExplanationEditProvenance>? explanationProvenance,
    Map<int, String>? answerDistillationStatuses,
    bool? isDistillingAnswers,
    bool? answerDistillationCancellationRequested,
    int? answerDistillationCompletedCount,
    int? answerDistillationTotalCount,
    int? activeAnswerDistillationIndex,
    bool clearActiveAnswerDistillationIndex = false,
    int? activeRepairIndex,
    bool clearActiveRepairIndex = false,
    Set<int>? autoRepairProposalIndices,
  }) {
    return ImportReviewViewState(
      allItems: allItems ?? this.allItems,
      visibleItems: visibleItems ?? this.visibleItems,
      reviewResult: reviewResult ?? this.reviewResult,
      activeFilter: activeFilter ?? this.activeFilter,
      activeSort: activeSort ?? this.activeSort,
      isSaving: isSaving ?? this.isSaving,
      selectionMode: selectionMode ?? this.selectionMode,
      selectedOriginalIndices:
          selectedOriginalIndices ?? this.selectedOriginalIndices,
      explanationRetentionMode:
          explanationRetentionMode ?? this.explanationRetentionMode,
      isDocumentImportEntryTask:
          isDocumentImportEntryTask ?? this.isDocumentImportEntryTask,
      diagnosticMessages: diagnosticMessages ?? this.diagnosticMessages,
      existingFolders: existingFolders ?? this.existingFolders,
      presentationSnapshots:
          presentationSnapshots ?? this.presentationSnapshots,
      explanationProvenance:
          explanationProvenance ?? this.explanationProvenance,
      answerDistillationStatuses:
          answerDistillationStatuses ?? this.answerDistillationStatuses,
      isDistillingAnswers: isDistillingAnswers ?? this.isDistillingAnswers,
      answerDistillationCancellationRequested:
          answerDistillationCancellationRequested ??
              this.answerDistillationCancellationRequested,
      answerDistillationCompletedCount: answerDistillationCompletedCount ??
          this.answerDistillationCompletedCount,
      answerDistillationTotalCount:
          answerDistillationTotalCount ?? this.answerDistillationTotalCount,
      activeAnswerDistillationIndex: clearActiveAnswerDistillationIndex
          ? null
          : (activeAnswerDistillationIndex ??
              this.activeAnswerDistillationIndex),
      activeRepairIndex: clearActiveRepairIndex
          ? null
          : (activeRepairIndex ?? this.activeRepairIndex),
      autoRepairProposalIndices:
          autoRepairProposalIndices ?? this.autoRepairProposalIndices,
    );
  }
}
