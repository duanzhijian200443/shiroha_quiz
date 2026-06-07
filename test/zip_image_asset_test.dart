import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/import_pipeline/adapters/zip_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('zip_asset_test');
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
    final file = File(p.join(tempDir.path, name));
    file.writeAsBytesSync(zipBytes);
    return file;
  }

  test('ZipDocumentAdapter resolves markdown image refs and prevents zip slip',
      () async {
    final file = createMockZip('assets.zip', {
      'docs/a.md': '题干\n![img](../images/q1.png)\n',
      'images/q1.png': [0xFF, 0xD8], // Resolvable
      'images/q2.png': [0xFF, 0xD8], // Unreferenced
      '../evil.png': [0xFF], // Zip slip attempt
    });

    final parsed = await ZipDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'assets.zip',
    );

    // Should drop evil.png, have q1 and q2
    expect(parsed.imageAssets.length, 2);

    // docs/a.md part
    final imgParts = parsed.parts.whereType<ImagePart>().toList();
    // 1 from markdown, 1 unreferenced
    expect(imgParts.length, 2);

    // Referenced image
    expect(imgParts[0].path, '../images/q1.png');
    expect(imgParts[0].resolvedPath, isNotNull);

    // Unreferenced image
    expect(imgParts[1].path, 'images/q2.png');
    expect(imgParts[1].resolvedPath, isNotNull);

    expect(parsed.diagnostics.containsKey('unreferencedImages'), true);
    final unref = parsed.diagnostics['unreferencedImages'] as List;
    expect(unref.contains('images/q2.png'), true);

    expect(parsed.diagnostics.containsKey('warnings'), true);
    final warnings = parsed.diagnostics['warnings'] as List;
    expect(warnings.any((w) => w.toString().contains('非法路径图片')), true);
  });

  test(
      'ZipDocumentAdapter prevents collision for colliding image names like a/b.png vs a_b.png',
      () async {
    final file = createMockZip('collision.zip', {
      'docs/a.md': '题干1\n![img](a/b.png)\n题干2\n![img](a_b.png)\n',
      'a/b.png': [0xFF, 0xD8, 0x01],
      'a_b.png': [0xFF, 0xD8, 0x02],
    });

    final parsed = await ZipDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'collision.zip',
    );

    // Both should be resolvable
    expect(parsed.imageAssets.length, 2);
    final asset1 =
        parsed.imageAssets.firstWhere((a) => a.originalPath == 'a/b.png');
    final asset2 =
        parsed.imageAssets.firstWhere((a) => a.originalPath == 'a_b.png');

    expect(asset1.isResolvable, true);
    expect(asset2.isResolvable, true);

    // They must have different extracted paths, so they don't overwrite each other!
    expect(asset1.extractedPath, isNot(equals(asset2.extractedPath)));

    // Verify file contents of extracted paths are indeed different (not overwritten)
    final file1Bytes = File(asset1.extractedPath!).readAsBytesSync();
    final file2Bytes = File(asset2.extractedPath!).readAsBytesSync();
    expect(file1Bytes, [0xFF, 0xD8, 0x01]);
    expect(file2Bytes, [0xFF, 0xD8, 0x02]);
  });
}
