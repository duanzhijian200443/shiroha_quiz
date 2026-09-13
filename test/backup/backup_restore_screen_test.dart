import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_contracts.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/ui/pages/backup/backup_restore_screen.dart';

final class _ScreenOperations implements BackupRestoreOperations {
  PreparedRestoreState? prepared;
  int prepareCalls = 0;
  int cancelCalls = 0;
  int commitCalls = 0;
  int inspectCalls = 0;

  @override
  PreparedRestoreState? get preparedRestore => prepared;

  @override
  Future<BackupExportSummary> exportTo(String destinationPath) async {
    return const BackupExportSummary(
      fileName: 'backup.shiroha',
      schemaVersion: BackupValues.currentSchemaVersion,
      fileCount: 0,
      databaseSizeBytes: 0,
      managedBytes: 0,
    );
  }

  @override
  Future<BackupRestorePreview> inspectPackage(String packagePath) async {
    inspectCalls++;
    return _preview;
  }

  @override
  Future<BackupRestorePreview> prepareRestore(String packagePath) async {
    prepareCalls++;
    prepared = _preparedState;
    return prepared!.preview;
  }

  @override
  Future<void> cancelPreparedRestore() async {
    cancelCalls++;
    prepared = null;
  }

  @override
  Future<BackupRestoreSuccess> commitPreparedRestore({
    Future<void> Function()? beforeCommitted,
  }) async {
    commitCalls++;
    await beforeCommitted?.call();
    prepared = null;
    return const BackupRestoreSuccess(
      schemaVersion: BackupValues.currentSchemaVersion,
      fileCount: 0,
    );
  }

  @override
  Future<BackupStartupRecovery> recoverStartupIfNeeded() async {
    return const BackupStartupRecovery(
      blocked: false,
      diagnosticId: 'OBS-2222-2222',
    );
  }
}

final _preview = BackupRestorePreview(
  packageVersion: 1,
  schemaVersion: BackupValues.currentSchemaVersion,
  createdAtUtc: DateTime.utc(2026, 8, 17),
  fileCount: 2,
  totalSizeBytes: 2048,
);

final _preparedState = PreparedRestoreState(
  packageVersion: 1,
  schemaVersion: BackupValues.currentSchemaVersion,
  createdAtUtc: DateTime.utc(2026, 8, 17),
  fileCount: 2,
  totalSizeBytes: 2048,
);

Widget _screen(
  BackupRestoreCoordinator coordinator, {
  Key? key,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme,
    home: BackupRestoreScreen(
      key: key,
      backupRestore: coordinator,
      onRestoreCompleted: () {},
    ),
  );
}

void main() {
  testWidgets('prepared projection survives screen recreation',
      (WidgetTester tester) async {
    final operations = _ScreenOperations()..prepared = _preparedState;
    final coordinator = BackupRestoreCoordinator(operations: operations);

    await tester.pumpWidget(_screen(coordinator));
    expect(find.text('备份与数据管理'), findsOneWidget);
    expect(find.text('Shiroha 全量备份'), findsOneWidget);
    expect(find.text('备份全部本地学习数据与设置'), findsOneWidget);
    expect(find.text('导出全量备份 (.shiroha)'), findsOneWidget);
    expect(find.text('开始恢复'), findsOneWidget);
    expect(find.text('验证并准备恢复'), findsNothing);
    expect(find.text('数据版本：'), findsOneWidget);
    expect(operations.prepareCalls, 0);
    final picker = tester.widget<TextButton>(
      find.byKey(const ValueKey<String>('backup-restore-picker')),
    );
    expect(picker.onPressed, isNull);
    expect(operations.inspectCalls, 0);

    await tester.pumpWidget(_screen(coordinator, key: const ValueKey('new')));
    expect(find.text('开始恢复'), findsOneWidget);
    expect(find.text('验证并准备恢复'), findsNothing);
    expect(operations.prepareCalls, 0);
    final recreatedPicker = tester.widget<TextButton>(
      find.byKey(const ValueKey<String>('backup-restore-picker')),
    );
    expect(recreatedPicker.onPressed, isNull);
    expect(operations.inspectCalls, 0);

    await tester.tap(find.text('开始恢复'));
    await tester.pumpAndSettle();
    expect(operations.commitCalls, 1);
  });

  testWidgets('cancel clears the Application prepared projection',
      (WidgetTester tester) async {
    final operations = _ScreenOperations()..prepared = _preparedState;
    final coordinator = BackupRestoreCoordinator(operations: operations);

    await tester.pumpWidget(_screen(coordinator));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(operations.cancelCalls, 1);
    expect(operations.preparedRestore, isNull);
    expect(find.text('开始恢复'), findsNothing);
    expect(find.text('验证并准备恢复'), findsNothing);

    final picker = tester.widget<TextButton>(
      find.byKey(const ValueKey<String>('backup-restore-picker')),
    );
    expect(picker.onPressed, isNotNull);

    await tester.pumpWidget(_screen(coordinator, key: const ValueKey('idle')));
    expect(find.text('开始恢复'), findsNothing);
    expect(find.text('验证并准备恢复'), findsNothing);
  });

  testWidgets('keeps one backup structure across light and dark themes', (
    WidgetTester tester,
  ) async {
    for (final brightness in <Brightness>[
      Brightness.light,
      Brightness.dark,
    ]) {
      final operations = _ScreenOperations();
      final coordinator = BackupRestoreCoordinator(operations: operations);
      final theme = ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF08B9E8),
          brightness: brightness,
        ),
      );

      await tester.pumpWidget(_screen(coordinator, theme: theme));

      expect(find.text('全量备份与迁移'), findsOneWidget);
      expect(find.text('从备份恢复'), findsOneWidget);
      expect(find.text('导出全量备份 (.shiroha)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
