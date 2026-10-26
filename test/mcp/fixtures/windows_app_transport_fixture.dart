// Existing product-root/P27 mathematical/Fake TLS facilities only.
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_bridge.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_startup.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_registration.dart';
import 'package:shiroha_quiz/data/external/windows_codex_client.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_acquisition.dart';
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart'
    show WindowsBridgeProcess;
import 'package:shiroha_quiz/data/external/windows_credential_object_store.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../../application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../../data/external/windows_pairing_test.dart' as p27;
import '../../data/external/windows_tls_transport_test.dart' as tls;
import '../../data/external/windows_peer_certificate_policy_test.dart'
    show OfflinePeerCalls;
import '../../data/external/windows_credential_initialization_test.dart'
    as init;
import '../../data/external/windows_credential_object_store_test.dart'
    as objects;
import '../../data/external/fixtures/windows_tls_bridge_cases.dart'
    show LinkedChannel;
import 'first_party_app_integration_cases.dart';

class FakeWindowsMcpProcess implements McpVnextWindowsProcessOwner {
  int stops = 0;
  bool fail = false;
  Completer<void>? stopping;
  void Function()? onStop;
  final reached = Completer<void>();
  @override
  Future<void> stopAndWait() async {
    stops++;
    onStop?.call();
    if (!reached.isCompleted) reached.complete();
    await stopping?.future;
    if (fail) throw StateError('Fake process exit unconfirmed');
  }
}

class WindowsAppTransportFixture extends FirstPartyAppHarness {
  final pairing = p27.PairingHarness();
  final listener = tls.MemoryListener();
  late WindowsPairingHandoff handoff;
  late WindowsTlsHost host;
  late McpVnextWindowsAppStartup startup;
  WindowsCodexClientSelection? registeredClient;
  McpVnextWindowsAppRegistration? registration;
  late ExternalInitializationResult publicMaterial;
  late McpVnextWindowsAppDependencies appDependencies;
  late McpVnextWindowsBridgeDependencies bridgeDependencies;
  McpVnextWindowsBridgeStartup? bridgeStartup;
  final appProcess = FakeWindowsMcpProcess();
  final bridgeProcess = FakeWindowsMcpProcess();
  McpVnextWindowsProcessOwner? appProcessOverride;
  McpVnextWindowsProcessOwner? bridgeProcessOverride;
  TlsListenerIo? listenerOverride;
  Future<void> Function()? beforeAcquire;
  bool failReadiness = false;
  Future<void> Function()? beforeLocalOpen;
  bool localPlanCreated = false;
  late TlsContextPlan plan;
  tls.MemoryTlsChannel? controlChannel;
  late VnextMcpPort bridge;
  late FirstPartyStageApproval approval;
  late FirstPartyStageApprovalView approvalView;
  final clients = <LinkedChannel>[];
  final servers = <LinkedChannel>[];
  final connections = <WindowsTlsBridge>[];
  void Function(LinkedChannel client, LinkedChannel server)?
      configureConnection;
  Uint8List? clientDer;
  Completer<void>? localCloseReached;
  bool useAcceptedLocalConnection = false;
  FirstPartyPairingPort Function(WindowsAppPairing)? pairingOverride;
  Future<Uint8List> Function()? publicSubmissionId;
  bool Function()? associationRecoveryAvailable;

