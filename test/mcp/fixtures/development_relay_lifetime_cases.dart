import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_development_access.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_development_lifetime.dart';
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';

import 'windows_app_transport_fixture.dart';
import 'windows_resource_process_cases.dart';

void developmentRelayLifetimeCases() {
  test(
      'development relay lifetime preserves Host while old child settles and requires fresh Enable',
      () async {
    final io = FakeBridgeProcessIo();
    final child = WindowsBridgeProcess(io: io);
    await child.start();
    final f = WindowsAppTransportFixture()..useAcceptedLocalConnection = true;
    await f.open(enableWithoutRetainedChannel: true);
    Timer? monitor;
    addTearDown(() async {
      monitor?.cancel();
      if (!io.child.exit.isCompleted) io.child.finish();
      await f.close();
    });
    final originalHost = f.host;
    final context = await f.context();
    final pending = Completer<void>();
    final changes = f.approval.changes.listen((_) {
      if (f.approval.waitingForUser && !pending.isCompleted) pending.complete();
    });
    final oldRequest = f.stage(context, key: 'pending-relay-lifetime');
    await Future.any([pending.future, oldRequest.then((_) {})]);
    await changes.cancel();
    expect(f.approval.waitingForUser, isTrue);
    final oldApproval = f.approvalView.pending!;

    var settled = false, stops = 0, ticks = 0;
    final observed = Completer<void>();
    // Companion native-pipe regression supplies the real launch query through
    // these same production monitor callbacks while the old client call waits.
    monitor = monitorWindowsDevelopmentLifetime(
        isCurrent: () {
          if (++ticks == 3) observed.complete();
          return f.controls.isCurrent;
        },
        isExpired: () => false,
        launchIsCurrent: () => true,
        stop: (_) async {
          stops++;
          monitor?.cancel();
          await f.startup.close();
        });
    final withdrawn = f.controls.disconnectTransport();
    final closing = child.stopAndWait().then((_) => settled = true);
    await io.child.inputReached.future;
    await observed.future.timeout(const Duration(seconds: 3));
    expect(settled, isFalse);
    expect(stops, 0);
    expect(f.host, same(originalHost));
    expect(f.host.phase, WindowsTlsHostPhase.ready);
    expect(f.appProcess.stops, 0);
    f.pairing.native.owner.ensureOpen();
    expect((await f.controls.status()).enabled, isFalse);
    expect(f.approval.waitingForUser, isFalse);
    await expectLater(f.approvalView.confirm(oldApproval), throwsA(anything));
    expect(await f.files.s.h.count('generated_question_proposals'), 0);

    io.child.finish();
    await closing;
    await withdrawn;
    expect((await oldRequest)['error'], isNotNull);
    final before = f.connections.length;
    expect((await f.call('open_generation_context'))['error'], isNotNull);
    expect(f.connections.length, greaterThan(before));
    await f.controls.enable(const Duration(minutes: 5));
    final disabledAttempt = f.connections.last;
    expect(await f.context(), isNotEmpty);
    expect(f.connections.last, isNot(same(disabledAttempt)));
    expect(f.host, same(originalHost));
    expect(f.host.phase, WindowsTlsHostPhase.ready);
    expect(f.appProcess.stops, 0);
    expect(f.approval.waitingForUser, isFalse);
    expect(await f.files.s.h.count('generated_question_proposals'), 0);
  });

  for (final cause in [
    FirstPartyDevelopmentStopCause.relayLost,
    FirstPartyDevelopmentStopCause.expired,
    FirstPartyDevelopmentStopCause.appInvalidated,
  ]) {
    test(
        'development relay lifetime keeps $cause terminal through original drain',
        () async {
      final f = WindowsAppTransportFixture()..useAcceptedLocalConnection = true;
      await f.open(enableWithoutRetainedChannel: true);
      final release = f.appProcess.stopping = Completer<void>();
      Timer? monitor;
      addTearDown(() async {
        monitor?.cancel();
        if (!release.isCompleted) release.complete();
        await f.close();
      });
      FirstPartyDevelopmentStopCause? observed;
      Future<void>? stopped;
      monitor = monitorWindowsDevelopmentLifetime(
          isCurrent: () => false,
          isExpired: () => cause == FirstPartyDevelopmentStopCause.expired,
          launchIsCurrent: () =>
              cause != FirstPartyDevelopmentStopCause.relayLost,
          stop: (value) {
            observed = value;
            monitor?.cancel();
            return stopped ??= f.startup.close();
          });
      await f.appProcess.reached.future.timeout(const Duration(seconds: 3));
      expect(observed, cause);
      expect(f.host.phase, WindowsTlsHostPhase.closing);
      f.pairing.native.owner.ensureOpen();
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      release.complete();
      await stopped;
      expect(f.host.phase, WindowsTlsHostPhase.closed);
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      expect(f.appProcess.stops, 1);
    });
  }
}
