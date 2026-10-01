import 'package:shiroha_quiz/ui/pages/bank_detail_screen.dart';
import 'package:shiroha_quiz/application/practice/study_session_launch.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/ui/pages/mock_center_screen.dart';
import 'package:shiroha_quiz/ui/home/current_plan_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/today/today_context_query.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_command_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_pool_order.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_selection_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:shiroha_quiz/services/study_plan/study_plan_practice_session_launcher.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/home_page.dart';
import 'package:shiroha_quiz/ui/pages/import_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _StubTodayContextQuery implements TodayContextQuery {
  _StubTodayContextQuery(this.read);

  final Future<TodayContextSnapshot> Function() read;
  int calls = 0;

  @override
  Future<TodayContextSnapshot> loadContext() {
    calls++;
    return read();
  }
}

final class _StubPersistencePort implements StudyPlanPersistencePort {
  @override
  Future<ActiveStudyPlan?> loadActivePlan() async => null;

  @override
  Future<StudyPlanPersistenceCommitResult> commitAdoption({
    required String planId,
    required String bankName,
    String? goal,
    required int dailyTarget,
    required StudyPlanPriority priority,
    int? horizonDays,
    String? sourceConversationId,
    String? sourceUserMessageId,
    required ConversationScope sourceScope,
    required DateTime adoptedAt,
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  }) {
    throw UnimplementedError();
  }
}

final class _StubPlanningPort implements StudyPlanPlanningPort {
  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) {
    throw UnimplementedError();
  }
}

final class _StubCandidateQueryPort implements StudyPlanCandidateQueryPort {
  @override
  Future<StudyPlanCandidateBatch> loadCandidates({
    required String bankName,
    required int nowUnixSeconds,
    required int maxPerPool,
  }) {
    throw UnimplementedError();
  }
}

/// Fake selection service: counts every fresh selection run and can hold a
/// call pending to prove duplicate-start prevention.
final class _FakeSelectionService extends StudyPlanSelectionService {
  _FakeSelectionService({required this.state})
      : super(
          persistencePort: _StubPersistencePort(),
          planningPort: _StubPlanningPort(),
          candidateQueryPort: _StubCandidateQueryPort(),
          poolOrder: const StudyPlanPoolOrder(),
          clock: () => DateTime.utc(2026, 8, 15, 10, 0),
        );

  StudyPlanFocusedState state;
  int loadCalls = 0;
  Completer<StudyPlanFocusedState>? pending;

  @override
  Future<StudyPlanFocusedState> loadFocusedState() {
    loadCalls++;
    final completer = pending;
    // Once the pending completer is completed, later calls return the
    // current `state` (latest live state), never the completed stale future.
    if (completer != null && !completer.isCompleted) {
      return completer.future;
    }
    return Future<StudyPlanFocusedState>.value(state);
  }
}

/// Fake persistence port for stop: records the exact expected plan id and
/// returns the configured bounded stop result. The REAL
/// [StudyPlanCommandService] (still `final`) is used in widget tests, so the
/// stop CAS parameter validation stays production-true.
final class _FakeStopPersistencePort implements StudyPlanPersistencePort {
  int stopCalls = 0;
  String? lastExpectedPlanId;
  StudyPlanPersistenceStopResult nextStopResult =
      const StudyPlanPersistenceStopSuccess();

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  }) async {
    stopCalls++;
    lastExpectedPlanId = expectedPlanId;
    return nextStopResult;
  }

  @override
  Future<ActiveStudyPlan?> loadActivePlan() async => null;

  @override
  Future<StudyPlanPersistenceCommitResult> commitAdoption({
    required String planId,
    required String bankName,
    String? goal,
    required int dailyTarget,
    required StudyPlanPriority priority,
    int? horizonDays,
    String? sourceConversationId,
    String? sourceUserMessageId,
    required ConversationScope sourceScope,
    required DateTime adoptedAt,
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  }) {
    throw UnimplementedError();
  }
}

/// Real command service wired to a fake stop persistence port.
final class _CommandHarness {
  final _FakeStopPersistencePort stopPort = _FakeStopPersistencePort();
  late final StudyPlanCommandService service = StudyPlanCommandService(
    draftService: StudyPlanDraftService(
      planningPort: _StubPlanningPort(),
      draftIdFactory: () => 'draft_x',
      clock: () => DateTime.utc(2026, 8, 15, 10, 0),
    ),
    persistencePort: stopPort,
    planIdFactory: () => 'plan_x',
    clock: () => DateTime.utc(2026, 8, 15, 10, 0),
  );
}

