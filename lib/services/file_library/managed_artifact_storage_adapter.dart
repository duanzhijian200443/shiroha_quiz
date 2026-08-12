// ignore_for_file: depend_on_referenced_packages
// `crypto` is an existing transitive dependency of this package and the
// pubspec is frozen for this stage; no new direct dependency is introduced.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/assets/library_file.dart';
import 'managed_artifact_storage.dart';

final _artifactIdentityPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Physical adapter that stores immutable artifact sidecars under an
/// app-managed root directory.
///
/// This is the only D1 component allowed to parse physical absolute paths.
/// Every storage key goes through the same containment gate as the F0
/// managed file storage: unsafe keys (`..`, absolute paths, drive escapes,
/// empty/dot/colon segments) are rejected before any filesystem access, and
/// the normalized result must stay within the managed root.
final class ManagedArtifactStorageAdapter implements ManagedArtifactStorage {
  ManagedArtifactStorageAdapter({required Directory managedRoot})
      : _rootPath = p.normalize(managedRoot.path);

  final String _rootPath;

  static const String _namespace = 'artifacts';
  static const String _suffix = '.json';

  @override
  String allocateArtifactStorageKey(String artifactId) {
    if (!_artifactIdentityPattern.hasMatch(artifactId)) {
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.unsafeArtifactId,
      );
    }
    final storageKey = '$_namespace/$artifactId$_suffix';
    if (!LibraryFile.isSafeStorageKey(storageKey)) {
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.unsafeStorageKey,
      );
    }
    return storageKey;
  }

  @override
  Future<ArtifactWriteResult> writeArtifact({
    required String storageKey,
    required List<int> bytes,
  }) async {
    final target = _resolveRooted(storageKey);
    final temp = File('${target.path}.tmp');
    try {
      if (await temp.exists()) {
        await temp.delete();
      }
      if (await target.exists()) {
        throw const ManagedArtifactStorageException(
          ManagedArtifactStorageFailure.alreadyFinalized,
        );
      }
      await target.parent.create(recursive: true);
      final digest = sha256.convert(bytes);
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
      return ArtifactWriteResult(
        storageKey: storageKey,
        sha256: digest.toString(),
        sizeBytes: bytes.length,
      );
    } on ManagedArtifactStorageException {
      rethrow;
    } catch (_) {
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.ioFailed,
      );
    }
  }

  @override
  Future<ArtifactReadResult?> readArtifact({
    required String storageKey,
    String? expectedSha256,
    int? expectedSizeBytes,
  }) async {
    final file = _resolveRooted(storageKey);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final actualSha256 = sha256.convert(bytes).toString();
      if (expectedSizeBytes != null && bytes.length != expectedSizeBytes) {
        throw const ManagedArtifactStorageException(
          ManagedArtifactStorageFailure.sizeMismatch,
        );
      }
      if (expectedSha256 != null && actualSha256 != expectedSha256) {
        throw const ManagedArtifactStorageException(
          ManagedArtifactStorageFailure.digestMismatch,
        );
      }
      return ArtifactReadResult(
        bytes: bytes,
        sha256: actualSha256,
        sizeBytes: bytes.length,
      );
    } on ManagedArtifactStorageException {
      rethrow;
    } catch (_) {
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.ioFailed,
      );
    }
  }

  @override
  Future<void> deleteArtifact(String storageKey) async {
    final file = _resolveRooted(storageKey);
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.ioFailed,
      );
    }
  }

  /// Shared containment gate: rejects unsafe keys and verifies the
  /// normalized target stays inside the managed root.
  File _resolveRooted(String storageKey) {
    if (!LibraryFile.isSafeStorageKey(storageKey)) {
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.unsafeStorageKey,
      );
    }
    final resolved = p.normalize(p.join(_rootPath, storageKey));
    if (!p.isWithin(_rootPath, resolved)) {
      throw const ManagedArtifactStorageException(
        ManagedArtifactStorageFailure.unsafeStorageKey,
      );
    }
    return File(resolved);
  }
}
