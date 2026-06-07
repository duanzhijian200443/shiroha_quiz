import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiroha_quiz/services/import_pipeline/adapters/docx_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('docx_chinese_test');
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  File createMockDocx(String name, String documentXml) {
    final archive = Archive();
    final docBytes = utf8.encode(documentXml);
    archive
        .addFile(ArchiveFile('word/document.xml', docBytes.length, docBytes));
    final zipBytes = ZipEncoder().encode(archive)!;
    final file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(zipBytes);
    return file;
  }

  test('DocxDocumentAdapter can extract chinese markers', () async {
    final xml = r'''
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
          <w:p><w:r><w:t>第1题 这是一道数学题，请计算矩阵和特征值</w:t></w:r></w:p>
          <w:p><w:r><w:t>已知特征值为 λ</w:t></w:r></w:p>
          <w:p><w:r><w:t>答案</w:t></w:r></w:p>
          <w:p><w:r><w:t>选B</w:t></w:r></w:p>
          <w:p><w:r><w:t>解析</w:t></w:r></w:p>
          <w:p><w:r><w:t>使用 \frac{1}{2} 公式进行计算</w:t></w:r></w:p>
        </w:body>
      </w:document>
    ''';

    final file = createMockDocx('test_chinese.docx', xml);

    final parsed = await DocxDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'test_chinese.docx',
    );

    expect(parsed.fallbackUsed, false);

    // Check signals
    expect(parsed.signals.questionMarkerCount, 1, reason: 'Should detect 第1题');
    expect(parsed.signals.formulaLikeCount, 3,
        reason: 'Should detect 矩阵, λ, \frac');
    expect(parsed.signals.answerMarkerCount, 2,
        reason: 'Should detect 答案 and 解析');

    // Check roles
    final p1 = parsed.parts[0] as TextPart;
    expect(p1.text, '第1题 这是一道数学题，请计算矩阵和特征值');
    expect(p1.role, TextRole.paragraph);

    final p3 = parsed.parts[2] as TextPart;
    expect(p3.text, '答案');
    expect(p3.role, TextRole.answerBlock);

    final p5 = parsed.parts[4] as TextPart;
    expect(p5.text, '解析');
    expect(p5.role, TextRole.answerBlock);
  });
}
