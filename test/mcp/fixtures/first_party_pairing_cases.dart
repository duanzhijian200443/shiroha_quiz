import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_credential_boundary.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import 'package:shiroha_quiz/ui/pages/first_party_external_control.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import '../../application/external/external_credential_test_support.dart';
import '../../application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../../ui/generated_question/generated_ui_test_support.dart'
    show settleGenerated;
import 'first_party_app_integration_cases.dart';
import '../../data/external/windows_pairing_test.dart' as p27;
import '../../data/external/windows_tls_transport_test.dart' as tls;
import '../../data/external/windows_peer_certificate_policy_test.dart'
    show OfflinePeerCalls;
import '../../data/external/windows_credential_initialization_test.dart'
    as init;

/// No Windows primitives: the real App root/P15/P12/P0 and temporary SQLite,
/// with the existing explicitly synthetic association/event test facilities.
final class CredentialAppHarness extends FirstPartyAppHarness {
  final store = MemoryExternalAssociations();
  final verifier = SyntheticCredentialVerifier();
  late ExternalCredentialBoundary boundary;
  late _PairingPort _pairing;
  Object? authentication;
  Object Function()? proof;
  bool badAuthentication = false;
  Future<void> Function()? afterConnectionResult;
  Duration elapsed = Duration.zero;

  @override
  Future<void> connect() async {
    port = await integration.attachCredentials(
        associations: store,
        verification: (_) => verifier,
        clock: files.s.clock,
        installationId: 'offline-install',
        monotonicNow: () => elapsed,
        readiness:
            OfflineReadiness(() async => files.s.h.db.rawQuery('SELECT 1')),
        services: (value) {
          boundary = value;
          _pairing = _PairingPort(this);
          return FirstPartyCredentialServices(
              boundary: value,
              pairing: _pairing,
              openConnection: (ref) async {
                final snapshot = await store.read(ref.profileId);
                final event = badAuthentication
                    ? Object()
                    : verifier.event(
                        profile: ref.profileId,
                        revision: snapshot.record!.revision);
                authentication = event;
                final session = await boundary.openSession(ref, event);
                return FirstPartyCredentialConnection(session, () async {
                  // Equivalent custody to WindowsTlsSession: no new Session,
                  // no event replay, and invalidation never revives a snapshot.
                  await store.read(ref.profileId);
                  final result = boundary.isCurrent &&
                          snapshot.isCurrent &&
                          verifier.isLive(event) &&
                          session.failure == null
                      ? session
                      : null;
                  await afterConnectionResult?.call();
                  return result;
                });
              },
              close: () async {});
        });
  }

  Future<void> pair() async {
    await controls.select(files.s.profile.profileId);
    await controls.requestPairing();
    await controls.approvePairing();
    await controls.completePairing();
  }
}

final class _PairingPort implements FirstPartyPairingPort {
  _PairingPort(this.h);
  final CredentialAppHarness h;
  late ExternalProfileReference reference;
  ExternalCredentialRegistration? registration;
  @override
  Future<FirstPartyPairingRequest> request(
      ExternalProfileReference profile) async {
    reference = profile;
    final old = await h.store.read(profile.profileId);
    registration = await h.boundary.requestPairing(profile,
        requestId: 'registration',
        credentialIdentity: 'verified-leaf',
        expectedRevision: old.record?.revision ?? 0);
    return _Request(h, registration!);
  }

  @override
  Future<void> close() => h.boundary.shutdown();
}

final class _Request implements FirstPartyPairingRequest {
  _Request(this.h, this.request);
  final CredentialAppHarness h;
  final ExternalCredentialRegistration request;
  bool completed = false;
  @override
  Future<FirstPartyPairingDisplay> display() async {
    if (completed) {
      final record = await h.boundary.confirmedPairing(request);
      return FirstPartyPairingDisplay(revision: record.revision);
    }
    await h.boundary.validatePairingRequest(request);
    return const FirstPartyPairingDisplay();
  }

  @override
  Future<void> approve() => h.boundary.approvePairing(request);
  @override
  Future<void> complete() async {
    await h.boundary.completePairing(
        request,
        h.proof?.call() ??
            h.verifier.event(
                profile: request.challenge.profileId,
                pairing: true,
                revision: request.challenge.revision));
    await h.boundary.confirmedPairing(request);
    completed = true;
  }
}

