import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_filter.dart';
import 'package:shiroha_quiz/ui/import_review/import_review_view_state.dart';

/// Locks the publish boundary of [ImportReviewViewState]: every collection it
/// exposes must reject in-place mutation, so a published state can only be
/// changed by the controller producing a new state value.
void main() {
  ImportReviewViewState buildState() {
    return ImportReviewViewState(
      allItems: [],
      visibleItems: [],
      reviewResult: ImportReviewAnalyzer.analyzeItems(const []),
      activeFilter: ImportReviewFilter.all,
      activeSort: ImportReviewSort.originalOrder,
      isSaving: false,
      selectionMode: false,
      selectedOriginalIndices: <int>{},
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      isDocumentImportEntryTask: false,
      diagnosticMessages: [],
      existingFolders: [],
      presentationSnapshots: {},
      explanationProvenance: {},
      answerDistillationStatuses: {},
      isDistillingAnswers: false,
      answerDistillationCancellationRequested: false,
      answerDistillationCompletedCount: 0,
      answerDistillationTotalCount: 0,
      activeAnswerDistillationIndex: null,
      activeRepairIndex: null,
      autoRepairProposalIndices: <int>{},
    );
  }

  test('published collections reject mutation through state fields', () {
    final state = buildState();

    expect(() => state.allItems.length = 3, throwsUnsupportedError);
    expect(() => state.visibleItems.length = 3, throwsUnsupportedError);
    expect(() => state.selectedOriginalIndices.add(1), throwsUnsupportedError);
    expect(() => state.diagnosticMessages.length = 3, throwsUnsupportedError);
    expect(() => state.existingFolders.add('数学'), throwsUnsupportedError);
    expect(() => state.presentationSnapshots.remove(0), throwsUnsupportedError);
    expect(() => state.explanationProvenance.remove(0), throwsUnsupportedError);
    expect(
      () => state.answerDistillationStatuses[0] = 'local_extracted',
      throwsUnsupportedError,
    );
    expect(
        () => state.autoRepairProposalIndices.add(0), throwsUnsupportedError);
  });

  test('copyWith republishes unmodifiable collections', () {
    final next = buildState().copyWith(
      selectedOriginalIndices: {1, 2},
      existingFolders: ['数学'],
    );

    expect(next.selectedOriginalIndices, {1, 2});
    expect(() => next.selectedOriginalIndices.add(3), throwsUnsupportedError);
    expect(next.existingFolders, ['数学']);
    expect(() => next.existingFolders.add('物理'), throwsUnsupportedError);
    // Fields that were not replaced stay unmodifiable too.
    expect(() => next.allItems.length = 1, throwsUnsupportedError);
  });
}
