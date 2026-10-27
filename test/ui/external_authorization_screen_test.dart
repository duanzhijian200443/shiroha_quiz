import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/ui/pages/external_authorization_screen.dart';
import '../application/external/local_authorization_test_support.dart';

void main() {
  initializeGeneratedTests();
  late LocalAuthorizationHarness fixture;
  setUp(() async {
    fixture = LocalAuthorizationHarness();
    await fixture.open();
  });
  tearDown(() async => fixture.close());

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: ExternalAuthorizationScreen(service: fixture.service)));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    final finder = find.text(text).last;
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump();
    // Confirmation intentionally holds the busy gate. Do not wait for its
    // indeterminate progress animation to settle before clicking the dialog.
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> create(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'Synthetic UI');
    await tap(tester, '新建 Profile');
    expect(find.text('无 Grant'), findsOneWidget);
    await tap(tester, '高级权限字段');
  }

  testWidgets(
      'guided file choice explicitly saves READ and fileContent with exact scope',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'Guided access');
    await tap(tester, '新建 Profile');
    await tap(tester, '文件 · 本地 · Synthetic file2');
    expect(find.textContaining('阅读资料还需要选择同一空间的题库'), findsOneWidget);
    await tap(tester, '题库 · 本地 · second');
    expect(find.textContaining('阅读资料还需要选择同一空间的题库'), findsNothing);
    await tap(tester, '允许提交待审核练习');
    await tap(tester, '保存策略');
    expect(find.textContaining('所选资料的正文'), findsWidgets);
    await tap(tester, '确认');
    final record = await fixture.repository.read(
        (await fixture.repository.listProfiles()).items.single.clientProfileId);
    expect(record.grant!.policy.permissions,
        {CapabilityPermission.read, CapabilityPermission.stage});
    expect(record.grant!.policy.categories, {
      ExternalContentCategory.questionContent,
      ExternalContentCategory.fileContent,
      ExternalContentCategory.proposalMetadata,
    });
    expect(record.grant!.policy.scopes.map((s) => s.targetId).toSet(),
        {'second', 'file2'});
    expect(
        record.grant!.policy.scopes.every((s) => s.projectId == null), isTrue);
  });

  testWidgets(
      'create/edit/revoke flow remains unpaired and permission/egress independent',
      (tester) async {
    await pump(tester);
    await create(tester);
    expect(find.text(externalPolicyNotice), findsOneWidget);
    expect(find.text('READ'), findsOneWidget);
    expect(find.text('STAGE'), findsOneWidget);
    expect(find.text('COMMIT'), findsNothing);
    expect(find.text('DESTRUCTIVE'), findsNothing);
    await tap(tester, 'READ');
    await tap(tester, 'STAGE');
    await tap(tester, '题库 · Space · bank');
    await tap(tester, '题库 · 本地 · second');
    await tap(tester, '文件 · Space · Synthetic file1');
    await tap(tester, '文件 · 本地 · Synthetic file2');
    await tap(tester, 'proposalMetadata');
    await tap(tester, '保存策略');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tap(tester, '确认');
    expect(find.text('当前 Revision：1'), findsOneWidget);
    expect(find.text('已保存访问规则'), findsOneWidget);
    final record = await fixture.repository.read(
        (await fixture.repository.listProfiles()).items.single.clientProfileId);
    expect(record.grant!.policy.scopes, hasLength(4));
    expect(record.grant!.policy.categories,
        {ExternalContentCategory.proposalMetadata});
    await tap(tester, '撤销 Grant');
    await tap(tester, '取消');
    expect(find.text('当前 Revision：1'), findsOneWidget);
    await tap(tester, '撤销 Grant');
    await tap(tester, '确认');
    expect(find.text('Grant 已撤销'), findsOneWidget);
    await tap(tester, '撤销 Profile');
    expect(find.text('永久撤销此 Profile，之后不能重新授权或激活。'), findsOneWidget);
    await tap(tester, '确认');
    expect(find.text('Profile 已撤销（不可重新激活）'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存策略'))
            .onPressed,
        isNull);
  });
  testWidgets(
      'empty scope saves no target; confirmation blocks duplicate save and cancel writes nothing',
      (tester) async {
    await pump(tester);
    await create(tester);
    await tap(tester, 'READ');
    await tap(tester, '保存策略');
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存策略'))
            .onPressed,
        isNull);
    await tap(tester, '取消');
    expect(find.text('无 Grant'), findsOneWidget);
    await tap(tester, '保存策略');
    await tap(tester, '确认');
    final record = await fixture.repository.read(
        (await fixture.repository.listProfiles()).items.single.clientProfileId);
    expect(record.grant!.policy.scopes, isEmpty);
    expect(record.grant!.policy.categories, isEmpty);
    expect(record.profile.grantRevision, 1);
  });
  testWidgets('CAS conflict reloads winning strategy instead of overwriting',
      (tester) async {
    await pump(tester);
    await create(tester);
    await tap(tester, 'READ');
    final other = fixture.service.openView();
    final ref = await other.select(
        (await fixture.repository.listProfiles()).items.single.clientProfileId);
    await other.save(ref, 0,
        permissions: [CapabilityPermission.stage], targets: [], categories: []);
    await tap(tester, '保存策略');
    await tap(tester, '确认');
    expect(find.text('当前 Revision：1'), findsOneWidget);
    expect(find.textContaining('策略已被其他管理视图修改'), findsOneWidget);
    final readTile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'READ'));
    final stageTile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'STAGE'));
    expect(readTile.value, isFalse);
    expect(stageTile.value, isTrue);
    expect((await other.read(ref)).profile.grantRevision, 1);
    other.close();
  });
  testWidgets(
      'stale saved Project scope is explicit and cannot silently become local',
      (tester) async {
    final view = fixture.service.openView();
    final ref = await view.create('Synthetic saved');
    await view.save(ref, 0,
        permissions: [CapabilityPermission.read],
        targets: (await view.targets()).where((t) => t.scope.projectId != null),
        categories: []);
    await fixture.h.db.delete('project_files');
    await pump(tester);
    await tap(tester, 'Synthetic saved');
    expect(find.text('目标已失效：请明确移除'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存策略'))
            .onPressed,
        isNull);
    await tap(tester, '移除失效目标');
    await tap(tester, '保存策略');
    await tap(tester, '确认');
    final current = await view.read(ref);
    expect(current.grant!.policy.scopes, hasLength(1));
    expect(current.grant!.policy.scopes.single.projectId, 'space');
    view.close();
  });
  testWidgets('loading disables clicks; disposal suppresses delayed state',
      (tester) async {
    fixture.query.pause = Completer<void>();
    await tester.pumpWidget(MaterialApp(
        home: ExternalAuthorizationScreen(service: fixture.service)));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '新建 Profile'))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
    fixture.query.pause!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((await fixture.repository.listProfiles()).items, isEmpty);
  });
  testWidgets(
      'generation invalidation cancels confirmed pending operation without a write',
      (tester) async {
    await pump(tester);
    await create(tester);
    await tap(tester, 'READ');
    await tap(tester, '保存策略');
    fixture.service.invalidate();
    await tap(tester, '确认');
    final record = await fixture.repository.read(
        (await fixture.repository.listProfiles()).items.single.clientProfileId);
    expect(record.grant, isNull);
    expect(find.text('管理视图已失效，请重新打开页面。'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '新建 Profile'))
            .onPressed,
        isNull);
  });
  testWidgets('corrupt authorization refuses editing without raw errors',
      (tester) async {
    final view = fixture.service.openView();
    final ref = await view.create('Synthetic');
    await view.save(ref, 0,
        permissions: [CapabilityPermission.read], targets: [], categories: []);
    await fixture.h.db.execute('PRAGMA ignore_check_constraints=ON');
    await fixture.h.db.execute('UPDATE external_grants SET allow_read=2');
    await fixture.h.db.execute('PRAGMA ignore_check_constraints=OFF');
    await pump(tester);
    expect(find.text('授权数据损坏，已安全拒绝编辑。'), findsOneWidget);
    expect(find.text('保存策略'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '新建 Profile'))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
    view.close();
  });
}
