import 'library_file.dart';

/// F0.1 File Library folder metadata.
///
/// A folder is a flat, user-managed classification for [LibraryFile] values.
/// It is not a filesystem directory, Project/Learning Space, Subject tree, or
/// owner of file bytes. Membership is persisted separately so [folderId]
/// remains stable across rename operations.
final class LibraryFolder {
  factory LibraryFolder({
    required String folderId,
    required String displayName,
    required DateTime createdAt,
  }) {
    if (!_folderIdPattern.hasMatch(folderId)) {
      throw const FormatException(
        'Folder identifiers must use the bounded opaque token format.',
      );
    }
    final normalizedName = normalizeDisplayName(displayName);
    final normalizedCreatedAt = DateTime.fromMillisecondsSinceEpoch(
      createdAt.millisecondsSinceEpoch,
      isUtc: true,
    );
    return LibraryFolder._(
      folderId: folderId,
      displayName: normalizedName,
      createdAt: normalizedCreatedAt,
    );
  }

  const LibraryFolder._({
    required this.folderId,
    required this.displayName,
    required this.createdAt,
  });

  static const int maxDisplayNameRunes = 100;

  static final RegExp _folderIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );
  static final RegExp _asciiControlPattern = RegExp(r'[\x00-\x1F\x7F]');
  static const Set<String> _reservedDisplayNames = <String>{
    '全部文件',
    '最近',
    '未分类',
  };

  /// Returns the canonical logical label used by Domain and persistence.
  /// Slash, backslash, and dot segments remain ordinary display characters;
  /// folders never acquire filesystem path semantics.
  static String normalizeDisplayName(String displayName) {
    final normalized = displayName.trim();
    if (normalized.isEmpty ||
        normalized.runes.length > maxDisplayNameRunes ||
        _asciiControlPattern.hasMatch(normalized) ||
        _reservedDisplayNames.contains(normalized)) {
      throw const FormatException('Folder display names are invalid.');
    }
    return normalized;
  }

  final String folderId;
  final String displayName;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LibraryFolder &&
            folderId == other.folderId &&
            displayName == other.displayName &&
            createdAt == other.createdAt;
  }

  @override
  int get hashCode => Object.hash(folderId, displayName, createdAt);
}