  @override
  Future<void> open(
      {bool attach = true,
      bool stage = true,
      bool enableWithoutRetainedChannel = false,
      bool productBridge = false,
      bool protectedAcquisition = false,
      bool enroll = true}) async {
    await pairing.open();
    await super.open(attach: false);
    final h = pairing;
    final process = appProcessOverride ?? appProcess;
    McpVnextWindowsProtectedAcquirer acquirer() =>
        McpVnextWindowsProtectedAcquirer(
          openNative: () => objects.adapter(h.native.calls),
          primitives: McpVnextWindowsCredentialPrimitives(
              generateKey: h.native.generate,
              signDigest: p27.signPublicFixture,
              verifyDigest: h.native.verify,
              nativePolicy:
                  WindowsPeerCertificatePolicy(OfflinePeerCalls()).check),
          utcNow: () => h.native.now,
          monotonicNow: () => h.elapsed,
          compositionIsCurrent: () => h.current && controls.isCurrent,
          randomBytes: h.random,
        );
    Future<void> closeLocal() async {
      if (localCloseReached?.isCompleted == false) {
        localCloseReached!.complete();
      }
      await controlChannel?.close();
      if (localPlanCreated) plan.dispose();
    }

    final initialMaterial = h.native.service.validatedPublicMaterial();
    if (protectedAcquisition) h.native.owner.close();
    files.s.clock.current = h.native.now;
    final verifier = WindowsPairingVerification.withPrimitives(
        verifyDigest: h.native.verify,
        utcNow: () => h.native.now,
        monotonicNow: () => h.elapsed,
        compositionIsCurrent: () => h.current && controls.isCurrent);
    startup = McpVnextWindowsAppStartup(
      integration: integration,
      enableStageApprovalWait: stage,
      enableWithoutRetainedChannel: enableWithoutRetainedChannel,
      associationRecoveryAvailable: associationRecoveryAvailable,
      acquire: () async {
        await beforeAcquire?.call();
        if (publicSubmissionId case final input?) {
          final d = appDependencies = await acquirer().acquireAppRuntime(
              clock: files.s.clock,
              readiness: OfflineReadiness(() async {
                if (failReadiness) throw StateError('Fake readiness failure');
                await files.s.h.db.rawQuery('SELECT 1');
              }),
              port: listener.port,
              listener: listenerOverride ?? listener,
              process: process as WindowsBridgeProcess,
              submissionId: input);
          h.native.owner = d.owner;
          h.native.store = WindowsCredentialObjectStore(d.owner);
          h.native.service = d.credentials;
          h.associations = d.associations;
          h.appExchange = d.exchange;
          return d;
        }
        McpVnextWindowsAppDependencies assemble(
            [McpVnextWindowsAppResources? resources]) {
          if (resources != null) {
            h.native.owner = resources.owner;
            h.native.store = WindowsCredentialObjectStore(resources.owner);
            h.native.service = resources.credentials;
            h.associations = resources.associations;
            h.appExchange = resources.exchange;
          }
          return appDependencies = McpVnextWindowsAppDependencies(
            owner: h.native.owner,
            credentials: resources?.credentials ??
                WindowsCredentialInitialization.withPrimitives(
                    owner: h.native.owner,
                    generateKey: h.native.generate,
                    signDigest: p27.signPublicFixture,
                    verifyDigest: h.native.verify,
                    utcNow: () => h.native.now,
                    randomBytes: h.random),
            associations: h.associations,
            exchange: h.appExchange,
            pairingVerification: resources?.verification ?? verifier,
            signDigest: p27.signPublicFixture,
            verifyDigest: h.native.verify,
            nativePolicy:
                WindowsPeerCertificatePolicy(OfflinePeerCalls()).check,
            clock: files.s.clock,
            utcNow: () => h.native.now,
            monotonicNow: () => h.elapsed,
            randomBytes: h.random,
            compositionIsCurrent: () => h.current && controls.isCurrent,
            readiness: OfflineReadiness(() async {
              if (failReadiness) throw StateError('Fake readiness failure');
              await files.s.h.db.rawQuery('SELECT 1');
            }),
            listener: listenerOverride ?? listener,
            port: listener.port,
            pairing: pairingOverride ??
                (appPairing) => handoff = WindowsPairingHandoff(
                    appOwner: appPairing, bridgeOwner: h.bridge),
            openLocalConnection: useAcceptedLocalConnection
                ? null
                : () async {
                    await beforeLocalOpen?.call();
                    return (channel: controlChannel!, plan: plan);
                  },
            closeLocalConnections:
                useAcceptedLocalConnection ? null : closeLocal,
            process: process,
          );
        }

        return protectedAcquisition
            ? acquirer().acquireApp(
                assemble: assemble,
                process: process,
                closeLocalConnections:
                    useAcceptedLocalConnection ? null : closeLocal)
            : assemble();
      },
    );
    if (registeredClient case final selected?) {
      if (!protectedAcquisition || !enroll || appProcessOverride != null) {
        throw StateError('Registered test composition requires direct custody');
      }
      useAcceptedLocalConnection = true;
      registration = McpVnextWindowsAppRegistration.directClient(
          integration: integration,
          acquirer: acquirer(),
          clientSelection: selected,
          requireSecurityAdmission: () async {},
          clock: files.s.clock,
          readiness:
              OfflineReadiness(() async => files.s.h.db.rawQuery('SELECT 1')),
          port: listener.port,
          listener: listener,
          enableStageApprovalWait: stage);
      startup = registration!.startup!;
      await registration!.start();
    } else {
      port = await startup.start();
    }
    host = startup.host!;
    if (stage) {
      approval = (host.binding as VnextMcpAppComposition).stageApproval!;
    }
    final material = publicMaterial = registeredClient == null
        ? h.native.service.validatedPublicMaterial()
        : initialMaterial;
    plan = TlsContextPlan.validate(
        role: TlsPeerRole.server,
        leafDer: material.serverLeafDer!,
        issuerDer: material.issuerCertificateDer,
        privateKeyDer: init.publicFixtureKey(),
        independentlyPinnedIssuer: material.issuerCertificateDer,
        signDigest: p27.signPublicFixture,
        verifyDigest: h.native.verify,
        utcNow: () => h.native.now);
    localPlanCreated = true;
    if (!enroll) {
      bridge = port!;
      return;
    }
    if (registration != null) {
      final local = WindowsBridgePublicPairing(owner: h.bridge);
      local.beginEnrollment(
          displayLabel: 'PUBLIC FIXTURE', clientBuild: 'offline');
      await controls.select(files.s.profile.profileId);
      await controls.requestPairing(
          submissionId: local.display().submissionId!);
      await local.importTrust(await controls.exportPairingTrust());
      final displayed = (await controls.status()).pairingDisplay!;
      expect(local.display().initialDigest, displayed.digest);
      await controls.approvePairing();
      local.confirmInitial(displayed.digest!);
      await controls.completePairing();
      await local.importCompletion(await controls.exportPairingCompletion());
      final completed = (await controls.status()).pairingDisplay!;
      expect(local.display().completionDigest, completed.digest);
      local.confirmCompletion(completed.digest!, completed.revision!);
      clientDer =
          (h.bridgeStore.read(4)! as ExternalBridgeClient).clientLeafDer;
      controlChannel = tls.MemoryTlsChannel(clientDer);
      await local.close();
    } else {
      final local = handoff.bridge;
      local.beginEnrollment(
          displayLabel: 'PUBLIC FIXTURE', clientBuild: 'offline');
      final id = local.display().submissionId!;
      await controls.select(files.s.profile.profileId);
      await controls.requestPairing();
      await local.inspectAppTrust();
      expect((await controls.status()).pairingDisplay!.digest,
          local.display().initialDigest);
      clientDer = h.bridgeExchange.readChallenge(id)!.clientLeafDer;
      controlChannel = tls.MemoryTlsChannel(clientDer);
      await controls.approvePairing();
      local.confirmInitialAndPublishProof(
          comparedDigest: local.display().initialDigest!);
      await controls.completePairing();
      final completed = (await controls.status()).pairingDisplay!;
      await local.inspectAppCompletion();
      expect(completed.digest, local.display().completionDigest);
      local.confirmCompletionAndSave(
          comparedRevision: completed.revision!,
          comparedDigest: completed.digest!);
    }
    final enabling = controls.enable(const Duration(minutes: 5));
    if (useAcceptedLocalConnection && !enableWithoutRetainedChannel) {
      await pumpEventQueue(times: 20);
      expect(host.verification.hasPendingLocalConnection, isTrue);
      listener.controller.add(tls.MemoryRawPeer(controlChannel!));
    }
    await enabling;
    if (stage) approvalView = controls.openStageApprovalView()!;
    if (productBridge) {
      final process = bridgeProcessOverride ?? bridgeProcess;
      if (protectedAcquisition) {
        if (registration == null) await handoff.bridge.close();
        h.bridgeOwner.close();
      }
      McpVnextWindowsBridgeDependencies assembleBridge(
          ExternalProtectedObjects owner) {
        h.bridgeOwner = owner;
        return bridgeDependencies = McpVnextWindowsBridgeDependencies(
          owner: owner,
          trusted: DiscoveryExpectations(
              trustedAnchorDer: material.issuerCertificateDer,
              installationId: material.installationId,
              serverLeafDigest: plan.leafDigest,
              verifiedEpochHighWater: BigInt.one),
          createIo: () {
            final client = LinkedChannel(material.serverLeafDer!);
            final server = LinkedChannel(clientDer!);
            client.peer = server;
            client.abortPeer = true;
            server.peer = client;
            clients.add(client);
            servers.add(server);
            configureConnection?.call(client, server);
            listener.controller.add(tls.MemoryRawPeer(server));
            return tls.MemoryBridgeIo(client);
          },
          signDigest: p27.signPublicFixture,
          verifyDigest: h.native.verify,
          nativePolicy: WindowsPeerCertificatePolicy(OfflinePeerCalls()).check,
          utcNow: () => h.native.now,
          monotonicNow: () => h.elapsed,
          compositionIsCurrent: () => h.current,
          process: process,
        );
      }

      bridgeStartup = McpVnextWindowsBridgeStartup(
        enableStageApprovalWait: stage,
        acquire: () async => protectedAcquisition
            ? acquirer()
                .acquireBridge(assemble: assembleBridge, process: process)
            : assembleBridge(h.bridgeOwner),
      );
      await bridgeStartup!.start();
      bridge = bridgeStartup!;
    } else {
      bridge = McpVnextWindowsBridge(
          enableStageApprovalWait: stage,
          createConnection: () {
            final client = LinkedChannel(material.serverLeafDer!);
            final server = LinkedChannel(clientDer!);
            client.peer = server;
            client.abortPeer = true;
            server.peer = client;
            clients.add(client);
            servers.add(server);
            configureConnection?.call(client, server);
            final connection = WindowsTlsBridge(
                io: tls.MemoryBridgeIo(client),
                reader: WindowsDiscoveryReader(h.bridgeOwner, verifier: (
                    {required publicPoint,
                    required digest,
                    required rawSignature}) {
                  h.native.verify(
                      publicPoint: publicPoint,
                      digest: digest,
                      rawSignature: rawSignature);
                  return true;
                }),
                trusted: DiscoveryExpectations(
                    trustedAnchorDer: material.issuerCertificateDer,
                    installationId: material.installationId,
                    serverLeafDigest: plan.leafDigest,
                    verifiedEpochHighWater: BigInt.one),
                owner: h.bridgeOwner,
                signDigest: p27.signPublicFixture,
                verifyDigest: h.native.verify,
                nativePolicy:
                    WindowsPeerCertificatePolicy(OfflinePeerCalls()).check,
                utcNow: () => h.native.now,
                compositionIsCurrent: () => h.current,
                enableStageApprovalWait: stage);
            connections.add(connection);
            listener.controller.add(tls.MemoryRawPeer(server));
            return connection;
          });
    }
  }

  @override
  Future<Map<String, Object?>> call(String tool,
          [Map<String, dynamic> args = const {}]) =>
      bridge.call(tool, args,
          cancelled: const Stream.empty(), available: () => true);

  Future<Map<String, Object?>> approvedStage(String context, String key) async {
    final waiting = Completer<void>();
    final changes = approval.changes.listen((_) {
      if (approval.waitingForUser && !waiting.isCompleted) waiting.complete();
    });
    final result = stage(context, key: key);
    await Future.any([waiting.future, result.then((_) {})]);
    await changes.cancel();
    expect(approval.waitingForUser, isTrue);
    await approvalView.confirm(approvalView.pending!);
    return result;
  }

  @override
  Future<void> close() async {
    await bridge.close();
    await registration?.close();
    await startup.close();
    await super.close();
    plan.dispose();
    await pairing.close();
  }
}
