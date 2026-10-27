import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_development_access.dart';
import 'package:shiroha_quiz/application/external/first_party_external_access.dart';
import 'package:shiroha_quiz/application/external/external_credential_boundary.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_bridge.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_development_app.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/association_object_codec.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:shiroha_quiz/ui/pages/first_party_external_control.dart';
import 'package:shiroha_quiz/ui/pages/external_authorization_screen.dart';
import 'package:shiroha_quiz/ui/dependencies/first_party_external_scope.dart';
import '../../ui/generated_question/generated_ui_test_support.dart'
    show settleGenerated;
import '../../data/external/bootstrap_test_support.dart';
import '../../data/external/windows_credential_object_store_test.dart'
    as objects;
import '../../data/external/windows_pairing_test.dart' show signPublicFixture;
import '../../data/external/windows_peer_certificate_policy_test.dart'
    show OfflinePeerCalls;
import '../../data/external/windows_tls_transport_test.dart' as tls;
import '../../data/external/fixtures/windows_tls_bridge_cases.dart'
    show LinkedChannel;
import 'windows_app_transport_fixture.dart';
import 'first_party_interaction_cases.dart'
    show interactionApp, interactionFrame, interactionRead, interactionTap;
import 'first_party_pairing_cases.dart' show CredentialAppHarness;

final class _RecoveryFixture {
  final app = WindowsAppTransportFixture()..useAcceptedLocalConnection = true;
  final development = _DevelopmentControl()
    ..bridgePinMissing = true
    ..childSettled.complete();
  bool admitted = true;
  int stops = 0;
  Future<void>? _closing;
  Future<void> open({bool installed = true, bool grantless = false}) async {
    if (installed) app.associationRecoveryAvailable = () => admitted;
    await app.open(enroll: false, enableWithoutRetainedChannel: true);
    app.controls.installDevelopment(development);
    development.onStop = () => _closing ??= () async {
          stops++;
          try {
            await app.startup.close();
            development.phase = FirstPartyDevelopmentPhase.closed;
          } catch (_) {
            development.phase = FirstPartyDevelopmentPhase.failed;
            rethrow;
          }
        }();
    var id = app.files.s.profile.profileId;
    if (grantless) {
      final view = app.policy.openView();
      id = (await view.create('Recovery without Grant')).profileId;
      view.close();
    }
    await app.controls.select(id);
    await app.pairing.associations.register(
        profileId: id,
        installationId: app.publicMaterial.installationId,
        credentialIdentity: sha256Hex(vectorBytes('clientDer')),
        expectedRevision: 0,
        validateManagement: () async {});
  }

  Future<void> close() => app.close();
}

final class _ExistingFixture {
  final app = WindowsAppTransportFixture()..useAcceptedLocalConnection = true;
  WindowsTlsBridge? proof;
  LinkedChannel? client, server;
  Future<void>? peerClosed;

  Future<void> open({bool grantless = false}) async {
    await app.open(enroll: false, enableWithoutRetainedChannel: true);
    final h = app.pairing;
    final pin = objects.fixture(4) as ExternalBridgeClient;
    h.bridgeStore.write(pin);
    pin.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
    var profileId = app.files.s.profile.profileId;
    if (grantless) {
      final view = app.policy.openView();
      profileId =
          (await view.create('Existing identity without Grant')).profileId;
      view.close();
    }
    await h.associations.register(
        profileId: profileId,
        installationId: app.publicMaterial.installationId,
        credentialIdentity: sha256Hex(vectorBytes('clientDer')),
        expectedRevision: 0,
        validateManagement: () async {});
    await app.controls.select(profileId);
    app.bridge = McpVnextWindowsBridge(
        createConnection: connection, enableStageApprovalWait: true);
    app.approvalView = app.controls.openStageApprovalView()!;
  }

  WindowsTlsBridge connection() {
    final h = app.pairing;
    client = LinkedChannel(app.publicMaterial.serverLeafDer!);
    server = LinkedChannel(vectorBytes('clientDer'));
    client!.peer = server;
    client!.abortPeer = true;
    server!.peer = client;
    app.listener.controller.add(tls.MemoryRawPeer(server!));
    return WindowsTlsBridge(
        io: tls.MemoryBridgeIo(client!),
        reader: WindowsDiscoveryReader(h.bridgeOwner, verifier: (
            {required publicPoint, required digest, required rawSignature}) {
          h.native.verify(
              publicPoint: publicPoint,
              digest: digest,
              rawSignature: rawSignature);
          return true;
        }),
        trusted: DiscoveryExpectations(
            trustedAnchorDer: app.publicMaterial.issuerCertificateDer,
            installationId: app.publicMaterial.installationId,
            serverLeafDigest: app.plan.leafDigest,
            verifiedEpochHighWater: BigInt.one),
        requirePublication: (value) =>
            expect(value, app.publicMaterial.publicationEpoch),
        owner: h.bridgeOwner,
        signDigest: signPublicFixture,
        verifyDigest: h.native.verify,
        nativePolicy: WindowsPeerCertificatePolicy(OfflinePeerCalls()).check,
        utcNow: () => h.native.now,
        compositionIsCurrent: () => h.current,
        enableStageApprovalWait: true);
  }

  Future<void> begin() async {
    await app.controls.beginExistingCredentialConfirmation();
    proof = connection();
    await proof!.connect();
    peerClosed = proof!.waitForProofClosure();
    for (var i = 0;
        i < 100 &&
            app.controls.existingCredentialDisplay?.credentialIdentity == null;
        i++) {
      await pumpEventQueue(times: 1);
    }
    expect(
        app.controls.existingCredentialDisplay?.credentialIdentity, isNotNull);
  }

  Future<void> close() async {
    await app.controls.cancelExistingCredentialConfirmation();
    await proof?.close();
    await peerClosed;
    await app.close();
  }
}

final class _DevelopmentControl implements FirstPartyDevelopmentAccess {
  final childSettled = Completer<void>();
  FirstPartyDevelopmentPhase phase = FirstPartyDevelopmentPhase.active;
  bool? bridgePinMissing = false;
  Future<void> Function()? onStop;
  Future<void> Function()? onInitialize;
  Future<void> Function()? onStart, onOpenWindow;
  DateTime? expiresAt;
  Duration maxAccessDuration = const Duration(minutes: 30);
  FirstPartyInitializationObservation? initialization;
  Completer<FirstPartyDevelopmentStatus>? pendingStatus;
  bool failStatus = false;
  int statusReads = 0;
  @override
  Future<FirstPartyDevelopmentStatus> status() async {
    statusReads++;
    if (failStatus) throw StateError('observationUnavailable');
    return pendingStatus?.future ??
        Future.value(FirstPartyDevelopmentStatus(
            phase: phase,
            expiresAt: expiresAt,
            maxAccessDuration: maxAccessDuration,
            bridgePinMissing: bridgePinMissing,
            initialization: initialization,
            pairingWindowOpen: !childSettled.isCompleted));
  }

