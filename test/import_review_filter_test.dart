import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';
import 'package:shiroha_quiz/services/import_review/import_review_metadata.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_filter.dart';

void main() {
  group('ImportReviewFilterService Tests', () {
    late List<ImportReviewItem> testItems;
    late ImportReviewAnalyzerResult analysis;

    setUp(() {
      testItems = [
        // 0: Clean question (fused)
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'This is a clean question stem',
            type: QuestionType.singleChoice,
            options: const ['A', 'B', 'C', 'D'],
            explanation: 'Explanation here',
            standardAnswer: 'A',
          ),
          metadata: const ImportReviewMetadata(
            source: 'fused',
            sources: ['text', 'vision'],
            fragmentKinds: ['fullQuestion'],
            originalIndices: [0, 1],
            riskHints: [],
          ),
          originalIndex: 0,
        ),
        // 1: Missing answer (error)
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Stem of question 2',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: '',
            standardAnswer: '',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 1,
        ),
        // 2: Answer conflict (warning)
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Stem of question 3',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: const ImportReviewMetadata(
            source: 'fused',
            sources: ['text', 'vision'],
            fragmentKinds: ['fullQuestion'],
            originalIndices: [2, 3],
            riskHints: ['answer_conflict', 'fused_from_text_vision'],
          ),
          originalIndex: 2,
        ),
        // 3: Choice issue - out of bounds (error)
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Stem of choice issue',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'C', // out of bounds
          ),
          metadata: const ImportReviewMetadata(
            source: 'text',
            sources: ['text'],
            fragmentKinds: ['fullQuestion'],
            originalIndices: [4],
            riskHints: [],
          ),
          originalIndex: 3,
        ),
        // 4: Vision only (info)
        ImportReviewItem(
          draft: QuestionDraft(
            content: 'Vision only stem here',
            type: QuestionType.singleChoice,
            options: const ['A', 'B'],
            explanation: 'Exp',
            standardAnswer: 'A',
          ),
          metadata: const ImportReviewMetadata(
            source: 'vision',
            sources: ['vision'],
            fragmentKinds: ['fullQuestion'],
            originalIndices: [5],
            riskHints: ['vision_only'],
          ),
          originalIndex: 4,
        ),
      ];

      analysis = ImportReviewAnalyzer.analyzeItems(testItems);
    });

    test('errorsOnly returns only error items', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.errorsOnly,
        sort: ImportReviewSort.originalOrder,
      );
      expect(res.length, 2);
      expect(res.map((vi) => vi.canonicalIndex).toList(),
          [1, 3]); // missingAnswer & choice issue
    });

    test('warningsOnly returns only warning items', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.warningsOnly,
        sort: ImportReviewSort.originalOrder,
      );
      expect(res.length, 1);
      expect(res.first.canonicalIndex, 2); // answer conflict
    });

    test('missingAnswer returns only missing answer items', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.missingAnswer,
        sort: ImportReviewSort.originalOrder,
      );
      expect(res.length, 1);
      expect(res.first.canonicalIndex, 1);
    });

    test('choiceIssues returns choice issue items', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.choiceIssues,
        sort: ImportReviewSort.originalOrder,
      );
      expect(res.length, 1);
      expect(res.first.canonicalIndex, 3);
    });

    test('type options mismatch is locatable and prioritized as choice issue',
        () {
      final items = [
        ImportReviewItem(
          draft: const QuestionDraft(
            content: 'Clean question',
            type: QuestionType.shortAnswer,
            options: [],
            explanation: '',
            standardAnswer: 'Answer',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 0,
        ),
        ImportReviewItem(
          draft: const QuestionDraft(
            content: 'Mismatched question',
            type: QuestionType.fillBlank,
            options: ['A', 'B'],
            explanation: '',
            standardAnswer: 'Answer',
          ),
          metadata: ImportReviewMetadata.empty(),
          originalIndex: 1,
        ),
      ];
      final result = ImportReviewAnalyzer.analyzeItems(items);

      final filtered = ImportReviewFilterService.apply(
        items: items,
        analysis: result,
        filter: ImportReviewFilter.choiceIssues,
        sort: ImportReviewSort.originalOrder,
      );
      final counts = ImportReviewFilterService.countByFilter(
        items: items,
        analysis: result,
      );
      final sorted = ImportReviewFilterService.apply(
        items: items,
        analysis: result,
        filter: ImportReviewFilter.all,
        sort: ImportReviewSort.missingFieldsFirst,
      );

      expect(filtered.map((item) => item.canonicalIndex), [1]);
      expect(counts[ImportReviewFilter.choiceIssues], 1);
      expect(sorted.first.canonicalIndex, 1);
    });

    test('fusionRisks returns correct fusion issue items', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.fusionRisks,
        sort: ImportReviewSort.originalOrder,
      );
      expect(res.length, 1);
      expect(res.first.canonicalIndex, 2); // answer conflict is a fusion risk
    });

    test('visionOnly and fused filter from metadata', () {
      final visOnly = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.visionOnly,
        sort: ImportReviewSort.originalOrder,
      );
      expect(visOnly.length, 1);
      expect(visOnly.first.canonicalIndex, 4);

      final fused = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.fused,
        sort: ImportReviewSort.originalOrder,
      );
      expect(fused.length, 2);
      expect(fused.map((vi) => vi.canonicalIndex).toList(), [0, 2]);
    });

    test('riskFirst sorts error before warning before info before clean', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.all,
        sort: ImportReviewSort.riskFirst,
      );
      // Index 1, 3 (errors) -> Index 2 (warning) -> Index 4 (info) -> Index 0 (clean)
      expect(res.map((vi) => vi.canonicalIndex).toList(), [1, 3, 2, 4, 0]);
    });

    test('originalOrder preserves order by originalIndex', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.all,
        sort: ImportReviewSort.originalOrder,
      );
      expect(res.map((vi) => vi.canonicalIndex).toList(), [0, 1, 2, 3, 4]);
    });

    test('sourceRiskFirst sorts strictly by source risk ranks', () {
      final res = ImportReviewFilterService.apply(
        items: testItems,
        analysis: analysis,
        filter: ImportReviewFilter.all,
        sort: ImportReviewSort.sourceRiskFirst,
      );
      // Rank mapping:
      // Index 2 (answer_conflict) -> Rank 4
      // Index 4 (vision_only) -> Rank 2
      // Index 0 (fused_from_text_vision) -> Rank 1
      // Clean/others -> Rank 0
      // Expected: 2 (Rank 4) -> 4 (Rank 2) -> 0 (Rank 1) -> 1, 3 (Rank 0)
      expect(res.map((vi) => vi.canonicalIndex).toList(), [2, 4, 0, 1, 3]);
    });

    test('countByFilter counts correctly', () {
      final counts = ImportReviewFilterService.countByFilter(
        items: testItems,
        analysis: analysis,
      );
      expect(counts[ImportReviewFilter.all], 5);
      expect(counts[ImportReviewFilter.errorsOnly], 2);
      expect(counts[ImportReviewFilter.warningsOnly], 1);
    });
  });
}
