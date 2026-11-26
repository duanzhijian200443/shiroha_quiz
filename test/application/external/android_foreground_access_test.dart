import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import '../../composition/android_device_app_test.dart' as app_policy;

AndroidForegroundObservation observation(int sequence,
        {bool focus = true,
        bool resumed = true,
        bool visible = true,
        bool interactive = true,
        bool unlocked = true,
        bool backgroundRead = false,
        String? network = 'network-1'}) =>
    AndroidForegroundObservation(
        sequence: sequence,
        resumed: resumed,
        focused: focus,
        interactive: interactive,
        unlocked: unlocked,
        visible: visible,
        backgroundRead: backgroundRead,
        network: network);

final class Resources implements AndroidAccessResources {
  int withdrawals = 0, closes = 0;
  Completer<void>? barrier;
  bool fail = false;
  @override
  void withdraw() {
    withdrawals++;
  }

  @override
  Future<void> close() async {
    closes++;
    await barrier?.future;
    if (fail) throw StateError('synthetic');
  }
}

final class Preparation implements AndroidAccessPreparation {
  final acquired = Completer<AndroidAccessResources>();
  final drained = Completer<void>();
  bool cancelled = false;
  bool failCancellation = false;
  @override
  Future<AndroidAccessResources> get result => acquired.future;
  @override
  Future<void> get settled => drained.future;
  @override
  void cancel() {
    cancelled = true;
    if (failCancellation) throw StateError('synthetic cancellation failure');
  }

  void complete(Resources resources) {
    acquired.complete(resources);
    drained.complete();
  }
}

