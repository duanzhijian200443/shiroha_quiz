import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

class PdfPageRenderResult {
  final List<String> imagePaths;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;

  const PdfPageRenderResult({
    required this.imagePaths,
    required this.warnings,
    required this.diagnostics,
  });
}

class PdfPageImageRenderer {
  const PdfPageImageRenderer();

  Future<PdfPageRenderResult> renderToImages({
    required String filePath,
    required int fileIndex,
  }) async {
    final List<String> imagePaths = [];
    final List<String> warnings = [];
    final Map<String, dynamic> diagnostics = {};

    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw Exception('PDF 文件不存在: $filePath');
      }

      final tempDir = await getTemporaryDirectory();
      final document = await pdfx.PdfDocument.openFile(filePath);
      final pageCount = document.pagesCount;

      diagnostics['totalPages'] = pageCount;
      diagnostics['filePath'] = filePath;

      if (pageCount == 0) {
        warnings.add('PDF 文件没有可用的页面: $filePath');
        return PdfPageRenderResult(
          imagePaths: const [],
          warnings: warnings,
          diagnostics: {
            ...diagnostics,
            'status': 'empty_pdf',
          },
        );
      }

      int renderSuccessCount = 0;
      int renderFailedCount = 0;
      final List<String> renderErrors = [];

      for (int i = 1; i <= pageCount; i++) {
        pdfx.PdfPage? page;
        try {
          page = await document.getPage(i);
          double scale = 900 / page.width;
          if (scale > 2.0) scale = 2.0;
          if (scale < 1.0) scale = 1.0;

          final pageImage = await page.render(
            width: page.width * scale,
            height: page.height * scale,
            format: pdfx.PdfPageImageFormat.jpeg,
          );

          if (pageImage != null) {
            final imgFile =
                File('${tempDir.path}/file_${fileIndex}_page_$i.jpg');
            await imgFile.writeAsBytes(pageImage.bytes);
            imagePaths.add(imgFile.path);
            renderSuccessCount++;
          } else {
            throw Exception('Page render returned null bytes');
          }
        } catch (e) {
          renderFailedCount++;
          renderErrors.add('第 $i 页渲染失败: $e');
          warnings.add('PDF 文件第 $i 页渲染失败，已跳过。');
        } finally {
          if (page != null) {
            await page.close();
          }
        }
      }

      await document.close();

      diagnostics['renderSuccessCount'] = renderSuccessCount;
      diagnostics['renderFailedCount'] = renderFailedCount;
      if (renderErrors.isNotEmpty) {
        diagnostics['renderErrors'] = renderErrors;
      }

      return PdfPageRenderResult(
        imagePaths: imagePaths,
        warnings: warnings,
        diagnostics: diagnostics,
      );
    } catch (e) {
      debugPrint('PdfPageImageRenderer: PDF render crash: $e');
      return PdfPageRenderResult(
        imagePaths: const [],
        warnings: ['PDF 文件渲染崩溃，已放弃渲染图片: $e'],
        diagnostics: {
          'status': 'crash',
          'error': e.toString(),
        },
      );
    }
  }
}
