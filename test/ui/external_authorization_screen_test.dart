import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';
import 'package:shiroha_quiz/application/external/android_http_access.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/data/external/android_http_token_codec.dart';
import 'package:shiroha_quiz/ui/dependencies/android_device_scope.dart';
import 'package:shiroha_quiz/ui/pages/external_authorization_screen.dart';
import 'package:uuid/uuid.dart';
import '../application/external/local_authorization_test_support.dart';
import 'android_device_access_panel_test.dart' as android_panel;

final class _HttpAccess extends Fake implements AndroidHttpAccess {
  bool enabled = false;
  AndroidAccessPhase? forcedPhase;
  (AndroidAccessDuration, bool, bool)? requested;
  int disableCalls = 0;
  Future<void> Function()? onDisable;
  @override
  AndroidHttpAccessState get state => AndroidHttpAccessState(
        available: true,
        privateWifi: true,
        notificationsAllowed: true,
        phase: forcedPhase ??
            (enabled ? AndroidAccessPhase.ready : AndroidAccessPhase.off),
        endpoint: enabled ? Uri.parse('https://192.168.1.10:17443/mcp') : null,
        duration: requested?.$1,
        background: requested?.$2 ?? false,
        continueWhileLocked: requested?.$3 ?? false,
      );
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<void> inspect() async {}
  @override
  Future<void> cancelPending() async {}
  @override
  Future<void> enable(AndroidAccessDuration duration,
      {required bool background, required bool continueWhileLocked}) async {
    requested = (duration, background, continueWhileLocked);
    enabled = true;
  }

