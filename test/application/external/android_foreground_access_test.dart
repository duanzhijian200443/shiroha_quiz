import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';

AndroidForegroundObservation observation(int sequence,
        {bool focus = true,
        bool visible = true,
        bool unlocked = true,
        String? network = 'network-1'}) =>
    AndroidForegroundObservation(
        sequence: sequence,
        resumed: visible,
        focused: focus,
        interactive: true,
        unlocked: unlocked,
        visible: visible,
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
  @override
  Future<AndroidAccessResources> get result => acquired.future;
  @override
  Future<void> get settled => drained.future;
  @override
  void cancel() {
    cancelled = true;
  }

  void complete(Resources resources) {
    acquired.complete(resources);
    drained.complete();
  }
}

void main() {
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

  test('starts off and cannot enable without all foreground observations',
      () async {
    expect(access.acceptsNew, isFalse);
    access.observe(observation(1, focus: false));
    await expectLater(
        access.enable((_) => throw StateError('must not acquire')),
        throwsStateError);
    expect(access.phase, AndroidAccessPhase.off);
  });

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
}
