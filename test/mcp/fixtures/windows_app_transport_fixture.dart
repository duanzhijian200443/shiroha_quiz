// Existing product-root/P27 mathematical/Fake TLS facilities only.
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import 'package:shiroha_quiz/application/external/external_credential_boundary.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_bridge.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_transport.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../../application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../../data/external/windows_pairing_test.dart' as p27;
import '../../data/external/windows_tls_transport_test.dart' as tls;
import '../../data/external/windows_peer_certificate_policy_test.dart'
    show OfflinePeerCalls;
import '../../data/external/windows_credential_initialization_test.dart'
    as init;
import '../../data/external/fixtures/windows_tls_bridge_cases.dart'
    show LinkedChannel;
import 'first_party_app_integration_cases.dart';

class WindowsAppTransportFixture extends FirstPartyAppHarness {
  final pairing = p27.PairingHarness();
  final listener = tls.MemoryListener();
  late WindowsPairingHandoff handoff;
  late WindowsTlsHost host;
  late WindowsChannelVerification channels;
  late TlsContextPlan plan;
  tls.MemoryTlsChannel? controlChannel;
  late McpVnextWindowsBridge bridge;
  late FirstPartyStageApproval approval;
  late FirstPartyStageApprovalView approvalView;
  final clients = <LinkedChannel>[];
  final servers = <LinkedChannel>[];
  final connections = <WindowsTlsBridge>[];
  void Function(LinkedChannel client, LinkedChannel server)?
      configureConnection;
  Uint8List? clientDer;
  Completer<void>? localCloseReached;

  @override
  Future<void> open({bool attach = true, bool stage = true}) async {
    await pairing.open();
    await super.open(attach: false);
    final h = pairing;
    files.s.clock.current = h.native.now;
    final verifier = WindowsPairingVerification.withPrimitives(
        verifyDigest: h.native.verify,
        utcNow: () => h.native.now,
        monotonicNow: () => h.elapsed,
        compositionIsCurrent: () => h.current && controls.isCurrent);
    late WindowsAppPairing appPairing;
    port = await integration.attachCredentials(
        associations: h.associations,
        verification: (management) => channels = WindowsChannelVerification(
            pairing: verifier,
            associations: h.associations,
            management: management,
            nativePolicy:
                WindowsPeerCertificatePolicy(OfflinePeerCalls()).check,
            verifyDigest: h.native.verify,
            utcNow: () => h.native.now,
            monotonicNow: () => h.elapsed,
            compositionIsCurrent: () => h.current && controls.isCurrent),
        clock: files.s.clock,
        installationId:
            h.native.service.validatedPublicMaterial().installationId,
        monotonicNow: () => h.elapsed,
        readiness:
            OfflineReadiness(() async => files.s.h.db.rawQuery('SELECT 1')),
        enableStageApprovalWait: stage,
        services: (boundary) {
          channels.attach(boundary);
          appPairing = WindowsAppPairing.withPrimitives(
              exchange: h.appExchange,
              credentials: h.native.service,
              boundary: boundary,
              associations: h.associations,
              verification: verifier,
              utcNow: () => h.native.now,
              monotonicNow: () => h.elapsed,
              compositionIsCurrent: () => h.current && controls.isCurrent,
              randomBytes: h.random);
          handoff = WindowsPairingHandoff(
              appOwner: appPairing, bridgeOwner: h.bridge);
          return FirstPartyCredentialServices(
              boundary: boundary,
              pairing: handoff,
              openConnection: (_) async =>
                  (await channels.authenticate(controlChannel!, plan))
                      .firstPartyConnection,
              close: () async {
                await controlChannel?.close();
                channels.close();
              });
        },
        transport: (coordinator, binding) {
          if (stage) approval = binding.stageApproval!;
          final credentials = WindowsCredentialInitialization.withPrimitives(
              owner: h.native.owner,
              generateKey: h.native.generate,
              signDigest: p27.signPublicFixture,
              verifyDigest: h.native.verify,
              utcNow: () => h.native.now,
              randomBytes: h.random);
          final startup = P26TlsStartup(
              owner: h.native.owner,
              credentials: credentials,
              publisher: WindowsDiscoveryPublisher(
                  owner: h.native.owner, credentials: credentials),
              runtimeInstanceId: appPairing.runtimeInstanceId,
              generation:
                  BigInt.from(binding.stages.runtimeAdmission.trust.generation),
              signDigest: p27.signPublicFixture,
              verifyDigest: h.native.verify,
              utcNow: () => h.native.now,
              compositionIsCurrent: () => h.current && controls.isCurrent);
          host = WindowsTlsHost.owned(
              owner: h.native.owner,
              pairing: appPairing,
              associations: h.associations,
              boundary: binding.stages.runtimeAdmission.trust.credentials
                  as ExternalCredentialBoundary,
              coordinator: coordinator,
              startup: startup,
              verification: channels,
              closeLocalConnections: () async {
                localCloseReached?.complete();
                await controlChannel?.close();
              },
              io: listener,
              binding: binding,
              enableStageApprovalWait: stage,
              port: listener.port,
              monotonicNow: () => h.elapsed);
          return McpVnextWindowsTransport(binding: binding, transport: host);
        });
    final material = h.native.service.validatedPublicMaterial();
    plan = TlsContextPlan.validate(
        role: TlsPeerRole.server,
        leafDer: material.serverLeafDer!,
        issuerDer: material.issuerCertificateDer,
        privateKeyDer: init.publicFixtureKey(),
        independentlyPinnedIssuer: material.issuerCertificateDer,
        signDigest: h.native.sign,
        verifyDigest: h.native.verify,
        utcNow: () => h.native.now);
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
    await controls.enable(const Duration(minutes: 5));
    if (stage) approvalView = controls.openStageApprovalView()!;
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
              signDigest: h.native.sign,
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
    await super.close();
    plan.dispose();
    await pairing.close();
  }
}
