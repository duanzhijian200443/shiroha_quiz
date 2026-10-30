import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/external_agent_settings_body.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

void main() {
  testWidgets('access and direct writing are independent explicit callbacks',
      (tester) async {
    final access = <bool>[];
    final statistics = <bool>[];
    final writes = <bool>[];
    var reviews = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(
        body: ExternalAgentSettingsBody(
          clientName: 'Test client',
          phase: ExternalAgentAccessPhase.enabled,
          directWriteEnabled: false,
          pendingCount: 6,
          onAccessChanged: access.add,
          onStudyStatisticsChanged: statistics.add,
          onDirectWriteChanged: writes.add,
          onOpenReview: () => reviews++,
        ),
      ),
    ));
    expect(find.text('默认生成待审核草稿'), findsOneWidget);
    expect(writes, isEmpty);
    expect(statistics, isEmpty);
    await tester.tap(find.byKey(const Key('external-study-statistics')));
    expect(statistics, [true]);
    expect(writes, isEmpty);
    expect(access, isEmpty);
    await tester.tap(find.byKey(const Key('external-direct-write-switch')));
    expect(writes, [true]);
    expect(access, isEmpty);
    await tester.tap(find.byKey(const Key('external-access-switch')));
    expect(access, [false]);
    expect(writes, [true]);
    await tester.ensureVisible(find.byKey(const Key('external-open-review')));
    await tester.tap(find.byKey(const Key('external-open-review')));
    expect(reviews, 1);
  });

  testWidgets('closed access preserves direct-write choice and existing review',
      (tester) async {
    var writes = 0;
    var reviews = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ExternalAgentSettingsBody(
          clientName: 'Test client',
          phase: ExternalAgentAccessPhase.disabled,
          directWriteEnabled: true,
          pendingCount: 6,
          onDirectWriteChanged: (_) => writes++,
          onOpenReview: () => reviews++,
        ),
      ),
    ));
    final control = tester.widget<SwitchListTile>(
        find.byKey(const Key('external-direct-write-switch')));
    expect(control.value, isTrue);
    expect(control.onChanged, isNull);
    expect(find.text('开启访问后可设置'), findsOneWidget);
    expect(find.text('已有草稿仍需审核'), findsOneWidget);
    expect(find.text('新生成题目直接入库，无需审核'), findsNothing);
    expect(writes, 0);
    await tester.ensureVisible(find.byKey(const Key('external-open-review')));
    await tester.tap(find.byKey(const Key('external-open-review')));
    expect(reviews, 1);
  });

  testWidgets('narrow large-text settings remain usable in all product themes',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final theme in [
      AppTheme.lightTheme,
      AppTheme.darkTheme,
      AppTheme.colorfulTheme,
    ]) {
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: ExternalAgentSettingsBody(
            clientName: 'Test client',
            phase: ExternalAgentAccessPhase.setup,
            directWriteEnabled: false,
            onConnect: () {},
            onOpenReview: () {},
            connectionSettings: const Text('Synthetic connection settings'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('连接设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接设置'));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic connection settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
