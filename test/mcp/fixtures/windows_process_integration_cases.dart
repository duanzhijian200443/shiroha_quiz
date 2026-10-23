// Actual Windows child + App/Bridge startup roots. Native, TLS and protected
// storage are simulated. Only public test data and original P9 bytes cross files.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../../data/external/fixtures/public_pairing_process_support.dart';
import 'codex_app_server_support.dart' show flutterDartExecutable;
import 'windows_app_transport_fixture.dart';
import 'windows_process_channel.dart';
import 'windows_resource_process_cases.dart' show FakeBridgeProcessIo;

final class _PairingChild implements WindowsCreatedBridgeProcess {
  _PairingChild(this.original, this.root) {
    settlement = Future.wait<int>([
      original.exitCode,
      original.stdout.drain<void>().then((_) => 0),
      original.stderr.drain<void>().then((_) => 0),
    ]).then((values) => values.first);
  }
  final Process original;
  final Directory root;
  @override
  late final Future<int> settlement;
  @override
  Future<int> get exitCode => original.exitCode;
  @override
  Future<void> closeInput() async {
    // Flutter tools owns worker stdin, so its test-only exit gate is separate
    // from acknowledged EOF on the original SDK child's actual stdin.
    await publishPublic(root, 'stop-bridge', [1]);
    await original.stdin.close();
  }
}

final class _PairingChildIo implements WindowsBridgeProcessIo {
  _PairingChildIo(this.root);
  final Directory root;
  _PairingChild? child;
  int creates = 0;
  @override
  Future<Map<String, Uint8List>> inspect() => FakeBridgeProcessIo().inspect();
  @override
  Future<WindowsCreatedBridgeProcess> create() async {
    creates++;
    final dart = flutterDartExecutable();
    final snapshot =
        p.join(p.dirname(p.dirname(p.dirname(dart))), 'flutter_tools.snapshot');
    return child = _PairingChild(
        await Process.start(
            dart,
            [
              snapshot,
              'test',
              '--concurrency=1',
              '--no-pub',
              'test/data/external/windows_public_pairing_worker_test.dart'
            ],
            includeParentEnvironment: false,
            environment: {
              for (final entry in Platform.environment.entries)
                if (const {
                  'SYSTEMROOT',
                  'WINDIR',
                  'PATH',
                  'PATHEXT',
                  'TEMP',
                  'TMP',
                  'USERPROFILE',
                  'APPDATA',
                  'LOCALAPPDATA',
                  'PROGRAMFILES',
                  'PROGRAMFILES(X86)',
                  'PROGRAMW6432',
                  'COMSPEC',
                  'SYSTEMDRIVE',
                  'PROCESSOR_ARCHITECTURE'
                }.contains(entry.key.toUpperCase()))
                  entry.key: entry.value,
              'SHIROHA_PUBLIC_PAIRING_TEST': root.path,
              'SHIROHA_PUBLIC_PAIRING_INTEGRATION': '1',
            }),
        root);
  }
}

