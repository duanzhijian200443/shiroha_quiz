import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('U1-LIFECYCLE-UX reviewer regressions', () {
    test('legacy Assistant header delete entry stays removed', () {
      final source =
          File('lib/ui/assistant/assistant_screen.dart').readAsStringSync();

      expect(source, isNot(contains("'c0-delete-conversation'")));
      expect(source, isNot(contains('Future<void> _deleteConversation()')));
    });

    test('learning-space delete authority is scoped to the active project', () {
      final controller =
          File('lib/ui/assistant/workspace_controller.dart').readAsStringSync();
      final shell = File('lib/ui/assistant/assistant_workspace_shell.dart')
          .readAsStringSync();

      expect(controller, contains('deleteGuard?.call(projectId)'));
      expect(shell, contains('deleteGuard: _learningSpaceDeleteBlockReason'));
      expect(shell, contains('activeProjectId != projectId'));
      expect(shell, contains("return '请先停止当前生成';"));
      expect(shell, contains("return '请等待对话移动完成';"));
    });

    test('deleted learning-space home state is normalized, not only rendered',
        () {
      final shell = File('lib/ui/assistant/assistant_workspace_shell.dart')
          .readAsStringSync();

      expect(shell, contains('_handleSpacesChanged'));
      expect(shell, contains('_projectId = null;'));
      expect(
        shell,
        contains('_destination = _WorkspaceDestination.learningSpaces;'),
      );
    });
  });
}
