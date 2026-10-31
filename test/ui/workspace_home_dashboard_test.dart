import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/today/workspace_dashboard_query.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/ui/home/workspace_home_dashboard.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';

void main() {
  final snapshot = WorkspaceDashboardSnapshot(
    calendar: ReviewCalendarSnapshot(
        firstDate: DateTime(2025, 11, 1),
        lastDate: DateTime(2026, 10, 25),
        dailyCounts: {DateTime(2026, 10, 24): 3}),
    recentFiles: [
      LibraryFileSummary(
          fileId: 'file-1',
          displayName: '代数讲义.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 420,
          createdAt: DateTime(2026, 10, 24))
    ],
    banks: const [],
  );

  Future<void> pump(WidgetTester tester, Size size, Brightness brightness,
      {double scale = 1,
      List<String>? actions,
      WorkspaceDashboardSnapshot? data}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(
          ShirohaAppearance.paperLight
              .copyWith(layout: ShirohaLayoutMode.workspace),
          brightness),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: WorkspaceHomeDashboard(
            snapshot: data ?? snapshot,
            week: null,
            newCount: '7 题',
            reviewCount: '12 题',
            onRefresh: () async {},
            onTraining: () => actions?.add('training'),
            onSpaces: () => actions?.add('spaces'),
            onImport: () => actions?.add('import'),
            onBanks: () => actions?.add('banks'),
            onLibrary: () => actions?.add('library'),
            onParse: () => actions?.add('tasks'),
            onSettings: () => actions?.add('settings'),
            onOpenFile: (id) => actions?.add(id),
            onAssistant: (text) => actions?.add('assistant:$text')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(1440, 1100),
      const Size(1024, 768),
      const Size(768, 1024),
      const Size(390, 844)
    ]) {
      testWidgets('reference dashboard $brightness $size has reachable content',
          (tester) async {
        await pump(tester, size, brightness);
        expect(find.byKey(const ValueKey('workspace-review-calendar')),
            findsOneWidget);
        expect(find.text('代数讲义.pdf'), findsOneWidget);
        expect(find.text('练习记录'), findsOneWidget);
        expect(find.text('本周学习时长'), findsOneWidget);
        expect(find.text('正确率'), findsNothing);
        await tester.ensureVisible(
            find.byKey(const ValueKey('workspace-assistant-input')));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('large text and narrow window reflow without clipped actions',
      (tester) async {
    await pump(tester, const Size(390, 844), Brightness.dark, scale: 1.8);
    await tester.ensureVisible(
        find.byKey(const ValueKey('workspace-assistant-continue')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shortcuts, exact file identity and Assistant draft reuse callbacks',
      (tester) async {
    final actions = <String>[];
    await pump(tester, const Size(1440, 1200), Brightness.light,
        actions: actions);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(ValueKey('workspace-shortcut-$i')));
    }
    await tester.tap(find.text('代数讲义.pdf'));
    await tester.enterText(
        find.byKey(const ValueKey('workspace-assistant-input')), '帮我复习代数');
    await tester
        .tap(find.byKey(const ValueKey('workspace-assistant-continue')));
    expect(actions, [
      'training',
      'spaces',
      'import',
      'banks',
      'file-1',
      'assistant:帮我复习代数'
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable sections do not impersonate empty success',
      (tester) async {
    await pump(tester, const Size(1440, 1100), Brightness.light,
        data: const WorkspaceDashboardSnapshot());
    expect(find.text('学习记录暂不可用'), findsOneWidget);
    expect(find.text('最近资料暂不可用'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('workspace-review-calendar')), findsNothing);
    expect(find.text('已收录 0 道题'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
