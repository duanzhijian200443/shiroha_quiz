// Isolated compiled test entry ONLY. Never selected by the formal AOT entry.
// Existing Fake Native, public RFC6979 key and Fake TLS carry original P9 bytes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/composition/mcp_vnext_windows_acquisition.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_bootstrap.dart';
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/external_bootstrap_bytes.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_credential_object_store.dart';

import '../../data/external/bootstrap_test_support.dart';
import '../../data/external/external_native_test_support.dart';
import '../../data/external/fixtures/public_fixture_crypto.dart';
import 'windows_process_channel.dart';

final class _ObservedStdioCustody implements McpVnextWindowsProcessOwner {
  _ObservedStdioCustody(this.session);
  final Directory session;
  final _custody = McpVnextWindowsStdioCustody(stdout);
  @override
  Future<void> stopAndWait() {
    File(p.join(session.path, 'close-entered')).writeAsStringSync('closing');
    return _custody.stopAndWait();
  }
}

Future<void> main(List<String> arguments) async {
  RandomAccessFile? lock;
  McpVnextWindowsBridgeBootstrap? bootstrap;
  Timer? crash;
  try {
    if (arguments.length != 1 || !p.isAbsolute(arguments.single)) {
      throw StateError('isolated root required');
    }
    final root = Directory(arguments.single);
    if (await File(p.join(root.path, 'isolated-bootstrap')).readAsString() !=
        'public-fake-security-only') {
      throw StateError('isolated marker required');
    }
    // Models cross-process exclusion only in this Fake backend. It proves no
    // production client.lock/DPAPI property and performs no native security I/O.
    lock = await File(p.join(root.path, 'fake-bridge-owner.lock'))
        .open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    final material = jsonDecode(
        await File(p.join(root.path, 'public-material.json'))
            .readAsString()) as Map;
    Uint8List bytes(String key) => base64Decode(material[key] as String);
    final calls = FakeExternalNativeCalls()..associationCrypto = true;
    WindowsExternalNative native() => WindowsExternalNative.openForTesting(
        windows: true,
        executable: r'C:\isolated\fixture.exe',
        exists: (_) => true,
        load: (_) => calls);
    final seed = native().acquireBridgeObjects();
    WindowsCredentialObjectStore(seed).write(ExternalBridgeClient(
        clientPkcs8Der: publicFixtureKey(),
        clientLeafDer: bytes('client'),
        issuerCertificateDer: bytes('issuer'),
        pinnedInstallationId: material['installation'] as String,
        pinnedDiscoveryEpochHighWater:
            BigInt.parse(material['epoch'] as String)));
    seed.close();
    for (final row in material['discovery'] as List) {
      calls.discoveryFiles[row[0] as int] = base64Decode(row[1] as String);
    }
    final session = await Directory(p.join(root.path, 'session-$pid')).create();
    calls.onSuccessfulOwnerClose = () =>
        File(p.join(session.path, 'owner-closed')).writeAsStringSync('closed');
    final watch = Stopwatch()..start();
    var connection = 0;
    final trusted = DiscoveryExpectations(
        trustedAnchorDer: bytes('issuer'),
        installationId: material['installation'] as String,
        serverLeafDigest: bytes('serverDigest'),
        verifiedEpochHighWater: BigInt.parse(material['epoch'] as String));
    final acquirer = McpVnextWindowsProtectedAcquirer(
        utcNow: () => DateTime.parse(material['now'] as String),
        monotonicNow: () => watch.elapsed,
        compositionIsCurrent: () => true,
        randomBytes: (_) =>
            throw StateError('no key generation during bootstrap'),
        openNative: native,
        primitives: McpVnextWindowsCredentialPrimitives(
            generateKey: () => throw StateError('no key generation'),
            signDigest: signPublicFixture,
            verifyDigest: (
                {required publicPoint,
                required digest,
                required rawSignature}) {
              if (!offlineVerify(
                  publicPoint: publicPoint,
                  digest: digest,
                  rawSignature: rawSignature)) {
                throw StateError('public signature rejected');
              }
            },
            nativePolicy: (der, _) {
              if (!bootstrapEqual(der, bytes('server'))) {
                throw StateError('fake peer mismatch');
              }
            }));
    bootstrap = McpVnextWindowsBridgeBootstrap(
        acquirer: acquirer,
        requireSecurityAdmission: () async {
          if (material['security'] != 'fake-only') {
            throw StateError('unadmitted');
          }
        },
        independentTrust: () async => trusted,
        process: _ObservedStdioCustody(session),
        createIo: () =>
            ProcessTestBridgeIo(session, connection++, bytes('server')),
        enableStageApprovalWait: true);
    crash = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (File(p.join(session.path, 'crash')).existsSync()) exit(23);
    });
    await File(p.join(session.path, 'ready')).writeAsString('$pid');
    await serveWindowsBridgeStdio(bootstrap: bootstrap);
    if (calls.owners.isNotEmpty ||
        calls.allocations.isNotEmpty ||
        calls.credentialTickets.isNotEmpty) {
      throw StateError('fake ownership unsettled');
    }
    await File(p.join(session.path, 'settled')).writeAsString('closed');
  } catch (_) {
    stderr.writeln('isolatedBootstrapRejected');
    exitCode = 78;
  } finally {
    crash?.cancel();
    // A failed close is never converted into a successful receipt.
    await bootstrap?.close();
    await lock?.close();
  }
}
