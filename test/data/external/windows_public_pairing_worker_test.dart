// Independent Flutter test process: real product Bridge controls, Fake Native.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'windows_pairing_test.dart' show PairingHarness;
import '../../application/generated_question/generated_test_support.dart'
    show initializeGeneratedTests;
import 'fixtures/public_pairing_process_support.dart';

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
  }, skip: path == null ? 'Only run by isolated public-handoff parent' : false);
}
