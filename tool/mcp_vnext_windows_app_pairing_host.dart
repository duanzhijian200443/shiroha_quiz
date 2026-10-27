/// Test-only isolated App-side pairing window for the AR-R6B dual-process check.
///
/// It reuses the actual first-party authorization page and App control over the
/// existing public mathematical/Fake Native pairing fixtures. It is not the
/// production App entrypoint: normal startup still reports the external
/// composition unavailable and installs no credential or transport binding.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart'
    show PairingState;
import 'package:shiroha_quiz/application/external/first_party_external_access.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/ui/dependencies/first_party_external_scope.dart';
import 'package:shiroha_quiz/ui/pages/external_authorization_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test/application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../test/data/external/fixtures/public_pairing_process_support.dart'
    show exportExchange, importExchange;
import '../test/data/external/windows_pairing_test.dart' show PairingHarness;
import '../test/mcp/fixtures/first_party_app_integration_cases.dart'
    show FirstPartyAppHarness;
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
      PairingHostEvidence(File(p.join(root.path, 'app-events.jsonl')));
  final link = PairingHostLink(Directory(p.join(root.path, 'link')));
  await link.prepare();

  // The pairing fixture's synthetic database must be established before the App
  // harness switches the shared runtime profile; this is the proven test order.
  final pairing = PairingHarness();
  await pairing.open();
  final app = FirstPartyAppHarness();
  await app.open(attach: false);
  app.files.s.clock.current = pairing.native.now;
  final verifier = WindowsPairingVerification.withPrimitives(
      verifyDigest: pairing.native.verify,
      utcNow: () => pairing.native.now,
      monotonicNow: () => pairing.elapsed,
      compositionIsCurrent: () => pairing.current && app.controls.isCurrent);
  final installationId =
      pairing.native.service.validatedPublicMaterial().installationId;
  await app.integration.attachCredentials(
      associations: pairing.associations,
      verification: (_) => verifier,
      clock: app.files.s.clock,
      installationId: installationId,
      monotonicNow: () => pairing.elapsed,
      readiness:
          OfflineReadiness(() async => app.files.s.h.db.rawQuery('SELECT 1')),
      services: (boundary) {
        final owner = WindowsAppPairing.withPrimitives(
            exchange: pairing.appExchange,
            credentials: pairing.native.service,
            boundary: boundary,
            associations: pairing.associations,
            verification: verifier,
            utcNow: () => pairing.native.now,
            monotonicNow: () => pairing.elapsed,
            compositionIsCurrent: () =>
                pairing.current && app.controls.isCurrent,
            randomBytes: pairing.random);
        return FirstPartyCredentialServices(
            boundary: boundary,
            pairing: WindowsAppPublicPairingHandoff(owner: owner),
            openConnection: (_) async =>
                throw StateError('Connection unavailable'),
            close: () async {});
      });

  final surface = GlobalKey();
  final driver = PairingUiDriver(surface);
  evidence.record('host_ready', {'scenario': scenario});
  runApp(FirstPartyExternalLifetime(
      access: app.controls,
      close: () async {
        try {
          await app.close();
          await pairing.close();
          evidence.record('resources_closed');
        } catch (error) {
          evidence.record('resource_close_failed', {
            'failure': safeFailure(error),
          });
          rethrow;
        }
      },
      child: RepaintBoundary(
          key: surface,
          child: MaterialApp(
              title: 'Shiroha App Pairing',
              debugShowCheckedModeBanner: false,
              home: ExternalAuthorizationScreen(service: app.policy)))));
  unawaited(() async {
    try {
      await _script(driver, link, evidence, app, pairing, root.path, scenario);
      await link.publishText('app-script-complete', '1');
      evidence.record('script_complete');
    } catch (error) {
      evidence.record('script_failed', {'failure': safeFailure(error)});
    }
  }());
}

