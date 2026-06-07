import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/import_pipeline/adapters/docx_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('docx_asset_test');
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  File createMockDocx(String name, Map<String, dynamic> files) {
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

  test('DocxDocumentAdapter extracts media images to assets', () async {
    final file = createMockDocx('mock.docx', {
      'word/document.xml':
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document><w:body><w:p><w:t>Hello</w:t></w:p></w:body></w:document>',
      'word/media/image1.png': [0x89, 0x50, 0x4E, 0x47],
    });

    final parsed = await DocxDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'mock.docx',
    );

    expect(parsed.imageAssets.length, 1);
    final asset = parsed.imageAssets.first;
    expect(asset.originalPath, 'word/media/image1.png');
    expect(asset.isResolvable, true);
    expect(asset.extractedPath, isNotNull);

    expect(parsed.diagnostics.containsKey('docxImagePlacement'), true);

    final imgParts = parsed.parts.whereType<ImagePart>().toList();
    expect(imgParts.length, 1);
    expect(imgParts[0].path, 'word/media/image1.png');
    expect(imgParts[0].assetId, asset.id);
  });

  test('DocxDocumentAdapter fallback does not crash on missing xml with images',
      () async {
    final file = createMockDocx('bad.docx', {
      // missing word/document.xml
      'word/media/image1.png': [0x89, 0x50, 0x4E, 0x47],
    });

    final parsed = await DocxDocumentAdapter.parse(
      filePath: file.path,
      sourceName: 'bad.docx',
    );

    expect(parsed.fallbackUsed, true);
  });
}
