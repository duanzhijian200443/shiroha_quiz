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
import 'package:shiroha_quiz/ui/widgets/shiroha_workspace_navigation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/home_training_fakes.dart';
import '../widget_test.dart' as app_test;

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
    await app_test.pumpApp(tester, const Size(1440, 1000));
    await app_test.drainBackgroundWork(tester);
    final homeState = tester.state(find.byType(HomePage));
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
    expect(
        tester.getSize(find.byType(ShirohaWorkspaceNavigation)).height, 1000);
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
          isFalse);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(390, 844);
    await app_test.drainBackgroundWork(tester);
    expect(
        tester
            .widget<ShirohaWorkspaceNavigation>(
                find.byType(ShirohaWorkspaceNavigation))
            .horizontal,
        isTrue);
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
    testWidgets('training view reflows real snapshot cards in $brightness',
        (tester) async {
      final fake = HomeTrainingFake();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      State? categoryState;
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
          home: HomePage(homeTraining: fake.ports, trainingOnly: true),
        ));
        await tester.pumpAndSettle();
        final training =
            tester.getRect(find.byKey(const ValueKey('home-training-card')));
        final plan = tester
            .getRect(find.byKey(const ValueKey('today-focused-unavailable')));
        if (size.width >= 944) {
          expect(plan.left, greaterThan(training.right));
          expect(
              tester
                  .getSize(find.byKey(const ValueKey('home-welcome-banner')))
                  .height,
              lessThan(300));
        } else {
          expect(plan.top, greaterThan(training.bottom));
        }
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
