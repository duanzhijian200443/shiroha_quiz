import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_review/import_review_metadata.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';

void main() {
  group('ImportReviewMetadata Tests', () {
    test('toMap and fromMap should be symmetric', () {
      final meta = ImportReviewMetadata(
        source: 'fused',
        sources: ['text', 'vision'],
        fragmentKinds: ['fullQuestion', 'stemOnly'],
        originalIndices: [0, 8],
        riskHints: ['fused_from_text_vision', 'answer_conflict'],
      );

      final map = meta.toMap();
      final restored = ImportReviewMetadata.fromMap(map);

      expect(restored.source, 'fused');
      expect(restored.sources, ['text', 'vision']);
      expect(restored.fragmentKinds, ['fullQuestion', 'stemOnly']);
      expect(restored.originalIndices, [0, 8]);
      expect(restored.riskHints, ['fused_from_text_vision', 'answer_conflict']);
    });

    test('fromMap with null should return empty', () {
      final meta = ImportReviewMetadata.fromMap(null);
      expect(meta.source, 'unknown');
      expect(meta.sources, isEmpty);
      expect(meta.fragmentKinds, isEmpty);
      expect(meta.originalIndices, isEmpty);
      expect(meta.riskHints, isEmpty);
    });

    test('fromMap with malformed map should not crash', () {
      final meta1 = ImportReviewMetadata.fromMap({
        'sources': null,
        'riskHints': null,
      });
      expect(meta1.source, 'unknown');
      expect(meta1.sources, isEmpty);

      // Complete malformed fields
      final meta2 = ImportReviewMetadata.fromMap({
        'source': 123,
        'sources': 'not a list',
        'fragmentKinds': [123, 456], // non-string list
        'originalIndices': ['1', 2.0, null, 'bad'], // mixed list
        'riskHints': {},
      });
      expect(meta2.source, '123');
      expect(meta2.sources, isEmpty);
      expect(meta2.fragmentKinds, ['123', '456']);
      expect(meta2.originalIndices,
          [1, 2]); // '1' -> 1, 2.0 -> 2, null/'bad' ignored
      expect(meta2.riskHints, isEmpty);
    });

    test(
        'ImportReviewItem.fromMap handles non-string keys in _import_review safely',
        () {
      final rawData = {
        'content': 'Test question',
        '_import_review': {
          123: 'non-string key',
          'source': 'fused',
        }
      };

      final item = ImportReviewItem.fromMap(rawData, 0);
      expect(item.metadata.source, 'fused');
      // Should not crash, 123 is safely stringified or ignored
    });

    test('tracks absent, available, and unavailable metadata projections', () {
      final absent = ImportReviewItem.fromMap(
        {'content': 'Legacy question'},
        0,
      );
      expect(
        absent.metadataProjectionState,
        ImportReviewMetadataProjectionState.notProvided,
      );

      final available = ImportReviewItem.fromMap(
        {
          'content': 'Eligible question',
          '_import_review': {
            'riskHints': ['answer_conflict'],
            'repairCandidateCodes': ['cross_page'],
          },
        },
        1,
      );
      expect(
        available.metadataProjectionState,
        ImportReviewMetadataProjectionState.available,
      );

      final unavailable = ImportReviewItem.fromMap(
        {
          'content': 'Unavailable metadata question',
          '_import_review': 'not-a-map',
        },
        2,
      );
      expect(
        unavailable.metadataProjectionState,
        ImportReviewMetadataProjectionState.unavailable,
      );
      expect(unavailable.metadata.repairCandidateCodes, isEmpty);

      final malformedField = ImportReviewItem.fromMap(
        {
          'content': 'Malformed metadata question',
          '_import_review': {'riskHints': 'not-a-list'},
        },
        3,
      );
      expect(
        malformedField.metadataProjectionState,
        ImportReviewMetadataProjectionState.unavailable,
      );
    });
  });
}
