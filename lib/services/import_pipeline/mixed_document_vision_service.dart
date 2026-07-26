import 'dart:io';

import 'parsed_document.dart';

class MixedVisionResult {
  final List<Map<String, dynamic>> questions;
  final List<String> diagnostics;
  final List<String> warnings;
  final Map<String, dynamic> metadata;

  MixedVisionResult({
    required this.questions,
    required this.diagnostics,
    required this.warnings,
    this.metadata = const {},
  });
}

class MixedDocumentVisionService {
  final Future<List<Map<String, dynamic>>> Function(List<String> imagePaths)
      parseImages;

  MixedDocumentVisionService({
    required Future<List<Map<String, dynamic>>> Function(
      List<String> imagePaths,
    ) parseImages,
  }) : parseImages = parseImages;

  Future<MixedVisionResult> process(ParsedDocument document) async {
    final diagnostics = <String>[];
    final warnings = <String>[];

    final totalAssets = document.imageAssets.length;
    final resolvableAssets =
        document.imageAssets.where((a) => a.isResolvable).length;
    final unresolvableAssets =
        document.imageAssets.where((a) => !a.isResolvable).length;

    // Warn for unresolvable assets explicitly
    for (final asset in document.imageAssets.where((a) => !a.isResolvable)) {
      warnings.add('图片资产无法解析 (isResolvable=false): ${asset.originalPath}');
    }

    final validAssets = document.imageAssets
        .where((a) => a.isResolvable && a.extractedPath != null)
        .toList();

    // Preserve original document ordering if they have order property
    validAssets.sort((a, b) => a.order.compareTo(b.order));

    final imagePaths = <String>[];
    int missingPathsCount = 0;
    for (final asset in validAssets) {
      if (File(asset.extractedPath!).existsSync()) {
        imagePaths.add(asset.extractedPath!);
      } else {
        missingPathsCount++;
        warnings.add('图片资产路径不存在: ${asset.extractedPath}');
      }
    }

    final skippedCount = totalAssets - imagePaths.length;
    if (skippedCount > 0) {
      warnings.add('跳过了 $skippedCount 张不可解析或丢失的图片。');
    }

    diagnostics.add('总图片资产数: $totalAssets');
    diagnostics.add('可解析图片数: $resolvableAssets');
    diagnostics.add('不可解析资产数: $unresolvableAssets');
    diagnostics.add('缺失路径数: $missingPathsCount');
    diagnostics.add('实际发送 Vision 数: ${imagePaths.length}');
    diagnostics.add('原始顺序是否已排序: true');

    final Map<String, dynamic> metadata = {
      'totalAssets': totalAssets,
      'resolvableAssets': resolvableAssets,
      'unresolvableAssets': unresolvableAssets,
      'missingPathsCount': missingPathsCount,
      'sentCount': imagePaths.length,
      'isSorted': true,
    };

    if (imagePaths.isEmpty) {
      diagnostics.add('没有可用的有效图片资产。');
      return MixedVisionResult(
        questions: [],
        diagnostics: diagnostics,
        warnings: warnings,
        metadata: metadata,
      );
    }

    diagnostics.add('发送了 ${imagePaths.length} 张图片到 Vision 解析。');

    try {
      final questions = await parseImages(imagePaths);
      return MixedVisionResult(
        questions: questions,
        diagnostics: diagnostics,
        warnings: warnings,
        metadata: metadata,
      );
    } catch (e) {
      warnings.add('混合图文 Vision 解析失败: $e');
      return MixedVisionResult(
        questions: [],
        diagnostics: diagnostics,
        warnings: warnings,
        metadata: metadata,
      );
    }
  }
}
