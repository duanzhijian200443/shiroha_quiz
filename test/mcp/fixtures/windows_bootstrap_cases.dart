import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_acquisition.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_bootstrap.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_registration.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/data/external/windows_codex_client.dart';

import '../../application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../../data/external/windows_credential_object_store_test.dart'
    as objects;
import '../../data/external/windows_pairing_test.dart' as p27;
import '../../data/external/windows_tls_transport_test.dart' as tls;
import 'first_party_app_integration_cases.dart';
import 'windows_app_transport_fixture.dart';
import 'windows_codex_selection_fixture.dart';
import 'windows_codex_client_cases.dart';

McpVnextWindowsProtectedAcquirer bootstrapAcquirer(p27.PairingHarness h) =>
    McpVnextWindowsProtectedAcquirer(
      openNative: () => objects.adapter(h.native.calls),
      primitives: McpVnextWindowsCredentialPrimitives(
        generateKey: h.native.generate,
        signDigest: p27.signPublicFixture,
        verifyDigest: h.native.verify,
        // Fake infrastructure only; real P26/P15/P8/P10 still execute.
        nativePolicy: (_, __) {},
      ),
      utcNow: () => h.native.now,
      monotonicNow: () => h.elapsed,
      compositionIsCurrent: () => h.current,
      randomBytes: h.random,
    );

