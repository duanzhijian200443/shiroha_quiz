/// Test-only isolated Bridge UI host process for the AR-R6B dual-process check.
///
/// The window and lifecycle are the real [BridgeUiHost]; only the security
/// primitives are the existing public mathematical/Fake Native facilities. It is
/// not a production Bridge bootstrap, adds no Pairing IPC and carries no private
/// key, Pin or Session through the bounded link directory.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/composition/bridge_ui_host.dart';

import '../test/data/external/fixtures/public_pairing_process_support.dart'
    show exportExchange, importExchange;
import '../test/data/external/windows_pairing_test.dart' show PairingHarness;
import 'mcp_vnext_windows_app_smoke.dart' show SmokeHttpOverrides;
import 'mcp_vnext_windows_pairing_host_support.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = pairingHostRoot(const String.fromEnvironment(
    pairingHostRootDefine,
  ));
  final scenario = await pairingHostScenario(root);
  HttpOverrides.global = SmokeHttpOverrides();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  final evidence =
      PairingHostEvidence(File(p.join(root.path, 'bridge-events.jsonl')));
  final link = PairingHostLink(Directory(p.join(root.path, 'link')));
  await link.prepare();
  final h = PairingHarness();
  await h.open();
  bool? pinAtClose;
  bool pinPresent() => pinAtClose ?? (h.bridgeStore.read(4) != null);
  final hostRoot = Directory(p.join(root.path, 'bridge-host'))
    ..createSync(recursive: true);
  final host = await BridgeUiHost.open(BridgeUiHostDependencies(
      pairing: h.bridge,
      instanceRoot: hostRoot.path,
      closeResources: () async {
        try {
          pinAtClose = h.bridgeStore.read(4) != null;
          await h.close();
          evidence.record('resources_closed', {'pinPresent': pinAtClose});
        } catch (error) {
          evidence.record('resource_close_failed', {
            'failure': safeFailure(error),
          });
          rethrow;
        }
      },
      title: 'Shiroha Bridge'));
  final surface = GlobalKey();
  final driver = PairingUiDriver(surface);
  evidence.record('host_ready', {'scenario': scenario});
  runApp(RepaintBoundary(key: surface, child: host.build()));
  unawaited(() async {
    try {
      await _script(
          driver, link, evidence, h, host, root.path, scenario, pinPresent);
      evidence.record('script_complete');
    } catch (error) {
      evidence.record('script_failed', {'failure': safeFailure(error)});
    }
  }());
}

