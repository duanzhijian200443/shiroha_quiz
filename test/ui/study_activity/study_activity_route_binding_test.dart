import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import 'package:shiroha_quiz/ui/study_activity/study_activity_route_binding.dart';
import '../../support/study_activity_runtime_fakes.dart';

void main() {
  StudyActivityRouteBinding binding(RecordingActivity service) =>
      StudyActivityRouteBinding(
          service: service,
          descriptor: const StudyActivityRouteDescriptor(
              scene: StudyActivityScene.ordinaryPractice,
              context: StudyActivityContext()));

  testWidgets('30s checkpoint bounded while pending; terminal/dispose cancel',
      (tester) async {
    final service = RecordingActivity();
    final route = binding(service);
    await route.begin();
    service.checkpointHold = Completer();
    await tester.pump(const Duration(seconds: 30));
    await tester.pump(const Duration(minutes: 5));
    expect(service.events.where((e) => e == 'checkpoint'), hasLength(1));
    route.end(StudyActivityEndReason.queueFinished);
    expect(service.ends, hasLength(1));
    route.dispose();
    service.checkpointHold!.complete(HomeTrainingSuccess(service.snapshot()));
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(service.ends.single.reason, StudyActivityEndReason.queueFinished);
    expect(service.events.where((e) => e == 'checkpoint'), hasLength(1));
  });

  testWidgets('background and nested cover keep same owner; no early resume',
      (tester) async {
    final service = RecordingActivity();
    final route = binding(service);
    await route.begin();
    final cover = Completer<void>();
    final covering = route.duringTemporaryCover(() => cover.future);
    await tester.pump();
    route.didChangeAppLifecycleState(AppLifecycleState.inactive);
    route.didChangeAppLifecycleState(AppLifecycleState.paused);
    cover.complete();
    await covering;
    await tester.pump();
    expect(service.events, ['pause']);
    route.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.events, ['pause', 'resume']);
    expect(service.owners.map((o) => o.ownerToken).toSet(), hasLength(1));
    expect(service.ends, isEmpty);
    route.dispose();
    await tester.pump();
    expect(service.ends.single.reason, StudyActivityEndReason.exited);
  });

  testWidgets('pending begin is released once after owner disposal',
      (tester) async {
    final service = RecordingActivity()..beginHold = Completer();
    final route = binding(service);
    unawaited(route.begin());
    route.dispose();
    route.end(StudyActivityEndReason.queueFinished);
    service.beginHold!.complete(HomeTrainingSuccess(StudyActivityOwner(
        sessionId: 'session', ownerToken: service.begins.single.ownerToken)));
    await tester.pump();
    expect(service.ends.single.reason, StudyActivityEndReason.exited);
    await tester.pump(const Duration(minutes: 1));
    expect(service.events, ['end']);
  });

  for (final failure in ['checkpoint', 'pause', 'end']) {
    testWidgets('$failure failure stops scheduling but still releases owner',
        (tester) async {
      final service = RecordingActivity()..failures.add(failure);
      final route = binding(service);
      await route.begin();
      if (failure == 'pause') {
        route.didChangeAppLifecycleState(AppLifecycleState.paused);
      }
      await tester.pump(const Duration(seconds: 30));
      route.dispose();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      expect(service.ends, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }
}
