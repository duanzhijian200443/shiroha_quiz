import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';
import 'package:shiroha_quiz/ui/pages/home_page.dart';
import 'package:shiroha_quiz/ui/task_center/task_center_components.dart';
import 'package:shiroha_quiz/ui/task_center/task_center_detail_sheet.dart';
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
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: capture
                ? theme.copyWith(
                    textTheme: theme.textTheme.apply(fontFamily: 'B5Font'))
                : theme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: TaskCenterScreen(
                dependencies: fake.ports,
                localize: (utc) => utc.add(const Duration(hours: 8))))));
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (!capture) return;
    debugDisableShadows = false;
    try {
      void repaint(RenderObject render) {
        render.markNeedsPaint();
        render.visitChildren(repaint);
      }

      repaint(boundary.currentContext!.findRenderObject()!);
      await tester.pump();
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory('.dart_tool/task-center-v2-visual')
            .create(recursive: true);
        await File('.dart_tool/task-center-v2-visual/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = true;
    }
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
    expect(find.textContaining('trace-'), findsNothing);
    await tester
        .ensureVisible(find.byKey(const ValueKey('task-details-pending')));
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('task-center-detail-sheet'));
    expect(find.descendant(of: sheet, matching: find.text('trace-current')),
        findsOneWidget);
    expect(
        find.descendant(of: sheet, matching: find.byType(TaskCenterTaskCard)),
        findsNothing);
    for (final label in ['去校对', '重试', '取消', '删除', '查看详情']) {
      expect(
          find.descendant(of: sheet, matching: find.text(label)), findsNothing);
    }
    for (final forbidden in ['raw', 'source', 'token-', 'provider']) {
      expect(find.textContaining(forbidden), findsNothing);
    }
    expect(find.text('2 分 34 秒'), findsOneWidget);
    expect(find.text('synthetic.pdf'), findsWidgets);
    expect(fake.commands, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('task-review-pending')));
    await tester.tap(find.byKey(const ValueKey('task-review-pending')));
    await tester.pumpAndSettle();
    expect(fake.reviews, 1);
  });

  test('duration formatting preserves zero and clear hour/minute boundaries',
      () {
    expect(formatTaskCenterDuration(null), '未记录');
    expect(formatTaskCenterDuration(0), '0 秒');
    expect(formatTaskCenterDuration(59), '59 秒');
    expect(formatTaskCenterDuration(60), '1 分 0 秒');
    expect(formatTaskCenterDuration(154), '2 分 34 秒');
    expect(formatTaskCenterDuration(3754), '1 小时 2 分 34 秒');
  });

  testWidgets('trace copies exactly once on explicit tap only', (tester) async {
    final fake = TaskCenterFake();
    final copies = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copies.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(tester, fake, size: const Size(390, 844), scale: 1);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-task-pending')));
    await tester.pumpAndSettle();
    expect(copies, isEmpty);
    expect(fake.commands, 0);
    await tester
        .ensureVisible(find.byKey(const ValueKey('task-detail-copy-trace')));
    await tester.tap(find.byKey(const ValueKey('task-detail-copy-trace')));
    await tester.pumpAndSettle();
    expect(copies, ['trace-current']);
  });

  testWidgets('unknown detail facts stay unknown and copy is disabled',
      (tester) async {
    final fake = TaskCenterFake()
      ..detailTrace = null
      ..detailDuration = null
      ..items = [taskItem('pending', questionCount: null, warningCount: 0)];
    await pump(tester, fake);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pumpAndSettle();
    expect(find.text('未记录'), findsNWidgets(3));
    expect(find.text('0 项'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('task-detail-copy-trace')))
            .onPressed,
        isNull);
  });

  testWidgets(
      'dismissed query cannot overwrite another detail or reopen after dispose',
      (tester) async {
    final old = Completer<HomeTrainingResult<TaskCenterDetail>>();
    final fake = TaskCenterFake()..detailGates.add(old);
    await pump(tester, fake, size: const Size(390, 844), scale: 1);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    final card =
        tester.widget<TaskCenterTaskCard>(find.byType(TaskCenterTaskCard));
    card.onDetail();
    card.onDetail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.detailReads, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    fake.detailTrace = 'trace-second';
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pumpAndSettle();
    old.complete(HomeTrainingSuccess(TaskCenterDetail(
        taskId: 'old',
        fileDisplayName: 'old.pdf',
        coarseStatus: TaskCenterCoarseStatus.pendingReview,
        attemptStatus: TaskCenterAttemptStatus.readyForReview,
        counts: TaskCenterCounts(questionCount: null, warningCount: null),
        eventTime: TaskCenterEventTime(
            kind: TaskCenterEventKind.parsedAt, utcSeconds: null),
        traceId: 'trace-old',
        durationSeconds: 500)));
    await tester.pumpAndSettle();
    expect(find.text('trace-second'), findsOneWidget);
    expect(find.text('trace-old'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed detail query renders safe error with no stale diagnostics',
      (tester) async {
    final fake = TaskCenterFake()..detailUnavailable = true;
    await pump(tester, fake);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pumpAndSettle();
    expect(find.text('任务详情暂不可用'), findsOneWidget);
    expect(find.textContaining('trace-'), findsNothing);
    expect(fake.commands, 0);
  });

  testWidgets(
      'mismatched detail response and disposed pending query publish no facts',
      (tester) async {
    final wrong = Completer<HomeTrainingResult<TaskCenterDetail>>();
    final fake = TaskCenterFake()..detailGates.add(wrong);
    await pump(tester, fake, size: const Size(390, 844), scale: 1);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pump();
    wrong.complete(HomeTrainingSuccess(TaskCenterDetail(
        taskId: 'other',
        fileDisplayName: 'other.pdf',
        coarseStatus: TaskCenterCoarseStatus.pendingReview,
        attemptStatus: TaskCenterAttemptStatus.readyForReview,
        counts: TaskCenterCounts(questionCount: 0, warningCount: 0),
        eventTime: TaskCenterEventTime(
            kind: TaskCenterEventKind.parsedAt, utcSeconds: null),
        traceId: 'trace-other',
        durationSeconds: 0)));
    await tester.pumpAndSettle();
    expect(find.text('任务详情暂不可用'), findsOneWidget);
    expect(find.text('trace-other'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final disposed = Completer<HomeTrainingResult<TaskCenterDetail>>();
    fake.detailGates.add(disposed);
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    disposed
        .complete(const HomeTrainingFailed(HomeTrainingFailure.unavailable));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(fake.commands, 0);
  });

  testWidgets(
      'task menu does not open detail and still executes only admitted actions',
      (tester) async {
    final fake = TaskCenterFake()
      ..items = [
        taskItem('queued',
            status: TaskCenterCoarseStatus.inProgress,
            attempt: TaskCenterAttemptStatus.queued)
      ];
    await pump(tester, fake);
    await tester.tap(find.byKey(const ValueKey('task-menu-queued')));
    await tester.pumpAndSettle();
    expect(fake.detailReads, 0);
    expect(fake.commands, 0);
    await tester.tap(find.text('取消任务'));
    await tester.pumpAndSettle();
    expect(fake.commands, 1);
    expect(fake.detailReads, 0);
  });

  testWidgets(
      'review after detail close still rejects stale Application admission',
      (tester) async {
    final fake = TaskCenterFake();
    await pump(tester, fake);
    await tester.tap(find.byKey(const ValueKey('task-category-pendingReview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-details-pending')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    fake.failure = HomeTrainingFailure.stale;
    await tester.tap(find.byKey(const ValueKey('task-review-pending')));
    await tester.pumpAndSettle();
    expect(fake.reviews, 0);
    expect(find.text('任务状态已变化，请刷新'), findsOneWidget);
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
  for (final size in [
    const Size(360, 720),
    const Size(390, 844),
    const Size(1024, 768)
  ]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final status in TaskCenterCoarseStatus.values) {
          testWidgets(
              'TaskCenter fixture $size dark=$dark scale=$scale ${status.name}',
              (tester) async {
            final fake = TaskCenterFake()
              ..items = [
                taskItem('q',
                    status: TaskCenterCoarseStatus.inProgress,
                    attempt: TaskCenterAttemptStatus.queued),
                taskItem('p', name: '2026年数学考试第一部分及第二部分长文件名校对资料.pdf'),
                taskItem('p2', name: '数学练习·解析示例.pdf'),
                taskItem('d', status: TaskCenterCoarseStatus.completed),
                taskItem('f',
                    status: TaskCenterCoarseStatus.error,
                    attempt: TaskCenterAttemptStatus.failed)
              ];
            await pump(tester, fake, size: size, dark: dark, scale: scale);
            await tester.ensureVisible(
                find.byKey(ValueKey('task-category-${status.name}')));
            await tester
                .tap(find.byKey(ValueKey('task-category-${status.name}')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(fake.commands, 0);
            expect(fake.picks, 0);
            await shot(tester,
                '${size.width.toInt()}-${dark ? 'dark' : 'light'}-$scale-${status.name}');
            if (status == TaskCenterCoarseStatus.pendingReview) {
              await tester
                  .ensureVisible(find.byKey(const ValueKey('task-details-p')));
              await tester.tap(find.byKey(const ValueKey('task-details-p')));
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                  find.byKey(const ValueKey('task-detail-copy-trace')));
              expect(tester.takeException(), isNull);
              await shot(tester,
                  '${size.width.toInt()}-${dark ? 'dark' : 'light'}-$scale-detail');
            }
          });
        }
      }
    }
  }
}
