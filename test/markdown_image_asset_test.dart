import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/import_pipeline/adapters/markdown_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  late Directory tempDir;
  late File mdFile;
  late File imgFile;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('md_asset_test');
    imgFile = File(p.join(tempDir.path, 'q1.png'));
    await imgFile.writeAsBytes([0x89, 0x50, 0x4E, 0x47]); // fake png bytes

    mdFile = File(p.join(tempDir.path, 'test.md'));
    await mdFile.writeAsString('第一题\n\n![题图](q1.png)\n\n![不存](missing.png)\n');
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  test('MarkdownDocumentAdapter parses local images as DocumentImageAsset',
      () async {
    final parsed = await MarkdownDocumentAdapter.parse(
      filePath: mdFile.path,
      sourceName: 'test.md',
    );

    // Should have 2 assets (1 resolvable, 1 unresolved)
    expect(parsed.imageAssets.length, 2);
    final asset = parsed.imageAssets.first;
    expect(asset.originalPath, 'q1.png');
    expect(asset.isResolvable, true);
    expect(asset.extractedPath, p.canonicalize(imgFile.path));

    // Check diagnostics for unresolved
    expect(parsed.diagnostics.containsKey('unresolvedImages'), true);
    expect(
        (parsed.diagnostics['unresolvedImages'] as List)
            .contains('missing.png'),
        true);

    // Check ImagePart linking
    final imgParts = parsed.parts.whereType<ImagePart>().toList();
    expect(imgParts.length, 2);

    // First img is resolvable
    expect(imgParts[0].path, 'q1.png');
    expect(imgParts[0].assetId, asset.id);
    expect(imgParts[0].resolvedPath, p.canonicalize(imgFile.path));
    expect(imgParts[0].altText, '题图');

    // Second is not
    expect(imgParts[1].path, 'missing.png');
    expect(imgParts[1].assetId, isNotNull);
    expect(imgParts[1].resolvedPath, null);
    expect(imgParts[1].altText, '不存');

    // toPlainTextForParsing output
    final plainText = parsed.toPlainTextForParsing();
    expect(
        plainText.contains(
            '[Image asset=${asset.id} alt=题图 source=${p.canonicalize(imgFile.path)}]'),
        true);
    expect(
        plainText.contains(
            '[Image asset=${imgParts[1].assetId} alt=不存 source=missing.png]'),
        true);
  });

  test('MarkdownDocumentAdapter rejects absolute and escaping paths', () async {
    final escapingMdFile = File(p.join(tempDir.path, 'escaping.md'));
    await escapingMdFile.writeAsString(
        '第一题\n\n![逃逸](../escaping.png)\n\n![绝对](C:/secret.png)\n\n![绝对斜杠](/secret.png)\n');

    final parsed = await MarkdownDocumentAdapter.parse(
      filePath: escapingMdFile.path,
      sourceName: 'escaping.md',
    );

    // All should be marked as unresolvable
    expect(parsed.imageAssets.length, 3);
    for (final asset in parsed.imageAssets) {
      expect(asset.isResolvable, false);
      expect(asset.extractedPath, null);
    }

    // Warnings diagnostics should be populated
    expect(parsed.diagnostics.containsKey('warnings'), true);
    final warnings = parsed.diagnostics['warnings'] as List;
    expect(warnings.length, 3);
    expect(warnings.any((w) => w.toString().contains('拒绝解析超出目录边界的图片路径')), true);

    // Unresolved list
    expect(parsed.diagnostics.containsKey('unresolvedImages'), true);
    final unresolved = parsed.diagnostics['unresolvedImages'] as List;
    expect(unresolved.contains('../escaping.png'), true);
    expect(unresolved.contains('C:/secret.png'), true);
    expect(unresolved.contains('/secret.png'), true);
  });
}
