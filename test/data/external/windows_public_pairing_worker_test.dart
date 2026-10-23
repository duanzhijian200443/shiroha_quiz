// Independent Flutter test process: real product Bridge controls, Fake Native.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_startup.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_acquisition.dart';
import 'windows_peer_certificate_policy_test.dart' show OfflinePeerCalls;
import 'windows_credential_object_store_test.dart' as objects;
import '../../mcp/fixtures/windows_process_channel.dart';
import 'windows_pairing_test.dart' show PairingHarness, signPublicFixture;
import '../../application/generated_question/generated_test_support.dart'
    show initializeGeneratedTests;
import 'fixtures/public_pairing_process_support.dart';

// The parent's WindowsBridgeProcess owns the actual child. This inner fake
// represents no second OS process or security evidence.
final class _WorkerLifetime implements McpVnextWindowsProcessOwner {
  @override
  Future<void> stopAndWait() async {}
}

Future<void> _runBridge(PairingHarness h, Directory root, Uint8List id) async {
  await waitPublicFile(root, 'start-bridge');
  final public = PairingPublicExport.decodeTrust(
      await (await waitPublicFile(root, 'trust')).readAsBytes(), id);
  final discovery =
      jsonDecode(await (await waitPublicFile(root, 'discovery')).readAsString())
          as List;
  for (final row in discovery) {
    h.native.calls.discoveryFiles[row[0] as int] =
        Uint8List.fromList(base64Decode(row[1] as String));
  }
  final pin = h.bridgeStore.read(4) as ExternalBridgeClient;
  final installation = pin.pinnedInstallationId;
  pin.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
  var connections = 0;
  h.bridgeOwner.close();
  final acquirer = McpVnextWindowsProtectedAcquirer(
      openNative: () => objects.adapter(h.native.calls),
      primitives: McpVnextWindowsCredentialPrimitives(
          generateKey: h.native.generate,
          signDigest: signPublicFixture,
          verifyDigest: h.native.verify,
          nativePolicy: WindowsPeerCertificatePolicy(OfflinePeerCalls()).check),
      utcNow: () => h.native.now,
      monotonicNow: () => h.elapsed,
      compositionIsCurrent: () => h.current,
      randomBytes: h.random);
  final startup = McpVnextWindowsBridgeStartup(acquire: () async {
    final d = await acquirer.acquireBridgeRuntime(
      trusted: DiscoveryExpectations(
          trustedAnchorDer: public.issuerDer,
          installationId: installation,
          serverLeafDigest: public.serverLeafDigest,
          verifiedEpochHighWater: BigInt.one),
      createIo: () => ProcessTestBridgeIo(root, connections++,
          h.native.service.validatedPublicMaterial().serverLeafDer!),
      process: _WorkerLifetime(),
    );
    h.bridgeOwner = d.owner;
    return d;
  });
  await startup.start();
  try {
    for (var i = 0; i < 2; i++) {
      final result = await startup.call('open_generation_context', {},
          cancelled: const Stream.empty(), available: () => true);
      expect(result['error'], isNull);
      await publishPublic(root, 'result-$i', utf8.encode(jsonEncode(result)));
      if (i == 0) await waitPublicFile(root, 'reconnect');
    }
    expect(connections, 2);
    await publishPublic(root, 'bridge-ready', [1]);
    await waitPublicFile(root, 'stop-bridge');
  } finally {
    await startup.close();
    await startup.close();
    expect(h.bridgeOwner.isUsable, isFalse);
  }
}

void main() {
  initializeGeneratedTests();
  final path = Platform.environment['SHIROHA_PUBLIC_PAIRING_TEST'];
  test('independent Bridge imports public exports and requires both decisions',
      () async {
    final root = Directory(path!);
    final h = PairingHarness();
    await h.open();
    final bridge = WindowsBridgeOnboarding.fromPublicExports(
        owner: h.bridge,
        readTrust: (_) async =>
            (await waitPublicFile(root, 'trust')).readAsBytes(),
        readCompletion: (_) async =>
            (await waitPublicFile(root, 'completion')).readAsBytes());
    addTearDown(() async {
      await bridge.close();
      await h.close();
    });
    bridge.beginEnrollment(
        displayLabel: 'PUBLIC WORKER', clientBuild: 'isolated');
    final id = bridge.display().submissionId!;
    await exportExchange(h, root, 'submission.exchange');
    await publishPublic(root, 'submission', id);
    await importExchange(h, root, 'challenge.exchange');
    await bridge.inspectAppTrust();
    expect(bridge.display().proofPublished, isFalse);
    expect(h.bridgeStore.read(4), isNull);
    await publishPublic(
        root, 'initial-ready', utf8.encode(bridge.display().initialDigest!));
    final first = await waitPublicFile(root, 'confirm-initial');
    bridge.confirmInitialAndPublishProof(
        comparedDigest: await first.readAsString());
    await exportExchange(h, root, 'proof.exchange');
    await bridge.inspectAppCompletion();
    expect(h.bridgeStore.read(4), isNull);
    await publishPublic(root, 'completion-ready', [1]);
    final second = await waitPublicFile(root, 'confirm-completion');
    final decision = jsonDecode(await second.readAsString()) as List;
    bridge.confirmCompletionAndSave(
        comparedRevision: decision[0] as int,
        comparedDigest: decision[1] as String);
    expect(bridge.display().pinSaved, isTrue);
    expect(h.bridgeStore.read(4), isNotNull);
    await bridge.close();
    expect(bridge.display().closed, isTrue);
    await publishPublic(root, 'finished', Uint8List.fromList([1]));
    if (Platform.environment['SHIROHA_PUBLIC_PAIRING_INTEGRATION'] == '1') {
      await _runBridge(h, root, id);
    }
  }, skip: path == null ? 'Only run by isolated public-handoff parent' : false);
}
