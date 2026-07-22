import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/vision_import_quality_summary.dart';

void main() {
  group('VisionImportQualitySummary', () {
    test('returns empty when no gate entries exist', () {
      final result =
          VisionImportQualitySummary.fromDiagnostics({'other': 'value'});
      expect(result.hasLowQualityVisionParse, false);
      expect(result.total, 0);
      expect(result.riskyCount, 0);
      expect(result.lowQualityFileCount, 0);
      expect(result.issueCounts, isEmpty);
      expect(result.recommendedAction, isNull);
    });

    test('returns empty for empty diagnostics', () {
      final result = VisionImportQualitySummary.fromDiagnostics({});
      expect(result.hasLowQualityVisionParse, false);
    });

    test('aggregates single lowQuality gate entry', () {
      final result = VisionImportQualitySummary.fromDiagnostics({
        'vision_quality_gate_file_0': {
          'sourceName': 'vision_pdf_page',
          'total': 10,
          'riskyCount': 6,
          'lowQuality': true,
          'issueCounts': {
            'answer_leaked_to_content': 3,
            'missing_answer_or_explanation': 2,
            'duplicate_q_num': 1,
          },
        },
      });

      expect(result.hasLowQualityVisionParse, true);
      expect(result.total, 10);
      expect(result.riskyCount, 6);
      expect(result.lowQualityFileCount, 1);
      expect(
        result.issueCounts,
        {
          'answer_leaked_to_content': 3,
          'missing_answer_or_explanation': 2,
          'duplicate_q_num': 1,
        },
      );
      expect(result.recommendedAction, 'review_or_retry_stronger_vision');
    });

    test('aggregates multiple gate entries', () {
      final result = VisionImportQualitySummary.fromDiagnostics({
        'vision_quality_gate_file_0': {
          'total': 10,
          'riskyCount': 2,
          'lowQuality': false,
          'issueCounts': {'missing_answer_or_explanation': 2},
        },
        'vision_quality_gate_file_1': {
          'total': 15,
          'riskyCount': 9,
          'lowQuality': true,
          'issueCounts': {
            'answer_leaked_to_content': 5,
            'missing_answer_or_explanation': 3,
          },
        },
      });

      expect(result.hasLowQualityVisionParse, true);
      expect(result.total, 25);
      expect(result.riskyCount, 11);
      expect(result.lowQualityFileCount, 1);
      expect(
        result.issueCounts,
        {
          'answer_leaked_to_content': 5,
          'missing_answer_or_explanation': 5,
        },
      );
    });

    test(
        'lowQuality:false still aggregates correctly without recommendedAction',
        () {
      final result = VisionImportQualitySummary.fromDiagnostics({
        'vision_quality_gate_file_0': {
          'total': 5,
          'riskyCount': 1,
          'lowQuality': false,
          'issueCounts': {'type_options_mismatch': 1},
        },
      });

      expect(result.hasLowQualityVisionParse, false);
      expect(result.total, 5);
      expect(result.riskyCount, 1);
      expect(result.recommendedAction, isNull);
    });

    test('handles malformed gate diagnostics gracefully', () {
      final result = VisionImportQualitySummary.fromDiagnostics({
        'vision_quality_gate_file_0': 'not_a_map',
        'vision_quality_gate_file_1': null,
        'vision_quality_gate_file_2': {
          // missing total, riskyCount, lowQuality
          'sourceName': 'x',
        },
      });

      expect(result.hasLowQualityVisionParse, false);
      expect(result.total, 0);
    });

    test('handles non-map summary lookup (defensive)', () {
      final summary = VisionImportQualitySummary.fromDiagnostics({});
      // _hasLowQualityVision guard: summary is not a map → false
      final diag = {
        'visionQualitySummary': 42,
      };
      final map = diag['visionQualitySummary'];
      expect(map is Map, false);
    });

    test('empty issueCounts with lowQuality still sets hasLowQuality', () {
      final result = VisionImportQualitySummary.fromDiagnostics({
        'vision_quality_gate_file_0': {
          'total': 3,
          'riskyCount': 2,
          'lowQuality': true,
        },
      });

      expect(result.hasLowQualityVisionParse, true);
      expect(result.issueCounts, isEmpty);
      expect(result.recommendedAction, 'review_or_retry_stronger_vision');
    });

    test('toDiagnostics returns correct shape', () {
      final summary = VisionImportQualitySummary(
        hasLowQualityVisionParse: true,
        total: 10,
        riskyCount: 5,
        lowQualityFileCount: 1,
        issueCounts: const {'answer_leaked_to_content': 3},
        recommendedAction: 'review_or_retry_stronger_vision',
      );

      final diag = summary.toDiagnostics();
      expect(diag['hasLowQualityVisionParse'], true);
      expect(diag['total'], 10);
      expect(diag['riskyCount'], 5);
      expect(diag['lowQualityFileCount'], 1);
      expect(diag['issueCounts'], {'answer_leaked_to_content': 3});
      expect(diag['recommendedAction'], 'review_or_retry_stronger_vision');
    });
  });
}
