import 'dart:io';

import 'package:path/path.dart' as p;

import '../../application/content/content_asset_authority.dart';
import '../../domain/backup/archive_path_policy.dart';
import '../../domain/assets/sourced_asset_ref.dart';
import '../../domain/assets/image_byte_signature.dart';
import '../backup/sha256.dart';

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

    if (_readDigest(target) != expectedDigest) {
      throw const FileSystemException(
        'Content asset write did not preserve its digest.',
      );
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
  Future<void> deleteCandidateAssets(ContentAssetCandidateLease lease) async {
    for (final localAssetId in lease.localAssetIds) {
      try {
        final file = _resolveKey(
          storageKey(
            sourceId: lease.sourceId,
            localAssetId: localAssetId,
          ),
        );
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Candidate rollback is best-effort and idempotent. A later retry or
        // explicit failure path can safely attempt the same lease again.
      } on FormatException {
        // Invalid identities are ignored rather than allowing diagnostics to
        // carry an implementation detail or unsafe path.
      }
    }
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
