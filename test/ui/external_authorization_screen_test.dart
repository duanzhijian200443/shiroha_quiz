import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/ui/pages/external_authorization_screen.dart';
import '../application/external/local_authorization_test_support.dart';
import 'android_device_access_panel_test.dart' as android_panel;

void main() {
  group('Android generation settings', android_panel.main);
  initializeGeneratedTests();
  late LocalAuthorizationHarness fixture;
  setUp(() async {
    fixture = LocalAuthorizationHarness();
    await fixture.open();
  });
  tearDown(() async => fixture.close());
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ExternalAuthorizationScreen(service: fixture.service)));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'opening simplified settings neither creates nor widens authorization',
      (tester) async {
    await pump(tester);
    expect(find.text('全部题库与资料'), findsOneWidget);
    expect(find.text('允许直接写入题库'), findsOneWidget);
    expect(find.text('待审核草稿'), findsOneWidget);
    expect(find.text('保存策略'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(
        await fixture.repository.listProfiles().then((v) => v.items), isEmpty);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('external-connect')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'existing precise policy is preserved until explicit access upgrade',
      (tester) async {
    final view = fixture.service.openView();
    final ref = await view.create('Legacy client');
    await view.save(ref, 0,
        permissions: [CapabilityPermission.read], targets: [], categories: []);
    await pump(tester);
    expect(find.text('Legacy client'), findsOneWidget);
    final record = await view.read(ref);
    expect(record.profile.grantRevision, 1);
    expect(record.grant!.policy.allContent, isFalse);
    expect(record.grant!.policy.generationMode, ExternalGenerationMode.confirm);
    await tester.pumpWidget(const SizedBox());
    view.close();
  });
  testWidgets('saved direct policy remains selected while access is off',
      (tester) async {
    final view = fixture.service.openView();
    final ref = await view.create('Configured client');
    await view.saveAllContent(ref, 0, directWrite: true);
    await pump(tester);
    final tile = tester.widget<SwitchListTile>(
        find.byKey(const Key('external-direct-write-switch')));
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNull);
    expect(find.text('访问已关闭'), findsOneWidget);
    expect(find.text('已有草稿仍需审核'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    view.close();
  });
  testWidgets('loading and disposal cannot create a delayed profile',
      (tester) async {
    fixture.query.pause = Completer<void>();
    await tester.pumpWidget(MaterialApp(
        home: ExternalAuthorizationScreen(service: fixture.service)));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('external-connect')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
    fixture.query.pause!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((await fixture.repository.listProfiles()).items, isEmpty);
  });
  testWidgets(
      'corrupt authorization refuses editing without exposing database details',
      (tester) async {
    final view = fixture.service.openView();
    final ref = await view.create('Synthetic');
    await view.saveAllContent(ref, 0, directWrite: false);
    await fixture.h.db.execute('PRAGMA ignore_check_constraints=ON');
    await fixture.h.db.execute('UPDATE external_grants SET allow_read=2');
    await fixture.h.db.execute('PRAGMA ignore_check_constraints=OFF');
    await pump(tester);
    expect(find.text('授权设置暂不可用，请重新打开页面。'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('external-connect')))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    view.close();
  });
}