void main() {
  group('Android App policy ownership', app_policy.main);
  late Duration now;
  late AndroidForegroundAccess access;
  setUp(() {
    now = Duration.zero;
    access = AndroidForegroundAccess(elapsed: () => now);
  });

  Future<Resources> enable() async {
    access.observe(observation(1));
    final p = Preparation(), r = Resources();
    final work = access.enable((_) => p);
    p.complete(r);
    await work;
    return r;
  }

  for (final event in [
    observation(1, focus: false),
    observation(1, resumed: false),
    observation(1, visible: false),
  ]) {
    test(
        'OFF rejects incomplete foreground ${event.focused}/${event.resumed}/${event.visible}',
        () async {
      expect(access.acceptsNew, isFalse);
      access.observe(event);
      var acquisitions = 0;
      final p = Preparation()..complete(Resources());
      try {
        await expectLater(access.enable((_) {
          acquisitions++;
          return p;
        }), throwsStateError);
        expect(acquisitions, 0);
        expect(access.phase, AndroidAccessPhase.off);
        expect(access.acceptsNew, isFalse);
      } finally {
        await access.disable();
      }
    });
  }

  for (final acquiredBeforeHiding in [false, true]) {
    test(
        'hidden while resumed cannot revive pending enable (acquired=$acquiredBeforeHiding)',
        () async {
      access.observe(observation(1));
      final p = Preparation(), r = Resources()..barrier = Completer<void>();
      final enabling = access.enable((_) => p);
      if (acquiredBeforeHiding) {
        p.acquired.complete(r);
        await Future<void>.delayed(Duration.zero);
      }
      access.observe(observation(2, visible: false));
      try {
        expect(p.cancelled, isTrue);
        expect(access.phase, AndroidAccessPhase.draining);
        expect(access.acceptsNew, isFalse);
        access.observe(observation(3));
        if (!acquiredBeforeHiding) p.acquired.complete(r);
        p.drained.complete();
        await Future<void>.delayed(Duration.zero);
        expect(r.withdrawals, greaterThan(0));
        expect(r.closes, 1);
        expect(access.phase, AndroidAccessPhase.draining);
        expect(access.acceptsNew, isFalse);
      } finally {
        if (!p.acquired.isCompleted) p.acquired.complete(r);
        if (!p.drained.isCompleted) p.drained.complete();
        r.barrier!.complete();
        await Future.wait([enabling, access.disable()]);
      }
      expect(access.phase, AndroidAccessPhase.off);
      expect(access.acceptsNew, isFalse);
      expect(r.closes, 1);
    });
  }

  test('cancel before acquisition owns late resources until original drain',
      () async {
    access.observe(observation(1));
    final p = Preparation(), r = Resources()..barrier = Completer<void>();
    final enabling = access.enable((_) => p);
    var closed = false;
    final closing = access.cancelPending().then((_) => closed = true);
    expect(p.cancelled, isTrue);
    expect(access.acceptsNew, isFalse);
    p.complete(r);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    r.barrier!.complete();
    await Future.wait([enabling, closing]);
    expect(r.closes, 1);
    expect(access.phase, AndroidAccessPhase.off);
  });

  test('navigation after READY leaves access enabled', () async {
    final r = await enable();
    await access.cancelPending();
    expect(access.acceptsNew, isTrue);
    expect(r.closes, 0);
    await access.disable();
  });

  test('synchronous cancellation inside acquisition still owns late resources',
      () async {
    access.observe(observation(1));
    final p = Preparation(), r = Resources();
    late Future<void> closing;
    final enabling = access.enable((_) {
      closing = access.disable();
      return p;
    });
    expect(p.cancelled, isTrue);
    expect(access.phase, AndroidAccessPhase.draining);
    p.complete(r);
    await Future.wait([enabling, closing]);
    expect(r.closes, 1);
    expect(access.phase, AndroidAccessPhase.off);
  });

  for (final reentrant in [true, false]) {
    test(
        'throwing cancellation retains late resources and original barriers (reentrant=$reentrant)',
        () async {
      access.observe(observation(1));
      final p = Preparation()..failCancellation = true;
      final r = Resources()..barrier = Completer<void>();
      var closed = false;
      var acquisitions = 0;
      Future<void>? enabling, closing;
      void cancel() {
        closing = access.disable().then((_) => closed = true);
      }

      try {
        enabling = access.enable((_) {
          acquisitions++;
          if (reentrant) cancel();
          return p;
        });
        if (!reentrant) cancel();
        expect(p.cancelled, isTrue);
        expect(access.acceptsNew, isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        expect(access.phase, AndroidAccessPhase.draining);
        await expectLater(access.enable((_) {
          acquisitions++;
          return Preparation();
        }), throwsStateError);
        expect(acquisitions, 1);

        p.acquired.complete(r);
        await Future<void>.delayed(Duration.zero);
        expect(r.withdrawals, greaterThan(0));
        expect(r.closes, 0);
        expect(closed, isFalse);
        expect(access.phase, AndroidAccessPhase.draining);

        p.drained.complete();
        await Future<void>.delayed(Duration.zero);
        expect(r.closes, 1);
        expect(closed, isFalse);
        expect(access.phase, AndroidAccessPhase.draining);
      } finally {
        if (!p.acquired.isCompleted) p.acquired.complete(r);
        if (!p.drained.isCompleted) p.drained.complete();
        r.barrier!.complete();
        await Future.wait(
            [if (enabling != null) enabling, if (closing != null) closing!]);
      }
      expect(closed, isTrue);
      expect(r.closes, 1);
      expect(access.phase, AndroidAccessPhase.recovery);
      access.observe(observation(2));
      await access.disable();
      await expectLater(access.enable((_) {
        acquisitions++;
        return Preparation();
      }), throwsStateError);
      expect(acquisitions, 1);
      expect(access.phase, AndroidAccessPhase.recovery);
      expect(access.acceptsNew, isFalse);
    });
  }

  test('focus loss closes old connection; resume does not renew deadline',
      () async {
    final r = await enable();
    now = const Duration(hours: 7);
    access.observe(observation(2, focus: false));
    expect(access.phase, AndroidAccessPhase.suspended);
    expect(access.acceptsNew, isFalse);
    access.observe(observation(3));
    final p = Preparation(), next = Resources();
    p.complete(next);
    await access.resume((_) => p);
    expect(r.closes, 1);
    expect(access.acceptsNew, isTrue);
    now = const Duration(hours: 8);
    await access.checkDeadline();
    expect(access.phase, AndroidAccessPhase.off);
    expect(next.closes, 1);
  });

  for (final event in [
    observation(2, visible: false),
    observation(2, unlocked: false),
    observation(2, network: 'network-2'),
    observation(2, network: null)
  ]) {
    test(
        'background/lock/network invalidation ${event.visible}/${event.unlocked}/${event.network}',
        () async {
      final r = await enable();
      access.observe(event);
      expect(access.acceptsNew, isFalse);
      await access.disable();
      expect(access.phase, AndroidAccessPhase.off);
      expect(r.closes, 1);
      access.observe(observation(3));
      expect(access.acceptsNew, isFalse);
    });
  }

  test('failed settlement latches recovery and cannot reacquire', () async {
    final r = await enable();
    r.fail = true;
    await access.disable();
    expect(access.phase, AndroidAccessPhase.recovery);
    await expectLater(access.enable((_) => Preparation()), throwsStateError);
  });

  test('stale native observation and repeated enable cannot renew access',
      () async {
    await enable();
    access.observe(observation(0, visible: false));
    expect(access.acceptsNew, isTrue);
    await expectLater(access.enable((_) => Preparation()), throwsStateError);
    now = const Duration(hours: 8);
    expect(access.acceptsNew, isFalse);
    await access.disable();
  });

  test('androidBackgroundQuestionRead admits pure question READ only', () {
    final pureScopedRead = ExternalGrantPolicy(
      permissions: const [CapabilityPermission.read],
      scopes: [
        ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'Bank A'),
      ],
      categories: const [ExternalContentCategory.questionContent],
    );
    expect(androidBackgroundQuestionRead(pureScopedRead), isTrue);

    final pureAllContentRead = ExternalGrantPolicy(
      permissions: const [CapabilityPermission.read],
      scopes: const [],
      categories: const [ExternalContentCategory.questionContent],
      allContent: true,
    );
    expect(androidBackgroundQuestionRead(pureAllContentRead), isTrue);

    expect(
      androidBackgroundQuestionRead(ExternalGrantPolicy(
        permissions: const [
          CapabilityPermission.read,
          CapabilityPermission.stage,
        ],
        scopes: const [],
        categories: const [ExternalContentCategory.questionContent],
        allContent: true,
      )),
      isFalse,
    );
    expect(
      androidBackgroundQuestionRead(ExternalGrantPolicy(
        permissions: const [CapabilityPermission.read],
        scopes: const [],
        categories: const [
          ExternalContentCategory.questionContent,
          ExternalContentCategory.studyStatistics,
        ],
        allContent: true,
      )),
      isFalse,
    );
    expect(
      androidBackgroundQuestionRead(ExternalGrantPolicy(
        permissions: const [CapabilityPermission.read],
        scopes: const [],
        categories: const [
          ExternalContentCategory.questionContent,
          ExternalContentCategory.fileContent,
        ],
        allContent: true,
      )),
      isFalse,
    );
    expect(
      androidBackgroundQuestionRead(ExternalGrantPolicy(
        permissions: const [CapabilityPermission.read],
        scopes: [
          ExternalGrantScope(kind: ExternalTargetKind.file, targetId: 'f1'),
        ],
        categories: const [ExternalContentCategory.questionContent],
      )),
      isFalse,
    );
    expect(
      AndroidAccessDuration.values.map((d) => d.limit).toList(),
      const [
        Duration(minutes: 5),
        Duration(minutes: 15),
        Duration(minutes: 30),
        Duration(hours: 1),
        Duration(hours: 2),
        Duration(hours: 4),
        Duration(hours: 8),
        null,
      ],
    );
  });

  test(
      'background pure-question READ supports untilAppStops and continueWhileLocked gating',
      () async {
    access.observe(observation(1, backgroundRead: true));
    await expectLater(
      access.enable((_) => Preparation(), continueWhileLocked: true),
      throwsStateError,
    );
    await expectLater(
      access.enable((_) => Preparation(), duration: null),
      throwsStateError,
    );

    final p = Preparation(), r = Resources();
    final work = access.enable(
      (_) => p,
      duration: AndroidAccessDuration.untilAppStops.limit,
      allowBackgroundRead: true,
      continueWhileLocked: true,
    );
    p.complete(r);
    await work;

    expect(access.phase, AndroidAccessPhase.ready);
    expect(access.untilAppStops, isTrue);
    expect(access.boundedRemaining, isNull);
    expect(access.allowsAuthenticatedUse, isTrue);
    expect(access.acceptsNew, isTrue);

    access.observe(observation(
      2,
      visible: false,
      resumed: false,
      focus: false,
      backgroundRead: true,
    ));
    expect(access.phase, AndroidAccessPhase.ready);
    expect(access.allowsAuthenticatedUse, isTrue);
    expect(access.acceptsNew, isTrue);

    access.observe(observation(
      3,
      visible: false,
      resumed: false,
      focus: false,
      interactive: false,
      unlocked: false,
      backgroundRead: true,
    ));
    expect(access.phase, AndroidAccessPhase.ready);
    expect(access.allowsAuthenticatedUse, isTrue);
    expect(access.acceptsNew, isFalse);

    now = const Duration(hours: 24);
    await access.checkDeadline();
    expect(access.phase, AndroidAccessPhase.ready);
    expect(access.allowsAuthenticatedUse, isTrue);

    access.observe(observation(
      4,
      visible: false,
      resumed: false,
      focus: false,
      interactive: false,
      unlocked: false,
      backgroundRead: false,
    ));
    await access.disable();
    expect(access.phase, AndroidAccessPhase.off);
    expect(r.closes, 1);
    expect(access.allowsAuthenticatedUse, isFalse);
    expect(access.acceptsNew, isFalse);
  });

  test(
      'background READ without continueWhileLocked withdraws immediately on lock',
      () async {
    access.observe(observation(1, backgroundRead: true));
    final p = Preparation(), r = Resources();
    final work = access.enable(
      (_) => p,
      duration: AndroidAccessDuration.thirtyMinutes.limit,
      allowBackgroundRead: true,
      continueWhileLocked: false,
    );
    p.complete(r);
    await work;

    access.observe(observation(
      2,
      visible: false,
      resumed: false,
      focus: false,
      interactive: false,
      unlocked: false,
      backgroundRead: true,
    ));
    await access.disable();
    expect(access.phase, AndroidAccessPhase.off);
    expect(r.closes, 1);
  });
}
