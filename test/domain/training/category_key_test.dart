import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';

void main() {
  const codec = CategoryKeyCodec();

  test('real folders never collide with the uncategorized sentinel', () {
    const sentinel = UncategorizedCategoryKey();
    final folder = FolderCategoryKey('📁 未分类题库');
    expect(folder, isNot(sentinel));
    expect(FolderCategoryKey('默认学科'), isNot(sentinel));
    expect({folder, sentinel}, hasLength(2));
    expect(const UncategorizedCategoryKey(), sentinel);
    expect(sentinel.hashCode, const UncategorizedCategoryKey().hashCode);
  });

  test('folder identity preserves exact Unicode, case and whitespace', () {
    for (final name in ['数学', 'Math', '📁 未分类题库', ' 数学 ', 'e\u0301']) {
      final key = FolderCategoryKey(name);
      expect(key.exactFolderName, name);
      expect(key, FolderCategoryKey(name));
      expect(key.hashCode, FolderCategoryKey(name).hashCode);
    }
    expect(FolderCategoryKey('Math'), isNot(FolderCategoryKey('math')));
    expect(FolderCategoryKey(' 数学 '), isNot(FolderCategoryKey('数学')));
    expect(FolderCategoryKey('é'), isNot(FolderCategoryKey('e\u0301')));
  });

  test('tagged arrays and persisted JSON round-trip without guessing identity',
      () {
    expect(codec.encode(FolderCategoryKey('数学')), ['folder', '数学']);
    expect(codec.encode(const UncategorizedCategoryKey()), ['uncategorized']);
    expect(codec.encodeString(FolderCategoryKey('数学')), '["folder","数学"]');
    expect(codec.encodeString(const UncategorizedCategoryKey()),
        '["uncategorized"]');
    for (final key in <CategoryKey>[
      const UncategorizedCategoryKey(),
      FolderCategoryKey('📁 未分类题库'),
      FolderCategoryKey('Math'),
      FolderCategoryKey(' 数学 '),
      FolderCategoryKey('quote"\\\n'),
    ]) {
      expect(codec.decode(codec.encode(key)), key);
      expect(codec.decodeString(codec.encodeString(key)), key);
    }
  });

  test('malformed shapes, types, tags and missing folder name fail safely', () {
    for (final payload in <Object?>[
      null,
      1,
      '数学',
      {'folder': '数学'},
      [],
      ['folder'],
      ['folder', null],
      ['folder', 1],
      ['folder', ''],
      ['folder', '数学', 'extra'],
      ['uncategorized', 'extra'],
      ['Folder', '数学'],
      ['unknown'],
    ]) {
      expect(() => codec.decode(payload), throwsFormatException);
    }
    expect(() => FolderCategoryKey(''), throwsFormatException);
  });

  test('JSON parsing failures omit raw input from safe errors', () {
    for (final payload in ['private-test-marker{', 'null', '{}', '"数学"']) {
      expect(
        () => codec.decodeString(payload),
        throwsA(isA<FormatException>()
            .having((error) => error.source, 'source', isNull)
            .having((error) => error.toString(), 'safe message',
                isNot(contains('private-test-marker')))),
      );
    }
  });
}
