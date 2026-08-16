/// Central archive-entry path admission for B0.
///
/// B0 uses exactly the frozen regular-file layout:
///
/// ```text
/// manifest.json
/// database/shiroha.db
/// files/library/<fileId>
/// ```
abstract final class ArchivePathPolicy {
  static final RegExp _safeSegment = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
  static final RegExp _drivePrefix = RegExp(r'^[A-Za-z]:');

  static bool isSafeArchivePath(String path) {
    if (path.isEmpty ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path.startsWith('/') ||
        _drivePrefix.hasMatch(path) ||
        path.contains('|')) {
      return false;
    }
    final segments = path.split('/');
    return segments.isNotEmpty && segments.every(_safeSegment.hasMatch);
  }

  static bool isSafeManagedStorageKey(String key) => isSafeArchivePath(key);

  /// Returns an error code when [path] is unsafe, otherwise null.
  static String? unsafeReason(String path) {
    if (!isSafeArchivePath(path)) return 'unsafeArchivePath';
    return null;
  }

  /// Normalizes archive paths for duplicate detection. All admitted paths are
  /// already normalized, but this also lets tests exercise `a//b` and
  /// `a/../b` before rejection.
  static String? normalizeAdmittedPath(String path) {
    if (!isSafeArchivePath(path)) return null;
    final segments = <String>[];
    for (final segment in path.split('/')) {
      if (segment == '.' || segment == '..' || segment.isEmpty) return null;
      segments.add(segment);
    }
    return segments.join('/');
  }

  static bool hasCaseInsensitiveCollision(Iterable<String> paths) {
    final seen = <String>{};
    for (final path in paths) {
      if (!seen.add(path.toLowerCase())) return true;
    }
    return false;
  }

  static bool hasNormalizedDuplicate(Iterable<String> paths) {
    final seen = <String>{};
    for (final raw in paths) {
      final path = normalizeAdmittedPath(raw);
      if (path == null) return true;
      if (!seen.add(path)) return true;
    }
    return false;
  }
}