final class _FakeLauncher extends StudyPlanPracticeSessionLauncher {
  _FakeLauncher()
      : super(
          reviewRepository: ReviewRepository.instance,
          reviewEngine: ReviewEngineService(),
        );

  int launchCalls = 0;
  List<String>? lastStorageIds;
  StudyPlanPracticeLaunchResult nextResult =
      const StudyPlanPracticeLaunchSuccess(1);

  @override
  Future<StudyPlanPracticeLaunchResult> launch(
    List<String> selectedStorageIds,
  ) async {
    launchCalls++;
    lastStorageIds = selectedStorageIds;
    return nextResult;
  }
}

final class _OrdinaryLauncher implements StudySessionLauncher {
  final pools = <StudySessionPool>[];
  final banks = <String>[];
  Completer<StudySessionLaunchResult>? pending;
  StudySessionLaunchResult result = const StudySessionEmpty();
  @override
  Future<StudySessionLaunchResult> launch(
      {required String bankName, required StudySessionPool pool}) {
    pools.add(pool);
    banks.add(bankName);
    return pending?.future ?? Future.value(result);
  }
}

ActiveStudyPlan _focusedPlan() {
  return ActiveStudyPlan(
    planId: 'plan_1',
    bankName: 'Math 题库',
    goal: '掌握核心',
    dailyTarget: 30,
    priority: StudyPlanPriority.dueFirst,
    horizonDays: 21,
    adoptedAt: DateTime.utc(2026, 8, 1, 10, 0),
  );
}