void registerFirstPartyPairingTests() {
  group(
      'first-party P15 pairing integration (synthetic, not Windows acceptance)',
      () {
    late CredentialAppHarness f;
    setUp(() async {
      f = CredentialAppHarness();
      await f.open();
    });
    tearDown(() async {
      if (f.verifier.resume case final resume? when !resume.isCompleted) {
        resume.complete();
      }
      await f.close();
    });
    Future<PairingState?> state() async => (await f.controls.status()).pairing;

    test(
        'request/approval/proof/auth/finite enable/explicit target/STAGE/disable',
        () async {
      await f.controls.select(f.files.s.profile.profileId);
      expect(await state(), PairingState.unpaired);
      expect((await f.controls.status()).pairingAvailable, isTrue);
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      await f.controls.requestPairing();
      expect(await state(), PairingState.requestPending);
      expect(await f.controls.authenticatedSession(), isNull);
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      await f.controls.approvePairing();
      expect(await state(), PairingState.approvedPendingProof);
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      await f.controls.completePairing();
      expect(await state(), PairingState.pairedDisabled);
      expect((await f.controls.status()).pairingDisplay!.revision, 1);
      expect((await f.controls.status()).connected, isFalse);
      expect(await f.controls.authenticatedSession(), isNull);
      await f.controls.enable(const Duration(minutes: 5));
      final session = await f.controls.authenticatedSession();
      expect(session, isNotNull);
      expect(await f.controls.authenticatedSession(), same(session));
      expect(await state(), PairingState.enabledForCurrentRuntime);
      final context = await f.context();
      expect((await f.stage(context))['error'], isNotNull);
      await f.approve();
      expect(f.data(await f.stage(context))['publication'], 'STAGED');
      expect(await f.files.s.h.count('questions'), 0);
      expect((await f.call('commit_generated_questions'))['error'], isNotNull);
      await f.controls.disable();
      expect(session!.failure, isNotNull);
      expect(await state(), PairingState.pairedDisabled);
      expect((await f.stage(context))['error'], isNotNull);
      expect((await f.controls.status()).approvedTargets, 0);
    });

    for (final invalid in [
      'opaque',
      'public P0 evidence',
      'wrong Profile',
      'wrong revision'
    ]) {
      test('rejects $invalid pairing proof without success or retry', () async {
        await f.controls.select(f.files.s.profile.profileId);
        await f.controls.requestPairing();
        await f.controls.approvePairing();
        f.proof = () => switch (invalid) {
              'opaque' => Object(),
              'public P0 evidence' =>
                const PairingProof('registration', 'verified-leaf'),
              'wrong Profile' =>
                f.verifier.event(profile: 'wrong', pairing: true),
              _ => f.verifier.event(
                  profile: f.files.s.profile.profileId,
                  pairing: true,
                  revision: 99),
            };
        await expectLater(f.controls.completePairing(), throwsA(anything));
        final status = await f.controls.status();
        expect(status.pairing, PairingState.approvedPendingProof);
        expect(status.pairingFailed, isTrue);
        expect(status.pairingDisplay, isNull);
        expect(f.store.records, isEmpty);
        await f.controls.select(f.files.s.profile.profileId);
        expect((await f.controls.status()).pairingFailed, isTrue);
        await expectLater(f.controls.completePairing(), throwsA(anything));
        await expectLater(
            f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
        expect(await f.controls.authenticatedSession(), isNull);
      });
    }

    test(
        'duplicate request/completion and foreign selected Profile cannot consume request',
        () async {
      await f.controls.select(f.files.s.profile.profileId);
      await f.controls.requestPairing();
      await expectLater(f.controls.requestPairing(), throwsA(anything));
      await expectLater(f.controls.completePairing(), throwsA(anything));
      expect((await f.controls.status()).pairingFailed, isFalse);
      final view = f.policy.openView();
      final other = await view.create('Other');
      view.close();
      await f.controls.select(other.profileId);
      expect(await state(), PairingState.unpaired);
      await expectLater(f.controls.approvePairing(), throwsA(anything));
      expect(f.store.records, isEmpty);
    });

    test(
        'authentication is independent; failed authentication disables enablement',
        () async {
      await f.pair();
      f.badAuthentication = true;
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      expect(await state(), PairingState.pairedDisabled);
      expect(await f.controls.authenticatedSession(), isNull);
      f.badAuthentication = false;
      await f.controls.enable(const Duration(minutes: 5));
      f.verifier.disconnect(f.authentication!);
      expect(await f.controls.authenticatedSession(), isNull);
      expect((await f.controls.status()).enabled, isFalse);
      expect((await f.call('open_generation_context'))['error'], isNotNull);
    });

    test('request expiry latches on monotonic clock, with no P0 success',
        () async {
      await f.controls.select(f.files.s.profile.profileId);
      await f.controls.requestPairing();
      await f.controls.approvePairing();
      f.elapsed = ExternalCredentialBoundary.evidenceLifetime;
      expect((await f.controls.status()).pairingFailed, isTrue);
      f.elapsed = Duration.zero;
      await expectLater(f.controls.completePairing(), throwsA(anything));
      expect(f.store.records, isEmpty);
    });

    test(
        'grantless Profile can pair independently but cannot open business access',
        () async {
      final view = f.policy.openView();
      final ref = await view.create('No grant');
      view.close();
      await f.controls.select(ref.profileId);
      expect((await f.controls.status()).pairingAvailable, isTrue);
      await f.controls.requestPairing();
      await f.controls.approvePairing();
      await f.controls.completePairing();
      expect(await state(), PairingState.pairedDisabled);
      expect(f.store.records[ref.profileId], isNotNull);
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      expect(await f.controls.authenticatedSession(), isNull);
      expect(await state(), PairingState.pairedDisabled);
    });

    test('READ never grants STAGE, including explicit target approval',
        () async {
      final s = f.files.s;
      final revision =
          (await s.management.read(s.profile)).profile.grantRevision;
      await s.management.replaceGrant(
          s.profile,
          revision,
          s.policy(
              permissions: [CapabilityPermission.read],
              scopes: [f.files.bank]));
      await f.pair();
      await f.controls.enable(const Duration(minutes: 5));
      final context = await f.context();
      await expectLater(f.approve(), throwsA(anything));
      expect((await f.stage(context))['error'], isNotNull);
      expect(await s.h.count('generated_question_proposals'), 0);
    });

    test('shutdown during final async channel validation withholds old Session',
        () async {
      await f.pair();
      await f.controls.enable(const Duration(minutes: 5));
      final reached = Completer<void>(), release = Completer<void>();
      var checks = 0;
      f.afterConnectionResult = () async {
        if (++checks == 2) {
          reached.complete();
          await release.future;
        }
      };
      final pending = f.controls.authenticatedSession();
      await reached.future;
      await f.integration.close();
      release.complete();
      expect(await pending, isNull);
    });

    test(
        'expiry, revoke and fresh composition do not revive Session or pairing',
        () async {
      await f.pair();
      await expectLater(f.controls.requestPairing(), throwsA(anything));
      await expectLater(f.controls.completePairing(), throwsA(anything));
      expect((await f.controls.status()).pairingFailed, isFalse);
      await f.integration.close();
      f.compose();
      await f.connect();
      await f.controls.select(f.files.s.profile.profileId);
      expect(await state(), PairingState.unpaired);
      expect(await f.controls.authenticatedSession(), isNull);
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      await f.pair();
      await f.controls.enable(const Duration(minutes: 5));
      final session = await f.controls.authenticatedSession();
      f.files.s.clock.current =
          f.files.s.clock.current.add(const Duration(minutes: 5));
      expect(await f.controls.authenticatedSession(), isNull);
      expect(session!.failure, isNotNull);
      await f.controls.enable(const Duration(minutes: 5));
      await f.boundary.revoke(f._pairing.reference, 1);
      expect(await f.controls.authenticatedSession(), isNull);
      expect(f.store.records[f.files.s.profile.profileId]!.revoked, isTrue);
    });

    test(
        'database close waits for pending P15 proof and rejects late completion',
        () async {
      await f.controls.select(f.files.s.profile.profileId);
      await f.controls.requestPairing();
      await f.controls.approvePairing();
      final reached = Completer<void>(), release = Completer<void>();
      f.verifier.reached = reached;
      f.verifier.resume = release;
      final pending = f.controls.completePairing();
      final rejected = expectLater(pending, throwsA(anything));
      await reached.future;
      var closed = false;
      final closing = f.closeDatabase().then((_) => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);
      expect(f.controls.isCurrent, isFalse);
      expect(f.files.s.h.db.isOpen, isTrue);
      release.complete();
      await rejected;
      await closing;
      expect(f.files.s.h.db.isOpen, isFalse);
      expect(f.store.records, isEmpty);
    });

    testWidgets('local request, cancel/approve, verify, enable and disable',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: FirstPartyExternalControl(access: f.controls))));
      await settleGenerated(tester);
      Future<void> tap(String text) async {
        await tester.tap(find.text(text).last);
        await settleGenerated(tester);
      }

      await tap('选择连接 Profile');
      await tap('Synthetic client');
      await tap('请求配对');
      expect(find.text('配对状态：等待批准配对'), findsOneWidget);
      await tap('确认配对');
      await tap('取消');
      expect((await tester.runAsync(state)), PairingState.requestPending);
      await tap('确认配对');
      await tap('批准配对');
      expect(find.text('配对状态：等待凭据验证'), findsOneWidget);
      await tap('验证配对证明');
      expect(find.text('已确认凭据版本：1'), findsOneWidget);
      expect(find.text('可信连接已认证'), findsNothing);
      await tap('限时启用');
      expect(find.text('可信连接已认证'), findsOneWidget);
      await tap('禁用访问');
      expect((await tester.runAsync(f.controls.status))!.enabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('actual App root + P27/P20/P15 math + channel binding stays isolated',
      () async {
    final h = p27.PairingHarness();
    await h.open();
    final f = FirstPartyAppHarness();
    await f.open(attach: false);
    late WindowsPairingHandoff handoff;
    addTearDown(() async {
      await f.close();
      await handoff.close();
      await h.close();
    });
    f.files.s.clock.current = h.native.now;
    final pairingVerifier = WindowsPairingVerification.withPrimitives(
        verifyDigest: h.native.verify,
        utcNow: () => h.native.now,
        monotonicNow: () => h.elapsed,
        compositionIsCurrent: () => h.current && f.controls.isCurrent);
    late WindowsChannelVerification channels;
    late tls.MemoryTlsChannel channel;
    f.port = await f.integration.attachCredentials(
        associations: h.associations,
        verification: (management) => channels = WindowsChannelVerification(
            pairing: pairingVerifier,
            associations: h.associations,
            management: management,
            nativePolicy:
                WindowsPeerCertificatePolicy(OfflinePeerCalls()).check,
            verifyDigest: h.native.verify,
            utcNow: () => h.native.now,
            monotonicNow: () => h.elapsed,
            compositionIsCurrent: () => h.current && f.controls.isCurrent),
        clock: f.files.s.clock,
        installationId:
            h.native.service.validatedPublicMaterial().installationId,
        monotonicNow: () => h.elapsed,
        readiness:
            OfflineReadiness(() async => f.files.s.h.db.rawQuery('SELECT 1')),
        services: (boundary) {
          channels.attach(boundary);
          final owner = WindowsAppPairing.withPrimitives(
              exchange: h.appExchange,
              credentials: h.native.service,
              boundary: boundary,
              associations: h.associations,
              verification: pairingVerifier,
              utcNow: () => h.native.now,
              monotonicNow: () => h.elapsed,
              compositionIsCurrent: () => h.current && f.controls.isCurrent,
              randomBytes: h.random);
          handoff =
              WindowsPairingHandoff(appOwner: owner, bridgeOwner: h.bridge);
          return FirstPartyCredentialServices(
              boundary: boundary,
              pairing: handoff,
              openConnection: (_) async {
                final material = h.native.service.validatedPublicMaterial();
                final pin = h.bridgeStore.read(4)! as ExternalBridgeClient;
                final issuer = Uint8List.fromList(pin.issuerCertificateDer);
                pin.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
                final plan = TlsContextPlan.validate(
                    role: TlsPeerRole.server,
                    leafDer: material.serverLeafDer!,
                    issuerDer: material.issuerCertificateDer,
                    privateKeyDer: init.publicFixtureKey(),
                    independentlyPinnedIssuer: issuer,
                    signDigest: h.native.sign,
                    verifyDigest: h.native.verify,
                    utcNow: () => h.native.now);
                try {
                  return (await channels.authenticate(channel, plan))
                      .firstPartyConnection;
                } finally {
                  plan.dispose();
                }
              },
              close: () async => channels.close());
        });
    final bridgeControls = handoff.bridge;
    bridgeControls.beginEnrollment(
        displayLabel: 'PUBLIC FIXTURE', clientBuild: 'offline');
    final submissionId = bridgeControls.display().submissionId!;
    await f.controls.select(f.files.s.profile.profileId);
    await f.controls.requestPairing();
    await bridgeControls.inspectAppTrust();
    final compared = bridgeControls.display();
    expect((await f.controls.status()).pairingDisplay!.digest,
        compared.initialDigest);
    channel = tls.MemoryTlsChannel(
        h.bridgeExchange.readChallenge(submissionId)!.clientLeafDer);
    await f.controls.approvePairing();
    bridgeControls.confirmInitialAndPublishProof(
        comparedDigest: compared.initialDigest!);
    await f.controls.completePairing();
    final completed = (await f.controls.status()).pairingDisplay!;
    await bridgeControls.inspectAppCompletion();
    expect(completed.digest, bridgeControls.display().completionDigest);
    expect(h.native.calls.credentialFiles[4], isNull);
    bridgeControls.confirmCompletionAndSave(
        comparedRevision: completed.revision!,
        comparedDigest: completed.digest!);
    expect(bridgeControls.display().pinSaved, isTrue);
    expect(await f.controls.authenticatedSession(), isNull);
    await f.controls.enable(const Duration(minutes: 5));
    final session = await f.controls.authenticatedSession();
    expect(session, isNotNull);
    final context = await f.context();
    expect((await f.stage(context))['error'], isNotNull);
    await f.approve();
    expect(f.data(await f.stage(context))['publication'], 'STAGED');
    expect(await f.files.s.h.count('questions'), 0);
    await f.controls.disable();
    expect(session!.failure, isNotNull);
    await channel.close();
  });
}
