import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/backup/archive_path_policy.dart';

/// Abstract storage authority for question rich content assets (images).
abstract interface class ContentAssetStore {
  /// Asynchronously decodes and stores a base64 Data URL.
  ///
  /// Returns the canonical relative storage key (e.g. `content_assets/<sha256>.<ext>`).
  Future<String> storeDataUrl(String dataUrl);

  /// Synchronously decodes and stores a base64 Data URL.
  ///
  /// Returns the canonical relative storage key (e.g. `content_assets/<sha256>.<ext>`).
  String storeDataUrlSync(String dataUrl);

  /// Asynchronously stores raw image bytes.
  Future<String> storeBytes({
    required List<int> bytes,
    required String mimeType,
  });

  /// Synchronously stores raw image bytes.
  String storeBytesSync({
    required List<int> bytes,
    required String mimeType,
  });

  /// Resolves a relative storage key to a local filesystem [File].
  ///
  /// Returns null if the storage key is unsafe or the file does not exist.
  File? resolveAsset(String assetRef);
}

/// Abstract resolver used by UI and application layers to locate image files.
abstract interface class ContentAssetResolver {
  File? resolveAsset(String assetRef);
}

/// Global ambient resolver for UI and tests.
final class DefaultContentAssetResolver implements ContentAssetResolver {
  DefaultContentAssetResolver._();

  static final DefaultContentAssetResolver instance =
      DefaultContentAssetResolver._();

  ContentAssetStore? _store;

  /// Sets the active content asset store.
  void setStore(ContentAssetStore? store) {
    _store = store;
  }

  @override
  File? resolveAsset(String assetRef) {
    return _store?.resolveAsset(assetRef);
  }
}

/// Filesystem-backed implementation of [ContentAssetStore].
///
/// Stores files under `<managedRoot>/content_assets/<sha256>.<ext>`.
final class ManagedContentAssetStore implements ContentAssetStore {
  ManagedContentAssetStore({
    required Directory managedRoot,
  }) : _managedRoot = managedRoot;

  final Directory _managedRoot;

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
    final digest = sha256.convert(bytes).toString();
    final ext = _extensionForMime(mimeType);
    final fileName = '$digest$ext';
    final storageKey = 'content_assets/$fileName';

    if (!ArchivePathPolicy.isSafeManagedStorageKey(storageKey)) {
      throw const FormatException('Generated storage key is not safe.');
    }

    final targetDir = Directory(p.join(_managedRoot.path, 'content_assets'));
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final targetFile = File(p.join(targetDir.path, fileName));
    if (targetFile.existsSync() && targetFile.lengthSync() == bytes.length) {
      return storageKey;
    }

    final tmpFile = File(p.join(targetDir.path,
        '$fileName.tmp_${DateTime.now().microsecondsSinceEpoch}'));
    tmpFile.writeAsBytesSync(bytes, flush: true);
    tmpFile.renameSync(targetFile.path);

    return storageKey;
  }

  @override
  File? resolveAsset(String assetRef) {
    final trimmed = assetRef.trim();
    if (trimmed.isEmpty) return null;
    if (!ArchivePathPolicy.isSafeManagedStorageKey(trimmed)) {
      return null;
    }
    final file = File(p.join(_managedRoot.path, trimmed));
    if (!file.existsSync()) {
      return null;
    }
    return file;
  }

  static String _extensionForMime(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'image/png' => '.png',
      'image/jpeg' || 'image/jpg' => '.jpg',
      'image/webp' => '.webp',
      'image/gif' => '.gif',
      _ => '.png',
    };
  }
}
