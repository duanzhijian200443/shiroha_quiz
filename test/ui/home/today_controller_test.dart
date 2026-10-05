import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_selection_service.dart';
import 'package:shiroha_quiz/application/today/today_context_query.dart';
import 'package:shiroha_quiz/ui/home/today_controller.dart';
import '../../support/home_training_fakes.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/today_training_contracts.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';

void main() {
  test(
      'V2 late read is invalidated before Category mutation; stale has zero retry',
      () async {
    final fake = HomeTrainingFake();
    final subject = TodayController(
        training: fake.ports,
        activityQuery: fake,
        loadFocusedState: () async => const StudyPlanFocusedNoActivePlan());
    addTearDown(subject.dispose);
    final old = fake.snapshot;
    fake.readGate = Completer<HomeTrainingResult<TodayTrainingSnapshot>>();
    final pending = subject.loadTraining();
    final gate = fake.readGate!;
    fake.readGate = null;
    await subject.selectCategory(homeB);
    gate.complete(HomeTrainingSuccess(old));
    await pending;
    expect(
        (subject.trainingResult as HomeTrainingSuccess<TodayTrainingSnapshot>)
            .value
            .selection
            .categoryKey,
        homeB);
    expect(fake.selections.single.contentId,
        isNull); // Preserve persisted absence, not fallback.
    fake.selectionFailure = HomeTrainingFailure.stale;
    expect(await subject.selectCategory(homeA), HomeTrainingFailure.stale);
    expect(fake.selections, hasLength(2));
    expect(
        (subject.trainingResult as HomeTrainingSuccess<TodayTrainingSnapshot>)
            .value
            .selection
            .categoryKey,
        homeB);
  });

  test(
      'V2 corner cycles ordered usable contents and ignores overlapping mutations',
      () async {
    final fake = HomeTrainingFake();
    final subject = TodayController(
        training: fake.ports,
        loadFocusedState: () async => const StudyPlanFocusedNoActivePlan());
    addTearDown(subject.dispose);
    await subject.loadTraining();
    final first = fake.snapshot.selection.currentContent!.content.contentId;
    final ordered =
        fake.groups.first.contents.map((v) => v.content.contentId).toList();
    fake.selectionGate = Completer<void>();
    final move = subject.cycleContent();
    await Future<void>.delayed(Duration.zero);
    await subject.cycleContent();
    expect(fake.selections, hasLength(1));
    fake.selectionGate!.complete();
    await move;
    fake.selectionGate = null;
    expect(
        fake.snapshot.selection.currentContent!.content.contentId, ordered[1]);
    await subject.cycleContent();
    expect(
        fake.snapshot.selection.currentContent!.content.contentId, ordered[2]);
    await subject.cycleContent();
    expect(fake.snapshot.selection.currentContent!.content.contentId, first);
    fake.groups[0] = TrainingCategorySnapshot(
        categoryKey: homeA,
        preference: fake.groups.first.preference,
        contents: [
          fake.groups.first.contents[0],
          TrainingContentView(
              content: fake.groups.first.contents[1].content, usable: false),
          fake.groups.first.contents[2]
        ]);
    await subject.loadTraining();
    await subject.cycleContent();
    expect(
        fake.snapshot.selection.currentContent!.content.contentId, ordered[2]);
  });

  test(
      'V2 week failure stays independent and dispose suppresses late publication',
      () async {
    final fake = HomeTrainingFake()..weekFailed = true;
    final subject = TodayController(
        training: fake.ports,
        activityQuery: fake,
        loadFocusedState: () async => const StudyPlanFocusedNoActivePlan());
    await Future.wait([subject.loadTraining(), subject.loadWeek()]);
    expect(subject.trainingResult,
        isA<HomeTrainingSuccess<TodayTrainingSnapshot>>());
    expect(subject.weekResult, isA<HomeTrainingFailed>());
    fake.readGate = Completer<HomeTrainingResult<TodayTrainingSnapshot>>();
    final pending = subject.loadTraining();
    var notified = 0;
    subject.addListener(() => notified++);
    subject.dispose();
    fake.readGate!.complete(HomeTrainingSuccess(fake.snapshot));
    await pending;
    expect(notified, 0);
  });
  TodayController controller({
    Future<TodayContextSnapshot> Function()? context,
    Future<StudyPlanFocusedState> Function()? focused,
  }) =>
      TodayController(
        loadContext: context ?? () async => const TodayContextSnapshot(),
        loadFocusedState:
            focused ?? () async => const StudyPlanFocusedNoActivePlan(),
      );

  test('ordinary read failure retains last snapshot and is not a successful 0',
      () async {
    var failed = false;
    final subject = controller(context: () async {
      if (failed) throw const TodayContextUnavailable();
      return const TodayContextSnapshot(bankName: 'ordinary', newCount: 7);
    });
    addTearDown(subject.dispose);
    await subject.loadContext();
    expect(subject.contextSnapshot.bankName, 'ordinary');
    expect(subject.contextSnapshot.newCount, 7);
    expect(subject.contextLoading, isFalse);
    expect(subject.contextUnavailable, isFalse);
    failed = true;
    await subject.loadContext();
    expect(subject.contextSnapshot.newCount, 7);
    expect(subject.contextUnavailable, isTrue);
    expect(subject.contextLoading, isFalse);
  });

  test('ordinary stale completion cannot overwrite the newer bank or loading',
      () async {
    final older = Completer<TodayContextSnapshot>();
    final newer = Completer<TodayContextSnapshot>();
    var calls = 0;
    final subject =
        controller(context: () => ++calls == 1 ? older.future : newer.future);
    addTearDown(subject.dispose);
    final oldLoad = subject.loadContext();
    final newLoad = subject.loadContext();
    older.complete(const TodayContextSnapshot(bankName: 'old', newCount: 99));
    await oldLoad;
    expect(subject.contextLoading, isTrue);
    expect(subject.contextSnapshot.bankName, isNull);
    newer.complete(const TodayContextSnapshot(bankName: 'new', newCount: 3));
    await newLoad;
    expect(subject.contextLoading, isFalse);
    expect(subject.contextSnapshot.bankName, 'new');
    expect(subject.contextSnapshot.newCount, 3);
  });

  test('focused requests queue one fresh read and reject stale publication',
      () async {
    final stale = Completer<StudyPlanFocusedState>();
    final fresh = Completer<StudyPlanFocusedState>();
    final freshStarted = Completer<void>();
    var calls = 0;
    final subject = controller(focused: () {
      if (++calls == 1) return stale.future;
      freshStarted.complete();
      return fresh.future;
    });
    addTearDown(subject.dispose);
    var notifications = 0;
    subject.addListener(() => notifications++);
    final first = subject.loadFocusedState();
    await subject.loadFocusedState();
    await subject.loadFocusedState();
    expect(calls, 1);
    stale.complete(const StudyPlanFocusedFailure(
        StudyPlanFocusedFailureKind.temporarilyUnavailable));
    await first;
    await freshStarted.future;
    expect(calls, 2);
    expect(subject.focusedState, isNull);
    expect(notifications, 0);
    final updated = Completer<void>();
    subject.addListener(() => updated.complete());
    fresh.complete(const StudyPlanFocusedNoActivePlan());
    await updated.future;
    expect(subject.focusedState, isA<StudyPlanFocusedNoActivePlan>());
    expect(notifications, 1);
  });

  test('focused read exception becomes the existing bounded failure state',
      () async {
    final subject =
        controller(focused: () async => throw StateError('private'));
    addTearDown(subject.dispose);
    await subject.loadFocusedState();
    final state = subject.focusedState as StudyPlanFocusedFailure;
    expect(state.kind, StudyPlanFocusedFailureKind.internalError);
  });

  test('dispose suppresses both read publications and queued focused work',
      () async {
    final context = Completer<TodayContextSnapshot>();
    final focused = Completer<StudyPlanFocusedState>();
    var focusedCalls = 0;
    final subject = controller(
      context: () => context.future,
      focused: () {
        focusedCalls++;
        return focused.future;
      },
    );
    var notifications = 0;
    subject.addListener(() => notifications++);
    final contextLoad = subject.loadContext();
    final focusedLoad = subject.loadFocusedState();
    await subject.loadFocusedState();
    final beforeDispose = notifications;
    subject.dispose();
    context.complete(const TodayContextSnapshot(bankName: 'late'));
    focused.complete(const StudyPlanFocusedNoActivePlan());
    await Future.wait([contextLoad, focusedLoad]);
    await Future<void>.value();
    expect(notifications, beforeDispose);
    expect(subject.contextSnapshot.bankName, isNull);
    expect(subject.focusedState, isNull);
    expect(focusedCalls, 1);
  });

  test('start guard spans route lifetime and permits next start after return',
      () async {
    final route = Completer<void>();
    final subject = controller();
    addTearDown(subject.dispose);
    var starts = 0;
    final first = subject.runFocusedStart(() {
      starts++;
      return route.future;
    });
    await subject.runFocusedStart(() async => starts++);
    expect(starts, 1);
    expect(subject.practiceStartPending, isTrue);
    route.complete();
    await first;
    expect(subject.practiceStartPending, isFalse);
    await subject.runFocusedStart(() async => starts++);
    expect(starts, 2);
  });

  test('failed start releases guard; disposed controller cannot start',
      () async {
    final subject = controller();
    await expectLater(
      subject.runFocusedStart(() async => throw StateError('prepare failed')),
      throwsStateError,
    );
    var starts = 0;
    await subject.runFocusedStart(() async => starts++);
    expect(starts, 1);
    subject.dispose();
    await subject.runFocusedStart(() async => starts++);
    expect(starts, 1);
  });
}
