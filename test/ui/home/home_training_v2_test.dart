import '../../support/task_center_test_composition.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/application/training/today_training_contracts.dart';
import 'package:shiroha_quiz/application/training/training_session_contracts.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/dependencies/study_activity_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/home/today_category_training_card.dart';
import 'package:shiroha_quiz/ui/home/weekly_activity_card.dart';
import 'package:shiroha_quiz/ui/home/today_category_visual.dart';
import 'package:shiroha_quiz/ui/home/today_welcome_banner.dart';
import 'package:shiroha_quiz/ui/home/today_visual_theme.dart';
import 'package:shiroha_quiz/ui/pages/mock_center_screen.dart';
import 'package:shiroha_quiz/ui/pages/home_page.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:shiroha_quiz/ui/training/training_configuration_page.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import '../../support/home_training_fakes.dart';
import '../../support/activity_widget_dependencies.dart';
import '../../support/study_activity_runtime_fakes.dart';
import '../../support/theme_visual_evidence.dart';

class _Exam extends Fake implements ExamMutationPersistencePort {}

void main() {
  setUpAll(loadThemeEvidenceFonts);
  final capture = Platform.environment['B4_VISUAL_EVIDENCE'] == '1';
  final boundaryKey = GlobalKey();
  setUpAll(() async {
    if (capture && Platform.isWindows) {
      final font = FontLoader('B4VisualFont')
        ..addFont(Future.value(ByteData.sublistView(
            await File('C:/Windows/Fonts/msyh.ttc').readAsBytes())));
      await font.load();
      final materialFont = Platform.environment['B4_MATERIAL_FONT'];
      if (materialFont != null) {
        await (FontLoader('MaterialIcons')
              ..addFont(Future.value(ByteData.sublistView(
                  await File(materialFont).readAsBytes()))))
            .load();
      }
    }
  });
  Future<void> pump(
    WidgetTester tester,
    HomeTrainingFake fake, {
    Size size = const Size(360, 720),
    bool dark = false,
    String? appearance,
    double scale = 1,
    int epoch = 0,
    bool settle = true,
    bool reduceMotion = false,
    RecordingActivity? activity,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = appearance != null
        ? AppTheme.getTheme(appearance)
        : dark
            ? AppTheme.darkTheme
            : AppTheme.lightTheme;
    await tester.pumpWidget(StudyActivityDependenciesScope(
        dependencies: StudyActivityDependencies(
            service: activity ?? RecordingActivity(), query: fake),
        child: activityWidgetDependencies(
            exam: _Exam(),
            child: MaterialApp(
                theme: capture
                    ? theme.copyWith(
                        textTheme:
                            theme.textTheme.apply(fontFamily: 'B4VisualFont'))
                    : theme,
                home: MediaQuery(
                    data: MediaQueryData(
                        size: size,
                        textScaler: TextScaler.linear(scale),
                        disableAnimations: reduceMotion),
                    child: RepaintBoundary(
                        key: boundaryKey,
                        child: HomePage(
                            homeTraining: fake.ports,
                            studyActivityQuery: fake,
                            taskCenter: testTaskCenterDependencies(
                                manager: TaskManager.forTesting()),
                            todayActivationEpoch: epoch,
                            localNow: () => DateTime(2026, 10, 5, 9))))))));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  for (final appearance in ['light', 'dark', 'colorful']) {
    testWidgets('today appearance sample screenshot: $appearance',
        (tester) async {
      await pump(tester, HomeTrainingFake(),
          appearance: appearance, size: const Size(390, 1000));
      await tester.runAsync(() async {
        await precacheImage(
            const AssetImage('assets/images/today/welcome-landscape.png'),
            boundaryKey.currentContext!);
        await precacheImage(
            const AssetImage('assets/images/today/category-math-v3.png'),
            boundaryKey.currentContext!);
      });
      await tester.pumpAndSettle();
      await captureThemeEvidence(tester, boundaryKey, 'today-$appearance');
      expect(
          Theme.of(tester
                  .element(find.byKey(const ValueKey('home-training-card'))))
              .colorScheme
              .primary,
          AppTheme.getTheme(appearance).colorScheme.primary);
      expect(tester.takeException(), isNull);
    });
  }

  Future<void> screenshot(WidgetTester tester, String name,
      {Finder? crop}) async {
    if (!capture) return;
    final previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      await tester.runAsync(() async {
        for (final asset in const [
          'assets/images/today/welcome-landscape.png',
          'assets/images/today/paper-pencil.png',
          'assets/images/today/category-math.png',
          'assets/images/today/category-math-v3.png',
          'assets/images/today/category-english.png',
        ]) {
          await precacheImage(AssetImage(asset), boundaryKey.currentContext!);
        }
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        var image = await boundary.toImage(pixelRatio: 2);
        if (crop != null) {
          final bounds = tester
              .getRect(crop)
              .shift(-boundary.localToGlobal(Offset.zero))
              .inflate(8);
          final source = Rect.fromLTRB(bounds.left * 2, bounds.top * 2,
              bounds.right * 2, bounds.bottom * 2);
          final output = Size(bounds.width * 4, bounds.height * 4);
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder)
              .drawImageRect(image, source, Offset.zero & output, Paint());
          final picture = recorder.endRecording();
          final cropped =
              await picture.toImage(output.width.ceil(), output.height.ceil());
          picture.dispose();
          image.dispose();
          image = cropped;
        }
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory('.dart_tool/home-v3-visual').create(recursive: true);
        await File('.dart_tool/home-v3-visual/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = previousShadows;
    }
  }

  testWidgets(
      'reference composition keeps action cards outside category surface',
      (tester) async {
    await pump(tester, HomeTrainingFake(), size: const Size(390, 844));
    final surface = find.byKey(const ValueKey('home-training-card'));
    final action = find.byKey(const ValueKey('home-new-task'));
    expect(find.descendant(of: surface, matching: action), findsNothing);
    expect(tester.getTopLeft(action).dy,
        greaterThan(tester.getBottomLeft(surface).dy));
    expect(find.byType(TodayCategoryVisual), findsNWidgets(2));
    final pages = tester
        .widget<PageView>(find.byKey(const ValueKey('home-category-pages')));
    expect(pages.controller!.viewportFraction, .83);
    final pageFinder = find.byKey(const ValueKey('home-category-pages'));
    expect(tester.getSize(pageFinder).height, greaterThanOrEqualTo(180));
    expect(
        find.byKey(const ValueKey('home-category-pagination')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-category-dot-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-category-dot-1')), findsOneWidget);
    expect(find.descendant(of: pageFinder, matching: find.byType(IconButton)),
        findsNothing);
    expect(find.descendant(of: pageFinder, matching: find.byType(TextButton)),
        findsNothing);
    final visualRects = tester
        .widgetList<TodayCategoryVisual>(find.byType(TodayCategoryVisual))
        .map((widget) => tester.getRect(find.byWidget(widget)))
        .toList();
    final viewport = tester.getRect(pageFinder);
    expect(
        visualRects.first.width / viewport.width, inInclusiveRange(.80, .85));
    expect((viewport.right - visualRects[1].left) / viewport.width,
        inInclusiveRange(.15, .20));
    expect(
        tester
            .getBottomLeft(find.byKey(const ValueKey('home-training-config')))
            .dy,
        lessThanOrEqualTo(viewport.top));
    expect(find.text('早上好'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'reference-390-top');
    expect(find.byType(WeeklyActivityCard), findsNothing);
    expect(find.byKey(const ValueKey('home-exam-entry')), findsNothing);
    expect(find.byKey(const ValueKey('home-bank-detail')), findsNothing);
    expect(find.text('新题'), findsOneWidget);
    expect(find.text('复习'), findsOneWidget);
    final banner = tester.getSize(find.byType(TodayWelcomeBanner));
    expect(banner.height / banner.width, inInclusiveRange(.40, .46));
    final parse = find.byKey(const ValueKey('home-parse-action'));
    final config = find.byKey(const ValueKey('home-training-config'));
    final create = find.byKey(const ValueKey('home-import-action'));
    expect(tester.getCenter(parse).dx, lessThan(tester.getCenter(config).dx));
    expect(tester.getCenter(config).dx, lessThan(tester.getCenter(create).dx));
    for (final action in [parse, config, create]) {
      expect(tester.getSize(action).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
    }
    expect(find.text('让每一次练习，靠近更好的你'), findsNothing);
    expect(find.textContaining('连续学习'), findsNothing);
    final icons = tester
        .widgetList<TodayIconTile>(find.byType(TodayIconTile))
        .take(3)
        .map((tile) => tile.icon);
    expect(icons, [
      Icons.bar_chart_rounded,
      Icons.check_box_rounded,
      Icons.local_fire_department_rounded
    ]);
  });

  testWidgets('saved category visual overrides inferred category illustration',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
            width: 320,
            height: 120,
            child: TodayCategoryVisual(
                label: '数学', visualKey: CategoryVisualKey.english))));
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName,
        'assets/images/today/category-english.png');
  });

  testWidgets(
      'non-current Category preview shows its saved visual and keeps it when selected',
      (tester) async {
    final fake = HomeTrainingFake();
    fake.groups[1] = TrainingCategorySnapshot(
        categoryKey: homeB,
        preference: TrainingCategoryPreference(
            categoryKey: homeB, revision: 1, visualKey: CategoryVisualKey.math),
        contents: fake.groups[1].contents);
    await pump(tester, fake);
    String pageAsset(int index) {
      final visual = tester
          .widgetList<TodayCategoryVisual>(find.byType(TodayCategoryVisual))
          .elementAt(index);
      final image = tester.widget<Image>(find.descendant(
          of: find.byWidget(visual), matching: find.byType(Image)));
      return (image.image as AssetImage).assetName;
    }

    expect(pageAsset(0), 'assets/images/today/category-math-v3.png');
    expect(pageAsset(1), 'assets/images/today/category-math-v3.png');
    expect(fake.selections, isEmpty);
    final preview = pageAsset(1);
    await tester
        .ensureVisible(find.byKey(const ValueKey('home-category-pages')));
    await tester.drag(find.byKey(const ValueKey('home-category-pages')),
        const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(fake.selected, homeB);
    expect(fake.selections, hasLength(1));
    expect(find.text('词汇 + 阅读'), findsOneWidget);
    expect(pageAsset(1), preview);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'math uses the transparent paper illustration rather than a photographic backdrop',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
            width: 300,
            height: 180,
            child: TodayCategoryVisual(
                label: '数学', visualKey: CategoryVisualKey.math))));
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName,
        'assets/images/today/category-math-v3.png');
  });

  testWidgets(
      'settled Category swipe writes once, authoritative sync never writes, stale swipe returns',
      (tester) async {
    final fake = HomeTrainingFake();
    await pump(tester, fake);
    await tester
        .ensureVisible(find.byKey(const ValueKey('home-category-pages')));
    await tester.drag(find.byKey(const ValueKey('home-category-pages')),
        const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(fake.selected, homeB);
    expect(fake.selections, hasLength(1));
    expect(fake.selections.single.contentId, isNull);
    fake.selected = homeA;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fake.selections, hasLength(1));
    final page = tester
        .widget<PageView>(find.byKey(const ValueKey('home-category-pages')))
        .controller!;
    expect(page.page, closeTo(0, .01));
    fake.selectionFailure = HomeTrainingFailure.stale;
    await tester.drag(find.byKey(const ValueKey('home-category-pages')),
        const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(fake.selections, hasLength(2));
    expect(page.page, closeTo(0, .01));
  });

  testWidgets(
      'desktop mouse drag pages categories and the corner stays an independent click',
      (tester) async {
    final fake = HomeTrainingFake();
    await pump(tester, fake);
    await tester
        .ensureVisible(find.byKey(const ValueKey('home-category-pages')));
    await tester.drag(find.byKey(const ValueKey('home-category-pages')),
        const Offset(-280, 0),
        kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(fake.selected, homeB);
    expect(fake.selections, hasLength(1));
    expect(find.text('词汇 + 阅读'), findsOneWidget);
    final corner = find.byKey(const ValueKey('home-content-corner'));
    await tester.ensureVisible(corner);
    await tester.pumpAndSettle();
    final before = fake.snapshot.selection.currentContent!.content.contentId;
    final press = await tester.press(corner, kind: ui.PointerDeviceKind.mouse);
    await press.up();
    await tester.pumpAndSettle();
    expect(fake.snapshot.selection.currentContent!.content.contentId,
        isNot(before));
    expect(fake.selections, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'corner semantic hit area, quick cycle and B2 config route return refresh',
      (tester) async {
    final fake = HomeTrainingFake(categories: 1);
    await pump(tester, fake);
    expect(find.byKey(const ValueKey('home-category-dot-0')), findsNothing);
    await tester
        .ensureVisible(find.byKey(const ValueKey('home-content-corner')));
    expect(tester.getSize(find.byType(FoldedPageCorner)), const Size(48, 48));
    final before = fake.snapshot.selection.currentContent!.content.contentId;
    final reviewBefore = (fake.snapshot.categoryReviewCount
            as HomeTrainingSuccess<TrainingCount>)
        .value
        .value;
    fake.newCount = 6;
    await tester.tap(find.byKey(const ValueKey('home-content-corner')));
    await tester.pumpAndSettle();
    expect(fake.snapshot.selection.currentContent!.content.contentId,
        isNot(before));
    expect(
        (fake.snapshot.categoryReviewCount
                as HomeTrainingSuccess<TrainingCount>)
            .value
            .value,
        reviewBefore);
    expect(
        (tester
                .widget<TodayTrainingActionCard>(
                    find.byKey(const ValueKey('home-new-task')))
                .count as HomeTrainingSuccess<TrainingCount>)
            .value
            .value,
        6);
    expect(fake.selections, hasLength(1));
    final reads = fake.reads;
    await tester
        .ensureVisible(find.byKey(const ValueKey('home-training-config')));
    await tester.tap(find.byKey(const ValueKey('home-training-config')));
    await tester.pumpAndSettle();
    expect(find.byType(TrainingConfigurationPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(fake.reads, greaterThan(reads));
  });

  for (final review in [false, true]) {
    testWidgets(
        'ready ${review ? 'review' : 'new'} opens B3 normal route once; guard lasts through route',
        (tester) async {
      final fake = HomeTrainingFake()
        ..launchGate = Completer<TrainingSessionLaunchResult>();
      final activity = RecordingActivity();
      ReviewEngineService().initPreparedStudySession([
        LegacyPersistedQuestion(
            question: Question(
                id: 'b4-q',
                type: 1,
                content: 'B4 synthetic question',
                options: '["A", "B"]',
                answer: 'A',
                createdAt: 1,
                explanation: '',
                bankName: 'bank'))
      ]);
      await pump(tester, fake, activity: activity);
      final target =
          find.byKey(ValueKey(review ? 'home-review-task' : 'home-new-task'));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.tap(target);
      await tester.pump();
      expect(fake.starts, 1);
      fake.launchGate!.complete(TrainingSessionReady(1));
      await tester.pumpAndSettle();
      final practice = tester.widget<PracticePage>(find.byType(PracticePage));
      expect(practice.usePreparedStudySession, isTrue);
      expect(practice.preparedSessionKind, AnswerAttemptSessionKind.normal);
      expect(practice.isPomodoroActive, isFalse);
      expect(
          activity.begins.single.scene,
          review
              ? StudyActivityScene.categoryReview
              : StudyActivityScene.ordinaryPractice);
      expect(activity.begins.single.context.categoryKey, homeA);
      expect(activity.begins.single.context.contentId,
          review ? isNull : fake.launchedTarget!.contentId);
      final homeContext =
          tester.element(find.byType(HomePage, skipOffstage: false));
      final home =
          tester.widget<HomePage>(find.byType(HomePage, skipOffstage: false));
      expect(home.homeTraining, isNotNull);
      expect(homeContext.mounted, isTrue);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(fake.reads, greaterThan(1));
      expect(fake.weeks, greaterThan(1));
      expect(activity.ends.single.reason, StudyActivityEndReason.exited);
    });
  }

  testWidgets(
      'stale and empty starts never navigate or retry; unconfigured still permits review',
      (tester) async {
    final fake = HomeTrainingFake()
      ..launchResult = const TrainingSessionStaleConfiguration();
    await pump(tester, fake);
    await tester.ensureVisible(find.byKey(const ValueKey('home-new-task')));
    await tester.tap(find.byKey(const ValueKey('home-new-task')));
    await tester.pumpAndSettle();
    expect(fake.starts, 1);
    expect(find.byType(PracticePage), findsNothing);
    expect(find.text('训练配置已变化'), findsOneWidget);
    fake.launchResult = const TrainingSessionEmpty();
    await tester.tap(find.byKey(const ValueKey('home-new-task')));
    await tester.pumpAndSettle();
    expect(fake.starts, 2);
    expect(find.byType(PracticePage), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final empty = HomeTrainingFake(unconfigured: true);
    await pump(tester, empty);
    expect(find.text('配置训练内容'), findsOneWidget);
    expect(
        tester
            .widget<TodayTrainingActionCard>(
                find.byKey(const ValueKey('home-new-task')))
            .enabled,
        isFalse);
    expect(
        tester
            .widget<TodayTrainingActionCard>(
                find.byKey(const ValueKey('home-review-task')))
            .enabled,
        isTrue);
  });

  testWidgets(
      'three Category pages peek and a single usable corner stays hidden',
      (tester) async {
    final fake = HomeTrainingFake(categories: 3, durationMs: 0);
    fake.groups[0] = TrainingCategorySnapshot(
        categoryKey: homeA,
        preference: fake.groups.first.preference,
        contents: [fake.groups.first.contents.first]);
    await pump(tester, fake);
    final pager = tester
        .widget<PageView>(find.byKey(const ValueKey('home-category-pages')));
    expect(pager.controller!.viewportFraction, .83);
    expect(find.byKey(const ValueKey('home-category-dot-2')), findsOneWidget);
    expect(find.byType(FoldedPageCorner), findsNothing);
    expect(find.byType(WeeklyActivityCard), findsNothing);
    expect(find.textContaining('本周学习'), findsNothing);
    fake.weekFailed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(WeeklyActivityCard), findsNothing);
    expect(find.text('本周学习记录暂不可用'), findsNothing);
  });

  testWidgets('retained weekly presentation still excludes future dates',
      (tester) async {
    final week =
        (await HomeTrainingFake().readCurrentWeek() as HomeTrainingSuccess)
            .value;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WeeklyActivityCard(
                result: HomeTrainingSuccess(week),
                loading: false,
                todayLocalDate: '2026-10-04'))));
    expect(find.byKey(const ValueKey('home-week-bar-0')),
        findsNothing); // Recorded future date never looks completed.
  });

  testWidgets(
      'unavailable data never masquerades as zero and retired modules stay absent',
      (tester) async {
    final fake = HomeTrainingFake()
      ..readGate = Completer<HomeTrainingResult<TodayTrainingSnapshot>>();
    await pump(tester, fake, settle: false);
    expect(find.byKey(const ValueKey('home-context-loading')), findsOneWidget);
    expect(
        tester
            .widget<TodayTrainingActionCard>(
                find.byKey(const ValueKey('home-new-task')))
            .enabled,
        isFalse);
    fake.readGate!
        .complete(const HomeTrainingFailed(HomeTrainingFailure.unavailable));
    await tester.pumpAndSettle();
    expect(find.text('训练暂不可用'), findsOneWidget);
    expect(find.byType(WeeklyActivityCard), findsNothing);
    expect(find.byKey(const ValueKey('home-exam-entry')), findsNothing);
    expect(find.text('—'), findsNWidgets(3));
    expect(find.text('保持学习，慢慢进步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'long category labels grow at large text without clipping or changing selection',
      (tester) async {
    final longKey = FolderCategoryKey('用于验证长分类名称在窄屏与放大字体下能够完整换行的合成分类');
    final fake = HomeTrainingFake()..selected = longKey;
    fake.groups[0] = TrainingCategorySnapshot(
        categoryKey: longKey,
        preference:
            TrainingCategoryPreference(categoryKey: longKey, revision: 1),
        contents: [
          TrainingContentView(
              content: homeContent('long-A', longKey), usable: true),
          TrainingContentView(
              content: homeContent('long-B', longKey, order: 1), usable: true),
        ]);
    await pump(tester, fake,
        size: const Size(360, 720), scale: 1.8, reduceMotion: true);
    expect(tester.takeException(), isNull);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('home-category-pages')))
            .height,
        greaterThan(180));
    expect(
        tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
        Duration.zero);
    await tester
        .ensureVisible(find.byKey(const ValueKey('home-content-corner')));
    await tester.tap(find.byKey(const ValueKey('home-content-corner')));
    await tester.pumpAndSettle();
    expect(fake.selected, longKey);
    expect(fake.selections.single.contentId, 'long-B');
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
        'full V3 visual evidence dark=$dark with usable corner and Reduce Motion',
        (tester) async {
      final fake = HomeTrainingFake();
      await pump(tester, fake,
          size: const Size(390, 1100), dark: dark, reduceMotion: true);
      final corner = find.byType(FoldedPageCorner);
      expect(corner, findsOneWidget);
      await screenshot(tester, '390-${dark ? 'dark' : 'light'}-full');
      await screenshot(tester, '390-${dark ? 'dark' : 'light'}-corner',
          crop: corner);
      await tester.tap(find.byKey(const ValueKey('home-content-corner')));
      await tester.pumpAndSettle();
      expect(fake.selections, hasLength(1));
      expect(fake.selections.single.contentId, 'Bmath');
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(360, 720),
    const Size(390, 844),
    const Size(1024, 768)
  ]) {
    for (final dark in [false, true]) {
      for (final state in [
        'multiple',
        'single',
        'unconfigured',
        'zero',
        'partial'
      ]) {
        testWidgets('V2 fixture $size dark=$dark $state', (tester) async {
          final fake = HomeTrainingFake(
              categories: state == 'single' ? 1 : 2,
              unconfigured: state == 'unconfigured',
              newCount: state == 'zero' ? 0 : 327,
              partial: state == 'partial');
          await pump(tester, fake, size: size, dark: dark, scale: 1.5);
          expect(tester.takeException(), isNull);
          expect(find.text('题库题量'), findsOneWidget);
          expect(find.byKey(const ValueKey('home-switch-bank')), findsNothing);
          expect(find.byType(DropdownButton), findsNothing);
          await screenshot(tester,
              '${size.width.toInt()}-${dark ? 'dark' : 'light'}-$state-top');
          await tester
              .ensureVisible(find.byKey(const ValueKey('home-view-plan')));
          await tester.pumpAndSettle();
          expect(find.byType(WeeklyActivityCard), findsNothing);
          expect(find.textContaining('本周学习'), findsNothing);
          expect(find.byKey(const ValueKey('home-exam-entry')), findsNothing);
          expect(find.byType(MockCenterScreen), findsNothing);
          expect(find.text('尚未采用学习计划'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await screenshot(tester,
              '${size.width.toInt()}-${dark ? 'dark' : 'light'}-$state-plan');
        });
      }
    }
  }
}
