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

Widget _screen(BackupRestoreCoordinator coordinator, {Key? key}) {
  return MaterialApp(
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
    expect(find.text('开始恢复'), findsOneWidget);
    expect(find.text('验证并准备恢复'), findsNothing);
    expect(
      find.text('数据版本：${BackupValues.currentSchemaVersion}'),
      findsOneWidget,
    );
    expect(operations.prepareCalls, 0);
    final picker = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '恢复备份'),
    );
    expect(picker.onPressed, isNull);
    expect(operations.inspectCalls, 0);

    await tester.pumpWidget(_screen(coordinator, key: const ValueKey('new')));
    expect(find.text('开始恢复'), findsOneWidget);
    expect(find.text('验证并准备恢复'), findsNothing);
    expect(operations.prepareCalls, 0);
    final recreatedPicker = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '恢复备份'),
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

    final picker = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '恢复备份'),
    );
    expect(picker.onPressed, isNotNull);

    await tester.pumpWidget(_screen(coordinator, key: const ValueKey('idle')));
    expect(find.text('开始恢复'), findsNothing);
    expect(find.text('验证并准备恢复'), findsNothing);
  });
}
