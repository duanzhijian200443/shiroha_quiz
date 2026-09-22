import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../utils/image_utils.dart';
import 'llm_providers/llm_provider_client.dart';

Uint8List _compressForVisionIsolate(Uint8List bytes) {
  return Uint8List.fromList(ImageUtils.compressForVisionSync(bytes));
}

class VisionAssetBuilder {
  const VisionAssetBuilder();

  /// Durable bytes are decoded and re-encoded; invalid images fail closed.
  Future<LlmVisionAsset> buildInlineImageBytes(List<int> bytes) async {
    try {
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded == null) {
        throw const FormatException('Invalid context image.');
      }
      final resized =
          decoded.width > 1024 ? img.copyResize(decoded, width: 1024) : decoded;
      return LlmVisionAsset.inline(
        mimeType: 'image/jpeg',
        base64Data: base64Encode(img.encodeJpg(resized, quality: 80)),
      );
    } catch (_) {
      throw const FormatException('Invalid context image.');
    }
  }

  Future<List<LlmVisionAsset>> buildInlineImageAssets(
    List<String> imagePaths, {
    int compressionThresholdBytes = 500 * 1024,
  }) async {
    final assets = <LlmVisionAsset>[];

    for (final path in imagePaths) {
      var bytes = await File(path).readAsBytes();
      if (bytes.length > compressionThresholdBytes) {
        bytes = await compute(_compressForVisionIsolate, bytes);
        debugPrint('多图预处理: 图片 $path 已压缩至 ${bytes.length ~/ 1024} KB');
      }

      assets.add(
        LlmVisionAsset.inline(
          mimeType: 'image/jpeg',
          base64Data: base64Encode(bytes),
        ),
      );
    }

    return assets;
  }

  Future<LlmVisionAsset> buildInlineFileAsset(
    String filePath, {
    required String mimeType,
    required bool compressImage,
  }) async {
    var bytes = await File(filePath).readAsBytes();
    if (compressImage) {
      bytes = Uint8List.fromList(ImageUtils.compressFilePreviewSync(bytes));
      debugPrint('图片压缩完成，压缩后大小: ${bytes.length ~/ 1024} KB');
    }

    return LlmVisionAsset.inline(
      mimeType: mimeType,
      base64Data: base64Encode(bytes),
    );
  }
}