Future<void> _script(
    PairingUiDriver driver,
    PairingHostLink link,
    PairingHostEvidence evidence,
    PairingHarness h,
    BridgeUiHost host,
    String root,
    String scenario,
    bool Function() pinPresent) async {
  await driver.tapButton('开始配对');
  await _until(() => host.port.display().submissionId != null, 'enrollment');
  final id = host.port.display().submissionId!;
  evidence.record('enrollment_started', {'submissionBytes': id.length});
  await _step(evidence, 'pre-publication-check', () async {
    final proofPublished = host.port.display().proofPublished;
    final pin = pinPresent();
    final proof = h.native.calls.exchangeFiles.keys.any((key) => key.$1 == 3);
    evidence.record('pre_publication_check', {
      'proofPublished': proofPublished,
      'pinPresent': pin,
      'proofPresent': proof,
    });
    if (proofPublished || pin || proof) {
      throw StateError('Enrollment pre-published Proof or Pin');
    }
  });
  await _step(evidence, 'publish-submission', () async {
    await exportExchange(h, link.root, PairingLinkFile.submission);
    await link.publishText(PairingLinkFile.submissionId, id);
  });
  await driver.screenshot(p.join(root, 'bridge-1-enrollment.png'));

  final trust = await link.waitText(PairingLinkFile.trust,
      timeout: const Duration(seconds: 60));
  await importExchange(h, link.root, PairingLinkFile.challenge);
  await driver.enterField('粘贴 App Trust 公共 JSON', trust);
  await driver.tapButton('导入 Trust');
  await _until(
      () => host.port.display().initialDigest != null, 'initial digest');
  final initial = host.port.display().initialDigest!;
  final peerInitial = await link.waitText(PairingLinkFile.initialDigest,
      timeout: const Duration(seconds: 60));
  final compared = peerInitial.trim() == initial;
  evidence.record('trust_imported', {
    'initialDigestLength': initial.length,
    'independentlyEqual': compared,
    'proofPublished': host.port.display().proofPublished,
    'pinPresent': pinPresent(),
  });
  if (!compared) throw StateError('Initial digests differ');
  await link.publishText(PairingLinkFile.bridgeInitialDigest, initial);
  await driver.screenshot(p.join(root, 'bridge-2-compare.png'));

  await driver.tapText('我已与受信任 App 独立比较完整初始摘要，且完全相同');
  await driver.tapButton('确认初始比较并发布 Proof');
  await _until(() => host.port.display().proofPublished, 'proof');
  if (pinPresent()) {
    throw StateError('Pin existed before completion comparison');
  }
  await exportExchange(h, link.root, PairingLinkFile.proofExchange);
  await link.publishText(PairingLinkFile.proofPublished, '1');
  evidence.record('proof_published', {'pinPresent': false});
  await driver.screenshot(p.join(root, 'bridge-3-proof.png'));

  if (scenario == pairingHostPeerAbort) {
    await _waitOrTimeout(
        () async =>
            (await link.readIfPresent(PairingLinkFile.completion)) != null,
        const Duration(seconds: 15));
    if ((await link.readIfPresent(PairingLinkFile.completion)) == null) {
      await driver.tapButton('取消配对');
      await _until(() => host.port.display().closed, 'peer cancellation');
      evidence.record('peer_absent_cancel', {
        'closed': host.port.display().closed,
        'pinPresent': pinPresent(),
      });
      if (pinPresent()) {
        throw StateError('Peer absence produced a Pin');
      }
      return;
    }
  }

  final completion = await link.waitText(PairingLinkFile.completion,
      timeout: const Duration(seconds: 60));
  final meta = (await link.waitText(PairingLinkFile.completionMeta)).trim();
  await driver.enterField('粘贴 App Completion 公共 JSON', completion);
  await driver.tapButton('导入 Completion');
  await _until(
      () => host.port.display().completionDigest != null, 'completion');
  final displayed = host.port.display();
  final expected = '${displayed.revision}|${displayed.completionDigest}';
  evidence.record('completion_imported', {
    'independentlyEqual': meta == expected,
    'pinPresent': pinPresent(),
  });
  if (meta != expected) throw StateError('Completion display differs');
  await driver.screenshot(p.join(root, 'bridge-4-completion.png'));

  await driver.tapText('我已再次独立比较 App 的完整完成摘要及实际 Revision，且均相同');
  await driver.tapButton('确认完成比较并保存凭据');
  await _until(() => host.port.display().pinSaved, 'pin save');
  if (!pinPresent()) throw StateError('Pin was not saved');
  evidence.record('pin_saved', {'pinPresent': true});
  await link.publishText(PairingLinkFile.saved, '1');
  await driver.screenshot(p.join(root, 'bridge-5-saved.png'));
  await host.closeForBusiness();
  if (!h.bridgeOwner.isClosed || !host.port.display().closed) {
    throw StateError('Pairing custody did not settle');
  }
  final lock =
      await File(p.join(root, 'bridge-host', BridgeUiHost.lockFileName))
          .open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
  } finally {
    await lock.close();
  }
  evidence.record('business_handoff_settled', {
    'controllerClosed': true,
    'ownerClosed': true,
    'hostLockReleased': true,
  });
}

Future<T> _step<T>(PairingHostEvidence evidence, String name,
    Future<T> Function() work) async {
  try {
    return await work();
  } catch (error) {
    evidence.record('step_failed', {
      'step': name,
      'failure': safeFailure(error),
    });
    rethrow;
  }
}

Future<void> _until(bool Function() condition, String name,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= timeout) throw StateError('Timed out: $name');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> _waitOrTimeout(
    Future<bool> Function() ready, Duration timeout) async {
  final watch = Stopwatch()..start();
  while (!await ready()) {
    if (watch.elapsed >= timeout) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
