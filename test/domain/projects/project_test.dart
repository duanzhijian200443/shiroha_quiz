import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';

void main() {
  group('Project', () {
    test('constructs with a stable id and renameable display name', () {
      final project = Project(
        projectId: 'project-0001',
        displayName: '高中数学',
        createdAt: DateTime.utc(2026, 8, 8, 12),
      );

      expect(project.projectId, 'project-0001');
      expect(project.displayName, '高中数学');
      expect(project.createdAt, DateTime.utc(2026, 8, 8, 12));
    });

    test('normalizes createdAt to its durable millisecond round trip', () {
      final created = Project(
        projectId: 'project-0002',
        displayName: 'math',
        createdAt: DateTime(2026, 8, 8, 12, 0, 0, 123, 456),
      );

      expect(
        created.createdAt,
        DateTime.fromMillisecondsSinceEpoch(
          created.createdAt.millisecondsSinceEpoch,
          isUtc: true,
        ),
      );
    });

    test('rejects empty and whitespace-only display names', () {
      expect(
        () => Project(
          projectId: 'project-0003',
          displayName: '',
          createdAt: DateTime.utc(2026),
        ),
        throwsFormatException,
      );
      expect(
        () => Project(
          projectId: 'project-0003',
          displayName: '   ',
          createdAt: DateTime.utc(2026),
        ),
        throwsFormatException,
      );
    });

    test('rejects unbounded or unsafe project ids', () {
      for (final id in <String>[
        '',
        '-leading-dash',
        'has space',
        '.leading-dot',
        'a\\backslash',
        'a' * 129,
      ]) {
        expect(
          () => Project(
            projectId: id,
            displayName: 'name',
            createdAt: DateTime.utc(2026),
          ),
          throwsFormatException,
          reason: 'Expected rejected project id: $id',
        );
      }
    });

    test('validateDisplayName is the single rename validation source', () {
      expect(() => Project.validateDisplayName('新名称'), returnsNormally);
      expect(() => Project.validateDisplayName('  '), throwsFormatException);
    });

    test('renaming changes the label, never the stable id', () {
      final original = Project(
        projectId: 'project-0004',
        displayName: 'old name',
        createdAt: DateTime.utc(2026, 8, 8, 12),
      );
      final renamed = Project(
        projectId: original.projectId,
        displayName: 'new name',
        createdAt: original.createdAt,
      );

      expect(renamed.projectId, original.projectId);
      expect(renamed.createdAt, original.createdAt);
      expect(renamed.displayName, 'new name');
      expect(renamed, isNot(equals(original)));
    });

    test('equality covers id, display name, and creation time', () {
      final a = Project(
        projectId: 'project-0005',
        displayName: 'A',
        createdAt: DateTime.utc(2026, 8, 8, 12),
      );
      final same = Project(
        projectId: 'project-0005',
        displayName: 'A',
        createdAt: DateTime.utc(2026, 8, 8, 12),
      );
      final otherName = Project(
        projectId: 'project-0005',
        displayName: 'B',
        createdAt: DateTime.utc(2026, 8, 8, 12),
      );

      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(a, isNot(equals(otherName)));
    });
  });
}
