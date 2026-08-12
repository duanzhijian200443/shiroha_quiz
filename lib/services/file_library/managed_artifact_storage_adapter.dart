// ignore_for_file: depend_on_referenced_packages
// `crypto` is an existing transitive dependency of this package and the
// pubspec is frozen for this stage; no new direct dependency is introduced.
import 'dart:async';
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

  /// Process-wide finalization guard chains, keyed by the normalized target
  /// path (managed root + storage key). F1 v0 promises a single application
  /// process and no cross-process writer; this guard serializes immutable
  /// finalize decisions inside that process and is never exposed to the
  /// Application layer and never locks across processes.
  static final Map<String, Future<void>> _finalizeChains =
      <String, Future<void>>{};

  /// Monotonic same-process counter for unique temp identities.
  static int _tempCounter = 0;

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
    final temp = File('${target.path}.tmp.$pid.${_tempCounter++}');
    try {
      await target.parent.create(recursive: true);
      final digest = sha256.convert(bytes);
      await temp.writeAsBytes(bytes, flush: true);
      return await _runFinalizeExclusive(target.path, () async {
        if (await target.exists()) {
          await _deleteTempIfExists(temp);
          throw const ManagedArtifactStorageException(
            ManagedArtifactStorageFailure.alreadyFinalized,
          );
        }
        await temp.rename(target.path);
        return ArtifactWriteResult(
          storageKey: storageKey,
          sha256: digest.toString(),
          sizeBytes: bytes.length,
        );
      });
    } on ManagedArtifactStorageException {
      await _deleteTempIfExists(temp);
      rethrow;
    } catch (_) {
      await _deleteTempIfExists(temp);
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
    try {
      if (!await file.exists()) return null;
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

  /// Serializes finalization decisions for one target path inside this
  /// process. Each writer stages its own unique temp first; the critical
  /// section re-checks the final sidecar so at most one writer renames and
  /// every loser deletes its own temp and receives a typed failure.
  Future<T> _runFinalizeExclusive<T>(
    String path,
    Future<T> Function() action,
  ) {
    final previous = _finalizeChains[path] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _finalizeChains[path] = tail;
    tail.whenComplete(() {
      if (identical(_finalizeChains[path], tail)) {
        _finalizeChains.remove(path);
      }
    });
    return result;
  }

  Future<void> _deleteTempIfExists(File temp) async {
    try {
      if (await temp.exists()) {
        await temp.delete();
      }
    } catch (_) {
      // Best-effort cleanup; a leftover temp is an orphan, never a final
      // sidecar, and never changes the typed outcome.
    }
  }
}
