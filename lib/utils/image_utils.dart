import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class ImageUtils {
  const ImageUtils._();

  static List<int> compressForVisionSync(List<int> bytes) {
    return _compressImageSync(
      bytes,
      maxWidth: 900,
      quality: 65,
      failureLog: '图片压缩失败，回退使用原图',
    );
  }

  static List<int> compressFilePreviewSync(List<int> bytes) {
    return _compressImageSync(
      bytes,
      maxWidth: 1024,
      quality: 80,
      failureLog: '图片压缩失败，回退使用原图',
    );
  }

  static List<int> _compressImageSync(
    List<int> bytes, {
    required int maxWidth,
    required int quality,
    required String failureLog,
  }) {
    try {
      final image = img.decodeImage(Uint8List.fromList(bytes));
      if (image == null) return bytes;

      final resized = image.width > maxWidth
          ? img.copyResize(image, width: maxWidth)
          : image;
      return img.encodeJpg(resized, quality: quality);
    } catch (e) {
      debugPrint('$failureLog: $e');
      return bytes;
    }
  }
}