void windowsProcessIntegrationCases() {
  test(
      'actual Windows child joins App startup, public P27, accepted channel and reconnect',
      () async {
    final root = await Directory(p.absolute('.dart_tool/public-pairing-tests'))
        .create(recursive: true);
    final temp = await root.createTemp('startup-');
    final io = _PairingChildIo(temp);
    final process = WindowsBridgeProcess(io: io);
    final idInput = Completer<Uint8List>();
    final f = WindowsAppTransportFixture()
      ..useAcceptedLocalConnection = true
      ..appProcessOverride = process
      ..publicSubmissionId = () => idInput.future;
    var complete = false;
    addTearDown(() async {
      if (!complete) {
        // Failure-only quarantine disposal of our original test child. Never
        // claim this killed process as successful product close/Owner release.
        io.child?.original.kill();
        await io.child?.settlement;
        try {
          await f.startup.close();
        } catch (_) {}
        f.policy.invalidate();
        await f.files.close();
        await f.pairing.close();
      }
      await temp.delete(recursive: true);
    });
    await f.open(enroll: false, stage: false, protectedAcquisition: true);
    final public = f.startup.publicPairing!;
    expect(io.creates, 1); // startup, not the test, launched the original child
    expect(process.isCurrent, isTrue);
    final h = f.pairing;
    final id = await (await waitPublicFile(temp, 'submission')).readAsBytes();
    idInput.complete(id);
    await importExchange(h, temp, 'submission.exchange');
    await f.controls.select(f.files.s.profile.profileId);
    await f.controls.requestPairing();
    await publishPublic(temp, 'trust', await public.exportTrust(id));
    await exportExchange(h, temp, 'challenge.exchange');
    final display = (await f.controls.status()).pairingDisplay!;
    expect(await (await waitPublicFile(temp, 'initial-ready')).readAsString(),
        display.digest);
    expect(
        h.native.calls.exchangeFiles.keys.any((key) => key.$1 == 3), isFalse);
    final clientDer = h.bridgeExchange.readChallenge(id)!.clientLeafDer;
    await f.controls.approvePairing();
    await publishPublic(temp, 'confirm-initial', utf8.encode(display.digest!));
    await importExchange(h, temp, 'proof.exchange');
    await f.controls.completePairing();
    final completed = (await f.controls.status()).pairingDisplay!;
    await publishPublic(temp, 'completion', await public.exportCompletion(id));
    await waitPublicFile(temp, 'completion-ready');
    // Each decision is a distinct test input. Neither import auto-confirms it.
    await publishPublic(temp, 'confirm-completion',
        utf8.encode(jsonEncode([completed.revision, completed.digest])));
    await waitPublicFile(temp, 'finished');
    await publishPublic(
        temp,
        'discovery',
        utf8.encode(jsonEncode([
          for (final row in h.native.calls.discoveryFiles.entries)
            [row.key, base64Encode(row.value)]
        ])));
    var enabling = f.controls.enable(const Duration(minutes: 5));
    await pumpEventQueue(times: 20);
    expect(f.host.verification.hasPendingLocalConnection, isTrue);
    await publishPublic(temp, 'start-bridge', [1]);
    for (var i = 0; i < 2; i++) {
      await waitPublicFile(temp, 'connect-$i');
      f.listener.controller.add(ProcessTestRawPeer(
          ProcessTestChannel(temp, 'server-$i', 'client-$i', clientDer)));
      await enabling;
      final result = jsonDecode(
              await (await waitPublicFile(temp, 'result-$i')).readAsString())
          as Map;
      expect(result['error'], isNull);
      expect(result['profileVersion'], 2);
      final items = (result['data'] as Map)['items'] as List;
      expect(items, isNotEmpty);
      expect((items.first as Map)['targetRef'], isNotEmpty);
      await f.host.whenConnectionsSettled;
      if (i == 0) {
        expect(await f.controls.authenticatedSession(), isNull);
        enabling = f.controls.enable(const Duration(minutes: 5));
        await pumpEventQueue(times: 20);
        expect(f.host.verification.hasPendingLocalConnection, isTrue);
        await publishPublic(temp, 'reconnect', [1]);
      }
    }
    await waitPublicFile(temp, 'bridge-ready');
    expect(process.isCurrent, isTrue);
    final closing = f.startup.close();
    expect(identical(closing, f.startup.close()), isTrue);
    await closing;
    expect(await io.child!.exitCode, 0);
    expect(await io.child!.settlement, 0);
    expect(f.host.phase, WindowsTlsHostPhase.closed);
    expect(h.native.owner.isUsable, isFalse);
    for (final resource in TlsResource.values) {
      expect(f.host.budget.used(resource), 0);
    }
    await f.close();
    complete = true;
  },
      skip: Platform.isWindows ? false : 'Windows process evidence only',
      timeout: const Timeout(Duration(minutes: 2)));
}
