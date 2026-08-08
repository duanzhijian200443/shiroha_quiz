/// Frozen F0 File Library metadata model.
///
/// A [LibraryFile] is an independent, user-owned file that may exist before
/// any OCR / import / project / bank / question work touches it. It never
/// owns a `projectId`, an absolute platform path, OCR payloads, embeddings,
/// or question-bank ownership.
///
/// The original bytes live in app-managed storage behind the storage port;
/// [storageKey] is the safe relative managed identity that, together with
/// [fileId], forms the durable identity of the file. [storageKey] must never
/// be an absolute path and must not be able to escape the managed root.
final class LibraryFile {
  factory LibraryFile({
    required String fileId,
    required String displayName,
    required String mimeType,
    required int sizeBytes,
    required String sha256,
    required String storageKey,
    required DateTime createdAt,
  }) {
    if (!_fileIdPattern.hasMatch(fileId)) {
      throw const FormatException(
        'File identifiers must use the bounded opaque token format.',
      );
    }
    if (displayName.trim().isEmpty) {
      throw const FormatException('File display names must not be empty.');
    }
    if (!_mimeTypePattern.hasMatch(mimeType)) {
      throw const FormatException(
        'File media types must use the safe canonical format.',
      );
    }
    if (sizeBytes < 0) {
      throw const FormatException('File sizes must be non-negative.');
    }
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw const FormatException(
        'File hashes must be lowercase SHA-256 hex.',
      );
    }
    if (!isSafeStorageKey(storageKey)) {
      throw const FormatException(
        'Storage keys must be safe relative managed identities.',
      );
    }
    // Persistence stores integer milliseconds; normalizing here keeps the
    // model equal to its own durable round trip.
    final normalizedCreatedAt = DateTime.fromMillisecondsSinceEpoch(
      createdAt.millisecondsSinceEpoch,
      isUtc: true,
    );
    return LibraryFile._(
      fileId: fileId,
      displayName: displayName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      sha256: sha256,
      storageKey: storageKey,
      createdAt: normalizedCreatedAt,
    );
  }

  const LibraryFile._({
    required this.fileId,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    required this.storageKey,
    required this.createdAt,
  });

  static final RegExp _fileIdPattern =
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
  static final RegExp _mimeTypePattern = RegExp(
    r'^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/'
    r'[a-z0-9][a-z0-9!#$&^_.+-]{0,127}$',
  );
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _storageKeySegmentPattern =
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

  /// Whether [storageKey] is a safe relative managed identity: non-empty,
  /// relative (no leading separator, no drive prefix), with no empty, dot,
  /// dot-dot, or colon-containing segments. Every segment must be a bounded
  /// opaque token so generated keys can never traverse out of the managed
  /// root, regardless of platform separator.
  static bool isSafeStorageKey(String storageKey) {
    if (storageKey.isEmpty) return false;
    if (storageKey.startsWith('/') || storageKey.startsWith(r'\')) {
      return false;
    }
    if (RegExp(r'^[A-Za-z]:').hasMatch(storageKey)) return false;
    final segments = storageKey.split(RegExp(r'[/\\]'));
    return segments.isNotEmpty &&
        segments.every(_storageKeySegmentPattern.hasMatch);
  }

  final String fileId;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final String sha256;
  final String storageKey;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LibraryFile &&
            fileId == other.fileId &&
            displayName == other.displayName &&
            mimeType == other.mimeType &&
            sizeBytes == other.sizeBytes &&
            sha256 == other.sha256 &&
            storageKey == other.storageKey &&
            createdAt == other.createdAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      fileId,
      displayName,
      mimeType,
      sizeBytes,
      sha256,
      storageKey,
      createdAt,
    );
  }
}
