import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_selection_service.dart';
import 'package:shiroha_quiz/application/today/today_context_query.dart';
import 'package:shiroha_quiz/ui/home/today_controller.dart';

void main() {
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
    route.complete();
    await first;
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
