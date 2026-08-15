import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
        theme: AppTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: HomePage(
            taskManager: taskManager,
            onSwitchBank: onSwitchBank,
            onPracticeRequested: onPracticeRequested,
            onImportRequested: onImportRequested,
            studyPlanSelectionService: studyPlanSelectionService,
            studyPlanCommandService: studyPlanCommandService,
            studyPlanSessionLauncher: studyPlanSessionLauncher,
            todayActivationEpoch: todayActivationEpoch,
          ),
        ),
      ),
    );
    // The default wait targets the ordinary-mode bank card, which is only
    // onstage while Today is in 普通 mode; re-pump scenarios pass an explicit
    // onstage target (e.g. the focused plan surface) instead.
    await pumpUntilFound(
      tester,
      waitFor ?? find.byKey(const ValueKey<String>('home-bank-card')),
    );
  }

  Future<void> openFocusedMode(
    WidgetTester tester, {
    Key? waitFor,
  }) async {
    await tester.tap(find.byKey(const ValueKey('today-mode-focused')));
    await tester.pump();
    if (waitFor != null) {
      await pumpUntilFound(tester, find.byKey(waitFor));
    }
  }

  testWidgets('empty home follows the compact today dashboard contract',
      (tester) async {
    await pumpHome(tester, textScale: 1.3);

    expect(find.byKey(const ValueKey('home-brand-title')), findsOneWidget);
    expect(find.byIcon(Icons.swap_vert_rounded), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(find.text('请选择题库'), findsOneWidget);
    expect(find.text('今日训练'), findsOneWidget);
    expect(find.text('开始今日训练'), findsOneWidget);
    expect(find.text('新题挑战'), findsOneWidget);
    expect(find.text('0 道新题'), findsOneWidget);
    expect(find.text('复习巩固'), findsOneWidget);
    expect(find.text('0 道待复习'), findsOneWidget);
    expect(find.text('暂无待复习题目'), findsOneWidget);
    expect(
      find.text('完成新题或产生错题后，将自动生成复习任务'),
      findsOneWidget,
    );

    expect(find.text('今日新学'), findsNothing);
    expect(find.text('今日复习'), findsNothing);
    expect(find.textContaining('个知识点'), findsNothing);
    expect(find.textContaining('个待复习'), findsNothing);
    expect(find.text('暂无复习数据'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real counts and existing home actions remain available',
      (tester) async {
    const bankName = '用于验证很长题库名称在窄窗口中不会溢出的合成题库';
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('questions', {
        'id': 'home-new',
        'type': 0,
        'content': 'synthetic-new',
        'standard_answer': 'A',
        'created_at': 0,
        'bank_name': bankName,
      });
      await db.insert('questions', {
        'id': 'home-review',
        'type': 0,
        'content': 'synthetic-review',
        'standard_answer': 'B',
        'created_at': 0,
        'bank_name': bankName,
      });
      await db.insert('review_states', {
        'question_id': 'home-new',
        'state': 0,
      });
      await db.insert('review_states', {
        'question_id': 'home-review',
        'state': 2,
        'next_review_time': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
      });
      await SettingsRepository.instance.setCurrentBank(bankName);
    });

    var switchCount = 0;
    var practiceCount = 0;
    await pumpHome(
      tester,
      onSwitchBank: () => switchCount++,
      onPracticeRequested: () => practiceCount++,
    );

    expect(find.text(bankName), findsOneWidget);
    expect(find.text('1 道新题'), findsOneWidget);
    expect(find.text('1 道待复习'), findsOneWidget);
    expect(find.text('已掌握 0 / 2'), findsOneWidget);
    expect(find.text('暂无待复习题目'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('home-switch-bank')));
    await tester.pump();
    expect(switchCount, 1);

    for (final key in const [
      'home-start-training',
      'home-new-task',
      'home-review-task',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
    }
    expect(practiceCount, 3);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Today modes: 普通 default, 特训 dependency-not-ready, 考试 exam '
      'surface reachable, and 普通 state survives switching', (tester) async {
    const bankName = '合成题库用于模式切换';
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('questions', {
        'id': 'today-mode-q',
        'type': 0,
        'content': 'synthetic',
        'standard_answer': 'A',
        'created_at': 0,
        'bank_name': bankName,
      });
      await db.insert('review_states', {
        'question_id': 'today-mode-q',
        'state': 0,
      });
      await SettingsRepository.instance.setCurrentBank(bankName);
    });

    await pumpHome(tester);

    // Selector exposes all three final Today modes; default is 普通.
    expect(find.byKey(const ValueKey('today-mode-ordinary')), findsOneWidget);
    expect(find.byKey(const ValueKey('today-mode-focused')), findsOneWidget);
    expect(find.byKey(const ValueKey('today-mode-exam')), findsOneWidget);
    expect(find.text(bankName), findsOneWidget);
    expect(find.text('开始今日训练'), findsOneWidget);

    // 特训 without an adopted plan: genuine no-plan state; no plan, counts,
    // or recommendations are fabricated.
    await tester.tap(find.byKey(const ValueKey('today-mode-focused')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('today-focused-unavailable')),
      findsOneWidget,
    );
    expect(find.text('特训需要学习计划'), findsOneWidget);
    expect(
      find.text('尚未采用学习计划。\n请先在助手中制定并采用学习计划。'),
      findsOneWidget,
    );
    expect(find.text('开始特训'), findsNothing);

    // Switch back to 普通: the previously loaded bank state remains (mode
    // switching must not recreate or reset unrelated mode state).
    await tester.tap(find.byKey(const ValueKey('today-mode-ordinary')));
    await tester.pump();
    expect(find.text(bankName), findsOneWidget);
    expect(find.text('1 道新题'), findsOneWidget);
    expect(find.text('开始今日训练'), findsOneWidget);

    // 考试: the existing Mock/Exam capability is reachable from Today.
    await tester.tap(find.byKey(const ValueKey('today-mode-exam')));
    await tester.pump();
    expect(find.byKey(const ValueKey('today-exam-surface')), findsOneWidget);
    await pumpUntilFound(tester, find.text('暂无试卷记录'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'embedded exam mode keeps the create-exam FAB and bottom sheet menu',
      (tester) async {
    await pumpHome(tester);

    // Switch to 考试 and wait until the embedded Mock center is loaded.
    await tester.tap(find.byKey(const ValueKey('today-mode-exam')));
    await tester.pump();
    expect(find.byKey(const ValueKey('today-exam-surface')), findsOneWidget);
    await pumpUntilFound(tester, find.text('暂无试卷记录'));

    // The embedded surface must keep the existing create-exam entry.
    final fab = find.byType(FloatingActionButton);
    expect(fab, findsOneWidget,
        reason: 'embedded exam mode must not lose the create-exam FAB');
    await tester.tap(fab);
    await pumpUntilFound(tester, find.text('组装新试卷'));
    expect(find.text('组装新试卷'), findsOneWidget);
    expect(find.text('AI 魔法组卷'), findsOneWidget);
    expect(find.text('经典随机抽卷'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'wide viewport 1024x768: Today selector does not overflow and every '
      'mode is reachable', (tester) async {
    await pumpHome(tester, size: const Size(1024, 768));

    expect(find.byKey(const ValueKey('today-mode-ordinary')), findsOneWidget);
    expect(find.byKey(const ValueKey('today-mode-focused')), findsOneWidget);
    expect(find.byKey(const ValueKey('today-mode-exam')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('today-mode-focused')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('today-focused-unavailable')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('today-mode-exam')));
    await tester.pump();
    expect(find.byKey(const ValueKey('today-exam-surface')), findsOneWidget);
    await pumpUntilFound(tester, find.text('暂无试卷记录'));

    await tester.tap(find.byKey(const ValueKey('today-mode-ordinary')));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-training-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.text('确定停止当前学习计划？'), findsOneWidget);

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
      expect(find.text('特训需要学习计划'), findsOneWidget);
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
      expect(find.text('特训需要学习计划'), findsOneWidget);
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
      expect(find.text('特训需要学习计划'), findsOneWidget);
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
      expect(find.text('特训需要学习计划'), findsOneWidget);

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
      expect(find.text('特训需要学习计划'), findsNothing);
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
          'Today AppBar has + import action with correct tooltip and key',
          (tester) async {
        await pumpHome(tester);

        final actionFinder =
            find.byKey(const ValueKey<String>('home-import-action'));
        expect(actionFinder, findsOneWidget);
        expect(find.byIcon(Icons.add_rounded), findsOneWidget);

        final iconButton = tester.widget<IconButton>(actionFinder);
        expect(iconButton.tooltip, '导入题库');
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'tapping + import action invokes onImportRequested callback seam',
          (tester) async {
        var importCalls = 0;
        await pumpHome(
          tester,
          onImportRequested: () => importCalls++,
        );

        final actionFinder =
            find.byKey(const ValueKey<String>('home-import-action'));
        await tester.tap(actionFinder);
        await tester.pump();

        expect(importCalls, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'tapping + import action without callback pushes ImportSettingsScreen',
          (tester) async {
        await pumpHome(tester);

        final actionFinder =
            find.byKey(const ValueKey<String>('home-import-action'));
        await tester.tap(actionFinder);
        await tester.pumpAndSettle();

        expect(find.byType(ImportSettingsScreen), findsOneWidget);
        expect(find.text('导入题目'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'import action is present across all Today modes without breaking modes',
          (tester) async {
        await pumpHome(tester);

        // Ordinary mode
        expect(
          find.byKey(const ValueKey<String>('home-import-action')),
          findsOneWidget,
        );

        // Focused mode
        await tester.tap(find.byKey(const ValueKey('today-mode-focused')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('home-import-action')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('today-mode-ordinary')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('today-mode-focused')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('today-mode-exam')),
          findsOneWidget,
        );

        // Exam mode
        await tester.tap(find.byKey(const ValueKey('today-mode-exam')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('home-import-action')),
          findsOneWidget,
        );
        expect(
            find.byKey(const ValueKey('today-exam-surface')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });
}
