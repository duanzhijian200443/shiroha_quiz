import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../application/content/content_asset_authority.dart';
import '../../domain/backup/archive_path_policy.dart';
import '../../domain/assets/sourced_asset_ref.dart';
import '../../domain/assets/image_byte_signature.dart';
import '../backup/sha256.dart';
import 'windows_reparse_point_probe.dart';

/// Filesystem-backed content asset authority under the existing managed root.
///
/// No database registry is needed: the source-qualified identity determin-
/// istically names the managed file, and the bytes are written atomically.
/// Replacing an existing identity with different bytes is rejected rather
/// than silently changing a confirmed question's asset.
final class ManagedContentAssetStore
    implements ContentAssetStore, ContentAssetAuthority, ContentAssetResolver {
  ManagedContentAssetStore({required Directory managedRoot})
      : _managedRoot = p.normalize(managedRoot.path);

  static const int maxImageBytes = 10 * 1024 * 1024;

  /// v0 complete-proof ceiling for one destructive-maintenance scan. The
  /// count covers physical entries under the managed asset root, meaning
  /// source directories and their asset files together. Breaching it, or the
  /// [completeInventoryTimeBudget] below, reports an incomplete pass and
  /// deletes nothing; it is not a limit on how many assets a library may
  /// hold, read or use.
  static const int completeInventoryEntryCeiling = 5000;
  static const Duration completeInventoryTimeBudget = Duration(seconds: 2);
  static final RegExp _identityPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );
  static final RegExp _mimePattern = RegExp(
    r'^image/(?:png|jpeg|jpg|webp|gif)$',
    caseSensitive: false,
  );

  final String _managedRoot;

  @override
  String storageKey({required String sourceId, required String localAssetId}) {
    _validateIdentity(sourceId, 'sourceId');
    _validateIdentity(localAssetId, 'localAssetId');
    final key = 'content_assets/$sourceId/$localAssetId';
    if (!ArchivePathPolicy.isSafeManagedStorageKey(key)) {
      throw const FormatException('Content asset storage identity is unsafe.');
    }
    return key;
  }

  @override
  Future<ContentAssetWriteResult> storeBytes({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) async {
    return storeBytesSync(
      sourceId: sourceId,
      localAssetId: localAssetId,
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  @override
  ContentAssetWriteResult storeBytesSync({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) {
    if (bytes.isEmpty || bytes.length > maxImageBytes) {
      throw const FormatException('Content asset byte size is unsupported.');
    }
    final normalizedMime = mimeType.trim().toLowerCase().split(';').first;
    if (!_mimePattern.hasMatch(normalizedMime) ||
        !ImageByteSignature.matchesMime(bytes, normalizedMime)) {
      throw const FormatException('Content asset media type is unsupported.');
    }

    final key = storageKey(sourceId: sourceId, localAssetId: localAssetId);
    final target = _resolveKey(key);
    final expectedDigest = sha256Hex(bytes);
    if (target.existsSync()) {
      final existing = _readDigest(target);
      if (existing != expectedDigest) {
        throw const FormatException(
          'Content asset identity already contains different bytes.',
        );
      }
      return ContentAssetWriteResult(
        storageKey: key,
        sha256: expectedDigest,
        sizeBytes: bytes.length,
        mimeType: _canonicalMime(normalizedMime),
        created: false,
      );
    }

    target.parent.createSync(recursive: true);
    final temporary = File(
      '${target.path}.tmp_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(target.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }

    try {
      if (_readDigest(target) != expectedDigest) {
        throw const ContentAssetWriteVisibilityException();
      }
    } catch (_) {
      throw const ContentAssetWriteVisibilityException();
    }
    return ContentAssetWriteResult(
      storageKey: key,
      sha256: expectedDigest,
      sizeBytes: bytes.length,
      mimeType: _canonicalMime(normalizedMime),
      created: true,
    );
  }

  @override
  Future<ContentAssetRollbackResult> deleteCandidateAssets(
    ContentAssetCandidateLease lease,
  ) async {
    var deletedCount = 0;
    var missingCount = 0;
    var failedCount = 0;
    for (final localAssetId in lease.localAssetIds) {
      try {
        final file = _resolveKey(
          storageKey(
            sourceId: lease.sourceId,
            localAssetId: localAssetId,
          ),
        );
        if (await file.exists()) {
          await file.delete();
          deletedCount++;
        } else {
          missingCount++;
        }
      } on FileSystemException {
        failedCount++;
      } on FormatException {
        failedCount++;
      }
    }
    return ContentAssetRollbackResult(
      deletedCount: deletedCount,
      missingCount: missingCount,
      failedCount: failedCount,
    );
  }

  @override
  List<int>? readAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) {
    try {
      final file = _resolveKey(
        storageKey(sourceId: sourceId, localAssetId: localAssetId),
      );
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      if (bytes.isEmpty ||
          bytes.length > maxImageBytes ||
          ImageByteSignature.detectMime(bytes) == null) {
        return null;
      }
      return List<int>.unmodifiable(bytes);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  List<int>? resolveAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) {
    return readAssetBytes(sourceId: sourceId, localAssetId: localAssetId);
  }

  @override
  Future<List<int>?> resolveAssetBytesAsync({
    required String sourceId,
    required String localAssetId,
  }) async {
    try {
      final file = _resolveKey(
        storageKey(sourceId: sourceId, localAssetId: localAssetId),
      );
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty ||
          bytes.length > maxImageBytes ||
          ImageByteSignature.detectMime(bytes) == null) {
        return null;
      }
      return List<int>.unmodifiable(bytes);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<bool> assetExists({
    required String sourceId,
    required String localAssetId,
  }) async {
    try {
      final file = _resolveKey(
        storageKey(sourceId: sourceId, localAssetId: localAssetId),
      );
      return file.existsSync();
    } on FormatException {
      return false;
    }
  }

  @override
  Future<List<ContentAssetRecord>> listAssets() async {
    final root = Directory(p.join(_managedRoot, 'content_assets'));
    if (!await root.exists()) return const <ContentAssetRecord>[];

    final records = <ContentAssetRecord>[];
    await for (final sourceEntity in root.list(followLinks: false)) {
      if (sourceEntity is! Directory) continue;
      final sourceId = p.basename(sourceEntity.path);
      if (!_identityPattern.hasMatch(sourceId)) continue;
      await for (final assetEntity in sourceEntity.list(followLinks: false)) {
        if (assetEntity is! File) continue;
        final localAssetId = p.basename(assetEntity.path);
        if (!_identityPattern.hasMatch(localAssetId) ||
            localAssetId.startsWith('.tmp_')) {
          continue;
        }
        final key = storageKey(
          sourceId: sourceId,
          localAssetId: localAssetId,
        );
        final bytes = await assetEntity.readAsBytes();
        if (bytes.isEmpty ||
            bytes.length > maxImageBytes ||
            ImageByteSignature.detectMime(bytes) == null) {
          continue;
        }
        records.add(
          ContentAssetRecord(
            sourceId: sourceId,
            localAssetId: localAssetId,
            storageKey: key,
            sizeBytes: bytes.length,
            sha256: sha256Hex(bytes),
          ),
        );
      }
    }
    records.sort((a, b) {
      final source = a.sourceId.compareTo(b.sourceId);
      if (source != 0) return source;
      return a.localAssetId.compareTo(b.localAssetId);
    });
    return List<ContentAssetRecord>.unmodifiable(records);
  }

  /// Strict destructive-maintenance inventory. Unlike [listAssets], every
  /// physical entry is accounted for; ambiguity aborts the entire scan.
  Future<List<ContentAssetRecord>> inspectCompleteInventory({
    int maxEntries = completeInventoryEntryCeiling,
    Duration maxDuration = completeInventoryTimeBudget,
  }) async {
    final classified = await classifyPhysicalInventory(
      maxEntries: maxEntries,
      maxDuration: maxDuration,
    );
    if (classified.unknownCount != 0) {
      throw ContentAssetPhysicalInventoryException(
          unknownCount: classified.unknownCount);
    }
    return classified.records;
  }

  /// Classifies each encountered directory entry once before content reads.
  /// Unknown entries are retained and prevent a destructive pass.
  Future<ContentAssetPhysicalInventory> classifyPhysicalInventory({
    int maxEntries = completeInventoryEntryCeiling,
    Duration maxDuration = completeInventoryTimeBudget,
  }) async {
    final watch = Stopwatch()..start();
    void checkBound(int entries) {
      if (entries > maxEntries || watch.elapsed >= maxDuration) {
        throw const ContentAssetPhysicalInventoryException(boundHit: true);
      }
    }

    final managedType = await FileSystemEntity.type(
      _managedRoot,
      followLinks: false,
    );
    if (managedType != FileSystemEntityType.directory ||
        !_isPlainEntity(_managedRoot)) {
      throw const ContentAssetPhysicalInventoryException();
    }
    final rootPath = p.join(_managedRoot, 'content_assets');
    final rootType = await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) {
      return const ContentAssetPhysicalInventory(entries: []);
    }
    if (rootType != FileSystemEntityType.directory ||
        !_isPlainEntity(rootPath)) {
      throw const ContentAssetPhysicalInventoryException();
    }
    final classified = <ContentAssetPhysicalEntry>[];
    var entries = 0;
    try {
      await for (final source in Directory(rootPath).list(followLinks: false)) {
        checkBound(++entries);
        final sourceType =
            await FileSystemEntity.type(source.path, followLinks: false);
        if (sourceType == FileSystemEntityType.link ||
            !_isPlainEntity(source.path)) {
          classified.add(const ContentAssetPhysicalEntry(
              ContentAssetPhysicalClass.junctionOrReparse));
          continue;
        }
        if (sourceType != FileSystemEntityType.directory) {
          classified.add(ContentAssetPhysicalEntry(
              sourceType == FileSystemEntityType.file
                  ? ContentAssetPhysicalClass.unexpectedFile
                  : ContentAssetPhysicalClass.unreadableEntity));
          continue;
        }
        final sourceId = p.basename(source.path);
        if (!_identityPattern.hasMatch(sourceId)) {
          classified.add(const ContentAssetPhysicalEntry(
              ContentAssetPhysicalClass.invalidSourceIdentity));
          continue;
        }
        classified.add(const ContentAssetPhysicalEntry(
            ContentAssetPhysicalClass.canonicalSourceDirectory));
        await for (final asset
            in Directory(source.path).list(followLinks: false)) {
          checkBound(++entries);
          final assetType =
              await FileSystemEntity.type(asset.path, followLinks: false);
          if (assetType == FileSystemEntityType.link ||
              !_isPlainEntity(asset.path)) {
            classified.add(const ContentAssetPhysicalEntry(
                ContentAssetPhysicalClass.junctionOrReparse));
            continue;
          }
          if (assetType != FileSystemEntityType.file) {
            classified.add(ContentAssetPhysicalEntry(
                assetType == FileSystemEntityType.directory
                    ? ContentAssetPhysicalClass.unexpectedDirectory
                    : ContentAssetPhysicalClass.unreadableEntity));
            continue;
          }
          final localAssetId = p.basename(asset.path);
          if (localAssetId.startsWith('.tmp_')) {
            classified.add(const ContentAssetPhysicalEntry(
                ContentAssetPhysicalClass.temporaryWrite));
            continue;
          }
          if (!_identityPattern.hasMatch(localAssetId)) {
            classified.add(const ContentAssetPhysicalEntry(
                ContentAssetPhysicalClass.invalidLocalAssetIdentity));
            continue;
          }
          if (!await _hasResolvedContainment(sourceId, localAssetId)) {
            classified.add(const ContentAssetPhysicalEntry(
                ContentAssetPhysicalClass.externalOrEscape));
            continue;
          }
          final file = File(asset.path);
          final length = await file.length();
          if (length == 0 || length > maxImageBytes) {
            classified.add(ContentAssetPhysicalEntry(length == 0
                ? ContentAssetPhysicalClass.canonicalEmptyAsset
                : ContentAssetPhysicalClass.canonicalOversizedAsset));
            continue;
          }
          final bytes = await file.readAsBytes();
          checkBound(entries);
          if (bytes.isEmpty || bytes.length > maxImageBytes) {
            classified.add(ContentAssetPhysicalEntry(bytes.isEmpty
                ? ContentAssetPhysicalClass.canonicalEmptyAsset
                : ContentAssetPhysicalClass.canonicalOversizedAsset));
            continue;
          }
          final mime = ImageByteSignature.detectMime(bytes);
          if (mime == null) {
            classified.add(const ContentAssetPhysicalEntry(
                ContentAssetPhysicalClass.unknownMimeAsset));
            continue;
          }
          if (!_hasBasicImageEnvelope(bytes, mime) ||
              !_isFullyDecodableImage(bytes)) {
            classified.add(const ContentAssetPhysicalEntry(
                ContentAssetPhysicalClass.canonicalCorruptAsset));
            continue;
          }
          classified.add(ContentAssetPhysicalEntry(
              ContentAssetPhysicalClass.canonicalValidAsset,
              record: ContentAssetRecord(
                sourceId: sourceId,
                localAssetId: localAssetId,
                storageKey:
                    storageKey(sourceId: sourceId, localAssetId: localAssetId),
                sizeBytes: bytes.length,
                sha256: sha256Hex(bytes),
              )));
        }
      }
    } on ContentAssetPhysicalInventoryException {
      rethrow;
    } catch (_) {
      throw const ContentAssetPhysicalInventoryException();
    }
    checkBound(entries);
    return ContentAssetPhysicalInventory(
        entries: List<ContentAssetPhysicalEntry>.unmodifiable(classified));
  }

  /// Fresh exact-target classification immediately before a destructive step.
  Future<bool> isExactTargetUnchanged(ContentAssetRecord record) async {
    try {
      if (await FileSystemEntity.type(_managedRoot, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(p.join(_managedRoot, 'content_assets'),
                  followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(
                  p.join(_managedRoot, 'content_assets', record.sourceId),
                  followLinks: false) !=
              FileSystemEntityType.directory) {
        return false;
      }
      final key = storageKey(
        sourceId: record.sourceId,
        localAssetId: record.localAssetId,
      );
      if (key != record.storageKey) return false;
      if (!await _hasResolvedContainment(
          record.sourceId, record.localAssetId)) {
        return false;
      }
      final target = _resolveKey(key);
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final bytes = await target.readAsBytes();
      return bytes.length == record.sizeBytes &&
          sha256Hex(bytes) == record.sha256;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteExactIfUnchanged(ContentAssetRecord record) async {
    if (!await isExactTargetUnchanged(record)) return false;
    try {
      await _resolveKey(record.storageKey).delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isPlainEntity(String path) {
    try {
      return !WindowsReparsePointProbe.isReparsePoint(path);
    } catch (_) {
      return false;
    }
  }

  static bool _hasBasicImageEnvelope(List<int> bytes, String mime) {
    switch (mime) {
      case 'image/png':
        const tail = <int>[0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
        return bytes.length >= 33 &&
            bytes[12] == 73 &&
            bytes[13] == 72 &&
            bytes[14] == 68 &&
            bytes[15] == 82 &&
            _endsWith(bytes, tail);
      case 'image/jpeg':
        return bytes.length >= 4 &&
            bytes[bytes.length - 2] == 0xff &&
            bytes.last == 0xd9;
      case 'image/gif':
        return bytes.length >= 14 && bytes.last == 0x3b;
      case 'image/webp':
        if (bytes.length < 20) return false;
        final riffLength =
            bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24);
        return riffLength + 8 == bytes.length;
      default:
        return false;
    }
  }

  static bool _isFullyDecodableImage(List<int> bytes) {
    try {
      final data = Uint8List.fromList(bytes);
      final decoder = img.findDecoderForData(data);
      if (decoder == null) return false;
      final info = decoder.startDecode(data);
      if (info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width * info.height > 20000000) {
        return false;
      }
      return decoder.decodeFrame(0) != null;
    } catch (_) {
      return false;
    }
  }

  static bool _endsWith(List<int> bytes, List<int> tail) {
    if (bytes.length < tail.length) return false;
    for (var i = 0; i < tail.length; i++) {
      if (bytes[bytes.length - tail.length + i] != tail[i]) return false;
    }
    return true;
  }

  Future<bool> _hasResolvedContainment(
      String sourceId, String localAssetId) async {
    try {
      final contentRoot = p.join(_managedRoot, 'content_assets');
      final source = p.join(contentRoot, sourceId);
      final target = p.join(source, localAssetId);
      if (!_isPlainEntity(_managedRoot) ||
          !_isPlainEntity(contentRoot) ||
          !_isPlainEntity(source) ||
          !_isPlainEntity(target)) {
        return false;
      }
      final resolvedManaged =
          p.normalize(await Directory(_managedRoot).resolveSymbolicLinks());
      final resolvedContent =
          p.normalize(await Directory(contentRoot).resolveSymbolicLinks());
      final resolvedSource =
          p.normalize(await Directory(source).resolveSymbolicLinks());
      final resolvedTarget =
          p.normalize(await File(target).resolveSymbolicLinks());
      return p.isWithin(resolvedManaged, resolvedContent) &&
          p.isWithin(resolvedContent, resolvedSource) &&
          p.isWithin(resolvedContent, resolvedTarget) &&
          p.dirname(resolvedSource) == resolvedContent &&
          p.dirname(resolvedTarget) == resolvedSource;
    } catch (_) {
      return false;
    }
  }

  @override
  bool isDurableAssetReady(SourcedAssetRef asset) {
    return readAssetBytes(
          sourceId: asset.sourceId,
          localAssetId: asset.localAssetId,
        ) !=
        null;
  }

  File _resolveKey(String key) {
    if (!ArchivePathPolicy.isSafeManagedStorageKey(key)) {
      throw const FormatException('Content asset storage key is unsafe.');
    }
    final resolved = p.normalize(p.join(_managedRoot, key));
    if (!p.isWithin(_managedRoot, resolved)) {
      throw const FormatException('Content asset path escaped managed root.');
    }
    return File(resolved);
  }

  String _readDigest(File file) {
    try {
      return sha256Hex(file.readAsBytesSync());
    } on FileSystemException {
      return '';
    }
  }

  static void _validateIdentity(String value, String label) {
    if (!_identityPattern.hasMatch(value)) {
      throw FormatException('Content asset $label is not a safe identity.');
    }
  }

  static String _canonicalMime(String mimeType) {
    return ImageByteSignature.canonicalMime(mimeType) ?? mimeType;
  }
}

enum ContentAssetPhysicalClass {
  canonicalSourceDirectory,
  canonicalValidAsset,
  canonicalCorruptAsset,
  canonicalEmptyAsset,
  canonicalOversizedAsset,
  unknownMimeAsset,
  invalidSourceIdentity,
  invalidLocalAssetIdentity,
  unexpectedFile,
  unexpectedDirectory,
  junctionOrReparse,
  temporaryWrite,
  unreadableEntity,
  externalOrEscape,
  inventoryError,
}

final class ContentAssetPhysicalEntry {
  const ContentAssetPhysicalEntry(this.classification, {this.record});

  final ContentAssetPhysicalClass classification;
  final ContentAssetRecord? record;
}

final class ContentAssetPhysicalInventory {
  const ContentAssetPhysicalInventory({required this.entries});

  final List<ContentAssetPhysicalEntry> entries;

  List<ContentAssetRecord> get records {
    final result = <ContentAssetRecord>[
      for (final entry in entries)
        if (entry.record != null) entry.record!,
    ];
    result.sort((a, b) {
      final source = a.sourceId.compareTo(b.sourceId);
      return source == 0 ? a.localAssetId.compareTo(b.localAssetId) : source;
    });
    return List<ContentAssetRecord>.unmodifiable(result);
  }

  int get unknownCount => entries
      .where((entry) =>
          entry.classification !=
              ContentAssetPhysicalClass.canonicalSourceDirectory &&
          entry.classification != ContentAssetPhysicalClass.canonicalValidAsset)
      .length;
}

final class ContentAssetPhysicalInventoryException implements Exception {
  const ContentAssetPhysicalInventoryException({
    this.unknownCount = 0,
    this.boundHit = false,
  });

  final int unknownCount;
  final bool boundHit;

  @override
  String toString() => 'ContentAssetPhysicalInventoryException';
}
