import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_diagnostic_message.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_diagnostic_formatter.dart';

void main() {
  group('ImportDiagnosticFormatter Tests', () {
    test('Empty inputs return empty list', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {},
      );
      expect(res, isEmpty);
    });

    test('Null inputs return empty list', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: null,
        diagnostics: null,
      );
      expect(res, isEmpty);
    });

    test('Maps simple warnings to severity.warning', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: ['Failed to load one image', 'Weak document structure'],
        diagnostics: {},
      );
      expect(res.length, 2);
      expect(res[0].severity, ImportDiagnosticSeverity.warning);
      expect(res[0].title, '解析警告');
      expect(res[0].message, 'Failed to load one image');
      expect(res[1].message, 'Weak document structure');
    });

    test('Handles fallbackReason mapping', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {
          'fallbackReason':
              'File structure unreadable, falling back to plaintext'
        },
      );
      expect(res.length, 1);
      expect(res[0].severity, ImportDiagnosticSeverity.warning);
      expect(res[0].title, '解析降级');
      expect(res[0].code, 'FALLBACK');
      expect(res[0].message, contains('plaintext'));
    });

    test('Handles pdf_render status=crash', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {
          'pdf_render': {
            'status': 'crash',
            'error': 'PdfPasswordException: Password required',
            'warnings': ['Page 1 rendering failed', 'Page 2 rendering failed'],
          }
        },
      );
      // Expected: 1 error for crash/error, plus 2 warnings for the warnings list
      expect(res.length, 3);
      final errorMsg =
          res.firstWhere((m) => m.severity == ImportDiagnosticSeverity.error);
      expect(errorMsg.title, 'PDF 渲染失败');
      expect(errorMsg.message, contains('Password required'));
      expect(errorMsg.code, 'PDF_RENDER_CRASH');

      final warnings = res
          .where((m) => m.severity == ImportDiagnosticSeverity.warning)
          .toList();
      expect(warnings.length, 2);
      expect(warnings[0].message, 'Page 1 rendering failed');
      expect(warnings[1].message, 'Page 2 rendering failed');
    });

    test('Handles vision_batch with failedBatchCount > 0', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {
          'vision_batch': {
            'failedBatchCount': 2,
            'totalBatches': 5,
            'errors': [
              'Batch 0: TimeoutException',
              'Batch 1: 429 Limit Exceeded'
            ],
          }
        },
      );
      // Expected: 1 error for failed batch count, plus 2 warnings for the batch errors
      expect(res.length, 3);
      final errorMsg =
          res.firstWhere((m) => m.severity == ImportDiagnosticSeverity.error);
      expect(errorMsg.title, '视觉解析批次失败');
      expect(errorMsg.message, contains('5 个批次中，有 2 个批次解析失败'));
      expect(errorMsg.code, 'VISION_BATCH_FAILED');

      final warnings = res
          .where((m) => m.severity == ImportDiagnosticSeverity.warning)
          .toList();
      expect(warnings.length, 2);
      expect(warnings[0].message, contains('TimeoutException'));
      expect(warnings[1].message, contains('429 Limit Exceeded'));
    });

    test('Handles mixed_vision metadata', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {
          'mixed_vision': {
            'total': 10,
            'resolvable': 8,
            'unresolvable': 2,
            'missing': 1,
            'sent': 7,
          }
        },
      );
      expect(res.length, 1);
      expect(res[0].severity, ImportDiagnosticSeverity.info);
      expect(res[0].title, '混合视觉资源统计');
      expect(res[0].message, contains('共包含图片 10 张'));
      expect(res[0].message, contains('未解析 2 张'));
    });

    test('Handles unresolvedImages list', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {
          'unresolvedImages': ['assets/img1.png', 'assets/img2.png']
        },
      );
      expect(res.length, 1);
      expect(res[0].severity, ImportDiagnosticSeverity.warning);
      expect(res[0].title, '未解析图片资源');
      expect(res[0].code, 'UNRESOLVED_IMAGES');
      expect(res[0].message, contains('img1.png'));
      expect(res[0].message, contains('img2.png'));
    });

    test('Robustness against nested maps and malformed types', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {
          'pdf_render': 'not_a_map', // Should not crash
          'vision_batch': 123, // Should not crash
          'mixed_vision': true, // Should not crash
          'errors': 'not_a_list', // Should not crash
          'warnings': null, // Should not crash
          'unresolvedImages': {}, // Should not crash
        },
      );
      expect(res, isEmpty);
    });

    test('Handles real diagnostics shape with nested and prefixed keys', () {
      final res = ImportDiagnosticFormatter.format(
        warnings: [],
        diagnostics: {
          'pdf_render_file_0': {
            'status': 'crash',
            'error': 'PdfPasswordException',
          },
          'vision_batch_file_0': {
            'failedBatchCount': 1,
            'totalBatches': 2,
            'errors': ['Batch 1: timeout'],
          },
          'test_doc.docx': {
            'mixedVisionMetadata': {
              'totalAssets': 5,
              'resolvableAssets': 5,
            },
            'mixedVisionDiagnostics': [
              '总图片资产数: 5',
            ],
            'fallbackReason': 'Test fallback',
            'errors': ['Inner error'],
          }
        },
      );

      // Expected:
      // 1. PDF Crash (error)
      // 2. Vision batch failed (error)
      // 3. Vision batch error list (warning)
      // 4. Fallback reason (warning)
      // 5. Mixed vision stats (info)
      // 6. Mixed vision diagnostics list (info)
      // 7. Inner error (error)
      expect(res.length, 7);

      final pdfError = res.firstWhere((m) => m.code == 'PDF_RENDER_CRASH');
      expect(pdfError.title, 'PDF 渲染失败');

      final visionError =
          res.firstWhere((m) => m.code == 'VISION_BATCH_FAILED');
      expect(visionError.title, '视觉解析批次失败');

      final mixedInfo = res.firstWhere((m) => m.code == 'MIXED_VISION_STATS');
      expect(mixedInfo.title, '混合视觉资源统计');

      final fallbackWarning = res.firstWhere((m) => m.code == 'FALLBACK');
      expect(fallbackWarning.message, 'Test fallback');

      final innerError = res.firstWhere((m) => m.message == 'Inner error');
      expect(innerError.title, '错误诊断');
    });
  });
}
