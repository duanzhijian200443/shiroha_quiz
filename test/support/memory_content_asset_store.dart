import 'dart:convert';
import 'dart:io';

import 'package:shiroha_quiz/domain/backup/archive_path_policy.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';

/// In-memory test double for [ContentAssetStore].
final class MemoryContentAssetStore implements ContentAssetStore {
  MemoryContentAssetStore();

  final Map<String, List<int>> storage = <String, List<int>>{};

  static final RegExp _dataUrlPattern = RegExp(
    r'^data:(image/(?:png|jpeg|jpg|webp|gif));base64,([A-Za-z0-9+/=\s]+)$',
    caseSensitive: false,
  );

  @override
  Future<String> storeDataUrl(String dataUrl) async {
    return storeDataUrlSync(dataUrl);
  }

  @override
  String storeDataUrlSync(String dataUrl) {
    final match = _dataUrlPattern.firstMatch(dataUrl.trim());
    if (match == null) {
      throw const FormatException('Invalid or unsupported image Data URL.');
    }
    final mimeType = match.group(1)!.toLowerCase();
    final base64Payload = match.group(2)!.replaceAll(RegExp(r'\s+'), '');
    final bytes = base64Decode(base64Payload);
    if (bytes.isEmpty) {
      throw const FormatException('Image payload bytes must not be empty.');
    }
    return storeBytesSync(bytes: bytes, mimeType: mimeType);
  }

  @override
  Future<String> storeBytes({
    required List<int> bytes,
    required String mimeType,
  }) async {
    return storeBytesSync(bytes: bytes, mimeType: mimeType);
  }

  @override
  String storeBytesSync({
    required List<int> bytes,
    required String mimeType,
  }) {
    if (bytes.isEmpty) {
      throw const FormatException('Cannot store empty image bytes.');
    }
    final digest = sha256Hex(bytes);
    final ext = switch (mimeType.toLowerCase()) {
      'image/png' => '.png',
      'image/jpeg' || 'image/jpg' => '.jpg',
      'image/webp' => '.webp',
      'image/gif' => '.gif',
      _ => throw FormatException('Unsupported image MIME type: $mimeType'),
    };
    final fileName = '$digest$ext';
    final storageKey = 'content_assets/$fileName';

    if (!ArchivePathPolicy.isSafeManagedStorageKey(storageKey)) {
      throw const FormatException('Generated storage key is not safe.');
    }

    storage[storageKey] = List<int>.from(bytes);
    return storageKey;
  }

  @override
  File? resolveAsset(String assetRef) {
    return null;
  }
}
