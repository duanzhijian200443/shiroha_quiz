import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/markdown_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  test('MarkdownDocumentAdapter parses heading and paragraphs', () {
    final md = '''
# Heading 1

This is a paragraph.

## 第1题

This is question 1.
''';

    final parsed = MarkdownDocumentAdapter.parseContent(
        content: md, sourceName: 'test.md');
    expect(parsed.parts.length, 4);
    expect((parsed.parts[0] as TextPart).role, TextRole.heading);
    expect((parsed.parts[1] as TextPart).role, TextRole.paragraph);
    expect((parsed.parts[2] as TextPart).text, '第1题');
    expect(parsed.signals.questionMarkerCount, 1);
  });

  test('MarkdownDocumentAdapter parses GFM table', () {
    final md = '''
| Col 1 | Col 2 |
| ----- | ----- |
| Val 1 | Val 2 |
''';
    final parsed = MarkdownDocumentAdapter.parseContent(
        content: md, sourceName: 'test.md');
    expect(parsed.parts.length, 1);
    expect(parsed.parts[0] is TablePart, true);
    final table = parsed.parts[0] as TablePart;
    expect(table.rows.length, 2);
    expect(table.rows[0], ['Col 1', 'Col 2']);
    expect(table.rows[1], ['Val 1', 'Val 2']);
  });

  test(
      'MarkdownDocumentAdapter handles fenced code blocks avoiding false positives',
      () {
    final md = '''
```python
# 第1题
def func():
    return '\\frac{1}{2}'
```
''';
    final parsed = MarkdownDocumentAdapter.parseContent(
        content: md, sourceName: 'test.md');
    expect(parsed.parts.length, 1);
    expect(parsed.signals.questionMarkerCount,
        0); // Should ignore inside code block
    expect(parsed.signals.formulaLikeCount, 0);
  });

  test('MarkdownDocumentAdapter parses image links', () {
    final md = '![Alt Text](image.png)';
    final parsed = MarkdownDocumentAdapter.parseContent(
        content: md, sourceName: 'test.md');
    expect(parsed.parts.length, 1);
    expect(parsed.parts[0] is ImagePart, true);
    expect((parsed.parts[0] as ImagePart).path, 'image.png');
    expect((parsed.parts[0] as ImagePart).relationshipId, 'Alt Text');
    expect(parsed.signals.imageCount, 1);
    expect(parsed.diagnostics.containsKey('warning'),
        true); // warning for only having image
  });
  test(
      'MarkdownDocumentAdapter detects Chinese markers in headings and paragraphs',
      () {
    final md = '''
## 第1题 以下哪个矩阵满足条件

已知特征值 λ 满足方程 \frac{1}{2}

### 答案

选B

### 解析

代入公式求解
''';
    final parsed = MarkdownDocumentAdapter.parseContent(
        content: md, sourceName: 'zh_test.md');
    expect(parsed.signals.questionMarkerCount, greaterThanOrEqualTo(1),
        reason: '应检测到 第1题');
    expect(parsed.signals.answerMarkerCount, greaterThanOrEqualTo(1),
        reason: '应检测到 答案/解析');
    expect(parsed.signals.formulaLikeCount, greaterThanOrEqualTo(1),
        reason: '应检测到 矩阵/λ/\frac');
  });

  test('MarkdownDocumentAdapter parses with_local_image.md fixture', () async {
    final file =
        File('test/fixtures/import_pipeline/markdown/with_local_image.md');
    if (file.existsSync()) {
      final parsed = await MarkdownDocumentAdapter.parse(
          filePath: file.path, sourceName: 'with_local_image.md');
      // note: the image "images/test.png" doesn't exist, so isResolvable = false, but it should parse
      expect(parsed.signals.imageCount, 1);
      expect(parsed.imageAssets.length, 1);
      expect(parsed.imageAssets.first.originalPath, 'images/test.png');
    }
  });

  test(
      'MarkdownDocumentAdapter parses missing_image.md fixture and records in unresolvedImages',
      () async {
    final file =
        File('test/fixtures/import_pipeline/markdown/missing_image.md');
    if (file.existsSync()) {
      final parsed = await MarkdownDocumentAdapter.parse(
          filePath: file.path, sourceName: 'missing_image.md');
      expect(parsed.imageAssets.length, 1);
      expect(parsed.imageAssets.first.isResolvable, false);
      expect(parsed.diagnostics.containsKey('unresolvedImages'), true);
      expect(
          (parsed.diagnostics['unresolvedImages'] as List)
              .contains('images/does_not_exist.png'),
          true);
    }
  });

  test(
      'MarkdownDocumentAdapter parses path_traversal.md and triggers traversal protection warnings',
      () async {
    final file =
        File('test/fixtures/import_pipeline/markdown/path_traversal.md');
    if (file.existsSync()) {
      final parsed = await MarkdownDocumentAdapter.parse(
          filePath: file.path, sourceName: 'path_traversal.md');
      expect(parsed.imageAssets.length, 3);
      for (final asset in parsed.imageAssets) {
        expect(asset.isResolvable, false);
      }
      expect(parsed.diagnostics.containsKey('warnings'), true);
      final warnings = parsed.diagnostics['warnings'] as List;
      expect(warnings.length, 3);
      expect(
          warnings.any((w) => w.toString().contains('拒绝解析超出目录边界的图片路径')), true);
    }
  });
}
