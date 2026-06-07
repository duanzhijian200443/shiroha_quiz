import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_review/import_review_batch_controller.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';
import 'package:shiroha_quiz/services/import_review/import_review_metadata.dart';

void main() {
  group('ImportReviewBatchController Tests', () {
    late List<ImportReviewItem> initialItems;

    setUp(() {
      initialItems = [
        ImportReviewItem(
          draft: const QuestionDraft(
            type: QuestionType.singleChoice,
            content: 'Q1',
            options: ['A', 'B'],
            standardAnswer: 'A',
            explanation: '',
          ),
          metadata: const ImportReviewMetadata(
              source: 'text',
              sources: ['file.txt'],
              fragmentKinds: ['fullQuestion'],
              originalIndices: [0],
              riskHints: []),
          originalIndex: 0,
        ),
        ImportReviewItem(
          draft: const QuestionDraft(
            type: QuestionType.fillBlank,
            content: 'Q2',
            options: [],
            standardAnswer: 'Answer 2',
            explanation: '',
          ),
          metadata: const ImportReviewMetadata(
              source: 'text',
              sources: ['file.txt'],
              fragmentKinds: ['fullQuestion'],
              originalIndices: [2],
              riskHints: []),
          originalIndex: 2,
        ),
        ImportReviewItem(
          draft: const QuestionDraft(
            type: QuestionType.shortAnswer,
            content: 'Q3',
            options: [],
            standardAnswer: 'Answer 3',
            explanation: '',
          ),
          metadata: const ImportReviewMetadata(
              source: 'text',
              sources: ['file.txt'],
              fragmentKinds: ['fullQuestion'],
              originalIndices: [5],
              riskHints: []),
          originalIndex: 5,
        ),
      ];
    });

    test('deleteSelected removes only items with matching originalIndex', () {
      final result = ImportReviewBatchController.deleteSelected(
        items: initialItems,
        selectedOriginalIndices: {2},
      );

      expect(result.length, 2);
      expect(result.any((item) => item.originalIndex == 2), false);
      expect(result.any((item) => item.originalIndex == 0), true);
      expect(result.any((item) => item.originalIndex == 5), true);
    });

    test('deleteSelected with empty selection returns unchanged list', () {
      final result = ImportReviewBatchController.deleteSelected(
        items: initialItems,
        selectedOriginalIndices: {},
      );

      expect(result.length, 3);
      expect(result, initialItems);
    });

    test('changeTypeSelected changes type for only selected indices', () {
      final result = ImportReviewBatchController.changeTypeSelected(
        items: initialItems,
        selectedOriginalIndices: {0, 5},
        targetType: QuestionType.fillBlank,
      );

      final item0 = result.firstWhere((item) => item.originalIndex == 0);
      final item2 = result.firstWhere((item) => item.originalIndex == 2);
      final item5 = result.firstWhere((item) => item.originalIndex == 5);

      expect(item0.draft.type, QuestionType.fillBlank); // changed
      expect(item5.draft.type, QuestionType.fillBlank); // changed
      expect(item2.draft.type, QuestionType.fillBlank); // unchanged

      // Options should be preserved
      expect(item0.draft.options, ['A', 'B']);

      // Metadata preserved
      expect(item0.metadata.sources.first, 'file.txt');
    });

    test('changeTypeSelected with empty selection returns unchanged list', () {
      final result = ImportReviewBatchController.changeTypeSelected(
        items: initialItems,
        selectedOriginalIndices: {},
        targetType: QuestionType.fillBlank,
      );

      expect(result.length, 3);
      expect(result.first.draft.type, QuestionType.singleChoice);
    });
  });
}