/// The product control refreshes status on its own timer; a local read may
/// legitimately lose the single-flight race. Polling retries instead of failing.
Future<FirstPartyExternalStatus?> _status(FirstPartyAppHarness app) async {
  for (var attempt = 0; attempt < 6; attempt++) {
    try {
      return await app.controls.status();
    } on ExternalAuthException {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
  return null;
}

Future<void> _script(
    PairingUiDriver driver,
    PairingHostLink link,
    PairingHostEvidence evidence,
    FirstPartyAppHarness app,
    PairingHarness pairing,
    String root,
    String scenario) async {
  await _selectProfile(driver, app);
  evidence.record('profile_selected');

  await importExchange(pairing, link.root, PairingLinkFile.submission);
  final id = (await link.waitText(PairingLinkFile.submissionId)).trim();
  await driver.enterField('粘贴 Bridge 原 Submission ID（32 位小写十六进制）', id);
  await _tapAndWait(driver, '请求配对', () async {
    final display = (await _status(app))?.pairingDisplay;
    return display?.submissionId == id;
  }, 'request');
  await exportExchange(pairing, link.root, PairingLinkFile.challenge);
  evidence.record('request_created', {'submissionBytes': id.length});

  await driver.tapButton('导出 Trust 公共数据');
  final trust = await driver.waitKeyedText(const Key('external-public-export'),
      timeout: const Duration(seconds: 20));
  final initial = (await _untilStatus(app, 'initial')).pairingDisplay!.digest!;
  await link.publishText(PairingLinkFile.trust, trust);
  await link.publishText(PairingLinkFile.initialDigest, initial);
  await driver.screenshot(p.join(root, 'app-1-trust.png'));
  evidence.record('trust_exported', {'initialDigestLength': initial.length});

  if (scenario == pairingHostPeerAbort) {
    evidence.record('abort_after_trust');
    await link.publishText('app-aborted', '1');
    exit(0);
  }

  final bridgeInitial =
      (await link.waitText(PairingLinkFile.bridgeInitialDigest)).trim();
  final initialEqual = bridgeInitial == initial;
  evidence.record('initial_compared', {'independentlyEqual': initialEqual});
  if (!initialEqual) throw StateError('Initial digests differ');

  await link.wait(PairingLinkFile.proofExchange);
  await importExchange(pairing, link.root, PairingLinkFile.proofExchange);
  await _approvePairing(driver, app);
  await link.publishText(PairingLinkFile.approved, '1');
  evidence.record('pairing_approved');
  await _tapAndWait(
      driver,
      '验证配对证明',
      () async => (await _status(app))?.pairingDisplay?.revision != null,
      'completion');
  await driver.screenshot(p.join(root, 'app-2-completed.png'));
  evidence.record('completion_verified');

  await driver.tapButton('导出 Completion 公共数据');
  final completion = await driver.waitKeyedText(
      const Key('external-public-export'),
      timeout: const Duration(seconds: 20));
  final display =
      (await _untilStatus(app, 'completion display')).pairingDisplay!;
  await link.publishText(PairingLinkFile.completion, completion);
  await link.publishText(
      PairingLinkFile.completionMeta, '${display.revision}|${display.digest}');
  evidence.record('completion_exported', {'revision': display.revision!});

  await link.wait(PairingLinkFile.saved, timeout: const Duration(seconds: 60));
  final status = await _untilStatus(app, 'final status');
  final session = await app.controls.authenticatedSession();
  final appPin = pairing.native.calls.credentialFiles[4];
  evidence.record('no_access_after_pairing', {
    'enabled': status.enabled,
    'authenticatedSession': session != null,
    'appPinPresent': appPin != null,
  });
  if (status.enabled || session != null || appPin != null) {
    throw StateError('Pairing produced access authority');
  }
  await driver.screenshot(p.join(root, 'app-3-no-access.png'));
}

Future<void> _selectProfile(
    PairingUiDriver driver, FirstPartyAppHarness app) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    if ((await _status(app))?.profileId != null) return;
    // A missed option tap leaves the original modal open and its opener busy.
    // Retry that same visible choice; never wait for the covered opener or
    // bypass the product dialog by selecting directly through Application.
    if (!driver.hasText('选择授权 Profile')) {
      if (!driver.hasText('选择连接 Profile')) {
        if (!driver.hasText('首次配对与连接诊断')) {
          await driver.scrollToBottom();
        }
        await driver.tapText('首次配对与连接诊断');
      }
      await driver.tapButton('选择连接 Profile');
    }
    try {
      await driver.tapText('Synthetic client',
          timeout: const Duration(seconds: 10));
    } on StateError {
      continue;
    }
    try {
      await _until(
          () async => (await _status(app))?.profileId != null, 'profile',
          timeout: const Duration(seconds: 12));
      return;
    } on StateError {
      // The dialog may have closed without selecting; retry the user action.
    }
  }
  throw StateError('Timed out: profile');
}

Future<void> _approvePairing(
    PairingUiDriver driver, FirstPartyAppHarness app) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    await driver.tapButton('确认配对');
    try {
      await driver.tapButton('批准配对', timeout: const Duration(seconds: 8));
      await _until(
          () async =>
              (await _status(app))?.pairing ==
              PairingState.approvedPendingProof,
          'approval',
          timeout: const Duration(seconds: 12));
      return;
    } on StateError {
      // Retry the explicit two-step human action.
    }
  }
  throw StateError('Timed out: approval');
}

/// A synthetic pointer tap can miss during a layout/animation boundary; the
/// effect is always re-verified and re-tapped a bounded number of times.
Future<void> _tapAndWait(PairingUiDriver driver, String label,
    Future<bool> Function() done, String name) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    await driver.tapButton(label);
    try {
      await _until(done, name, timeout: const Duration(seconds: 12));
      return;
    } on StateError {
      // Re-verify and retry the single explicit action.
    }
  }
  throw StateError('Timed out: $name');
}

Future<FirstPartyExternalStatus> _untilStatus(
    FirstPartyAppHarness app, String name) async {
  FirstPartyExternalStatus? status;
  await _until(() async {
    status = await _status(app);
    return status?.pairingDisplay != null;
  }, name);
  return status!;
}

Future<void> _until(Future<bool> Function() condition, String name,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed >= timeout) throw StateError('Timed out: $name');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
