import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/txt_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('txt_test');
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  File createTestFile(String name, List<int> bytes) {
    final file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  test('TxtDocumentAdapter handles UTF-8 BOM', () async {
    final content = '第1题 测试题\n\n答案：A';
    final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(content)];
    final file = createTestFile('bom.txt', bytes);

    final parsed = await TxtDocumentAdapter.parse(
        filePath: file.path, sourceName: 'bom.txt');
    expect(parsed.parts.length, 2);
    expect((parsed.parts[0] as TextPart).text, '第1题 测试题');
    expect(parsed.signals.questionMarkerCount, 1);
    expect(parsed.signals.answerMarkerCount, 1);
  });

  test('TxtDocumentAdapter normalizes CRLF and handles multiple paragraphs',
      () async {
    final content = 'Para 1\r\n\r\nPara 2\r\n\nPara 3';
    final file = createTestFile('crlf.txt', utf8.encode(content));

    final parsed = await TxtDocumentAdapter.parse(
        filePath: file.path, sourceName: 'crlf.txt');
    expect(parsed.parts.length, 3);
    expect((parsed.parts[0] as TextPart).text, 'Para 1');
    expect((parsed.parts[1] as TextPart).text, 'Para 2');
    expect((parsed.parts[2] as TextPart).text, 'Para 3');
  });

  test('TxtDocumentAdapter handles empty file without crash', () async {
    final file = createTestFile('empty.txt', []);
    final parsed = await TxtDocumentAdapter.parse(
        filePath: file.path, sourceName: 'empty.txt');
    expect(parsed.parts.isEmpty, true);
    expect(parsed.diagnostics.containsKey('warning'), true);
  });

  test('TxtDocumentAdapter detects Chinese question / answer / formula signals',
      () async {
    final content = '''第1题 已知矩阵特征值 λ 满足条件

(2) 求解方程

答案

解析：使用 \\frac{1}{2} 公式''';
    final bytes = utf8.encode(content);
    final file = createTestFile('chinese_signals.txt', bytes);

    final parsed = await TxtDocumentAdapter.parse(
        filePath: file.path, sourceName: 'chinese_signals.txt');
    expect(parsed.signals.questionMarkerCount, greaterThanOrEqualTo(1),
        reason: '应检测到 第1题');
    expect(parsed.signals.answerMarkerCount, greaterThanOrEqualTo(1),
        reason: '应检测到 答案/解析');
    expect(parsed.signals.formulaLikeCount, greaterThanOrEqualTo(1),
        reason: '应检测到 矩阵/λ/\\frac');
  });

  test('TxtDocumentAdapter parses tail_answers.txt fixture correctly',
      () async {
    final file = File('test/fixtures/import_pipeline/txt/simple_questions.txt');
    if (file.existsSync()) {
      final parsed = await TxtDocumentAdapter.parse(
          filePath: file.path, sourceName: 'simple_questions.txt');
      expect(parsed.signals.questionMarkerCount, 2);
      expect(parsed.signals.answerMarkerCount, 2);
    }
  });

  test('TxtDocumentAdapter parses tail_answers.txt with tail answer block',
      () async {
    final file = File('test/fixtures/import_pipeline/txt/tail_answers.txt');
    if (file.existsSync()) {
      final parsed = await TxtDocumentAdapter.parse(
          filePath: file.path, sourceName: 'tail_answers.txt');
      expect(parsed.signals.hasTailAnswerBlock, true);
    }
  });

  test(
      'TxtDocumentAdapter parses weak_structure.txt with weak structure signals',
      () async {
    final file = File('test/fixtures/import_pipeline/txt/weak_structure.txt');
    if (file.existsSync()) {
      final parsed = await TxtDocumentAdapter.parse(
          filePath: file.path, sourceName: 'weak_structure.txt');
      expect(parsed.signals.questionMarkerCount, 0);
      expect(parsed.signals.answerMarkerCount, 0);
      expect(parsed.signals.hasTailAnswerBlock, false);
    }
  });
}
