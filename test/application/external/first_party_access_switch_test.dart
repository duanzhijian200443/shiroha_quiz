import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_external_access.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'external_trust_test_support.dart';
import 'durable_stage_test_support.dart' show initializeGeneratedTests;

void main() {
  initializeGeneratedTests();
  test(
      'switch-off withdraws immediately while a status read owns the busy slot',
      () async {
    final f = OfflineTrustHarness();
    await f.open();
    final controls = FirstPartyExternalAccess(
        policy: f.local.service, compositionIsCurrent: () => f.current);
    controls.installTrusted(FirstPartyExternalBinding(
        management: f.management,
        coordinator: f.coordinator,
        trust: f.trust,
        stages: f.stages,
        localOwner: f.localSession,
        authenticationAttempt: () => f.credentials.first,
        publishApprovals: (_) {},
        shutdown: f.coordinator.shutdown));
    addTearDown(() async {
      await controls.shutdown();
      await f.close();
    });
    await f.save();
    await controls.select(f.reference.profileId);
    await f.pair();
    await f.coordinator.startOffline();
    await controls.enable(const Duration(minutes: 10));
    expect((await controls.status()).enabled, isTrue);
    final reached = f.barrier.reached = Completer<void>();
    final release = f.barrier.resume = Completer<void>();
    final observing = controls.status();
    await reached.future;
    var settled = false;
    final disabling = controls.disable().then((_) => settled = true);
    expect(f.trust.snapshot(f.profile.principal).state,
        PairingState.pairedDisabled);
    expect(settled, isFalse);
    release.complete();
    await observing;
    await disabling;
    expect((await controls.status()).enabled, isFalse);
  });
}