void main() {
  late TaskManager taskManager;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.deleteDatabaseFile();
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.instance.database;
    taskManager = TaskManager.forTesting();
  });

  tearDown(() async {
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.deleteDatabaseFile();
  });

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    int maxFrames = 40,
  }) async {
    for (var frame = 0; frame < maxFrames; frame++) {
      await tester.pump();
      if (finder.evaluate().isNotEmpty) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    fail('Expected widget did not appear within ${maxFrames * 25} ms.');
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(360, 720),
    double textScale = 1,
    VoidCallback? onSwitchBank,
    VoidCallback? onPracticeRequested,
    VoidCallback? onImportRequested,
    VoidCallback? onPhotoImportRequested,
    ValueChanged<String>? onAskAssistant,
    TodayContextQuery? todayContextQuery,
    StudySessionLauncher? studySessionLauncher,
    bool dark = false,
    StudyPlanSelectionService? studyPlanSelectionService,
    StudyPlanCommandService? studyPlanCommandService,
    StudyPlanPracticeSessionLauncher? studyPlanSessionLauncher,
    int todayActivationEpoch = 0,
    Finder? waitFor,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: HomePage(
            todayContextQuery: todayContextQuery ??
                _StubTodayContextQuery(
                    () async => const TodayContextSnapshot()),
            taskManager: taskManager,
            studySessionLauncher: studySessionLauncher,
            onSwitchBank: onSwitchBank,
            onPracticeRequested: onPracticeRequested,
            onImportRequested: onImportRequested,
            onPhotoImportRequested: onPhotoImportRequested,
            onAskAssistant: onAskAssistant,
            studyPlanSelectionService: studyPlanSelectionService,
            studyPlanCommandService: studyPlanCommandService,
            studyPlanSessionLauncher: studyPlanSessionLauncher,
            todayActivationEpoch: todayActivationEpoch,
          ),
        ),
      ),
    );
    await pumpUntilFound(
        tester, waitFor ?? find.byKey(const ValueKey('home-bank-card')));
    {
      for (var i = 0;
          i < 40 &&
              find
                  .byKey(const ValueKey('home-context-loading'))
                  .evaluate()
                  .isNotEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(
          find.byKey(const ValueKey('home-context-loading'),
              skipOffstage: false),
          findsNothing);
    }
  }

  Future<void> openFocusedMode(WidgetTester tester, {Key? waitFor}) async {
    final entry = find.byKey(const ValueKey('home-view-plan'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    if (waitFor != null) await pumpUntilFound(tester, find.byKey(waitFor));
  }

  testWidgets(
      'unified home uses injected counts and keeps the ordinary bank independent of the plan',
      (tester) async {
    final query = _StubTodayContextQuery(() async => const TodayContextSnapshot(
        bankName: 'ordinary-bank',
        newCount: 7,
        reviewCount: 3,
        totalCount: 12,
        masteredCount: 2,
        todayPracticeCount: 4));
    final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
            _focusedPlan(),
            ['id1'],
            const StudyPlanFocusedAdvisory(
                masteryReached: false, horizonElapsed: false)));
    await pumpHome(tester,
        todayContextQuery: query, studyPlanSelectionService: service);
    expect(find.text('ordinary-bank'), findsOneWidget);
    expect(find.text('7 题'), findsOneWidget);
    expect(find.text('3 题'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('Math 题库 · 训练计划'), findsOneWidget);
    expect(find.text('30 题'), findsNothing); // Strategy belongs in detail.
    for (final key in [
      'today-mode-ordinary',
      'today-mode-focused',
      'today-mode-exam',
      'home-start-training'
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    expect(find.byType(MockCenterScreen),
        findsNothing); // No hidden polling surface.
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reference composition uses horizontal compact cards and real assets',
      (tester) async {
    await pumpHome(tester,
        size: const Size(390, 844),
        todayContextQuery: _StubTodayContextQuery(() async =>
            const TodayContextSnapshot(
                bankName: '考研数学',
                totalCount: 86,
                masteredCount: 20,
                todayPracticeCount: 4,
                newCount: 6,
                reviewCount: 12)),
        studySessionLauncher: _OrdinaryLauncher());
    final banner =
        tester.getRect(find.byKey(const ValueKey('home-welcome-banner')));
    expect(banner.width / banner.height, inInclusiveRange(2.9, 3.6));
    final summaryIcon = find.descendant(
        of: find.byType(HomePage),
        matching: find.byIcon(Icons.bar_chart_rounded));
    expect(tester.getCenter(summaryIcon).dx,
        lessThan(tester.getCenter(find.text('已掌握')).dx));
    final newCard = find.byKey(const ValueKey('home-new-task'));
    final reviewCard = find.byKey(const ValueKey('home-review-task'));
    expect(tester.getSize(newCard).height, lessThan(90));
    expect(tester.getSize(newCard), tester.getSize(reviewCard));
    final newIcon =
        find.descendant(of: newCard, matching: find.byIcon(Icons.add_rounded));
    expect(tester.getCenter(newIcon).dx,
        lessThan(tester.getCenter(find.text('6 题')).dx));
    final assets = tester
        .widgetList<Image>(find.descendant(
            of: find.byType(HomePage), matching: find.byType(Image)))
        .map((image) => (image.image as AssetImage).assetName)
        .toSet();
    expect(assets, {
      'assets/images/today/welcome-landscape.png',
      'assets/images/today/paper-pencil.png'
    });
    final homeContext =
        tester.element(find.byKey(const ValueKey('home-brand-title')));
    expect(Theme.of(homeContext).colorScheme.primary, const Color(0xFF303238));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'loading, failure, absence and a real zero remain distinct and disabled',
      (tester) async {
    final pending = Completer<TodayContextSnapshot>();
    final query = _StubTodayContextQuery(() => pending.future);
    final launcher = _OrdinaryLauncher();
    await tester.pumpWidget(MaterialApp(
        home: HomePage(
            taskManager: taskManager,
            todayContextQuery: query,
            studySessionLauncher: launcher)));
    expect(
        find.byKey(const ValueKey('home-context-loading'), skipOffstage: false),
        findsOneWidget);
    expect(find.text('— 题'), findsNWidgets(2));
    pending.completeError(const TodayContextUnavailable());
    await tester.pump();
    expect(find.text('暂时无法加载题库，请重试'), findsOneWidget);
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('home-new-task')))
            .onTap,
        isNull);
    await pumpHome(tester,
        todayActivationEpoch: 1,
        todayContextQuery:
            _StubTodayContextQuery(() async => const TodayContextSnapshot()),
        studySessionLauncher: launcher);
    expect(find.text('选择题库'), findsOneWidget);
    expect(find.text('— 题'), findsNWidgets(2));
    await pumpHome(tester,
        todayActivationEpoch: 2,
        todayContextQuery: _StubTodayContextQuery(() async =>
            const TodayContextSnapshot(
                bankName: 'empty-bank', todayPracticeCount: 0)),
        studySessionLauncher: launcher);
    expect(find.text('0 题'), findsNWidgets(2));
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('home-new-task')))
            .onTap,
        isNull);
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('home-review-task')))
            .onTap,
        isNull);
    expect(launcher.pools, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'ordinary cards request separate fresh pools and suppress duplicate starts',
      (tester) async {
    final launcher = _OrdinaryLauncher()
      ..pending = Completer<StudySessionLaunchResult>();
    final query = _StubTodayContextQuery(() async => const TodayContextSnapshot(
        bankName: 'ordinary-bank', newCount: 7, reviewCount: 3));
    var switches = 0;
    await pumpHome(tester,
        todayContextQuery: query,
        studySessionLauncher: launcher,
        onSwitchBank: () => switches++);
    await tester.ensureVisible(find.byKey(const ValueKey('home-new-task')));
    await tester.tap(find.byKey(const ValueKey('home-new-task')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-review-task')));
    expect(launcher.pools, [StudySessionPool.newQuestions]);
    launcher.pending!.complete(const StudySessionEmpty());
    launcher.pending = null;
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-review-task')));
    await tester.pump();
    await tester.pump();
    expect(launcher.pools,
        [StudySessionPool.newQuestions, StudySessionPool.dueReviews]);
    expect(launcher.banks, ['ordinary-bank', 'ordinary-bank']);
    expect(find.byType(PracticePage), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('home-switch-bank')));
    await tester.tap(find.byKey(const ValueKey('home-switch-bank')));
    expect(switches, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'ordinary success opens non-preview Practice with normal attempt attribution',
      (tester) async {
    final launcher = _OrdinaryLauncher()..result = const StudySessionReady(1);
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('questions', {
        'id': 'ordinary-start',
        'type': 0,
        'content': 'synthetic ordinary stem',
        'options': '["A. first", "B. second"]',
        'standard_answer': 'A',
        'created_at': 0,
        'bank_name': 'ordinary-bank'
      });
      await db.insert(
          'review_states', {'question_id': 'ordinary-start', 'state': 0});
      await ReviewEngineService().initStudySession('ordinary-bank');
    });
    await pumpHome(tester,
        studySessionLauncher: launcher,
        todayContextQuery: _StubTodayContextQuery(() async =>
            const TodayContextSnapshot(
                bankName: 'ordinary-bank', newCount: 1)));
    await tester.ensureVisible(find.byKey(const ValueKey('home-new-task')));
    await tester.tap(find.byKey(const ValueKey('home-new-task')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final page = tester.widget<PracticePage>(find.byType(PracticePage));
    expect(page.usePreparedStudySession, isTrue);
    expect(page.initialQuestions, isNull);
    expect(page.preparedSessionKind, AnswerAttemptSessionKind.normal);
    await pumpUntilFound(tester, find.text('synthetic ordinary stem'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmounted Home ignores pending reads', (tester) async {
    final pending = Completer<TodayContextSnapshot>();
    await tester.pumpWidget(MaterialApp(
        home: HomePage(
            taskManager: taskManager,
            todayContextQuery: _StubTodayContextQuery(() => pending.future))));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(const TodayContextSnapshot(bankName: 'late-bank'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no-plan action supplies Assistant context without sending',
      (tester) async {
    String? assistantContext;
    await pumpHome(tester, onAskAssistant: (value) => assistantContext = value);
    await tester
        .ensureVisible(find.byKey(const ValueKey('home-ask-assistant')));
    await tester.tap(find.byKey(const ValueKey('home-ask-assistant')));
    expect(assistantContext, contains('制定并预览学习计划'));
  });

  testWidgets(
      'bank detail remains a separate route and return refreshes summaries',
      (tester) async {
    final query = _StubTodayContextQuery(() async =>
        const TodayContextSnapshot(bankName: 'ordinary-bank', newCount: 1));
    final launcher = _OrdinaryLauncher();
    await pumpHome(tester,
        todayContextQuery: query, studySessionLauncher: launcher);
    final readsBefore = query.calls;
    final entry = find.byKey(const ValueKey('home-bank-detail'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
        tester.widget<BankDetailScreen>(find.byType(BankDetailScreen)).bankName,
        'ordinary-bank');
    expect(launcher.pools, isEmpty);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(query.calls, readsBefore + 1);
    expect(find.byKey(const ValueKey('home-new-task')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'current plan detail keeps start and stop reachable at large text',
      (tester) async {
    final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
            _focusedPlan(),
            ['id1'],
            const StudyPlanFocusedAdvisory(
                masteryReached: true, horizonElapsed: true)));
    await pumpHome(tester,
        textScale: 1.6,
        studyPlanSelectionService: service,
        studyPlanCommandService: _CommandHarness().service,
        studyPlanSessionLauncher: _FakeLauncher());
    await openFocusedMode(tester,
        waitFor: const ValueKey('today-focused-plan-card'));
    for (final key in ['today-focused-start', 'today-focused-stop']) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
          tester
              .getRect(find.byKey(ValueKey(key)))
              .overlaps(const Rect.fromLTWH(0, 56, 360, 664)),
          isTrue);
    }
  });

  testWidgets(
      'standalone exam entry retains creation menu and returns to the unified home',
      (tester) async {
    await pumpHome(tester);
    expect(find.byType(MockCenterScreen), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('home-exam-entry')));
    await tester.tap(find.byKey(const ValueKey('home-exam-entry')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await pumpUntilFound(tester, find.text('暂无试卷记录'));
    expect(
        tester.widget<MockCenterScreen>(find.byType(MockCenterScreen)).embedded,
        isFalse);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('AI 魔法组卷'), findsOneWidget);
    expect(find.text('经典随机抽卷'), findsOneWidget);
    Navigator.of(tester.element(find.text('组装新试卷'))).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-import-action')), findsOneWidget);
    expect(find.byType(MockCenterScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 720), const Size(1024, 768)]) {
    for (final dark in [false, true]) {
      testWidgets('responsive unified home $size dark=$dark at large text',
          (tester) async {
        await pumpHome(tester,
            size: size,
            textScale: 1.6,
            dark: dark,
            todayContextQuery: _StubTodayContextQuery(() async =>
                const TodayContextSnapshot(
                    bankName: '用于验证窄屏大字号的很长合成题库名称',
                    totalCount: 12345,
                    newCount: 6,
                    reviewCount: 12,
                    todayPracticeCount: 4)));
        for (final key in [
          'home-training-card',
          'home-view-plan',
          'home-learning-activity',
          'home-exam-entry'
        ]) {
          await tester.ensureVisible(find.byKey(ValueKey(key)));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        expect(find.text('已连续学习 4 天'), findsNothing);
        expect(find.textContaining('%'), findsNothing);
      });
    }
  }

  group('特训 focused plan surface (SPL-1-U0)', () {
    testWidgets('active ready plan shows the real compact summary',
        (tester) async {
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          _focusedPlan(),
          <String>['id1', 'id2'],
          const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: _CommandHarness().service,
        studyPlanSessionLauncher: _FakeLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      expect(find.text('Math 题库'), findsOneWidget);
      expect(find.text('掌握核心'), findsOneWidget);
      expect(find.text('30 题'), findsOneWidget);
      expect(find.text('到期优先'), findsOneWidget);
      expect(find.text('21 天'), findsOneWidget);
      expect(find.text('今日可特训：2 题'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-focused-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-focused-stop')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('today-focused-unavailable')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('noCandidates shows 今日暂无任务 and keeps Start/Stop',
        (tester) async {
      final launcher = _FakeLauncher();
      final service = _FakeSelectionService(
        state: StudyPlanFocusedNoCandidates(
          _focusedPlan(),
          const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: _CommandHarness().service,
        studyPlanSessionLauncher: launcher,
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      expect(find.text('今日暂无任务'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-focused-stop')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('today-focused-start')));
      await tester.pump();
      await tester.pump();
      expect(launcher.launchCalls, 0);
      expect(find.byType(PracticePage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('planUnavailable shows bounded state and disables Start',
        (tester) async {
      final launcher = _FakeLauncher();
      final service = _FakeSelectionService(
        state: StudyPlanFocusedPlanUnavailable(_focusedPlan()),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: _CommandHarness().service,
        studyPlanSessionLauncher: launcher,
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      expect(find.text('当前计划题库已不可用'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-focused-stop')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('today-focused-start')));
      await tester.pump();
      await tester.pump();
      expect(launcher.launchCalls, 0);
      expect(find.byType(PracticePage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('masteryReached and horizonElapsed are advisory only',
        (tester) async {
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          _focusedPlan(),
          <String>['id1'],
          const StudyPlanFocusedAdvisory(
            masteryReached: true,
            horizonElapsed: true,
          ),
        ),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: _CommandHarness().service,
        studyPlanSessionLauncher: _FakeLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      expect(find.text('已掌握全部题目'), findsOneWidget);
      expect(find.text('计划期已结束'), findsOneWidget);
      // Advisory never empties the queue: the workload is still shown.
      expect(find.text('今日可特训：1 题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Start recomputes selection fresh and opens PracticePage in normal '
        'review mode with the first selected question', (tester) async {
      await tester.runAsync(() async {
        final db = await DatabaseHelper.instance.database;
        await db.insert('questions', <String, Object?>{
          'id': 'start_q_1',
          'type': 0,
          'content': 'Start one stem.',
          'options': '["A1. one-a", "A2. one-b"]',
          'standard_answer': 'A1|||',
          'created_at': 0,
          'bank_name': 'Math 题库',
        });
        await db.insert('questions', <String, Object?>{
          'id': 'start_q_2',
          'type': 0,
          'content': 'Start two stem.',
          'options': '["B1. two-a", "B2. two-b"]',
          'standard_answer': 'B1|||',
          'created_at': 0,
          'bank_name': 'Math 题库',
        });
      });
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          _focusedPlan(),
          <String>['start_q_1', 'start_q_2'],
          const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: _CommandHarness().service,
        studyPlanSessionLauncher: StudyPlanPracticeSessionLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      final callsBeforeStart = service.loadCalls;
      await tester.tap(find.byKey(const ValueKey('today-focused-start')));
      await pumpUntilFound(tester, find.text('Start one stem.'));

      // Exactly one fresh selection run per user action.
      expect(service.loadCalls, callsBeforeStart + 1);
      expect(find.byType(PracticePage), findsOneWidget);
      expect(find.text('Start two stem.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('duplicate Start cannot open two sessions', (tester) async {
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          _focusedPlan(),
          <String>['id1'],
          const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      );
      final launcher = _FakeLauncher();
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: _CommandHarness().service,
        studyPlanSessionLauncher: launcher,
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      // The Start action now hangs until completed: a second tap must not
      // trigger another selection run or a second session.
      service.pending = Completer<StudyPlanFocusedState>();
      final callsBeforeStart = service.loadCalls;
      await tester.tap(find.byKey(const ValueKey('today-focused-start')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('today-focused-start')));
      await tester.pump();
      expect(service.loadCalls, callsBeforeStart + 1);

      service.pending!.complete(StudyPlanFocusedReady(
        _focusedPlan(),
        <String>['id1'],
        const StudyPlanFocusedAdvisory(
          masteryReached: false,
          horizonElapsed: false,
        ),
      ));
      await pumpUntilFound(tester, find.byType(PracticePage));

      expect(launcher.launchCalls, 1);
      expect(find.byType(PracticePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Stop opens confirmation; Cancel issues zero stop commands',
        (tester) async {
      final command = _CommandHarness();
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          _focusedPlan(),
          <String>['id1'],
          const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      await tester.tap(find.byKey(const ValueKey('today-focused-stop')));
      await tester.pump();
      expect(find.textContaining('只停止当前学习计划'), findsOneWidget);
      expect(find.textContaining('不会删除题目、作答记录或学习历史'), findsOneWidget);
      expect(find.textContaining('保留备份'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(command.stopPort.stopCalls, 0);
      expect(find.byType(PracticePage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Confirm stop binds the exact observed planId and reloads',
        (tester) async {
      final command = _CommandHarness();
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          _focusedPlan(),
          <String>['id1'],
          const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      // The plan is replaced before the confirmation resolves: the old
      // confirmation must stop nothing and the surface reloads.
      service.state = const StudyPlanFocusedNoActivePlan();
      await tester.tap(find.byKey(const ValueKey('today-focused-stop')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('today-focused-stop-confirm')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey('today-focused-unavailable')),
      );

      expect(command.stopPort.stopCalls, 1);
      expect(command.stopPort.lastExpectedPlanId, 'plan_1');
      expect(find.text('尚未采用学习计划'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stale stop: zero auto-retry, bounded message, state reloaded',
        (tester) async {
      final command = _CommandHarness()
        ..stopPort.nextStopResult =
            const StudyPlanPersistenceStopStaleActivePlan();
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          _focusedPlan(),
          <String>['id1'],
          const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      final callsBeforeStop = service.loadCalls;
      await tester.tap(find.byKey(const ValueKey('today-focused-stop')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('today-focused-stop-confirm')),
      );
      await tester.pump();
      await tester.pump();

      // Exactly one stop attempt; the state is reloaded once, never retried.
      expect(command.stopPort.stopCalls, 1);
      expect(service.loadCalls, greaterThan(callsBeforeStop));
      expect(find.text('学习计划已变化，请重试'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('today-focused-plan-card')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'refresh coordinator: Stop during an in-flight load still ends in '
        'live NoActivePlan; the old plan never reappears', (tester) async {
      final command = _CommandHarness();
      final advisory = const StudyPlanFocusedAdvisory(
        masteryReached: false,
        horizonElapsed: false,
      );
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(_focusedPlan(), <String>['id1'], advisory),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      // An old focused load starts and blocks (activation-style refresh).
      service.pending = Completer<StudyPlanFocusedState>();
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
        todayActivationEpoch: 1,
        waitFor: find.byKey(const ValueKey('today-focused-plan-card')),
      );
      await tester.pump();

      // Stop succeeds while the old load is still in flight; the post-stop
      // reload request must NOT be dropped.
      await tester.tap(find.byKey(const ValueKey('today-focused-stop')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('today-focused-stop-confirm')),
      );
      await tester.pump();
      expect(command.stopPort.stopCalls, 1);

      // The old load completes with the old ActivePlan, then the follow-up
      // live load returns NoActivePlan (plan was stopped).
      service.state = const StudyPlanFocusedNoActivePlan();
      service.pending!.complete(
        StudyPlanFocusedReady(_focusedPlan(), <String>['id1'], advisory),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey('today-focused-unavailable')),
      );

      // Final UI MUST show NoActivePlan; the old plan must not reappear.
      expect(find.text('尚未采用学习计划'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('today-focused-plan-card')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'refresh coordinator: a required follow-up starts without frame '
        'production and ends in the latest live state', (tester) async {
      final command = _CommandHarness();
      final advisory = const StudyPlanFocusedAdvisory(
        masteryReached: false,
        horizonElapsed: false,
      );
      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(_focusedPlan(), <String>['id1'], advisory),
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );

      // A required refresh arrives and blocks (activation-style refresh).
      service.pending = Completer<StudyPlanFocusedState>();
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
        todayActivationEpoch: 1,
        waitFor: find.byKey(const ValueKey('today-focused-plan-card')),
      );
      await tester.pump();

      // A second required refresh arrives while the first load is in flight:
      // the coordinator must coalesce it into a follow-up (no extra service
      // call yet) and invalidate the in-flight generation.
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: _FakeLauncher(),
        todayActivationEpoch: 2,
        waitFor: find.byKey(const ValueKey('today-focused-plan-card')),
      );
      await tester.pump();

      // The stale generation completes; the latest live state is NoActivePlan.
      final callsBeforeStaleCompletion = service.loadCalls;
      service.state = const StudyPlanFocusedNoActivePlan();
      service.pending!.complete(
        StudyPlanFocusedReady(_focusedPlan(), <String>['id1'], advisory),
      );

      // Drain microtasks WITHOUT producing a frame: the coordinator itself
      // (microtask scheduling, not a frame callback) must already have
      // initiated the follow-up selection service call.
      await tester.idle();
      expect(service.loadCalls, callsBeforeStaleCompletion + 1);

      // Pump only to observe the already-started asynchronous work's result.
      await tester.pump();
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey('today-focused-unavailable')),
      );
      expect(find.text('尚未采用学习计划'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('today-focused-plan-card')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Today reactivation refresh A: NoActivePlan -> adopted plan appears '
        'without toggling modes', (tester) async {
      final advisory = const StudyPlanFocusedAdvisory(
        masteryReached: false,
        horizonElapsed: false,
      );
      final service = _FakeSelectionService(
        state: const StudyPlanFocusedNoActivePlan(),
      );
      final command = _CommandHarness();
      final launcher = _FakeLauncher();
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: launcher,
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-unavailable'),
      );
      expect(find.text('尚未采用学习计划'), findsOneWidget);

      // Leave Today (plan adopted elsewhere), then return to Today: the
      // activation epoch changes and the focused surface refreshes live.
      service.state = StudyPlanFocusedReady(
        _focusedPlan(),
        <String>['id1'],
        advisory,
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: launcher,
        todayActivationEpoch: 1,
        waitFor: find.byKey(const ValueKey('today-focused-plan-card')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey('today-focused-plan-card')),
      );

      expect(find.text('Math 题库'), findsOneWidget);
      expect(find.text('尚未采用学习计划'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Today reactivation refresh B: replaced plan appears after returning '
        'to Today', (tester) async {
      final advisory = const StudyPlanFocusedAdvisory(
        masteryReached: false,
        horizonElapsed: false,
      );
      ActiveStudyPlan planWithBank(String planId, String bankName) {
        return ActiveStudyPlan(
          planId: planId,
          bankName: bankName,
          dailyTarget: 30,
          priority: StudyPlanPriority.balanced,
          adoptedAt: DateTime.utc(2026, 8, 1, 10, 0),
        );
      }

      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          planWithBank('plan_a', 'Bank A'),
          <String>['id1'],
          advisory,
        ),
      );
      final command = _CommandHarness();
      final launcher = _FakeLauncher();
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: launcher,
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );
      expect(find.text('Bank A'), findsOneWidget);

      // The plan is replaced while away; returning to Today must show the
      // live plan, never the stale one.
      service.state = StudyPlanFocusedReady(
        planWithBank('plan_b', 'Bank B'),
        <String>['id2'],
        advisory,
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: launcher,
        todayActivationEpoch: 1,
        waitFor: find.text('Bank B'),
      );

      expect(find.text('Bank B'), findsOneWidget);
      expect(find.text('Bank A'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Today reactivation refresh C: activation refresh during an existing '
        'load still ends in the latest live state', (tester) async {
      final advisory = const StudyPlanFocusedAdvisory(
        masteryReached: false,
        horizonElapsed: false,
      );
      ActiveStudyPlan planWithBank(String planId, String bankName) {
        return ActiveStudyPlan(
          planId: planId,
          bankName: bankName,
          dailyTarget: 30,
          priority: StudyPlanPriority.balanced,
          adoptedAt: DateTime.utc(2026, 8, 1, 10, 0),
        );
      }

      final service = _FakeSelectionService(
        state: StudyPlanFocusedReady(
          planWithBank('plan_a', 'Bank A'),
          <String>['id1'],
          advisory,
        ),
      );
      final command = _CommandHarness();
      final launcher = _FakeLauncher();
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: launcher,
      );
      await openFocusedMode(
        tester,
        waitFor: const ValueKey('today-focused-plan-card'),
      );
      expect(find.text('Bank A'), findsOneWidget);

      // First reactivation refresh starts and blocks.
      service.pending = Completer<StudyPlanFocusedState>();
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: launcher,
        todayActivationEpoch: 1,
        waitFor: find.byKey(const ValueKey('today-focused-plan-card')),
      );
      await tester.pump();

      // A second reactivation refresh arrives while the first is in flight,
      // and the live state is now plan B.
      service.state = StudyPlanFocusedReady(
        planWithBank('plan_b', 'Bank B'),
        <String>['id2'],
        advisory,
      );
      await pumpHome(
        tester,
        studyPlanSelectionService: service,
        studyPlanCommandService: command.service,
        studyPlanSessionLauncher: launcher,
        todayActivationEpoch: 2,
        waitFor: find.byKey(const ValueKey('today-focused-plan-card')),
      );
      await tester.pump();

      // The stale in-flight load completes with plan A; the follow-up must
      // publish the latest live state (plan B), never plan A.
      service.pending!.complete(
        StudyPlanFocusedReady(
          planWithBank('plan_a', 'Bank A'),
          <String>['id1'],
          advisory,
        ),
      );
      await pumpUntilFound(tester, find.text('Bank B'));

      expect(find.text('Bank B'), findsOneWidget);
      expect(find.text('Bank A'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    group('UX-IMPORT global manual import entry', () {
      testWidgets(
          'Today AppBar has parse and + import actions with frozen order',
          (tester) async {
        await pumpHome(tester);

        expect(
          find.byKey(const ValueKey<String>('home-parse-action')),
          findsOneWidget,
        );
        expect(find.text('解析'), findsOneWidget);
        final actionFinder =
            find.byKey(const ValueKey<String>('home-import-action'));
        expect(actionFinder, findsOneWidget);
        expect(
            find.descendant(
                of: actionFinder, matching: find.byIcon(Icons.add_rounded)),
            findsOneWidget);

        final iconButton = tester.widget<IconButton>(actionFinder);
        expect(iconButton.tooltip, '创建 / 导入');
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'file option invokes the existing onImportRequested callback seam',
          (tester) async {
        var importCalls = 0;
        await pumpHome(
          tester,
          onImportRequested: () => importCalls++,
        );

        final actionFinder =
            find.byKey(const ValueKey<String>('home-import-action'));
        await tester.ensureVisible(actionFinder);
        await tester.tap(actionFinder);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        expect(find.text('创建 / 导入'), findsOneWidget);
        expect(find.text('文件导入'), findsOneWidget);
        expect(find.text('拍照识题'), findsOneWidget);
        expect(find.textContaining('OCR'), findsNothing);
        expect(importCalls, 0);

        await tester.tap(
          find.byKey(const ValueKey<String>('create-import-file-option')),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        expect(importCalls, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'file option without callback pushes the existing import screen',
          (tester) async {
        await pumpHome(tester);

        final actionFinder =
            find.byKey(const ValueKey<String>('home-import-action'));
        await tester.ensureVisible(actionFinder);
        await tester.tap(actionFinder);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        await tester.tap(
          find.byKey(const ValueKey<String>('create-import-file-option')),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        expect(find.byType(ImportSettingsScreen), findsOneWidget);
        expect(find.text('导入题目'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('import-camera-button')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('import-gallery-button')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('photo option invokes the dedicated capture callback seam',
          (tester) async {
        var photoCalls = 0;
        await pumpHome(
          tester,
          onPhotoImportRequested: () => photoCalls++,
        );

        await tester.ensureVisible(
            find.byKey(const ValueKey<String>('home-import-action')));
        await tester.tap(
          find.byKey(const ValueKey<String>('home-import-action')),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(photoCalls, 0);

        await tester.tap(
          find.byKey(const ValueKey<String>('create-import-photo-option')),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        expect(photoCalls, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'current-plan detail returns to the same import and parse entries',
          (tester) async {
        await pumpHome(tester);
        await openFocusedMode(tester,
            waitFor: const ValueKey('today-focused-unavailable'));
        expect(find.byType(CurrentPlanScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(
            find.byKey(const ValueKey('home-import-action')), findsOneWidget);
        expect(find.byKey(const ValueKey('home-parse-action')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });
}