  @override
  Future<void> waitPairingWindowClosed() => childSettled.future;
  @override
  Future<void> initializeCredentials() async {
    if (onInitialize == null) throw StateError('unused');
    await onInitialize!();
  }

  @override
  Future<void> openPairingWindow() async {
    if (onOpenWindow == null) throw StateError('unused');
    await onOpenWindow!();
  }

  @override
  Future<void> start() async {
    if (onStart == null) throw StateError('unused');
    await onStart!();
  }

  @override
  Future<void> stop() async {
    if (onStop == null) throw StateError('unused');
    await onStop!();
  }
}

final class _PrivateInitializationError implements Exception {
  int stringReads = 0;
  @override
  String toString() {
    stringReads++;
    return 'fixture-secret-key=private-value; private-path; certificate-body';
  }
}

void existingCredentialConfirmationCases() {
  for (final cancellation in ['disconnect', 'view']) {
    test('Enable preflight status preserves $cancellation cancellation',
        () async {
      final f = _ExistingFixture();
      await f.open();
      addTearDown(f.close);
      final development = _DevelopmentControl()
        ..expiresAt =
            f.app.files.s.clock.current.add(const Duration(minutes: 30))
        ..childSettled.complete();
      f.app.controls.installDevelopment(development);
      await f.begin();
      await f.app.controls
          .confirmExistingCredential(f.app.controls.existingCredentialDisplay!);
      final deployment = await development.status();
      final pending =
          development.pendingStatus = Completer<FirstPartyDevelopmentStatus>();
      final reads = development.statusReads;
      Object? failure;
      final enabling = f.app.controls
          .enable(const Duration(minutes: 10))
          .then((_) {}, onError: (Object error) {
        failure = error;
      });
      expect(development.statusReads, reads + 1);
      var settled = false;
      final cancelling = (cancellation == 'disconnect'
              ? f.app.controls.disconnectTransport()
              : f.app.controls.cancelPendingControls())
          .then((_) => settled = true);
      await pumpEventQueue(times: 10);
      final settledBeforeRead = settled;
      development.pendingStatus = null;
      pending.complete(deployment);
      await Future.wait([enabling, cancelling]);
      expect(failure, isA<ExternalAuthException>());
      expect(settledBeforeRead, isFalse);
      final status = await f.app.controls.status();
      expect(status.enabled, isFalse);
      expect(status.connectionPending, isFalse);
      expect(status.connectionSettling, isFalse);
      expect((await f.app.call('open_generation_context'))['error'], isNotNull);
      await f.app.controls.enable(const Duration(minutes: 10));
      expect((await f.app.controls.status()).enabled, isTrue);
      expect(await f.app.context(), isNotEmpty);
    });
  }

  test('Enable preflight status failure settles before a fresh explicit Enable',
      () async {
    final f = _ExistingFixture();
    await f.open();
    addTearDown(f.close);
    final development = _DevelopmentControl()
      ..expiresAt = f.app.files.s.clock.current.add(const Duration(minutes: 30))
      ..childSettled.complete();
    f.app.controls.installDevelopment(development);
    await f.begin();
    await f.app.controls
        .confirmExistingCredential(f.app.controls.existingCredentialDisplay!);
    development.failStatus = true;
    await expectLater(
        f.app.controls.enable(const Duration(minutes: 10)), throwsStateError);
    final status = await f.app.controls.status();
    expect(status.enabled, isFalse);
    expect(status.connectionPending, isFalse);
    expect(status.connectionSettling, isFalse);
    development.failStatus = false;
    await f.app.controls.enable(const Duration(minutes: 10));
    expect(await f.app.context(), isNotEmpty);
  });

  for (final minutes in [120, 480]) {
    for (final outcome in ['readFailure', 'closed', 'failed']) {
      testWidgets('guided duration $minutes survives $outcome observation',
          (tester) async {
        final f = _ExistingFixture();
        f.app.maxEnableDuration = const Duration(hours: 8);
        final development = _DevelopmentControl()
          ..maxAccessDuration = const Duration(hours: 8)
          ..childSettled.complete();
        await tester.binding.setSurfaceSize(const Size(1200, 1800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await interactionRead(tester, () async {
          await f.open();
          development.expiresAt =
              f.app.files.s.clock.current.add(const Duration(hours: 8));
          f.app.controls.installDevelopment(development);
          await f.begin();
          await f.app.controls.confirmExistingCredential(
              f.app.controls.existingCredentialDisplay!);
        });
        addTearDown(() async {
          final pending = development.pendingStatus;
          if (pending != null && !pending.isCompleted) {
            pending.complete(const FirstPartyDevelopmentStatus(
                phase: FirstPartyDevelopmentPhase.closed));
          }
          await tester.pumpWidget(const SizedBox());
          await interactionRead(tester, f.close);
        });
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: FirstPartyExternalControl(
                        access: f.app.controls,
                        guided: true,
                        profileId: f.app.files.s.profile.profileId)))));
        await interactionFrame(tester);
        await tester.tap(find.byType(DropdownButton<int>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('${minutes ~/ 60} 小时').last);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<DropdownButton<int>>(
                    find.byType(DropdownButton<int>).first)
                .value,
            minutes);
        expect(find.text('首次配置 App 凭据'), findsNothing);

        if (outcome == 'readFailure') {
          development.failStatus = true;
        } else {
          await interactionRead(tester, f.app.controls.shutdown);
          development.pendingStatus = Completer<FirstPartyDevelopmentStatus>();
        }
        await interactionFrame(tester, const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        expect(find.text('首次配对与连接诊断'), findsOneWidget);
        expect(find.text('首次配置 App 凭据'), findsNothing);
        if (outcome == 'readFailure') {
          expect(
              tester
                  .widget<FilledButton>(
                      find.widgetWithText(FilledButton, '允许本次访问'))
                  .onPressed,
              isNull);
        } else {
          expect(
              tester
                  .widget<FilledButton>(
                      find.widgetWithText(FilledButton, '连接 Codex'))
                  .onPressed,
              isNull);
        }
        // Expand only after the unavailable projection has built while collapsed.
        await interactionTap(tester, '首次配对与连接诊断');
        expect(find.text('开发连接：不可用（需从桌面 Explorer 启动正常 Debug App）'),
            findsOneWidget);
        for (final dropdown in tester.widgetList<DropdownButton<int>>(
            find.byType(DropdownButton<int>))) {
          expect(dropdown.value, isNull);
          expect(dropdown.onChanged, isNull);
        }
        final enable = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '限时启用'));
        expect(enable.onPressed, isNull);
        if (outcome == 'readFailure') {
          development.failStatus = false;
          await interactionFrame(tester, const Duration(seconds: 1));
          expect(
              tester
                  .widget<DropdownButton<int>>(
                      find.byType(DropdownButton<int>).first)
                  .value,
              minutes);
          expect((await interactionRead(tester, f.app.controls.status)).enabled,
              isFalse);
        } else {
          development.pendingStatus!.complete(FirstPartyDevelopmentStatus(
              phase: outcome == 'closed'
                  ? FirstPartyDevelopmentPhase.closed
                  : FirstPartyDevelopmentPhase.failed));
          await interactionFrame(tester);
          expect(
              find.text(outcome == 'closed'
                  ? '开发连接：已关闭，需正常重启 App'
                  : '开发连接：失败，需保留证据并正常重启 App'),
              findsOneWidget);
          expect(
              tester
                  .widget<FilledButton>(
                      find.widgetWithText(FilledButton, '限时启用'))
                  .onPressed,
              isNull);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  test(
      'guided connection prepares original proof but never confirms or enables',
      () async {
    final f = _ExistingFixture();
    f.app.maxEnableDuration = const Duration(hours: 8);
    await f.open();
    addTearDown(f.close);
    final now = f.app.files.s.clock.current;
    final development = _DevelopmentControl()
      ..expiresAt = now.add(const Duration(hours: 7))
      ..maxAccessDuration = const Duration(hours: 8)
      ..childSettled.complete()
      ..onOpenWindow = () async {
        f.proof = f.connection();
        await f.proof!.connect();
        f.peerClosed = f.proof!.waitForProofClosure();
      };
    f.app.controls.installDevelopment(development);
    final id = f.app.files.s.profile.profileId;
    await f.app.controls.prepareExistingConnection(id, available: () => true);
    for (var i = 0;
        i < 100 &&
            f.app.controls.existingCredentialDisplay?.credentialIdentity ==
                null;
        i++) {
      await pumpEventQueue(times: 1);
    }
    expect((await f.app.controls.status()).pairing, PairingState.unpaired);
    expect((await f.app.controls.status()).enabled, isFalse);
    await expectLater(
        f.app.controls.enable(const Duration(hours: 8)), throwsA(anything));
    final display = f.app.controls.existingCredentialDisplay!;
    await f.app.controls.confirmExistingCredential(display);
    await f.peerClosed;
    expect(
        (await f.app.controls.status()).pairing, PairingState.pairedDisabled);
    expect((await f.app.controls.status()).enabled, isFalse);
    await f.app.controls.enable(const Duration(hours: 8));
    final enabled = await f.app.controls.status();
    expect(enabled.enabled, isTrue);
    expect(enabled.expiresAt, development.expiresAt);
    await f.app.controls.disable();
    await expectLater(
        f.app.controls.enable(const Duration(hours: 9)), throwsA(anything));
    expect((await f.app.controls.status()).enabled, isFalse);
    f.app.files.s.clock.current = development.expiresAt!;
    await expectLater(
        f.app.controls.enable(const Duration(minutes: 30)), throwsA(anything));
  });

  test('guided connection stops after its view is cancelled during startup',
      () async {
    final f = _ExistingFixture();
    await f.open();
    addTearDown(f.close);
    var available = true, opened = 0;
    final entered = Completer<void>(), settle = Completer<void>();
    final development = _DevelopmentControl()
      ..phase = FirstPartyDevelopmentPhase.inactive
      ..childSettled.complete()
      ..onOpenWindow = () async {
        opened++;
      }
      ..onStart = () {
        entered.complete();
        return settle.future;
      };
    f.app.controls.installDevelopment(development);
    final work = f.app.controls.prepareExistingConnection(
        f.app.files.s.profile.profileId,
        available: () => available);
    final rejected = expectLater(work, throwsA(isA<ExternalAuthException>()));
    await entered.future;
    available = false;
    development.phase = FirstPartyDevelopmentPhase.active;
    settle.complete();
    await rejected;
    expect(opened, 0);
    expect(f.app.controls.existingCredentialDisplay, isNull);
    expect((await f.app.controls.status()).enabled, isFalse);
  });

  testWidgets(
      'guided connection names STAGE before Review and keeps technical controls collapsed',
      (tester) async {
    final f = _ExistingFixture();
    await tester.runAsync(f.open);
    final development = _DevelopmentControl()
      ..expiresAt = f.app.files.s.clock.current.add(const Duration(hours: 8))
      ..maxAccessDuration = const Duration(hours: 8)
      ..childSettled.complete();
    f.app.controls.installDevelopment(development);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: FirstPartyExternalControl(
          access: f.app.controls,
          guided: true,
          profileId: f.app.files.s.profile.profileId,
          profileName: 'Synthetic connection'),
    ))));
    await settleGenerated(tester);
    expect(find.text('连接 Codex'), findsOneWidget);
    expect(find.text('暂存确认'), findsOneWidget);
    expect(find.textContaining('成功发布后才会出现在'), findsOneWidget);
    expect(find.text('首次配置 App 凭据'), findsNothing);
    expect(find.text('Profile ID：'), findsNothing);
    expect((await tester.runAsync(f.app.controls.status))!.enabled, isFalse);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final width in [720.0, 1100.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('连接 Codex'), findsOneWidget);
    }
  });

  for (final outcome in ['copied', 'pageClosed', 'clipboardFailed']) {
    testWidgets('Completion copy during refresh: $outcome', (tester) async {
      final f = WindowsAppTransportFixture()
        ..pairingOverride =
            (owner) => WindowsAppPublicPairingHandoff(owner: owner);
      await interactionRead(tester, () => f.open(enroll: false, stage: false));
      final bridge = WindowsBridgePublicPairing(owner: f.pairing.bridge);
      final development = _DevelopmentControl()..childSettled.complete();
      f.controls.installDevelopment(development);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await interactionRead(tester, () async {
          await bridge.close();
          await f.close();
        });
      });
      await interactionRead(tester, () async {
        bridge.beginEnrollment(displayLabel: 'Copy fixture', clientBuild: '1');
        await f.controls.select(f.files.s.profile.profileId);
        await f.controls
            .requestPairing(submissionId: bridge.display().submissionId!);
        await bridge.importTrust(await f.controls.exportPairingTrust());
        bridge.confirmInitial(bridge.display().initialDigest!);
        await f.controls.approvePairing();
        await f.controls.completePairing();
      });
      var clipboard = 'previous Trust fixture';
      var writes = 0;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          writes++;
          if (outcome == 'clipboardFailed') {
            throw PlatformException(code: 'fixture_copy_failure');
          }
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.binding.setSurfaceSize(const Size(1600, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(interactionApp(f.controls));
      await interactionFrame(tester);
      await interactionTap(tester, '导出 Completion 公共数据');
      await interactionTap(tester, '查看公共交接数据');
      final displayed = tester
          .widget<SelectableText>(
              find.byKey(const Key('external-public-export')))
          .data!;
      final waiting =
          development.pendingStatus = Completer<FirstPartyDevelopmentStatus>();
      await interactionFrame(tester, const Duration(seconds: 1));
      await interactionTap(tester, '复制 Completion 公共数据');
      expect(writes, 0);
      expect(clipboard, 'previous Trust fixture');
      expect(find.text('正在核对并复制 Completion 公共数据…'), findsOneWidget);
      if (outcome == 'pageClosed') {
        await tester.pumpWidget(const SizedBox());
      }
      development.pendingStatus = null;
      waiting.complete(const FirstPartyDevelopmentStatus(
          phase: FirstPartyDevelopmentPhase.active));
      await interactionFrame(tester);
      if (outcome == 'copied') {
        expect(writes, 1);
        expect(clipboard, displayed);
        expect(find.text('已复制 Completion 公共数据。'), findsOneWidget);
      } else {
        expect(writes, outcome == 'pageClosed' ? 0 : 1);
        expect(clipboard, 'previous Trust fixture');
        expect(find.text('已复制 Completion 公共数据。'), findsNothing);
        if (outcome == 'clipboardFailed') {
          expect(find.text('复制未确认，请勿使用剪贴板中的旧数据。'), findsOneWidget);
        }
      }
      expect(f.pairing.native.calls.credentialFiles[4], isNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final race in [false, true]) {
    test(
        'association recovery original Host revoke survives shutdown race=$race',
        () async {
      final f = _RecoveryFixture();
      await f.open(grantless: true);
      addTearDown(f.close);
      final displayed = await f.app.controls.inspectAssociationForRevocation();
      final before =
          await f.app.files.s.authorization.read(displayed.profileId);
      final issuer =
          Uint8List.fromList(f.app.pairing.native.calls.credentialFiles[1]!);
      final server =
          Uint8List.fromList(f.app.pairing.native.calls.credentialFiles[2]!);
      Future<void>? monitorClose;
      if (race) {
        f.app.appProcess.onStop = () {
          monitorClose ??= f.app.controls.shutdown();
          unawaited(monitorClose!
              .then((_) {}, onError: (Object _, StackTrace __) {}));
        };
      }
      await f.app.controls.confirmAssociationRevocation(displayed);
      await monitorClose;
      final observation = f.app.controls.revocationObservation!;
      expect(observation.revoke, FirstPartyObservedResult.returned);
      expect(observation.close, FirstPartyObservedResult.returned);
      expect(observation.failure, isNull);
      expect(observation.closeFailure, isNull);
      expect(f.development.phase, FirstPartyDevelopmentPhase.closed);
      expect(f.stops, 1);
      expect(f.app.host.phase, WindowsTlsHostPhase.closed);
      expect(f.app.pairing.native.owner.isClosed, isTrue);
      final tombstone = AssociationObjectCodec.decode(Uint8List.fromList(
              f.app.pairing.native.calls.associationFile!.sublist(2)))
          .single
          .association;
      expect(tombstone.revoked, isTrue);
      expect(tombstone.revision, displayed.revision + 1);
      expect(tombstone.credentialIdentity, displayed.credentialIdentity);
      final after = await f.app.files.s.authorization.read(displayed.profileId);
      expect(after.profile.grantRevision, before.profile.grantRevision);
      expect(after.profile.revokedAtUtcMs, before.profile.revokedAtUtcMs);
      expect(after.grant, isNull);
      expect(f.app.pairing.native.calls.credentialFiles[1], issuer);
      expect(f.app.pairing.native.calls.credentialFiles[2], server);
      expect(f.app.pairing.native.calls.credentialFiles[4], isNull);
      await expectLater(f.app.controls.confirmAssociationRevocation(displayed),
          throwsA(isA<ExternalAuthException>()));
    });
  }

  for (final changed in [
    'cancel',
    'selection',
    'epoch',
    'grant',
    'profile',
    'peer',
    'expiry',
    'pinUnknown',
    'disconnect'
  ]) {
    test('association recovery rejects old confirmation after $changed',
        () async {
      final f = _RecoveryFixture();
      await f.open();
      addTearDown(f.close);
      final displayed = await f.app.controls.inspectAssociationForRevocation();
      final original =
          Uint8List.fromList(f.app.pairing.native.calls.associationFile!);
      switch (changed) {
        case 'cancel':
          f.app.controls.cancelAssociationRecovery();
        case 'selection':
          await f.app.controls.select(displayed.profileId);
        case 'epoch':
          f.app.pairing.native.owner.invalidateAssociationSnapshots();
        case 'grant' || 'profile':
          final view = f.app.policy.openView();
          final ref = await view.select(displayed.profileId);
          final record = await view.read(ref);
          if (changed == 'grant') {
            await view.revokeGrant(ref, record.profile.grantRevision);
          } else {
            await view.revokeProfile(ref, record.profile.grantRevision);
          }
          view.close();
        case 'peer' || 'expiry':
          f.admitted = false;
        case 'pinUnknown':
          f.development.bridgePinMissing = null;
        case 'disconnect':
          await f.app.controls.disconnectTransport();
      }
      await expectLater(f.app.controls.confirmAssociationRevocation(displayed),
          throwsA(isA<ExternalAuthException>()));
      expect(f.stops, 0);
      expect(f.app.controls.revocationObservation, isNull);
      expect(f.app.pairing.native.calls.associationFile, original);
    });
  }

  test(
      'association recovery is absent without explicit development installation',
      () async {
    final f = _RecoveryFixture();
    await f.open(installed: false);
    addTearDown(f.close);
    expect(f.app.controls.associationRecoveryAvailable, isFalse);
    await expectLater(f.app.controls.inspectAssociationForRevocation(),
        throwsA(isA<ExternalAuthException>()));
  });

  test('association recovery cancelled during read cannot dispatch late',
      () async {
    final f = _RecoveryFixture();
    await f.open();
    addTearDown(f.close);
    final displayed = await f.app.controls.inspectAssociationForRevocation();
    final blocked =
        f.development.pendingStatus = Completer<FirstPartyDevelopmentStatus>();
    final action = f.app.controls.confirmAssociationRevocation(displayed);
    final refused = expectLater(action, throwsA(isA<ExternalAuthException>()));
    f.app.controls.cancelAssociationRecovery();
    blocked.complete(const FirstPartyDevelopmentStatus(
        phase: FirstPartyDevelopmentPhase.active, bridgePinMissing: true));
    await refused;
    expect(f.stops, 0);
    expect(f.app.controls.revocationObservation, isNull);
  });

  test(
      'association recovery retains unknown close after original Host returned',
      () async {
    final f = _RecoveryFixture();
    await f.open();
    addTearDown(f.close);
    final displayed = await f.app.controls.inspectAssociationForRevocation();
    final secret = _PrivateInitializationError();
    f.development.onStop = () async => throw secret;
    await expectLater(f.app.controls.confirmAssociationRevocation(displayed),
        throwsA(same(secret)));
    final observed = f.app.controls.revocationObservation!;
    expect(observed.revoke, FirstPartyObservedResult.returned);
    expect(observed.close, FirstPartyObservedResult.failed);
    expect(observed.failure, isNull);
    expect(observed.closeFailure!.code, 'unknown');
    expect(secret.stringReads, 0);
    await expectLater(f.app.controls.confirmAssociationRevocation(displayed),
        throwsA(isA<ExternalAuthException>()));
  });

  test(
      'association recovery failed Host remains unconfirmed with retained custody',
      () async {
    final f = _RecoveryFixture();
    await f.open();
    // Explicit disposal of Fake quarantine only; never retries a product close.
    addTearDown(() async {
      f.app.plan.dispose();
      f.app.policy.invalidate();
      await f.app.files.close();
      await f.app.pairing.close();
    });
    final displayed = await f.app.controls.inspectAssociationForRevocation();
    f.app.pairing.native.calls.unknownAfterCommit = true;
    await expectLater(f.app.controls.confirmAssociationRevocation(displayed),
        throwsA(anything));
    final observed = f.app.controls.revocationObservation!;
    expect(observed.revoke, FirstPartyObservedResult.failed);
    expect(observed.close, FirstPartyObservedResult.failed);
    expect(observed.failure, isNotNull);
    expect(f.app.pairing.native.owner.isClosed, isFalse);
    expect(f.app.host.phase, WindowsTlsHostPhase.closing);
    // The original fake committed before reporting unknown. Never say rollback.
    final tombstone = AssociationObjectCodec.decode(Uint8List.fromList(
            f.app.pairing.native.calls.associationFile!.sublist(2)))
        .single
        .association;
    expect(tombstone.revoked, isTrue);
    await expectLater(f.app.controls.confirmAssociationRevocation(displayed),
        throwsA(isA<ExternalAuthException>()));
  });

  testWidgets(
      'association recovery UI binds full snapshot and waits original terminal result',
      (tester) async {
    final f = _RecoveryFixture();
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(f.open);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FirstPartyExternalControl(access: f.app.controls)))));
    await settleGenerated(tester);
    await interactionTap(tester, '核对配对残留关联');
    await settleGenerated(tester);
    expect(
        find.text('身份：${sha256Hex(vectorBytes('clientDer'))}'), findsOneWidget);
    expect(find.text('安装标识：${f.app.publicMaterial.installationId}'),
        findsOneWidget);
    expect(find.text('关联 Revision：1；已撤销：false'), findsOneWidget);
    await interactionTap(tester, '取消');
    await settleGenerated(tester);
    expect(f.app.controls.revocationObservation, isNull);
    await interactionTap(tester, '核对配对残留关联');
    await settleGenerated(tester);
    await interactionTap(tester, '撤销此关联并关闭开发连接');
    await settleGenerated(tester);
    await interactionTap(tester, '连接诊断');
    expect(find.text('关联撤销：原 Host 结果 returned；后续关闭 returned'), findsOneWidget);
    expect(find.text('关联已撤销，原运行时已关闭。请正常重启 App 后重新配对。'), findsOneWidget);
    expect(find.text('开发连接：已关闭，需正常重启 App'), findsOneWidget);
  });

  testWidgets(
      'App pairing diagnosis redacts unknown and survives closed controls',
      (tester) async {
    final f = CredentialAppHarness();
    final secret = _PrivateInitializationError();
    await tester.runAsync(() async {
      await f.open();
      await f.controls.select(f.files.s.profile.profileId);
      await f.controls.requestPairing();
      await f.controls.approvePairing();
      f.proof = () => Error.throwWithStackTrace(
          secret, StackTrace.fromString('fixture-private-stack'));
      await expectLater(f.controls.completePairing(), throwsA(same(secret)));
      await f.controls.shutdown();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FirstPartyExternalControl(access: f.controls)))));
    await settleGenerated(tester);
    await interactionTap(tester, '连接诊断');
    expect(find.text('App 配对阶段：complete；原结果 failed'), findsOneWidget);
    expect(find.text('App 配对首个失败：complete/unknown'), findsOneWidget);
    for (final value in [
      'fixture-secret-key',
      'private-value',
      'private-path',
      'certificate-body',
      'fixture-private-stack'
    ]) {
      expect(find.textContaining(value), findsNothing);
    }
    expect(secret.stringReads, 0);
  });

  for (final phase in FirstPartyAppPairingPhase.values) {
    test(
        'App pairing diagnosis retains first ${phase.name} failure after shutdown',
        () async {
      final f = CredentialAppHarness();
      await f.open();
      addTearDown(f.close);
      await f.controls.select(f.files.s.profile.profileId);
      if (phase == FirstPartyAppPairingPhase.display) {
        await f.controls.requestPairing();
        f.elapsed += const Duration(minutes: 1);
        await f.controls.status();
      } else {
        final action = switch (phase) {
          FirstPartyAppPairingPhase.request => () =>
              f.controls.requestPairing(submissionId: 'bad'),
          FirstPartyAppPairingPhase.approve => f.controls.approvePairing,
          FirstPartyAppPairingPhase.complete => f.controls.completePairing,
          FirstPartyAppPairingPhase.exportTrust => () async {
              await f.controls.exportPairingTrust();
            },
          FirstPartyAppPairingPhase.exportCompletion => () async {
              await f.controls.exportPairingCompletion();
            },
          FirstPartyAppPairingPhase.display => throw StateError('unreachable'),
        };
        await expectLater(action(), throwsA(anything));
      }
      final first = f.controls.pairingObservation!.firstFailure!;
      expect(first.phase, phase);
      expect(first.failure.code, isNot('unknown'));
      await f.controls.shutdown();
      await expectLater(f.controls.approvePairing(), throwsA(anything));
      expect(f.controls.pairingObservation!.firstFailure, same(first));
    });
  }

  testWidgets(
      'initialization diagnosis UI shows both fixed failures without private text',
      (tester) async {
    final f = _ExistingFixture();
    final development = _DevelopmentControl()
      ..phase = FirstPartyDevelopmentPhase.inactive
      ..childSettled.complete();
    final primary = _PrivateInitializationError();
    final cleanup = _PrivateInitializationError();
    final operation = DevelopmentCredentialInitialization();
    development.onInitialize = () async {
      try {
        operation.run(
            load: () {},
            acquire: () {},
            initializeP25: () => Error.throwWithStackTrace(primary,
                StackTrace.fromString('fixture-private-stack-primary')),
            postAdmission: () => fail('post-admission must not run'),
            close: () => Error.throwWithStackTrace(cleanup,
                StackTrace.fromString('fixture-private-stack-cleanup')));
      } finally {
        development.phase = FirstPartyDevelopmentPhase.failed;
        development.initialization = operation.observation;
      }
    };
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await f.open();
      f.app.controls.installDevelopment(development);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FirstPartyExternalControl(access: f.app.controls)))));
    await settleGenerated(tester);
    expect(find.textContaining('首次配置诊断：'), findsNothing);
    await tester.tap(find.text('首次配置 App 凭据'));
    await settleGenerated(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('确认首次配置'));
      await pumpEventQueue(times: 30);
    });
    await settleGenerated(tester);
    await tester.ensureVisible(find.text('连接诊断'));
    await tester.tap(find.text('连接诊断'));
    await settleGenerated(tester);
    expect(find.text('首次配置诊断：关闭 Owner（close）'), findsOneWidget);
    expect(find.text('Owner：已实际返回'), findsOneWidget);
    expect(find.text('原 close：失败，保留原退出屏障'), findsOneWidget);
    expect(find.text('主失败：初始化凭据（P25） / unknown'), findsOneWidget);
    expect(find.text('清理失败：关闭 Owner（close） / unknown'), findsOneWidget);
    expect(find.text('诊断仅记录原操作结果，不证明回滚或零副作用。'), findsOneWidget);
    expect(development.initialization!.primaryFailure!.code,
        FirstPartyInitializationFailureCode.unknown);
    expect(development.initialization!.cleanupFailure!.code,
        FirstPartyInitializationFailureCode.unknown);
    expect(primary.stringReads, 0);
    expect(cleanup.stringReads, 0);
    for (final secret in [
      'fixture-secret-key',
      'private-value',
      'private-path',
      'certificate-body',
      'fixture-private-stack'
    ]) {
      expect(find.textContaining(secret), findsNothing);
    }
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('首次配置 App 凭据'), matching: find.byType(OutlinedButton)));
    expect(button.onPressed, isNull);
  });

  test(
      'development UI production phase retains terminal results without admission',
      () {
    for (final phase in FirstPartyDevelopmentPhase.values) {
      expect(developmentStatusPhase(phase: phase, localAvailable: true), phase);
      expect(
          developmentStatusPhase(phase: phase, localAvailable: false),
          phase == FirstPartyDevelopmentPhase.closed ||
                  phase == FirstPartyDevelopmentPhase.failed
              ? phase
              : FirstPartyDevelopmentPhase.unavailable);
    }
  });

  for (final terminal in [
    FirstPartyDevelopmentPhase.closed,
    FirstPartyDevelopmentPhase.failed
  ]) {
    testWidgets('development UI observes ${terminal.name} after access closes',
        (tester) async {
      final f = _ExistingFixture();
      final development = _DevelopmentControl();
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await f.open();
        f.app.controls.installDevelopment(development);
        await f.begin();
      });
      addTearDown(() async {
        if (!development.childSettled.isCompleted) {
          development.childSettled.complete();
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.close);
      });
      development.onStop = () async {
        development.childSettled.complete();
        await f.app.controls.shutdown();
        development.phase = terminal;
        if (terminal == FirstPartyDevelopmentPhase.failed) {
          throw StateError('closeUnavailable');
        }
      };
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: FirstPartyExternalControl(access: f.app.controls)))));
      await settleGenerated(tester);
      expect(find.text('开发连接：已显式启用，最多 30 分钟'), findsOneWidget);
      expect(find.textContaining('凭据指纹：'), findsOneWidget);
      await tester.ensureVisible(find.text('关闭开发连接'));
      await tester.runAsync(() async {
        await tester.tap(find.text('关闭开发连接'));
        await pumpEventQueue(times: 30);
      });
      await settleGenerated(tester);
      expect(
          find.text(terminal == FirstPartyDevelopmentPhase.closed
              ? '开发连接：已关闭，需正常重启 App'
              : '开发连接：失败，需保留证据并正常重启 App'),
          findsOneWidget);
      expect(find.text('开发连接：已显式启用，最多 30 分钟'), findsNothing);
      expect(find.textContaining('凭据指纹：'), findsNothing);
      for (final label in [
        '首次配置 App 凭据',
        '开启开发连接',
        '打开独立 Bridge 配对窗口',
        '关闭开发连接'
      ]) {
        final button = tester.widget<ButtonStyleButton>(find.ancestor(
            of: find.text(label),
            matching: find
                .byWidgetPredicate((widget) => widget is ButtonStyleButton)));
        expect(button.onPressed, isNull, reason: label);
      }
    });
  }

  testWidgets('development UI requires a missing Pin for initial pairing',
      (tester) async {
    final f = _ExistingFixture();
    final development = _DevelopmentControl()..childSettled.complete();
    await tester.runAsync(() async {
      await f.open();
      f.app.controls.installDevelopment(development);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FirstPartyExternalControl(access: f.app.controls)))));
    await settleGenerated(tester);
    OutlinedButton initial() => tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '打开独立 Bridge 配对窗口'));
    expect(initial().onPressed, isNull);
    expect(find.byKey(const Key('external-submission-id')), findsNothing);
    expect(find.text('请求配对'), findsNothing);
    expect(find.text('确认配对'), findsNothing);
    expect(find.text('验证配对证明'), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '验证既有 Bridge 凭据'))
            .onPressed,
        isNotNull);
    development.bridgePinMissing = null;
    await tester.pump(const Duration(seconds: 1));
    await settleGenerated(tester);
    expect(initial().onPressed, isNull);
    development.bridgePinMissing = true;
    await tester.pump(const Duration(seconds: 1));
    await settleGenerated(tester);
    expect(initial().onPressed, isNotNull);
    development.failStatus = true;
    await tester.pump(const Duration(seconds: 1));
    await settleGenerated(tester);
    expect(find.text('开发连接：已显式启用，最多 30 分钟'), findsNothing);
    expect(find.text('开发连接：不可用（需从桌面 Explorer 启动正常 Debug App）'), findsOneWidget);
    expect(initial().onPressed, isNull);
  });

  testWidgets(
      'development UI serializes terminal reads and discards replaced status',
      (tester) async {
    final f = _ExistingFixture();
    final development = _DevelopmentControl()..childSettled.complete();
    await tester.runAsync(() async {
      await f.open();
      f.app.controls.installDevelopment(development);
      await f.begin();
    });
    addTearDown(() async {
      final pending = development.pendingStatus;
      if (pending != null && !pending.isCompleted) {
        pending.complete(const FirstPartyDevelopmentStatus(
            phase: FirstPartyDevelopmentPhase.closed));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    Widget app(FirstPartyExternalAccess access) => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FirstPartyExternalControl(access: access))));
    await tester.pumpWidget(app(f.app.controls));
    await settleGenerated(tester);
    expect(find.text('开发连接：已显式启用，最多 30 分钟'), findsOneWidget);
    expect(find.textContaining('凭据指纹：'), findsOneWidget);
    await interactionRead(tester, f.app.controls.shutdown);
    final before = development.statusReads;
    development.pendingStatus = Completer<FirstPartyDevelopmentStatus>();
    await tester.pump(const Duration(seconds: 1));
    await settleGenerated(tester);
    expect(development.statusReads, before + 1);
    expect(find.text('开发连接：已显式启用，最多 30 分钟'), findsNothing);
    expect(find.textContaining('凭据指纹：'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(development.statusReads, before + 1);
    final replacement = FirstPartyExternalAccess(
        policy: f.app.policy, compositionIsCurrent: () => true);
    addTearDown(replacement.shutdown);
    await tester.pumpWidget(app(replacement));
    await settleGenerated(tester);
    expect(find.textContaining('开发连接：'), findsNothing);
    expect(find.textContaining('凭据指纹：'), findsNothing);
    development.pendingStatus!.complete(const FirstPartyDevelopmentStatus(
        phase: FirstPartyDevelopmentPhase.failed));
    await settleGenerated(tester);
    expect(find.textContaining('开发连接：'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paired policy editor never claims runtime is unpaired',
      (tester) async {
    final f = _ExistingFixture();
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await f.open();
      await f.begin();
      await f.app.controls
          .confirmExistingCredential(f.app.controls.existingCredentialDisplay!);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(MaterialApp(
        home: FirstPartyExternalScope(
            access: f.app.controls,
            child: ExternalAuthorizationScreen(service: f.app.policy))));
    await settleGenerated(tester);
    expect(find.text('身份已确认，等待允许访问'), findsOneWidget);
    expect(find.textContaining('未配对 / 未启用'), findsNothing);
    final profile = find.byKey(ValueKey(f.app.files.s.profile.profileId));
    await tester.ensureVisible(profile);
    await tester.runAsync(() async {
      await tester.tap(profile);
      await pumpEventQueue(times: 30);
    });
    await settleGenerated(tester);
    expect(find.text('已保存访问规则'), findsOneWidget);
    await tester.ensureVisible(find.text('撤销 Grant'));
    await tester.tap(find.text('撤销 Grant'));
    await tester.pump();
    expect(find.text('撤销当前访问规则。此操作不修改已保存的配对凭据。'), findsOneWidget);
    expect(find.textContaining('客户端仍未配对'), findsNothing);
    await tester.tap(find.text('取消').last);
    await settleGenerated(tester);
  });

  testWidgets('guided profile change withdraws a late identity confirmation',
      (tester) async {
    final f = _ExistingFixture();
    final development = _DevelopmentControl()..childSettled.complete();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await f.open();
      f.app.controls.installDevelopment(development);
      await f.begin();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    Widget page(String profile) => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FirstPartyExternalControl(
                    access: f.app.controls,
                    guided: true,
                    profileId: profile))));
    await tester.pumpWidget(page(f.app.files.s.profile.profileId));
    await settleGenerated(tester);
    await interactionTap(tester, '确认本次身份');
    // The pending human decision intentionally keeps the progress indicator live.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.pumpWidget(page('another-profile'));
    await tester.runAsync(() => pumpEventQueue(times: 30));
    await tester.pump();
    await interactionTap(tester, '确认本次身份');
    await settleGenerated(tester);
    await tester.runAsync(() async {
      expect((await f.app.controls.status()).pairing, PairingState.unpaired);
      expect(f.app.controls.existingCredentialDisplay, isNull);
    });
  });

  testWidgets(
      'first-party identity dialog remains distinct from Enable and waits child settlement',
      (tester) async {
    final f = _ExistingFixture();
    final development = _DevelopmentControl();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await f.open();
      f.app.controls.installDevelopment(development);
      await f.begin();
    });
    addTearDown(() async {
      if (!development.childSettled.isCompleted) {
        development.childSettled.complete();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FirstPartyExternalControl(access: f.app.controls)))));
    await settleGenerated(tester);
    final approve = find.widgetWithText(FilledButton, '确认本次身份');
    expect(approve, findsOneWidget);
    await tester.ensureVisible(approve);
    await tester.runAsync(() async {
      await tester.tap(approve);
      await tester.pump();
    });
    await settleGenerated(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('仅确认这次运行的既有身份'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '确认本次身份').last);
      await tester.pump();
    });
    await settleGenerated(tester);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '限时启用'))
            .onPressed,
        isNull);
    await tester.runAsync(() async {
      development.childSettled.complete();
      await pumpEventQueue(times: 20);
    });
    final paired = find.text('配对状态：已配对，访问已禁用');
    for (var i = 0; i < 100 && paired.evaluate().isEmpty; i++) {
      await tester.runAsync(() => pumpEventQueue(times: 1));
      await tester.pump();
    }
    expect(paired, findsOneWidget);
    expect(find.text('访问已禁用'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test('existing identity confirmation grants no missing Grant or Enable',
      () async {
    final f = _ExistingFixture();
    await f.open(grantless: true);
    addTearDown(f.close);
    await f.begin();
    await f.app.controls
        .confirmExistingCredential(f.app.controls.existingCredentialDisplay!);
    expect(
        (await f.app.controls.status()).pairing, PairingState.pairedDisabled);
    await expectLater(
        f.app.controls.enable(const Duration(minutes: 5)), throwsA(anything));
    expect((await f.app.controls.status()).enabled, isFalse);
    expect((await f.app.call('open_generation_context'))['error'], isNotNull);
  });
  test(
      'fresh existing proof confirms only P0 identity and preserves credential stores',
      () async {
    final f = _ExistingFixture();
    await f.open();
    addTearDown(f.close);
    expect((await f.app.controls.status()).pairing, PairingState.unpaired);
    // A historical Proposal is seeded through the existing isolated P3 owner.
    // The fresh product runtime still has no Pairing, Enable or Session.
    final old = f.app.files.s;
    old.trust.enable(old.principal, const Duration(minutes: 5));
    old.session = old.trust
        .openSession(old.trust.authenticate(old.credentials.authentication));
    final originalTarget = (await old.localSession.targets()).firstWhere(
        (choice) =>
            choice.target.bankName == 'bank' &&
            choice.target.projectId == f.app.files.project);
    final originalApproval = await old.service
        .approveTarget(old.session, originalTarget.target, const []);
    await old.stage(
        key: 'original-before-confirmation', approved: originalApproval);
    expect(await old.h.count('generated_question_proposals'), 1);
    await expectLater(
        f.app.controls.enable(const Duration(minutes: 5)), throwsA(anything));
    await f.begin();
    final association =
        List<int>.from(f.app.pairing.native.calls.associationFile!);
    final pin = List<int>.from(f.app.pairing.native.calls.credentialFiles[4]!);
    final displayed = f.app.controls.existingCredentialDisplay!;
    expect(f.client!.writes, isEmpty);
    expect(f.server!.writes, isEmpty);
    expect(await f.app.controls.authenticatedSession(), isNull);
    await f.app.controls.confirmExistingCredential(displayed);
    await f.peerClosed;
    final status = await f.app.controls.status();
    expect(status.pairing, PairingState.pairedDisabled);
    expect(status.enabled, isFalse);
    expect(status.connected, isFalse);
    expect(f.app.pairing.native.calls.associationFile, association);
    expect(f.app.pairing.native.calls.credentialFiles[4], pin);
    await f.app.controls.enable(const Duration(minutes: 5));
    final context = await f.app.context();
    expect(context, isNotEmpty);
    expect(
        f.app.data(await f.app.call('get_question_proposal', {
          'submissionKey': 'original-before-confirmation'
        }))['lifecycleStatus'],
        'pending_review');
    expect(await old.h.count('generated_question_proposals'), 1);
    expect(f.app.host.phase, WindowsTlsHostPhase.ready);
    await expectLater(
        f.app.controls.confirmExistingCredential(displayed), throwsA(anything));
  });

  for (final mode in [
    'cancel',
    'eof',
    'revision',
    'expiry',
    'trailing',
    'close'
  ]) {
    test(
        'existing proof $mode rejects late confirmation and drains original channel',
        () async {
      final f = _ExistingFixture();
      await f.open();
      addTearDown(f.close);
      await f.begin();
      final old = f.app.controls.existingCredentialDisplay!;
      switch (mode) {
        case 'cancel':
          await f.app.controls.cancelExistingCredentialConfirmation();
        case 'eof':
          await f.proof!.close();
        case 'revision':
          await f.app.files.grant();
        case 'expiry':
          f.app.pairing.advance(const Duration(seconds: 31));
          f.app.files.s.clock.current = f.app.pairing.native.now;
        case 'trailing':
          await f.client!.write(Uint8List.fromList([1]));
        case 'close':
          await f.app.startup.close();
      }
      await expectLater(
          f.app.controls.confirmExistingCredential(old), throwsA(anything));
      await f.app.host.whenConnectionsSettled;
      await f.proof!.close();
      expect(f.app.controls.existingCredentialDisplay, isNull);
      expect(await f.app.files.s.h.count('generated_question_proposals'), 0);
      if (mode != 'close') {
        expect((await f.app.controls.status()).pairing, PairingState.unpaired);
      }
    });
  }

  test(
      'confirmation joins original channel close and admits no second candidate',
      () async {
    final f = _ExistingFixture();
    await f.open();
    addTearDown(f.close);
    await f.begin();
    final release = f.server!.closing = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var finished = false;
    final confirming = f.app.controls
        .confirmExistingCredential(f.app.controls.existingCredentialDisplay!)
        .then((_) => finished = true);
    await pumpEventQueue(times: 20);
    expect(finished, isFalse);
    await expectLater(f.app.controls.beginExistingCredentialConfirmation(),
        throwsA(anything));
    expect(f.app.pairing.native.owner.isClosed, isFalse);
    release.complete();
    await confirming;
    expect(finished, isTrue);
  });

  test('external objects cannot mint existing-confirmation evidence', () async {
    final f = _ExistingFixture();
    await f.open();
    addTearDown(f.close);
    final verifier = f.app.host.verification;
    final reference = await verifier.management
        .selectProfile(f.app.files.s.profile.profileId);
    final boundary = (f.app.host.binding! as VnextMcpAppComposition)
        .stages
        .runtimeAdmission
        .trust
        .credentials as ExternalCredentialBoundary;
    await expectLater(boundary.prepareExistingConfirmation(reference, Object()),
        throwsA(anything));
    expect((await f.app.controls.status()).pairing, PairingState.unpaired);
  });

  test('proof close failure keeps the original slot and App Owner quarantined',
      () async {
    final f = _ExistingFixture();
    await f.open();
    // Explicit test-only quarantine disposal after assertions, never a product retry.
    addTearDown(() async {
      try {
        await f.app.startup.close();
      } catch (_) {}
      f.server!.failClose = false;
      await f.server!.close();
      await f.proof!.close();
      f.app.plan.dispose();
      f.app.policy.invalidate();
      await f.app.files.close();
      await f.app.pairing.close();
    });
    await f.begin();
    f.server!.failClose = true;
    await expectLater(
        f.app.controls.confirmExistingCredential(
            f.app.controls.existingCredentialDisplay!),
        throwsA(anything));
    expect(f.app.host.budget.isUsable, isFalse);
    expect(f.app.controls.existingCredentialDisplay!.settling, isTrue);
    await expectLater(f.app.controls.beginExistingCredentialConfirmation(),
        throwsA(anything));
    await expectLater(f.app.startup.close(), throwsA(anything));
    expect(f.app.pairing.native.owner.isClosed, isFalse);
  });

  test('App close drains an in-flight proof check before releasing the Owner',
      () async {
    final f = _ExistingFixture();
    await f.open();
    addTearDown(f.close);
    await f.begin();
    final store = f.app.pairing.associations;
    final id = f.app.files.s.profile.profileId;
    final record = (await store.read(id)).record!;
    final reached = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final held = store.register(
        profileId: id,
        installationId: record.installationId,
        credentialIdentity: record.credentialIdentity,
        expectedRevision: record.revision,
        validateManagement: () async {
          reached.complete();
          await release.future;
        });
    await reached.future;
    final confirming = expectLater(
        f.app.controls.confirmExistingCredential(
            f.app.controls.existingCredentialDisplay!),
        throwsA(anything));
    await pumpEventQueue(times: 2);
    var closed = false;
    final closing = f.app.startup.close().then((_) => closed = true);
    await pumpEventQueue(times: 5);
    expect(closed, isFalse);
    expect(f.app.pairing.native.owner.isClosed, isFalse);
    release.complete();
    await held;
    await confirming;
    await closing;
    expect(f.app.pairing.native.owner.isClosed, isTrue);
    expect(await f.app.files.s.h.count('generated_question_proposals'), 0);
  });
}
