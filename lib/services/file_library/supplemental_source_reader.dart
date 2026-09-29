// ignore_for_file: depend_on_referenced_packages
// `crypto` is an existing transitive dependency; this stage does not change
// the package dependency set.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../application/supplemental_answers/supplemental_source_inspection.dart';
import '../../domain/assets/library_file.dart';
import 'managed_file_storage.dart';

final class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// Infrastructure adapter for bounded reads of managed original bytes.
///
/// Only this adapter resolves [LibraryFile.storageKey] to a physical [File].
final class SupplementalSourceReader implements SupplementalSourceReaderPort {
  const SupplementalSourceReader({required ManagedFileStorage managedStorage})
      : _managedStorage = managedStorage;

  final ManagedFileStorage _managedStorage;

  @override
  Future<SupplementalSourceReadResult> readOriginalBytes({
    required LibraryFile file,
    required int maxBytes,
  }) async {
    if (maxBytes < 0 || file.sizeBytes > maxBytes) {
      throw const SupplementalSourceReaderException(
        SupplementalSourceReaderFailure.resourceLimitExceeded,
      );
    }

    final File managedFile;
    try {
      managedFile = _managedStorage.resolveManagedFile(file.storageKey);
    } catch (_) {
      throw const SupplementalSourceReaderException(
        SupplementalSourceReaderFailure.sourceReadFailed,
      );
    }

    final bool exists;
    try {
      exists = await managedFile.exists();
    } catch (_) {
      throw const SupplementalSourceReaderException(
        SupplementalSourceReaderFailure.sourceReadFailed,
      );
    }
    if (!exists) {
      throw const SupplementalSourceReaderException(
        SupplementalSourceReaderFailure.fileUnavailable,
      );
    }

    final digestCapture = _DigestCapture();
    final digestSink = sha256.startChunkedConversion(digestCapture);
    final bytesBuilder = BytesBuilder(copy: true);
    var actualSizeBytes = 0;
    try {
      // Read at most one byte beyond the budget so an incorrect metadata size
      // cannot cause an unbounded whole-file read before the guard fires.
      await for (final chunk in managedFile.openRead(0, maxBytes + 1)) {
        if (actualSizeBytes + chunk.length > maxBytes) {
          throw const SupplementalSourceReaderException(
            SupplementalSourceReaderFailure.resourceLimitExceeded,
          );
        }
        actualSizeBytes += chunk.length;
        digestSink.add(chunk);
        bytesBuilder.add(chunk);
      }
      digestSink.close();
    } on SupplementalSourceReaderException {
      _closeDigestSink(digestSink);
      rethrow;
    } catch (_) {
      _closeDigestSink(digestSink);
      throw const SupplementalSourceReaderException(
        SupplementalSourceReaderFailure.sourceReadFailed,
      );
    }

    final actualSha256 = digestCapture.value?.toString();
    if (actualSha256 == null) {
      throw const SupplementalSourceReaderException(
        SupplementalSourceReaderFailure.sourceReadFailed,
      );
    }
    return SupplementalSourceReadResult(
      bytes: bytesBuilder.takeBytes(),
      actualSizeBytes: actualSizeBytes,
      actualSha256: actualSha256,
    );
  }

  void _closeDigestSink(Sink<List<int>> digestSink) {
    try {
      digestSink.close();
    } catch (_) {
      // Closing a failed read is best-effort and carries no public detail.
    }
  }
}
