import 'dart:convert';

/// Category identity is either an exact real folder name or the system sentinel.
sealed class CategoryKey {
  const CategoryKey();
}

final class FolderCategoryKey extends CategoryKey {
  FolderCategoryKey(this.exactFolderName) {
    if (exactFolderName.isEmpty) {
      throw const FormatException('Category folder name must not be empty.');
    }
  }

  /// Preserved verbatim, including Unicode, case, and whitespace.
  final String exactFolderName;

  @override
  bool operator ==(Object other) =>
      other is FolderCategoryKey && exactFolderName == other.exactFolderName;

  @override
  int get hashCode => Object.hash(FolderCategoryKey, exactFolderName);
}

final class UncategorizedCategoryKey extends CategoryKey {
  const UncategorizedCategoryKey();

  @override
  bool operator ==(Object other) => other is UncategorizedCategoryKey;

  @override
  int get hashCode => Object.hash(UncategorizedCategoryKey, null);
}

/// The V3 tagged-array encoding; no display-name or keyword inference.
final class CategoryKeyCodec {
  const CategoryKeyCodec();

  List<Object> encode(CategoryKey key) => switch (key) {
        FolderCategoryKey(:final exactFolderName) =>
          List<Object>.unmodifiable(['folder', exactFolderName]),
        UncategorizedCategoryKey() =>
          List<Object>.unmodifiable(['uncategorized']),
      };

  CategoryKey decode(Object? payload) {
    if (payload is List) {
      if (payload.length == 1 && payload[0] == 'uncategorized') {
        return const UncategorizedCategoryKey();
      }
      if (payload.length == 2 &&
          payload[0] == 'folder' &&
          payload[1] is String &&
          (payload[1] as String).isNotEmpty) {
        return FolderCategoryKey(payload[1] as String);
      }
    }
    throw const FormatException('Invalid CategoryKey payload.');
  }

  String encodeString(CategoryKey key) => jsonEncode(encode(key));

  CategoryKey decodeString(String payload) {
    try {
      return decode(jsonDecode(payload));
    } on FormatException {
      // JSON parser exceptions can include rejected input; never forward them.
      throw const FormatException('Invalid CategoryKey payload.');
    }
  }
}