  @override
  Future<void> disable() async {
    disableCalls++;
    await onDisable?.call();
    enabled = false;
  }
}

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
      'Android HTTP setup uses the requested window and the live URL in Codex setup',
      (tester) async {
    final management = ExternalAuthorizationManagement(
      repository: fixture.repository,
      compositionIsCurrent: () => true,
      mintProfileId: const Uuid().v4,
    );
    await management.createProfile(
      displayName: 'Test Codex',
      adapter: androidHttpAdapter,
      protocol: androidHttpProtocol,
    );
    addTearDown(management.invalidate);
    await tester.binding.setSurfaceSize(const Size(720, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final access = _HttpAccess();
    await tester.pumpWidget(MaterialApp(
      home: AndroidHttpAccessScope(
        access: access,
        child: ExternalAuthorizationScreen(service: fixture.service),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('后台运行'), findsOneWidget);
    expect(find.text('锁屏后继续读取'), findsNothing);
    await tester.tap(find.text('后台运行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏后继续读取'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许局域网访问'));
    await tester.pumpAndSettle();
    expect(
        access.requested, (AndroidAccessDuration.fifteenMinutes, true, true));
    expect(find.byTooltip('复制 HTTPS URL'), findsOneWidget);
    await tester.tap(find.text('Codex 配置模板'));
    await tester.pumpAndSettle();
    expect(find.textContaining('url = "https://192.168.1.10:17443/mcp"'),
        findsOneWidget);
    expect(find.textContaining('bearer_token_env_var'), findsOneWidget);
    expect(find.text('待审核草稿'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Android HTTP generation starts with scoped review and explicit direct consent',
      (tester) async {
    final management = ExternalAuthorizationManagement(
      repository: fixture.repository,
      compositionIsCurrent: () => true,
      mintProfileId: const Uuid().v4,
    );
    addTearDown(management.invalidate);
    final profile = await management.createProfile(
      displayName: 'Test HTTP',
      adapter: androidHttpAdapter,
      protocol: androidHttpProtocol,
    );
    await management.replaceGrant(profile, 0, androidHttpDefaultReadPolicy());
    await tester.binding.setSurfaceSize(const Size(720, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: AndroidHttpAccessScope(
        access: _HttpAccess(),
        child: ExternalAuthorizationScreen(service: fixture.service),
      ),
    ));
    await tester.pumpAndSettle();

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> openGrant() async {
      await tap(find.byTooltip('管理 Test HTTP'));
      await tap(find.text('授权范围'));
    }

    CheckboxListTile checkbox(String label) => tester.widget(find.ancestor(
        of: find.text(label), matching: find.byType(CheckboxListTile)));

    await openGrant();
    expect(checkbox('允许提交生成题目').value, isFalse);
    expect(find.text('允许直接写入题库'), findsNothing);
    await tap(find.text('允许提交生成题目'));
    expect(checkbox('全部范围（含今后新增）').value, isFalse);
    expect(checkbox('允许直接写入题库').value, isFalse);
    final save = find.widgetWithText(FilledButton, '保存');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tap(find.text('题库 · 本地 · second'));
    await tap(save);
    final saved = (await management.read(profile)).grant!.policy;
    expect(saved.generationMode, ExternalGenerationMode.review);
    expect(saved.scopes.single.targetId, 'second');
    expect(saved.allContent, isFalse);

    await openGrant();
    expect(checkbox('允许直接写入题库').value, isFalse);
    await tap(find.text('允许直接写入题库'));
    await tap(save);
    final direct = (await management.read(profile)).grant!.policy;
    expect(direct.generationMode, ExternalGenerationMode.direct);
    expect(direct.scopes, saved.scopes);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'a live Android HTTP grant save withdraws and joins before revision CAS',
      (tester) async {
    final management = ExternalAuthorizationManagement(
      repository: fixture.repository,
      compositionIsCurrent: () => true,
      mintProfileId: const Uuid().v4,
    );
    addTearDown(management.invalidate);
    final profile = await management.createProfile(
      displayName: 'Test HTTP',
      adapter: androidHttpAdapter,
      protocol: androidHttpProtocol,
    );
    await management.replaceGrant(profile, 0, androidHttpDefaultReadPolicy());
    final access = _HttpAccess()..enabled = true;
    final withdrawing = Completer<void>();
    int? revisionAtWithdraw;
    access.onDisable = () async {
      revisionAtWithdraw =
          (await management.read(profile)).profile.grantRevision;
      await withdrawing.future;
    };
    await tester.binding.setSurfaceSize(const Size(720, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: AndroidHttpAccessScope(
        access: access,
        child: ExternalAuthorizationScreen(service: fixture.service),
      ),
    ));
    await tester.pumpAndSettle();

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> openGrant() async {
      await tap(find.byTooltip('管理 Test HTTP'));
      await tap(find.text('授权范围'));
    }

    CheckboxListTile checkbox(String label) => tester.widget(find.ancestor(
        of: find.text(label), matching: find.byType(CheckboxListTile)));

    // READY: READ -> review. The save must join the live window first.
    await openGrant();
    expect(find.text('保存会先关闭当前访问窗口并等待原操作结算，之后需要重新开启。'), findsOneWidget);
    await tap(find.text('允许提交生成题目'));
    await tap(find.text('题库 · 本地 · second'));
    await tap(find.widgetWithText(FilledButton, '保存'));
    expect(access.disableCalls, 1);
    expect(revisionAtWithdraw, 1);
    expect((await management.read(profile)).profile.grantRevision, 1);
    expect((await management.read(profile)).grant!.policy.generationMode,
        ExternalGenerationMode.confirm);
    withdrawing.complete();
    await tester.pumpAndSettle();
    expect(access.enabled, isFalse);
    final reviewed = await management.read(profile);
    expect(reviewed.profile.grantRevision, 2);
    expect(
        reviewed.grant!.policy.generationMode, ExternalGenerationMode.review);
    expect(find.text('已保存授权，请重新开启访问'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // A new explicit Enable keeps the window, then review -> direct withdraws again.
    access.enabled = true;
    access.onDisable = () async {
      revisionAtWithdraw =
          (await management.read(profile)).profile.grantRevision;
    };
    await openGrant();
    expect(checkbox('允许直接写入题库').value, isFalse);
    await tap(find.text('允许直接写入题库'));
    await tap(find.widgetWithText(FilledButton, '保存'));
    expect(access.disableCalls, 2);
    expect(revisionAtWithdraw, 2);
    expect(access.enabled, isFalse);
    final direct = (await management.read(profile)).grant!.policy;
    expect(direct.generationMode, ExternalGenerationMode.direct);
    expect(direct.scopes, reviewed.grant!.policy.scopes);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unsettled withdrawal keeps the Android HTTP grant unchanged',
      (tester) async {
    final management = ExternalAuthorizationManagement(
      repository: fixture.repository,
      compositionIsCurrent: () => true,
      mintProfileId: const Uuid().v4,
    );
    addTearDown(management.invalidate);
    final profile = await management.createProfile(
      displayName: 'Test HTTP',
      adapter: androidHttpAdapter,
      protocol: androidHttpProtocol,
    );
    await management.replaceGrant(profile, 0, androidHttpDefaultReadPolicy());
    final access = _HttpAccess()..enabled = true;
    access.onDisable = () async {
      // Withdrawal did not reach a confirmed clean close.
      access.forcedPhase = AndroidAccessPhase.recovery;
    };
    await tester.binding.setSurfaceSize(const Size(720, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: AndroidHttpAccessScope(
        access: access,
        child: ExternalAuthorizationScreen(service: fixture.service),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('管理 Test HTTP'));
    await tester.tap(find.byTooltip('管理 Test HTTP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('授权范围'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('允许提交生成题目'));
    await tester.tap(find.text('允许提交生成题目'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('题库 · 本地 · second'));
    await tester.tap(find.text('题库 · 本地 · second'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(access.disableCalls, 1);
    expect(access.state.phase, AndroidAccessPhase.recovery);
    final unchanged = await management.read(profile);
    expect(unchanged.profile.grantRevision, 1);
    expect(
        unchanged.grant!.policy.generationMode, ExternalGenerationMode.confirm);
    expect(find.text('操作未完成，请检查连接或重新打开此页。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

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
