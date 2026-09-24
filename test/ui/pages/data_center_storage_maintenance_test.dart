import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/content/content_asset_maintenance.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/ui/dependencies/content_asset_maintenance_scope.dart';
import 'package:shiroha_quiz/ui/pages/data_center_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _MaintenanceSpy implements ContentAssetMaintenancePort {
  _MaintenanceSpy(this.report);

  final ContentAssetMaintenanceReport report;
  int reportCalls = 0;
  int sweepCalls = 0;

  @override
  Future<ContentAssetMaintenanceReport> reportOnly() async {
    reportCalls++;
    return report;
  }

  @override
  Future<ContentAssetMaintenanceReport> sweepEligible() async {
    sweepCalls++;
    return report;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late DatabaseHelper helper;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    temp = await Directory.systemTemp.createTemp('dc_maintenance_');
    final dbDir = Directory(p.join(temp.path, 'db'))..createSync();
    await databaseFactory.setDatabasesPath(dbDir.path);
    await DatabaseHelper.resetRuntimeProfileForTesting();
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitFile,
      databasePath: dbDir.path,
    );
    helper = DatabaseHelper.instance;
  });

  tearDown(() async {
    await helper.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<_MaintenanceSpy> pumpScreen(
    WidgetTester tester, {
    required int graceEligibleCount,
  }) async {
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final spy = _MaintenanceSpy(
      ContentAssetMaintenanceReport(
        outcome: ContentAssetMaintenanceOutcome.complete,
        graceEligibleCount: graceEligibleCount,
      ),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ContentAssetMaintenanceScope(
            maintenance: spy,
            child: const DataCenterScreen(),
          ),
        ),
      );
      // The question tree and the report-only pass both do real async IO,
      // which cannot complete inside the fake-async pump.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    return spy;
  }

  Finder sweepButton() => find.byKey(
        const ValueKey<String>('storage-maintenance-sweep'),
      );

  testWidgets('cancelling the confirmation performs no destructive sweep',
      (tester) async {
    final spy = await pumpScreen(tester, graceEligibleCount: 3);
    expect(spy.reportCalls, 1);

    await tester.tap(sweepButton());
    await tester.pumpAndSettle();
    expect(find.textContaining('此操作不可撤销'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(spy.sweepCalls, 0);
  });

  testWidgets('confirming runs the sweep once', (tester) async {
    final spy = await pumpScreen(tester, graceEligibleCount: 3);

    await tester.tap(sweepButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清理'));
    await tester.pumpAndSettle();

    expect(spy.sweepCalls, 1);
  });

  testWidgets('the destructive action stays unavailable without candidates',
      (tester) async {
    final spy = await pumpScreen(tester, graceEligibleCount: 0);

    expect(tester.widget<TextButton>(sweepButton()).onPressed, isNull);

    await tester.tap(sweepButton(), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(spy.sweepCalls, 0);
    expect(find.text('确认清理孤立文件'), findsNothing);
  });
}
