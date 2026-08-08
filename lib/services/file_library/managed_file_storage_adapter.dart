// ignore_for_file: depend_on_referenced_packages
// `crypto` is an existing transitive dependency of this package and the
// pubspec is frozen for this stage; no new direct dependency is introduced.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/assets/library_file.dart';
import 'managed_file_storage.dart';

/// Failure taxonomy of the managed file storage boundary.
enum ManagedFileStorageFailure {
  unsafeStorageKey,
  sourceMissing,
  copyFailed,
}

/// Raised when managed file storage cannot satisfy the F0 storage contract.
///
/// The exception retains no raw cause, path, storage key, or SQLite
/// exception; [toString] renders one fixed safe message per failure.
final class ManagedFileStorageException implements Exception {
  const ManagedFileStorageException(this.failure);

  final ManagedFileStorageFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      ManagedFileStorageFailure.unsafeStorageKey =>
        'The storage key is not a safe relative managed identity.',
      ManagedFileStorageFailure.sourceMissing =>
        'The external source file does not exist or is not readable.',
      ManagedFileStorageFailure.copyFailed =>
        'The managed copy could not be completed.',
    };
    return 'ManagedFileStorageException(${failure.name}): $detail';
  }
}

/// Captures the single [Digest] emitted by a chunked hash conversion.
class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// Physical adapter that stores original file bytes under an app-managed
/// root directory.
///
/// This is the only F0 component allowed to parse physical absolute paths.
/// Every storage key is resolved through the same containment gate: unsafe
/// keys (`..`, absolute paths, drive escapes, empty/dot segments, colon
/// segments) are rejected before any filesystem access, and the normalized
/// result must stay within the managed root.
final class ManagedFileStorageAdapter implements ManagedFileStorage {
  ManagedFileStorageAdapter({required Directory managedRoot})
      : _rootPath = p.normalize(managedRoot.path);

  /// Resolves the default app-managed root (support directory / library_files).
  static Future<ManagedFileStorageAdapter> appManaged() async {
    final support = await getApplicationSupportDirectory();
    return ManagedFileStorageAdapter(
      managedRoot: Directory(p.join(support.path, 'library_files')),
    );
  }

  final String _rootPath;

  static const String _managedNamespace = 'library';

  @override
  String allocateStorageKey(String fileId) {
    final storageKey = '$_managedNamespace/$fileId';
    if (!LibraryFile.isSafeStorageKey(storageKey)) {
      throw const ManagedFileStorageException(
        ManagedFileStorageFailure.unsafeStorageKey,
      );
    }
    return storageKey;
  }

  @override
  Future<ManagedFileCopyResult> copyIntoManagedStorage({
    required String externalPath,
    required String storageKey,
  }) async {
    final target = _resolveRooted(storageKey);
    final source = File(externalPath);
    try {
      final stat = await source.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const ManagedFileStorageException(
          ManagedFileStorageFailure.sourceMissing,
        );
      }
    } on ManagedFileStorageException {
      rethrow;
    } catch (_) {
      throw const ManagedFileStorageException(
        ManagedFileStorageFailure.sourceMissing,
      );
    }

    final File temp;
    try {
      await target.parent.create(recursive: true);
      temp = File('${target.path}.tmp');
      if (await temp.exists()) {
        await temp.delete();
      }
    } catch (_) {
      throw const ManagedFileStorageException(
        ManagedFileStorageFailure.copyFailed,
      );
    }

    final digestCapture = _DigestCapture();
    final digestSink = sha256.startChunkedConversion(digestCapture);
    final output = temp.openWrite();
    var totalBytes = 0;
    try {
      await for (final chunk in source.openRead()) {
        totalBytes += chunk.length;
        digestSink.add(chunk);
        output.add(chunk);
      }
      digestSink.close();
      await output.close();
    } catch (_) {
      try {
        digestSink.close();
      } catch (_) {}
      try {
        await output.close();
      } catch (_) {}
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
      throw const ManagedFileStorageException(
        ManagedFileStorageFailure.copyFailed,
      );
    }

    try {
      await temp.rename(target.path);
    } catch (_) {
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
      throw const ManagedFileStorageException(
        ManagedFileStorageFailure.copyFailed,
      );
    }

    return ManagedFileCopyResult(
      storageKey: storageKey,
      sha256: digestCapture.value!.toString(),
      sizeBytes: totalBytes,
    );
  }

  @override
  File resolveManagedFile(String storageKey) => _resolveRooted(storageKey);

  @override
  Future<bool> managedFileExists(String storageKey) async {
    return _resolveRooted(storageKey).exists();
  }

  @override
  Future<void> deleteManagedFile(String storageKey) async {
    final file = _resolveRooted(storageKey);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Shared containment gate: rejects unsafe keys and verifies the
  /// normalized target stays inside the managed root.
  File _resolveRooted(String storageKey) {
    if (!LibraryFile.isSafeStorageKey(storageKey)) {
      throw const ManagedFileStorageException(
        ManagedFileStorageFailure.unsafeStorageKey,
      );
    }
    final resolved = p.normalize(p.join(_rootPath, storageKey));
    if (!p.isWithin(_rootPath, resolved)) {
      throw const ManagedFileStorageException(
        ManagedFileStorageFailure.unsafeStorageKey,
      );
    }
    return File(resolved);
  }
}