void windowsBootstrapCases() {
  windowsCodexClientCases();
  for (final mode in WindowsCodexConnectionMode.values) {
    for (final missing in [true, false]) {
      test(
          'registration ${mode.name} refuses client before acquisition missing=$missing',
          () async {
        final f = FirstPartyAppHarness();
        final h = p27.PairingHarness();
        await h.open();
        await f.open(attach: false);
        final output =
            File('${f.files.s.h.temp.path}/refused-output').openWrite();
        var admissions = 0;
        final selection = missing
            ? null
            : await WindowsCodexClientSelection.inspect(
                executable: FakeCodexExecutable(),
                use: WindowsCodexClientUse.product,
                mode: mode);
        final owners = Map.of(h.native.calls.owners);
        final registration = mode == WindowsCodexConnectionMode.direct
            ? McpVnextWindowsAppRegistration.directClient(
                integration: f.integration,
                acquirer: bootstrapAcquirer(h),
                clientSelection: selection,
                requireSecurityAdmission: () async {
                  admissions++;
                },
                clock: f.files.s.clock,
                readiness: OfflineReadiness(() async => []),
                port: 43123,
                listener: tls.MemoryListener())
            : McpVnextWindowsAppRegistration.hostedClient(
                integration: f.integration,
                acquirer: bootstrapAcquirer(h),
                clientSelection: selection,
                requireSecurityAdmission: () async {
                  admissions++;
                },
                clock: f.files.s.clock,
                readiness: OfflineReadiness(() async => []),
                port: 43123,
                input: const Stream.empty(),
                output: output);
        try {
          await expectLater(registration.start(), throwsStateError);
          await registration.close();
          expect(admissions, 0);
          expect(registration.startup!.host, isNull);
          expect(f.integration.hasAttachment, isFalse);
          expect(h.native.calls.owners, owners);
        } finally {
          await output.close();
          await registration.close();
          await f.close();
          await h.close();
        }
      });
    }
  }

  test('bootstrap missing client refuses before trust and acquisition',
      () async {
    final h = p27.PairingHarness();
    await h.open();
    addTearDown(h.close);
    var admissions = 0, trustReads = 0;
    final owners = Map.of(h.native.calls.owners);
    final bootstrap = McpVnextWindowsBridgeBootstrap(
        acquirer: bootstrapAcquirer(h),
        requireSecurityAdmission: () async {
          admissions++;
        },
        independentTrust: () async {
          trustReads++;
          throw StateError('must not run');
        },
        process: FakeWindowsMcpProcess());
    await expectLater(bootstrap.start(), throwsStateError);
    await bootstrap.close();
    expect(admissions, 0);
    expect(trustReads, 0);
    expect(h.native.calls.owners, owners);
  });
  test('trusted bootstrap reacquires after settlement and rejects contention',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open(productBridge: true, protectedAcquisition: true);
    addTearDown(f.close);
    final d = f.bridgeDependencies;
    await f.bridge.close();
    final bootstrap = McpVnextWindowsBridgeBootstrap(
        clientSelection: await isolatedClientSelection(),
        acquirer: bootstrapAcquirer(f.pairing),
        requireSecurityAdmission: () async {},
        independentTrust: () async => d.trusted,
        process: FakeWindowsMcpProcess(),
        createIo: d.createIo);
    f.bridge = bootstrap;
    await bootstrap.start();
    expect((await f.call('open_generation_context'))['error'], isNull);
    final competitor = McpVnextWindowsBridgeBootstrap(
        clientSelection: await isolatedClientSelection(),
        acquirer: bootstrapAcquirer(f.pairing),
        requireSecurityAdmission: () async {},
        independentTrust: () async => d.trusted,
        process: FakeWindowsMcpProcess(),
        createIo: d.createIo);
    await expectLater(competitor.start(), throwsA(anything));
    await competitor.close();
    expect((await f.call('open_generation_context'))['error'], isNull);
    expect(() => bootstrap.start(), throwsStateError);
    final closed = bootstrap.close();
    expect(identical(closed, bootstrap.close()), isTrue);
    await closed;
    expect((await f.call('open_generation_context'))['error'], 'unavailable');
  });

  for (final failure in [
    'admission',
    'trust',
    'pairing',
    'missing',
    'mismatch'
  ]) {
    test('bootstrap refuses $failure without business or credential repair',
        () async {
      final f = WindowsAppTransportFixture();
      await f.open(productBridge: true, protectedAcquisition: true);
      addTearDown(f.close);
      final d = f.bridgeDependencies;
      await f.bridge.close();
      if (failure == 'missing') {
        f.pairing.native.calls.credentialFiles.remove(4);
      }
      final before = f.pairing.native.calls.commits;
      final bootstrap = McpVnextWindowsBridgeBootstrap(
          clientSelection: await isolatedClientSelection(),
          acquirer: bootstrapAcquirer(f.pairing),
          requireSecurityAdmission: () async {
            if (failure == 'admission') throw StateError('unadmitted');
          },
          independentTrust: () async {
            if (failure == 'trust') {
              throw StateError('missing independent trust');
            }
            return failure == 'mismatch'
                ? DiscoveryExpectations(
                    trustedAnchorDer: d.trusted.trustedAnchorDer,
                    installationId: '00000000-0000-4000-8000-000000000001',
                    serverLeafDigest: d.trusted.serverLeafDigest,
                    verifiedEpochHighWater: BigInt.one)
                : d.trusted;
          },
          settlePairing: () async {
            if (failure == 'pairing') throw StateError('unsettled');
          },
          process: FakeWindowsMcpProcess(),
          createIo: d.createIo);
      await expectLater(bootstrap.start(), throwsA(anything));
      await bootstrap.close();
      expect(f.pairing.native.calls.owners.values, isNot(contains(2)));
      expect(f.pairing.native.calls.commits, before);
      expect(f.clients, isEmpty);
    });
  }

  test('close during admission never acquires protected objects', () async {
    final h = p27.PairingHarness();
    await h.open();
    addTearDown(h.close);
    final gate = Completer<void>();
    var trustReads = 0;
    final bootstrap = McpVnextWindowsBridgeBootstrap(
        clientSelection: await isolatedClientSelection(),
        acquirer: bootstrapAcquirer(h),
        requireSecurityAdmission: () => gate.future,
        independentTrust: () async {
          trustReads++;
          throw StateError('must not run');
        },
        process: FakeWindowsMcpProcess());
    final starting = expectLater(bootstrap.start(), throwsStateError);
    final closing = bootstrap.close();
    gate.complete();
    await starting;
    await closing;
    expect(trustReads, 0);
    expect(h.bridgeOwner.isUsable, isTrue);
  });

  test('unavailable registration installs no authority and closes original App',
      () async {
    final f = FirstPartyAppHarness();
    await f.open(attach: false);
    addTearDown(f.close);
    final registration =
        McpVnextWindowsAppRegistration.unavailable(f.integration);
    await registration.start();
    expect(registration.registered, isFalse);
    expect(f.integration.hasAttachment, isFalse);
    expect((await f.controls.status()).enabled, isFalse);
    await registration.close();
    expect(f.controls.isCurrent, isFalse);
    expect(() => registration.start(), throwsStateError);
  });

  test('direct client registration owns Host only and never enables on start',
      () async {
    final f = FirstPartyAppHarness();
    final h = p27.PairingHarness();
    await h.open();
    await f.open(attach: false);
    h.native.owner.close();
    f.files.s.clock.current = h.native.now;
    final registration = McpVnextWindowsAppRegistration.directClient(
        clientSelection: await isolatedClientSelection(),
        integration: f.integration,
        acquirer: bootstrapAcquirer(h),
        requireSecurityAdmission: () async {},
        clock: f.files.s.clock,
        readiness:
            OfflineReadiness(() async => f.files.s.h.db.rawQuery('SELECT 1')),
        port: 43123,
        listener: tls.MemoryListener());
    addTearDown(() async {
      await registration.close();
      await f.close();
      await h.close();
    });
    await registration.start();
    expect(registration.startup!.host!.phase, WindowsTlsHostPhase.ready);
    expect(f.integration.hasAttachment, isTrue);
    expect((await f.controls.status()).enabled, isFalse);
    expect(await f.controls.authenticatedSession(), isNull);
    await registration.close();
    expect(registration.startup!.host!.phase, WindowsTlsHostPhase.closed);
    expect(h.native.calls.owners.values, isNot(contains(1)));
  });
}
