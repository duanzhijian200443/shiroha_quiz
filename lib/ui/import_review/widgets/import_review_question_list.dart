import 'package:flutter/material.dart';

import '../../../services/import_review/explanation_edit_provenance.dart';
import '../../../services/import_review/import_review_item.dart';
import '../import_review_view_state.dart';
import 'import_review_question_card.dart';

/// Scrollable review list: empty states, swipe-to-dismiss, selection checkboxes
/// and one [ImportReviewQuestionCard] per visible item.
///
/// It renders from the published [ImportReviewViewState] plus three per-item
/// presentation predicates, and reports every user intent through callbacks.
/// The answer-distillation status string is compared here because it is part of
/// what the card shows, not a business decision.
class ImportReviewQuestionList extends StatelessWidget {
  const ImportReviewQuestionList({
    super.key,
    required this.state,
    required this.isQuestionExplanationRetained,
    required this.isAnswerDistillationCandidate,
    required this.isReviewRepairEligible,
    required this.onToggleSelection,
    required this.onRemoveItem,
    required this.onEditExplanation,
    required this.onExplanationRetentionChanged,
    required this.onDistillAnswer,
    required this.onReviewRepair,
  });

  final ImportReviewViewState state;
  final bool Function(ImportReviewItem item) isQuestionExplanationRetained;
  final bool Function(ImportReviewItem item) isAnswerDistillationCandidate;
  final bool Function(ImportReviewItem item) isReviewRepairEligible;
  final ValueChanged<ImportReviewItem> onToggleSelection;
  final ValueChanged<ImportReviewItem> onRemoveItem;
  final void Function(ImportReviewItem item) onEditExplanation;
  final void Function(ImportReviewItem item, bool retain)
      onExplanationRetentionChanged;
  final void Function(ImportReviewItem item) onDistillAnswer;
  final void Function(ImportReviewItem item) onReviewRepair;

  @override
  Widget build(BuildContext context) {
    if (state.allItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.delete_outline,
              size: 48,
              color: Colors.grey.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '所有题目已被删除',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    if (state.visibleItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.filter_list_off,
              size: 48,
              color: Colors.grey.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '当前筛选下没有题目',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    final selectionMode = state.selectionMode;
    final isSaving = state.isSaving;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: state.visibleItems.length,
      itemBuilder: (context, index) {
        final visibleItem = state.visibleItems[index];
        final item = visibleItem.item;
        return Dismissible(
          key: ValueKey(item.originalIndex),
          direction: (selectionMode || isSaving)
              ? DismissDirection.none
              : DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.redAccent,
            child: const Icon(Icons.delete_sweep, color: Colors.white),
          ),
          onDismissed: (direction) {
            onRemoveItem(item);
          },
          child: Row(
            children: [
              if (selectionMode)
                Checkbox(
                  value: state.selectedOriginalIndices
                      .contains(item.originalIndex),
                  onChanged: (val) {
                    onToggleSelection(item);
                  },
                ),
              Expanded(
                child: GestureDetector(
                  onTap: selectionMode ? () => onToggleSelection(item) : null,
                  child: ImportReviewQuestionCard(
                    item: item,
                    snapshot: state.presentationSnapshots[item.originalIndex],
                    index: visibleItem.canonicalIndex,
                    issues: visibleItem.issues,
                    explanationRetained: isQuestionExplanationRetained(item),
                    onEditExplanation: (selectionMode || isSaving)
                        ? null
                        : () => onEditExplanation(item),
                    explanationProvenance:
                        state.explanationProvenance[item.originalIndex] ??
                            ExplanationEditProvenance.legacyUnknown,
                    onExplanationRetentionChanged: (selectionMode ||
                            isSaving ||
                            state.isDocumentImportEntryTask)
                        ? null
                        : (retain) =>
                            onExplanationRetentionChanged(item, retain),
                    answerDistillationCandidate:
                        isAnswerDistillationCandidate(item),
                    answerDistillationStatus:
                        state.answerDistillationStatuses[item.originalIndex],
                    proofExplanationRecognized:
                        state.answerDistillationStatuses[item.originalIndex] ==
                            'proof_explanation_recognized',
                    answerDistillationInProgress:
                        state.activeAnswerDistillationIndex ==
                            item.originalIndex,
                    onAnswerDistillation: (selectionMode ||
                            isSaving ||
                            state.activeRepairIndex != null ||
                            state.isDistillingAnswers)
                        ? null
                        : () => onDistillAnswer(item),
                    reviewRepairEligible: isReviewRepairEligible(item),
                    reviewRepairInProgress:
                        state.activeRepairIndex == item.originalIndex,
                    reviewRepairProposalReady: state.autoRepairProposalIndices
                        .contains(item.originalIndex),
                    onReviewRepair: (selectionMode ||
                            isSaving ||
                            state.isDistillingAnswers ||
                            state.activeRepairIndex != null)
                        ? null
                        : () => onReviewRepair(item),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
