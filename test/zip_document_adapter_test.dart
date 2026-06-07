import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/zip_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('zip_test');
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  File createMockZip(String name, Map<String, dynamic> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      List<int> bytes;
      if (entry.value is String) {
        bytes = utf8.encode(entry.value);
      } else {
        bytes = entry.value as List<int>;
      }
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final zipBytes = ZipEncoder().encode(archive)!;
    final file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(zipBytes);
    return file;
  }

  test(
      'ZipDocumentAdapter parses multiple text files in order and skips ignored',
      () async {
    final file = createMockZip('test_multiple.zip', {
      '__MACOSX/ignored.md': 'Ignore me',
      '.DS_Store': [0, 0, 0],
      '1.md': 'First file',
      '2.txt': 'Second file',
      'image.png': [0xFF, 0xD8],
    });

    final parsed = await ZipDocumentAdapter.parse(
        filePath: file.path, sourceName: 'test_multiple.zip');

    // We expect parts: ImagePart for png, text for '--- Source: 1.md ---', text for 'First file', text for '--- Source: 2.txt ---', text for 'Second file'.
    // Note: zip ordering is not strictly alphabetical but rather the order they were added to the archive map.
    // Map entries in Dart preserve insertion order.

    expect(parsed.parts.length, 5);
    expect((parsed.parts[0] as TextPart).text.contains('Source: 1.md'), true);
    expect((parsed.parts[1] as TextPart).text, 'First file');
    expect((parsed.parts[2] as TextPart).text.contains('Source: 2.txt'), true);
    expect((parsed.parts[3] as TextPart).text, 'Second file');
    expect(parsed.parts[4] is ImagePart,
        true); // unreferenced image is added at the end
    expect(parsed.signals.imageCount, 1);
  });

  test('ZipDocumentAdapter warns if only image exists', () async {
    final file = createMockZip('only_image.zip', {
      'image.png': [0xFF, 0xD8],
    });
    final parsed = await ZipDocumentAdapter.parse(
        filePath: file.path, sourceName: 'only_image.zip');
    expect(parsed.diagnostics.containsKey('warnings'), true);
    expect(
        (parsed.diagnostics['warnings'] as List)
            .first
            .toString()
            .contains('仅占位图片'),
        true);
  });

  test('ZipDocumentAdapter aggregates signals from multiple sub-documents',
      () async {
    // md1: 1 question marker, 1 answer marker
    const md1 = '第1题 求矩阵特征值\n\n答案\n\n选B';
    // md2: 1 question marker, 1 formula signal (λ)
    const md2 = '第2题 已知特征值 λ\n\n解析\n\n代入公式';

    final file = createMockZip('signals_test.zip', {
      'chap1.md': md1,
      'chap2.md': md2,
    });

    final parsed = await ZipDocumentAdapter.parse(
        filePath: file.path, sourceName: 'signals_test.zip');

    // Both text signals should be summed across the two sub-documents
    expect(parsed.signals.questionMarkerCount, greaterThanOrEqualTo(2),
        reason: '两个 md 各含 1 个题号，应合并为 ≥2');
    expect(parsed.signals.answerMarkerCount, greaterThanOrEqualTo(2),
        reason: '答案 和 解析 各 1 个，应合并为 ≥2');
    expect(parsed.signals.formulaLikeCount, greaterThanOrEqualTo(1),
        reason: 'λ 和 矩阵 至少有 1 个公式信号');
  });

  test('ZipDocumentAdapter strictly sorts sub-documents lexicographically',
      () async {
    final file = createMockZip('lexicographical_sort.zip', {
      'z.txt': 'Z content',
      'a.txt': 'A content',
      'm.txt': 'M content',
    });

    final parsed = await ZipDocumentAdapter.parse(
        filePath: file.path, sourceName: 'lexicographical_sort.zip');

    // Parts list should order A, then M, then Z.
    // TextPart order in parts: Source a.txt -> A content -> Source m.txt -> M content -> Source z.txt -> Z content.
    final texts =
        parsed.parts.whereType<TextPart>().map((p) => p.text).toList();
    expect(texts[0].contains('Source: a.txt'), true);
    expect(texts[1], 'A content');
    expect(texts[2].contains('Source: m.txt'), true);
    expect(texts[3], 'M content');
    expect(texts[4].contains('Source: z.txt'), true);
    expect(texts[5], 'Z content');
  });

  test('ZipDocumentAdapter rejects zip slip and path traversal entries',
      () async {
    final file = createMockZip('zip_slip.zip', {
      'good.txt': 'Safe content',
      '../evil.txt': 'Malicious file',
      '/absolute.txt': 'Absolute path file',
    });

    final parsed = await ZipDocumentAdapter.parse(
        filePath: file.path, sourceName: 'zip_slip.zip');

    expect(parsed.diagnostics.containsKey('warnings'), true);
    final warnings = parsed.diagnostics['warnings'] as List;
    expect(warnings.any((w) => w.toString().contains('拒绝解析具有潜在路径穿透风险')), true);

    // Make sure 'good.txt' is still parsed
    final texts =
        parsed.parts.whereType<TextPart>().map((p) => p.text).toList();
    expect(texts.any((t) => t.contains('Safe content')), true);
    expect(texts.any((t) => t.contains('Malicious file')), false);
  });
}
