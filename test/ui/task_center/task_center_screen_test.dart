import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';
import 'package:shiroha_quiz/ui/pages/home_page.dart';
import 'package:shiroha_quiz/ui/task_center/task_center_components.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import '../../support/task_center_fakes.dart';

void main() {
  final capture = Platform.environment['B5_VISUAL_EVIDENCE'] == '1';
  final boundary = GlobalKey();
  setUpAll(() async {
    if (capture && Platform.isWindows) {
      await (FontLoader('B5Font')
            ..addFont(Future.value(ByteData.sublistView(
                await File('C:/Windows/Fonts/msyh.ttc').readAsBytes()))))
          .load();
      final font = Platform.environment['B5_MATERIAL_FONT'];
      if (font != null) {
        await (FontLoader('MaterialIcons')
              ..addFont(Future.value(
                  ByteData.sublistView(await File(font).readAsBytes()))))
            .load();
      }
    }
  });
  Future<void> pump(WidgetTester tester, TaskCenterFake fake,
      {Size size = const Size(360, 720),
      bool dark = false,
      double scale = 1.3}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.darkTheme : AppTheme.lightTheme;
    await tester.pumpWidget(MaterialApp(
        theme: capture
            ? theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'B5Font'))
            : theme,
        home: MediaQuery(
            data: MediaQueryData(
                size: size, textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(
                key: boundary,
                child: TaskCenterScreen(
                    dependencies: fake.ports,
                    localize: (utc) => utc.add(const Duration(hours: 8)))))));
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final image = await (boundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory('.dart_tool/b5-visual').create(recursive: true);
      await File('.dart_tool/b5-visual/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });
  }

  test(
      'event times use exact kind, absent metadata and injected local conversion',
      () {
    DateTime local(DateTime utc) => utc.add(const Duration(hours: 8));
    final seconds =
        DateTime.utc(2026, 10, 6, 2, 3).millisecondsSinceEpoch ~/ 1000;
    for (final entry in {
      '排队': TaskCenterEventKind.queuedAt,
      '开始': TaskCenterEventKind.startedAt,
      '解析完成': TaskCenterEventKind.parsedAt,
      '完成': TaskCenterEventKind.completedAt,
      '失败': TaskCenterEventKind.failedAt
    }.entries) {
      expect(
          formatTaskCenterEventTime(
              TaskCenterEventTime(kind: entry.value, utcSeconds: seconds),
              localize: local),
          '${entry.key}于 2026.10.06 10:03');
    }
    for (final kind in [
      TaskCenterEventKind.startedAt,
      TaskCenterEventKind.parsedAt,
      TaskCenterEventKind.failedAt
    ]) {
      expect(
          formatTaskCenterEventTime(
              TaskCenterEventTime(kind: kind, utcSeconds: null)),
          contains('时间未记录'));
    }
    expect(
        formatTaskCenterEventTime(
            TaskCenterEventTime(kind: null, utcSeconds: null)),
        '时间未记录');
  });
  testWidgets('tabs and empty CTA consume DTO; details contain only safe facts',
      (tester) async {
    final fake = TaskCenterFake();
    await pump(tester, fake);
    expect(find.text('暂无正在解析的任务'), findsOneWidget);
    expect(find.text('还有 1 个任务等待校对，去处理'), findsOneWidget);
    await tester.tap(find.text('还有 1 个任务等待校对，去处理'));
    await tester.pumpAndSettle();
    expect(find.text('已识别 22 道题 · 1 项需要确认'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('task-details-pending')));
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pumpAndSettle();
    expect(find.textContaining('trace-'), findsNothing);
    expect(find.textContaining('raw'), findsNothing);
    expect(find.text('synthetic.pdf'), findsWidgets);
    expect(fake.commands, 0);
  });
  testWidgets(
      'missing times and command eligibility remain independent of tabs; read failure differs from zero',
      (tester) async {
    final fake = TaskCenterFake()
      ..items = [taskItem('pending', time: null, enabled: false)];
    await pump(tester, fake);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    expect(find.text('解析完成时间未记录'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-review-pending')), findsNothing);
    fake.unavailable = true;
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('任务暂不可用'), findsOneWidget);
    expect(find.text('暂无待校对任务'), findsNothing);
    expect(fake.commands, 0);
  });
  testWidgets(
      'review receives only safe request and cleanup confirms original snapshot',
      (tester) async {
    final fake = TaskCenterFake();
    await pump(tester, fake);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('task-review-pending')));
    await tester.tap(find.byKey(const ValueKey('task-review-pending')));
    await tester.pumpAndSettle();
    expect(fake.reviews, 1);
    await tester.tap(find.byKey(const ValueKey('task-center-page-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理已完成记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不影响已经保存的题库'), findsOneWidget);
    fake.items.add(taskItem('new', status: TaskCenterCoarseStatus.completed));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(fake.submitted, same(fake.issued));
    expect(fake.submitted!.targets, hasLength(1));
  });
  testWidgets(
      'Home badge and parse route use Application snapshot and refresh after return',
      (tester) async {
    final fake = TaskCenterFake()
      ..items = [
        for (var i = 0; i < 3; i++)
          taskItem('q$i',
              status: TaskCenterCoarseStatus.inProgress,
              attempt: TaskCenterAttemptStatus.queued)
      ];
    final dependencies = fake.ports;
    await tester
        .pumpWidget(MaterialApp(home: HomePage(taskCenter: dependencies)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('home-parse-action')));
    expect(
        tester
            .widget<Badge>(find.descendant(
                of: find.byKey(const ValueKey('home-parse-action')),
                matching: find.byType(Badge)))
            .label,
        isA<Text>());
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('home-parse-action')),
            matching: find.text('3')),
        findsOneWidget);
    final reads = fake.reads;
    await tester.tap(find.byKey(const ValueKey('home-parse-action')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TaskCenterScreen>(find.byType(TaskCenterScreen))
            .dependencies,
        same(dependencies));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(fake.reads, greaterThan(reads));
  });
  for (final size in [const Size(360, 720), const Size(1024, 768)]) {
    for (final dark in [false, true]) {
      for (final status in TaskCenterCoarseStatus.values) {
        testWidgets('TaskCenter fixture $size dark=$dark ${status.name}',
            (tester) async {
          final fake = TaskCenterFake()
            ..items = [
              taskItem('q',
                  status: TaskCenterCoarseStatus.inProgress,
                  attempt: TaskCenterAttemptStatus.queued),
              taskItem('p', name: '2026年数学考试第一部分及第二部分长文件名校对资料.pdf'),
              taskItem('d', status: TaskCenterCoarseStatus.completed),
              taskItem('f',
                  status: TaskCenterCoarseStatus.error,
                  attempt: TaskCenterAttemptStatus.failed)
            ];
          await pump(tester, fake, size: size, dark: dark);
          await tester
              .tap(find.byKey(ValueKey('task-category-${status.name}')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(fake.commands, 0);
          expect(fake.picks, 0);
          await shot(tester,
              '${size.width.toInt()}-${dark ? 'dark' : 'light'}-${status.name}');
        });
      }
    }
  }
}
