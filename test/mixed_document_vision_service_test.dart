import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/import_pipeline/document_image_asset.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/mixed_document_vision_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/parsed_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_signals.dart';

void main() {
  late Directory tempDir;
  late File validImg1;
  late File validImg2;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('mixed_vision_test');
    validImg1 = File(p.join(tempDir.path, 'valid1.png'));
    validImg2 = File(p.join(tempDir.path, 'valid2.png'));
    await validImg1.writeAsBytes([1, 2, 3]);
    await validImg2.writeAsBytes([4, 5, 6]);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  test(
      'MixedDocumentVisionService skips missing images and calls parseImages in order',
      () async {
    final doc = ParsedDocument(
      sourceName: 'test',
      format: ImportFormat.md,
      parts: [],
      signals: const DocumentSignals(),
      imageAssets: [
        DocumentImageAsset(
          id: 'img_0',
          order: 2, // intentionally unordered to check sort
          sourceName: 'test',
          originalPath: 'valid2.png',
          extractedPath: validImg2.path,
          isResolvable: true,
        ),
        DocumentImageAsset(
          id: 'img_1',
          order: 0,
          sourceName: 'test',
          originalPath: 'valid1.png',
          extractedPath: validImg1.path,
          isResolvable: true,
        ),
        DocumentImageAsset(
          id: 'img_2',
          order: 1,
          sourceName: 'test',
          originalPath: 'missing.png',
          extractedPath: p.join(tempDir.path, 'missing.png'), // does not exist
          isResolvable: true,
        ),
        DocumentImageAsset(
          id: 'img_3',
          order: 3,
          sourceName: 'test',
          originalPath: 'unresolvable.png',
          extractedPath: null,
          isResolvable: false,
        ),
      ],
    );

    List<String> capturedPaths = [];
    final service = MixedDocumentVisionService(
      parseImages: (paths) async {
        capturedPaths = paths;
        return [
          {'q_num': '1', 'content': 'Fake question from vision'}
        ];
      },
    );

    final result = await service.process(doc);

    // Should only have valid1 and valid2, ordered by order (0 then 2)
    expect(capturedPaths.length, 2);
    expect(capturedPaths[0], validImg1.path);
    expect(capturedPaths[1], validImg2.path);

    expect(result.questions.length, 1);
    expect(result.questions[0]['q_num'], '1');
    expect(
        result.warnings
            .any((w) => w.contains('图片资产路径不存在') || w.contains('不可解析或丢失')),
        true);
    expect(result.diagnostics.any((d) => d.contains('发送了 2 张图片')), true);
  });
}
