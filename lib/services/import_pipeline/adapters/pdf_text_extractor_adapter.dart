import 'dart:io';

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Single shared owner of Syncfusion PDF text extraction.
///
/// `ImportPipelineService` and the F1-I1 deterministic generation adapter
/// both call this helper, so production code contains exactly one
/// `PdfTextExtractor(...).extractText()` implementation. The helper only
/// extracts text; empty-text and OCR routing decisions stay with callers.
final class PdfTextExtractorAdapter {
  const PdfTextExtractorAdapter._();

  static Future<String> extractText({required String filePath}) async {
    final bytes = await File(filePath).readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    try {
      return PdfTextExtractor(document).extractText();
    } finally {
      document.dispose();
    }
  }
}
