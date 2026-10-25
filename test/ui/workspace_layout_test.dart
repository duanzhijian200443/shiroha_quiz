import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/main.dart' show globalThemeNotifier;
import 'package:shiroha_quiz/ui/home/today_category_training_card.dart';
import 'package:shiroha_quiz/ui/assistant/workspace_pages.dart';
import 'package:shiroha_quiz/ui/assistant/learning_spaces_screen.dart';
import 'package:shiroha_quiz/ui/assistant/global_sidebar.dart';
import 'package:shiroha_quiz/ui/pages/data_center_screen.dart';
import 'package:shiroha_quiz/ui/pages/home_page.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:shiroha_quiz/ui/theme/design_tokens.dart';
import 'package:shiroha_quiz/ui/widgets/shiroha_workspace_navigation.dart';
import 'package:shiroha_quiz/ui/widgets/workspace_layout_viewport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/home_training_fakes.dart';
import '../widget_test.dart' as app_test;

Rect _paintedRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  testWidgets('layout and width changes retain pages and all destinations',
      (tester) async {
    final previousFactory = databaseFactory;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      await DatabaseHelper.resetRuntimeProfileForTesting();
      DatabaseHelper.configureRuntimeProfile(
          DatabaseRuntimeProfile.isolatedSmokeInMemory);
      await DatabaseHelper.instance.database;
    });
    addTearDown(() async {
      globalThemeNotifier.value = ShirohaAppearance.light;
      await DatabaseHelper.resetRuntimeProfileForTesting();
      databaseFactory = previousFactory;
    });
    globalThemeNotifier.value = ShirohaAppearance.paperLight
        .copyWith(layout: ShirohaLayoutMode.workspace);
    await app_test.pumpApp(tester, const Size(1700, 1000));
    await app_test.drainBackgroundWork(tester);
    final homeState = tester.state(find.byType(HomePage));
    final geometry = {
      for (final key in [
        'workspace-home-hero',
        for (var i = 0; i < 4; i++) 'workspace-shortcut-$i',
        'workspace-review-calendar',
      ])
        key: _paintedRect(tester, find.byKey(ValueKey(key))),
    };
    for (final size in [
      const Size(1268, 714),
      const Size(768, 1024),
      const Size(540, 714),
      const Size(390, 844),
    ]) {
      tester.view.physicalSize = size;
      await app_test.drainBackgroundWork(tester);
      final scale = size.width / DesignTokens.workspaceReferenceWidth;
      for (final entry in geometry.entries) {
        final actual = _paintedRect(tester, find.byKey(ValueKey(entry.key)));
        expect(actual.left, closeTo(entry.value.left * scale, .1));
        expect(actual.top, closeTo(entry.value.top * scale, .1));
        expect(actual.width, closeTo(entry.value.width * scale, .1));
        expect(actual.height, closeTo(entry.value.height * scale, .1));
      }
      final navigation = tester.widget<ShirohaWorkspaceNavigation>(
          find.byType(ShirohaWorkspaceNavigation));
      expect(navigation.expanded, isTrue);
      expect(navigation.horizontal, isFalse);
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(1700, 1000);
    await app_test.drainBackgroundWork(tester);
    await tester
        .ensureVisible(find.byKey(const ValueKey('workspace-assistant-input')));
    await tester.enterText(
        find.byKey(const ValueKey('workspace-assistant-input')), '保留我的学习草稿');
    await tester.tap(find.byKey(const ValueKey('workspace-nav-3')));
    await app_test.drainBackgroundWork(tester);
    expect(find.byKey(const ValueKey('home-training-card')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-nav-0')));
    await app_test.drainBackgroundWork(tester);
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('workspace-assistant-input')))
            .controller!
            .text,
        '保留我的学习草稿');
    tester.view.physicalSize = const Size(768, 1024);
    for (final entry in [1, 2, 4]) {
      await tester.tap(find.byKey(ValueKey('workspace-nav-$entry')));
      await app_test.drainBackgroundWork(tester);
      if (entry == 1) expect(find.byType(FileLibraryWorkspace), findsOneWidget);
      if (entry == 2) expect(find.byType(LearningSpacesScreen), findsOneWidget);
      if (entry == 4) expect(find.byType(DataCenterScreen), findsOneWidget);
      expect(find.byType(GlobalSidebar), findsNothing);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(1440, 1000);
    await app_test.drainBackgroundWork(tester);
    expect(_paintedRect(tester, find.byType(ShirohaWorkspaceNavigation)).height,
        closeTo(1000, .1));
    expect(
        tester
            .widget<ShirohaWorkspaceNavigation>(
                find.byType(ShirohaWorkspaceNavigation))
            .expanded,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('workspace-nav-5')));
    await app_test.drainBackgroundWork(tester);
    for (final size in [const Size(1024, 768), const Size(768, 1024)]) {
      tester.view.physicalSize = size;
      await app_test.drainBackgroundWork(tester);
      expect(
          tester
              .widget<ShirohaWorkspaceNavigation>(
                  find.byType(ShirohaWorkspaceNavigation))
              .expanded,
          isTrue);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(390, 844);
    await app_test.drainBackgroundWork(tester);
    expect(
        tester
            .widget<ShirohaWorkspaceNavigation>(
                find.byType(ShirohaWorkspaceNavigation))
            .horizontal,
        isFalse);
    await tester.ensureVisible(find.byKey(const ValueKey('workspace-nav-6')));
    await tester.tap(find.byKey(const ValueKey('workspace-nav-6')));
    await app_test.drainBackgroundWork(tester);
    expect(find.text('外观设置'), findsOneWidget);
    globalThemeNotifier.value =
        globalThemeNotifier.value.copyWith(layout: ShirohaLayoutMode.mobile);
    await app_test.drainBackgroundWork(tester);
    expect(
        tester
            .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
            .currentIndex,
        2);
    await tester.tap(find.descendant(
        of: find.byType(BottomNavigationBar), matching: find.text('今日')));
    await app_test.drainBackgroundWork(tester);
    expect(tester.state(find.byType(HomePage)), same(homeState));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('training view scales its wide composition in $brightness',
        (tester) async {
      final fake = HomeTrainingFake();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      State? categoryState;
      double? planContentOffset;
      for (final size in [
        const Size(1280, 900),
        const Size(944, 768),
        const Size(688, 1024),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.themeFor(
              ShirohaAppearance.paperLight
                  .copyWith(layout: ShirohaLayoutMode.workspace),
              brightness),
          builder: (context, child) => WorkspaceLayoutViewport(child: child!),
          home: HomePage(homeTraining: fake.ports, trainingOnly: true),
        ));
        await tester.pumpAndSettle();
        final training = _paintedRect(
            tester, find.byKey(const ValueKey('home-training-card')));
        final plan = _paintedRect(
            tester, find.byKey(const ValueKey('today-focused-unavailable')));
        expect(plan.left, greaterThan(training.right));
        // The plan's own heading precedes its content; preserve that offset too.
        final scale = size.width / DesignTokens.workspaceReferenceWidth;
        planContentOffset ??= (plan.top - training.top) / scale;
        expect(plan.top - training.top, closeTo(planContentOffset * scale, .1));
        expect(
            _paintedRect(
                    tester, find.byKey(const ValueKey('home-welcome-banner')))
                .height,
            lessThan(300));
        final state = tester.state(find.byType(TodayCategoryTrainingCard));
        categoryState ??= state;
        expect(state, same(categoryState));
        expect(find.text('学习日历'), findsNothing);
        expect(find.text('新题'), findsOneWidget);
        expect(find.text('复习'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.physicalSize = const Size(1024, 768);
      await tester.pumpAndSettle();
      expect(
          tester
              .getTopLeft(
                  find.byKey(const ValueKey('today-focused-unavailable')))
              .dy,
          greaterThan(tester
              .getBottomLeft(find.byKey(const ValueKey('home-training-card')))
              .dy));
      expect(tester.takeException(), isNull);
    });
  }
}
