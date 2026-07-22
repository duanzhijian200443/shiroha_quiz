import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiroha_quiz/services/import_pipeline/adapters/docx_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    // Note: in unit tests, path_provider might not be fully initialized unless using test binding
    // For a pure dart test we can use system temp dir directly.
    tempDir = await Directory.systemTemp.createTemp('docx_test');
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  File createMockDocx(String name, String documentXml,
      {bool hasMedia = false}) {
    final archive = Archive();

    // Add document.xml
    final docBytes = utf8.encode(documentXml);
    archive
        .addFile(ArchiveFile('word/document.xml', docBytes.length, docBytes));

    // Add media
    if (hasMedia) {
      final imgBytes = [0, 1, 2, 3];
      archive.addFile(
          ArchiveFile('word/media/image1.png', imgBytes.length, imgBytes));
    }

    final encoder = ZipEncoder();
    final zipBytes = encoder.encode(archive)!;

    final file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(zipBytes);
    return file;
  }

  test('DocxDocumentAdapter can extract paragraphs and table', () async {
    final xml = '''
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
          <w:p><w:r><w:t>1. 这是一个测试题</w:t></w:r></w:p>
          <w:tbl>
            <w:tr>
              <w:tc><w:p><w:r><w:t>Header1</w:t></w:r></w:p></w:tc>
              <w:tc><w:p><w:r><w:t>Header2</w:t></w:r></w:p></w:tc>
            </w:tr>
            <w:tr>
              <w:tc><w:p><w:r><w:t>Data1</w:t></w:r></w:p></w:tc>
              <w:tc><w:p><w:r><w:t>Data2</w:t></w:r></w:p></w:tc>
            </w:tr>
          </w:tbl>
          <w:p><w:r><w:t>答案：选A</w:t></w:r></w:p>
        </w:body>
      </w:document>
    ''';

    final file = createMockDocx('test_basic.docx', xml, hasMedia: true);

    final parsed = await DocxDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'test_basic.docx',
    );

    expect(parsed.fallbackUsed, false);
    expect(parsed.parts.length, 4);

    expect(parsed.parts[0] is TextPart, true);
    expect((parsed.parts[0] as TextPart).text.trim(), '1. 这是一个测试题');

    expect(parsed.parts[1] is TablePart, true);
    expect((parsed.parts[1] as TablePart).rows.length, 2);
    expect((parsed.parts[1] as TablePart).rows[0], ['Header1', 'Header2']);

    expect(parsed.parts[2] is TextPart, true);
    expect((parsed.parts[2] as TextPart).role, TextRole.answerBlock);

    expect(parsed.signals.imageCount, 1);
    expect(parsed.signals.tableCount, 1);
    expect(parsed.signals.questionMarkerCount, 1);
    expect(parsed.signals.answerMarkerCount, 1);

    final plainText = parsed.toPlainTextForParsing();
    expect(plainText.contains('1. 这是一个测试题'), true);
    expect(plainText.contains('| Header1 | Header2 |'), true);
  });

  test('DocxDocumentAdapter fallbacks on malformed XML or missing document.xml',
      () async {
    final archive = Archive();
    final encoder = ZipEncoder();
    final zipBytes = encoder.encode(archive)!;
    final file = File('${tempDir.path}/test_empty.docx');
    file.writeAsBytesSync(zipBytes);

    final parsed = await DocxDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'test_empty.docx',
    );

    expect(parsed.fallbackUsed, true);
    expect(parsed.parts.length, 1);
    expect((parsed.parts.first as TextPart).role, TextRole.paragraph);
  });

  test(
      'DocxDocumentAdapter can extract formula and handle w:tbl prefix bug defense',
      () async {
    final xml = '''
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">
        <w:body>
          <w:p>
            <w:r><w:t>已知公式：</w:t></w:r>
            <m:oMath>
              <m:r><m:t>E=mc</m:t></m:r>
              <m:r><m:t>^2</m:t></m:r>
            </m:oMath>
            <w:r><w:t> 是著名的物理公式。</w:t></w:r>
          </w:p>
          <w:tbl>
            <w:tr>
              <w:tc><w:p><w:r><w:t>表格数据</w:t></w:r></w:p></w:tc>
            </w:tr>
          </w:tbl>
        </w:body>
      </w:document>
    ''';

    final file = createMockDocx('test_formula.docx', xml);

    final parsed = await DocxDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'test_formula.docx',
    );

    expect(parsed.fallbackUsed, false);
    final textPart = parsed.parts[0] as TextPart;
    expect(textPart.text, contains('已知公式： E=mc^2  是著名的物理公式。'));
  });
}
