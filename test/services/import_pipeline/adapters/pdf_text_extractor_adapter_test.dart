import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/pdf_text_extractor_adapter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pdf_helper_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('extracts text from a synthetic text PDF', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}text.pdf';
    await File(path).writeAsBytes(_buildTextPdf('formal pdf paragraph'));

    final text = await PdfTextExtractorAdapter.extractText(filePath: path);

    expect(text, contains('formal pdf paragraph'));
  });

  test('blank PDF extraction yields empty or whitespace-only text', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}blank.pdf';
    await File(path).writeAsBytes(_buildBlankPdf());

    final text = await PdfTextExtractorAdapter.extractText(filePath: path);

    expect(text.trim(), isEmpty);
  });

  test('missing source propagates the filesystem failure', () async {
    final missing = '${tempDir.path}${Platform.pathSeparator}missing.pdf';
    await expectLater(
      PdfTextExtractorAdapter.extractText(filePath: missing),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('production code owns exactly one Syncfusion PDF extraction site', () {
    const helperPath = 'lib/services/import_pipeline/adapters/'
        'pdf_text_extractor_adapter.dart';
    final extractorOwners = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final content = entity.readAsStringSync();
      if (content.contains('PdfTextExtractor(')) {
        extractorOwners.add(entity.path.replaceAll('\\', '/'));
      }
    }
    expect(extractorOwners, <String>[helperPath]);

    final pipeline =
        File('lib/services/import_pipeline/import_pipeline_service.dart')
            .readAsStringSync();
    expect(pipeline, contains('PdfTextExtractorAdapter.extractText'));
    expect(pipeline, isNot(contains('PdfTextExtractor(')));
  });
}

List<int> _buildTextPdf(String text) {
  final document = PdfDocument();
  document.pages.add().graphics.drawString(
        text,
        PdfStandardFont(PdfFontFamily.helvetica, 12),
      );
  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}

List<int> _buildBlankPdf() {
  final document = PdfDocument();
  document.pages.add();
  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}
