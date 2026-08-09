import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/library_folder.dart';

void main() {
  test('normalizes a Chinese display name and durable timestamp', () {
    final folder = LibraryFolder(
      folderId: 'folder-1',
      displayName: '  考研真题  ',
      createdAt: DateTime(2026, 8, 9, 12, 0, 0, 123, 456),
    );

    expect(folder.displayName, '考研真题');
    expect(
      folder.createdAt,
      DateTime.fromMillisecondsSinceEpoch(
        folder.createdAt.millisecondsSinceEpoch,
        isUtc: true,
      ),
    );
  });

  test('accepts bounded logical labels without path semantics', () {
    for (final name in <String>['a', 'a' * 100, '论文/2026', r'论文\2026', '..']) {
      expect(
        () => LibraryFolder(
          folderId: 'folder-ok',
          displayName: name,
          createdAt: DateTime.utc(2026),
        ),
        returnsNormally,
      );
    }
  });

  test('rejects blank, overlong, control, and reserved labels', () {
    for (final name in <String>[
      '',
      '  ',
      'a' * 101,
      'line\nbreak',
      'del\x7f',
      '全部文件',
      '最近',
      '未分类',
    ]) {
      expect(
        () => LibraryFolder(
          folderId: 'folder-invalid-name',
          displayName: name,
          createdAt: DateTime.utc(2026),
        ),
        throwsFormatException,
        reason: 'Expected rejected folder name: $name',
      );
    }
  });

  test('rejects unsafe ids and rename preserves stable identity', () {
    expect(
      () => LibraryFolder(
        folderId: '../unsafe',
        displayName: '资料',
        createdAt: DateTime.utc(2026),
      ),
      throwsFormatException,
    );

    final original = LibraryFolder(
      folderId: 'folder-stable',
      displayName: '旧名称',
      createdAt: DateTime.utc(2026),
    );
    final renamed = LibraryFolder(
      folderId: original.folderId,
      displayName: '新名称',
      createdAt: original.createdAt,
    );
    expect(renamed.folderId, original.folderId);
    expect(renamed.createdAt, original.createdAt);
  });
}
