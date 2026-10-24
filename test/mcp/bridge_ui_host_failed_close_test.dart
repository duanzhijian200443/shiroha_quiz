import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/composition/bridge_ui_host.dart';
import 'package:shiroha_quiz/data/external/windows_exchange_file_store.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';

import '../application/generated_question/generated_test_support.dart';
import '../data/external/windows_pairing_test.dart' show PairingHarness;
import 'fixtures/codex_app_server_support.dart' show flutterDartExecutable;

void main() {
  initializeGeneratedTests();

  // Separate suite: the failed host must remain quarantined until isolate exit.
  // No reset hook or successful second close may release its instance lock.
  test('failed original read release retains Owner and host lock without retry',
      () async {
    final h = PairingHarness();
    await h.open();
    // Test-only Fake resource disposal, after all custody assertions. This does
    // not clear the product host's failed-close latch or release its file lock.
    addTearDown(h.close);
    final root = await Directory(p.join(Directory.current.path, '.dart_tool'))
        .createTemp('bridge_host_failed_close_');
    var resources = 0;
    final dependencies = BridgeUiHostDependencies(
        pairing: h.bridge,
        instanceRoot: root.path,
        closeResources: () async {
          resources++;
          h.bridge.close();
          h.bridgeOwner.close();
        });
    final host = await BridgeUiHost.open(dependencies);
    host.port.beginEnrollment(displayLabel: 'Bridge', clientBuild: 'test');
    final id = host.port.display().submissionId!;
    final app = WindowsAppPublicPairingHandoff(owner: h.app);
    await app.requestSubmission(h.local.reference, id);
    final trust = await app.exportPublicTrust();
    await host.port.importTrust(trust);
    expect(host.port.display().initialDigest, hasLength(64));
    expect(h.native.calls.exchangeReadTickets, hasLength(1));
    final owners = h.native.calls.owners.keys.toSet();
    final releases = h.native.calls.exchangeReleases;
    final files = h.native.calls.exchangeFiles.length;

    // Fail the real P27 -> ExchangeFileRead -> Native adapter release, not a
    // replacement UI port. The Fake reports an uncertain original release.
    h.native.calls.throwRelease = true;
    final closing = host.port.close();
    expect(identical(closing, host.close()), isTrue);
    Object? failure;
    try {
      await closing;
    } catch (error) {
      failure = error;
    }
    expect(
        failure,
        isA<ExternalExchangeException>().having((e) => e.failure, 'failure',
            ExternalExchangeFailure.temporarilyUnavailable));
    expect(resources, 0);
    expect(h.bridgeOwner.isClosed, isFalse);
    expect(h.native.calls.owners.keys.toSet(), owners);
    expect(h.native.calls.exchangeReleases, releases + 1);
    expect(host.isClosed, isTrue);
    expect(host.port.display().closed, isTrue);
    expect(host.port.display().submissionId, isNull);
    expect(host.port.display().initialDigest, isNull);
    expect(h.keys, everyElement(everyElement(0)));

    // Neither a later caller nor a recovered primitive may retry the release.
    h.native.calls.throwRelease = false;
    expect(identical(host.close(), closing), isTrue);
    expect(identical(host.port.close(), closing), isTrue);
    await expectLater(host.close(), throwsA(same(failure)));
    await expectLater(host.port.importTrust(trust), throwsA(anything));
    expect(
        () => host.port
            .beginEnrollment(displayLabel: 'Late Bridge', clientBuild: 'test'),
        throwsA(anything));
    await expectLater(BridgeUiHost.open(dependencies), throwsStateError);
    expect(resources, 0);
    expect(h.bridgeOwner.isClosed, isFalse);
    expect(h.native.calls.exchangeReleases, releases + 1);
    expect(h.native.calls.exchangeFiles, hasLength(files));

    // A separate process is needed for POSIX as well as Windows lock exclusion.
    final probe = File(p.join(root.path, 'lock_probe.dart'));
    await probe.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File(args.single).open(mode: FileMode.append);
  try {
    await file.lock(FileLock.exclusive);
    exitCode = 1;
  } on FileSystemException {
    exitCode = 0;
  } finally {
    await file.close();
  }
}
''');
    final result = await Process.run(flutterDartExecutable(),
        [probe.path, p.join(root.path, BridgeUiHost.lockFileName)],
        runInShell: false);
    expect(result.exitCode, 0);
    expect(result.stdout, isEmpty);
    expect(result.stderr, isEmpty);
  });
}
