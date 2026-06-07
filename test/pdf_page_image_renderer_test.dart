import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/pdf_page_image_renderer.dart';

void main() {
  group('PdfPageImageRenderer Tests', () {
    test('Non-existent file returns warning and crash status in diagnostics',
        () async {
      const renderer = PdfPageImageRenderer();
      final res = await renderer.renderToImages(
        filePath: 'non_existent_file.pdf',
        fileIndex: 0,
      );

      expect(res.imagePaths, isEmpty);
      expect(res.warnings.length, 1);
      expect(res.warnings[0].contains('PDF 文件渲染崩溃'), true);
      expect(res.diagnostics['status'], 'crash');
      expect(res.diagnostics['error'].contains('PDF 文件不存在'), true);
    });
  });
}
