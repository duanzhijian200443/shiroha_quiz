import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_credential_object_store.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';

import 'bootstrap_test_support.dart';
import 'windows_credential_initialization_test.dart' as initialization;
import 'windows_credential_object_store_test.dart' as stores;

final _vectors = (jsonDecode(
        File('test/data/external/fixtures/discovery_publications_v1.json')
            .readAsStringSync()) as Map<String, dynamic>)['publications']
    as List<dynamic>;
Uint8List _sign(
    {required Uint8List pkcs8Der,
    required Uint8List publicPoint,
    required Uint8List digest}) {
  for (final dynamic row in _vectors) {
    if (initialization.digestHex(digest) ==
        initialization.digestHex(unhex(row['digest'] as String))) {
      expect(pkcs8Der, initialization.publicFixtureKey());
      expect(publicPoint, vectorBytes('point'));
      return unhex(row['signature'] as String);
    }
  }
  // P25's independently verified exact certificate vectors remain unchanged.
  final h = _active;
  return h.sign(pkcs8Der: pkcs8Der, publicPoint: publicPoint, digest: digest);
}

late initialization.Harness _active;

void main() {
  late initialization.Harness h;
  late WindowsCredentialInitialization credentials;
  late WindowsDiscoveryPublisher publisher;
  late ExternalProtectedObjects bridge;
  late WindowsDiscoveryReader reader;
  late WindowsCredentialObjectStore bridgeStore;
  DiscoveryDescriptor publish() => publisher.publish(
      runtimeInstanceId: vectorBytes('runtimeInstanceId'),
      generation: vectorInt('generation'),
      port: bootstrapVector['port'] as int,
      publishedAtUtcMs: vectorInt('publishedAtUtcMs'));
  ExternalIssuerKeyPair issuer() => h.store.read(1)! as ExternalIssuerKeyPair;
  void pin([BigInt? epoch]) {
    final original = stores.fixture(4) as ExternalBridgeClient;
    bridgeStore.write(ExternalBridgeClient(
        clientPkcs8Der: original.clientPkcs8Der,
        clientLeafDer: original.clientLeafDer,
        issuerCertificateDer: original.issuerCertificateDer,
        pinnedInstallationId: original.pinnedInstallationId,
        pinnedDiscoveryEpochHighWater: epoch ?? BigInt.one));
  }

  DiscoveryExpectations trusted([BigInt? highWater]) =>
      expectations(highWater: highWater ?? BigInt.one);
  void loadPublic(int epoch) {
    h.calls.discoveryFiles[1] = unhex(
        (_vectors[epoch - 1] as Map<String, dynamic>)['descriptor'] as String);
    h.calls.discoveryFiles[2] = vectorBytes('issuerDer');
    h.calls.discoveryFiles[3] = Uint8List.fromList(
        utf8.encode(bootstrapVector['installationId'] as String));
  }

  setUp(() {
    h = initialization.Harness();
    _active = h;
    h.seed(1);
    h.seed(2);
    credentials = WindowsCredentialInitialization.withPrimitives(
        owner: h.owner,
        generateKey: h.generate,
        signDigest: _sign,
        verifyDigest: h.verify,
        utcNow: () => h.now,
        randomBytes: (_) =>
            throw StateError('P26 must not generate entropy/identity'));
    publisher =
        WindowsDiscoveryPublisher(owner: h.owner, credentials: credentials);
    bridge = stores.adapter(h.calls).acquireBridgeObjects();
    bridgeStore = WindowsCredentialObjectStore(bridge);
    reader = WindowsDiscoveryReader(bridge, verifier: offlineVerify);
    h.calls.events.clear();
  });
  tearDown(() {
    bridge.close();
    h.dispose();
  });

  test(
      'persisted cryptographic pair, epoch 0 to 1 to 2, exact bytes and commit-before-publish',
      () {
    for (var i = 1; i <= 2; i++) {
      final result = publish();
      expect(result.publicationEpoch, BigInt.from(i));
      expect(issuer().publicationEpoch, BigInt.from(i));
      expect(
          h.calls.discoveryFiles[1],
          unhex((_vectors[i - 1] as Map<String, dynamic>)['descriptor']
              as String));
      expect(DiscoveryDescriptorCodec.encode(reader.read(trusted())),
          h.calls.discoveryFiles[1]);
    }
    expect(
        h.calls.events.where((event) =>
            event.startsWith('credential:') || event.startsWith('discovery:')),
        [
          'credential:1',
          'discovery:2',
          'discovery:3',
          'discovery:1',
          'credential:1',
          'discovery:2',
          'discovery:3',
          'discovery:1'
        ]);
    expect(h.generated, 0);
    expect(h.calls.associationFile, isNull);
    expect(h.calls.exchangeFiles, isEmpty);
    expect(publisher.toString(), 'WindowsDiscoveryPublisher(REDACTED)');
  });

  test(
      'only an existing trusted pin advances, equal epoch writes nothing, keys remain exact',
      () {
    loadPublic(2);
    pin();
    final before = bridgeStore.read(4)! as ExternalBridgeClient;
    expect(reader.readAndAdvanceExistingPin(trusted()).publicationEpoch,
        BigInt.two);
    final after = bridgeStore.read(4)! as ExternalBridgeClient;
    expect(after.clientPkcs8Der, before.clientPkcs8Der);
    expect(after.clientLeafDer, before.clientLeafDer);
    expect(after.issuerCertificateDer, before.issuerCertificateDer);
    expect(after.pinnedInstallationId, before.pinnedInstallationId);
    expect(after.pinnedDiscoveryEpochHighWater, BigInt.two);
    final commits = h.calls.commits;
    reader.readAndAdvanceExistingPin(trusted());
    expect(h.calls.commits, commits);
    loadPublic(1);
    expect(
        () => reader.readAndAdvanceExistingPin(trusted()),
        throwsA(
            stores.failure(ExternalCredentialFailure.verificationRejected)));
    expect(
        (bridgeStore.read(4)! as ExternalBridgeClient)
            .pinnedDiscoveryEpochHighWater,
        BigInt.two);
  });
  test('self-consistent directory never creates initial pin', () {
    loadPublic(1);
    expect(() => reader.readAndAdvanceExistingPin(trusted()),
        throwsA(stores.failure(ExternalCredentialFailure.unauthorized)));
    expect(h.calls.credentialFiles.containsKey(4), isFalse);
    expect(
        () => reader
            .read(expectations(anchor: changed(vectorBytes('issuerDer'), 10))),
        throwsA(
            stores.failure(ExternalCredentialFailure.verificationRejected)));
    expect(
        () => reader.read(expectations(
            installationId: '22222222-2222-4222-8222-222222222222')),
        throwsA(
            stores.failure(ExternalCredentialFailure.verificationRejected)));
    expect(
        () => reader.read(expectations(
            serverDigest: changed(vectorBytes('serverLeafDigest'), 0))),
        throwsA(
            stores.failure(ExternalCredentialFailure.verificationRejected)));
    expect(
        () => reader.read(trusted(BigInt.two)),
        throwsA(
            stores.failure(ExternalCredentialFailure.verificationRejected)));
  });
  test('partial three-file states and every descriptor mutation fail closed',
      () {
    for (final kind in [1, 2, 3]) {
      loadPublic(1);
      h.calls.discoveryFiles.remove(kind);
      expect(() => reader.read(trusted()),
          throwsA(isA<ExternalCredentialException>()));
    }
    loadPublic(1);
    final valid = Uint8List.fromList(h.calls.discoveryFiles[1]!);
    for (var i = 0; i < valid.length; i++) {
      h.calls.discoveryFiles[1] = changed(valid, i);
      expect(() => reader.read(trusted()),
          throwsA(isA<ExternalCredentialException>()),
          reason: 'bound byte $i');
    }
    for (final bytes in [Uint8List(0), Uint8List(184), Uint8List(186)]) {
      h.calls.discoveryFiles[1] = bytes;
      expect(() => reader.read(trusted()),
          throwsA(isA<ExternalCredentialException>()));
    }
  });
  test(
      'missing/corrupt/expired/unmatched credentials cannot consume epoch or publish',
      () {
    final issuerCipher = h.calls.credentialFiles[1]!,
        serverCipher = h.calls.credentialFiles[2]!;
    for (final kind in [1, 2]) {
      h.calls.credentialFiles.remove(kind);
      expect(publish, throwsA(isA<ExternalCredentialException>()));
      h.calls.credentialFiles[1] = issuerCipher;
      h.calls.credentialFiles[2] = serverCipher;
      h.calls.credentialFiles[kind] = Uint8List.fromList([0xda, 1, 0]);
      expect(publish,
          throwsA(stores.failure(ExternalCredentialFailure.dataCorrupt)));
      h.calls.credentialFiles[1] = issuerCipher;
      h.calls.credentialFiles[2] = serverCipher;
    }
    h.now = DateTime.utc(2040);
    expect(
        publish,
        throwsA(
            stores.failure(ExternalCredentialFailure.verificationRejected)));
    expect(h.calls.discoveryPublishes, 0);
  });
  test('invalid runtime inputs and u64 overflow never commit', () {
    final count = h.calls.commits;
    expect(
        () => publisher.publish(
            runtimeInstanceId: Uint8List(15),
            generation: BigInt.zero,
            port: 0,
            publishedAtUtcMs: BigInt.zero),
        throwsA(isA<ExternalCredentialException>()));
    expect(h.calls.commits, count);
    final original = stores.fixture(1) as ExternalIssuerKeyPair;
    h.seed(
        1,
        ExternalIssuerKeyPair(
            installationId: original.installationId,
            publicationEpoch: ExternalCredentialObjectCodec.maxEpoch,
            issuerPkcs8Der: original.issuerPkcs8Der,
            issuerCertificateDer: original.issuerCertificateDer));
    expect(publish,
        throwsA(stores.failure(ExternalCredentialFailure.dataCorrupt)));
    expect(issuer().publicationEpoch, ExternalCredentialObjectCodec.maxEpoch);
    expect(h.calls.discoveryFiles, isEmpty);
  });
  test('same-ticket epoch conflict and reentry cannot overwrite newer state',
      () {
    final expected = issuer();
    h.store.advancePublicationEpoch(expected, (_) {
      expect(() => h.store.read(2),
          throwsA(stores.failure(ExternalCredentialFailure.resourceLimit)));
    });
    expect(() => h.store.advancePublicationEpoch(expected, (_) {}),
        throwsA(stores.failure(ExternalCredentialFailure.conflict)));
    expect(issuer().publicationEpoch, BigInt.one);
  });
  test('epoch CAS covers upper unsigned range, and cannot create Missing', () {
    final original = stores.fixture(1) as ExternalIssuerKeyPair;
    h.seed(
        1,
        ExternalIssuerKeyPair(
            installationId: original.installationId,
            publicationEpoch:
                ExternalCredentialObjectCodec.maxEpoch - BigInt.one,
            issuerPkcs8Der: original.issuerPkcs8Der,
            issuerCertificateDer: original.issuerCertificateDer));
    expect(h.store.advancePublicationEpoch(issuer(), (_) {}),
        ExternalCredentialObjectCodec.maxEpoch);
    final snapshot = issuer();
    h.calls.credentialFiles.remove(1);
    expect(() => h.store.advancePublicationEpoch(snapshot, (_) {}),
        throwsA(stores.failure(ExternalCredentialFailure.conflict)));
    expect(h.calls.credentialFiles.containsKey(1), isFalse);
  });
  test('publication revalidates signing state after committed epoch', () {
    loadPublic(1);
    final prepared = credentials.prepareDiscoveryDescriptor(
        runtimeInstanceId: vectorBytes('runtimeInstanceId'),
        generation: vectorInt('generation'),
        port: bootstrapVector['port'] as int,
        publishedAtUtcMs: vectorInt('publishedAtUtcMs'));
    expect(
        credentials.validatePublication(prepared).publicationEpoch, BigInt.one);
    h.store.advancePublicationEpoch(issuer(), (_) {});
    expect(() => credentials.validatePublication(prepared),
        throwsA(stores.failure(ExternalCredentialFailure.conflict)));
    expect(issuer().publicationEpoch, BigInt.two);
  });
  test('epoch persisted but publication fails: retain skip, no rollback/retry',
      () {
    h.calls.discoveryStatus = 4;
    expect(
        publish,
        throwsA(
            stores.failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(issuer().publicationEpoch, BigInt.one);
    expect(h.calls.discoveryPublishes, 0);
    h.calls.discoveryStatus = 0;
    expect(publish().publicationEpoch, BigInt.two); // New explicit operation.
  });
  test('mismatched anchor/id remain untouched after epoch commit', () {
    h.calls.discoveryFiles[2] = Uint8List.fromList([1]);
    expect(publish,
        throwsA(stores.failure(ExternalCredentialFailure.dataCorrupt)));
    expect(h.calls.discoveryFiles[2], [1]);
    expect(h.calls.discoveryFiles.containsKey(1), isFalse);
    expect(issuer().publicationEpoch, BigInt.one);
  });
  test(
      'unknown epoch commit and unknown Discovery result never report success or retry',
      () {
    h.calls.unknownAfterCommit = true;
    expect(publish,
        throwsA(stores.failure(ExternalCredentialFailure.commitUnknown)));
    expect(issuer().publicationEpoch, BigInt.one);
    final commits = h.calls.commits;
    expect(
        publish,
        throwsA(
            stores.failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(h.calls.commits, commits);
    expect(h.calls.discoveryFiles, isEmpty);
  });
  test('FFI throw after endpoint rename is unknown and blocks this publisher',
      () {
    h.calls.beforeDiscoveryPublish = (kind) {
      h.calls.throwDiscovery = kind == 1;
    };
    expect(publish,
        throwsA(stores.failure(ExternalCredentialFailure.commitUnknown)));
    expect(h.calls.discoveryFiles.keys, containsAll([1, 2, 3]));
    // Observe synthetic backend bytes only; the affected Owner cannot be reused.
    final persisted = ExternalCredentialObjectCodec.decode(
            Uint8List.fromList(h.calls.credentialFiles[1]!.sublist(2)))
        as ExternalIssuerKeyPair;
    expect(persisted.publicationEpoch, BigInt.one);
    expect(h.owner.isUsable, isFalse);
    final count = h.calls.commits;
    expect(
        publish,
        throwsA(
            stores.failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(h.calls.commits, count);
    final replacement =
        WindowsDiscoveryPublisher(owner: h.owner, credentials: credentials);
    expect(
        () => replacement.publish(
            runtimeInstanceId: vectorBytes('runtimeInstanceId'),
            generation: vectorInt('generation'),
            port: bootstrapVector['port'] as int,
            publishedAtUtcMs: vectorInt('publishedAtUtcMs')),
        throwsA(stores.failure(ExternalCredentialFailure.invalidInput)));
    expect(h.calls.commits, count);
  });
  test('native commit-unknown status denies owner and latches the publisher',
      () {
    h.calls.beforeDiscoveryPublish = (kind) {
      if (kind == 1) h.calls.discoveryStatus = 7;
    };
    expect(publish,
        throwsA(stores.failure(ExternalCredentialFailure.commitUnknown)));
    expect(h.calls.discoveryFiles.keys, containsAll([2, 3]));
    expect(h.calls.discoveryFiles.containsKey(1), isFalse);
    expect(h.owner.isUsable, isFalse);
    final count = h.calls.commits;
    expect(
        publish,
        throwsA(
            stores.failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(h.calls.commits, count);
    final replacement =
        WindowsDiscoveryPublisher(owner: h.owner, credentials: credentials);
    expect(
        () => replacement.publish(
            runtimeInstanceId: vectorBytes('runtimeInstanceId'),
            generation: vectorInt('generation'),
            port: bootstrapVector['port'] as int,
            publishedAtUtcMs: vectorInt('publishedAtUtcMs')),
        throwsA(stores.failure(ExternalCredentialFailure.invalidInput)));
    expect(h.calls.commits, count);
  });
  test('Bridge cannot borrow App publisher or write objects', () {
    expect(
        () =>
            WindowsDiscoveryPublisher(owner: bridge, credentials: credentials),
        throwsA(stores.failure(ExternalCredentialFailure.invalidInput)));
    expect(() => bridge.publishDiscovery(1, Uint8List(185)),
        throwsA(isA<ExternalNativeException>()));
  });
  test(
      'FFI invalid lengths, allocation/release failure and lost owner return no data',
      () {
    loadPublic(1);
    h.calls.outputLength = 0;
    expect(
        () => bridge.readDiscovery(1), throwsA(isA<ExternalNativeException>()));
    h.calls.outputLength = 186;
    expect(
        () => bridge.readDiscovery(1), throwsA(isA<ExternalNativeException>()));
    h.calls.outputLength = null;
    h.calls.failAllocation = h.calls.allocationCount + 2;
    expect(
        () => bridge.readDiscovery(1), throwsA(isA<ExternalNativeException>()));
    expect(h.calls.allocations, isEmpty);
    h.calls.failAllocation = null;
    h.calls.throwFree = true;
    expect(
        () => h.owner.publishDiscovery(1, h.calls.discoveryFiles[1]!),
        throwsA(isA<ExternalNativeException>().having(
            (e) => e.failure, 'failure', ExternalNativeFailure.commitUnknown)));
    h.calls.throwFree = false;
    h.calls.ownerStatus = 4;
    expect(publish, throwsA(isA<ExternalCredentialException>()));
    h.calls.ownerStatus = 0;
    expect(h.calls.allocations, isEmpty);
  });
  test(
      'high-water CAS rejects racing change; failed/unknown commit returns no result',
      () {
    loadPublic(2);
    pin();
    var calls = 0;
    h.calls.beforeCredentialBegin = (kind) {
      if (kind == 4 && ++calls == 2) {
        h.calls.beforeCredentialBegin = null;
        final current = stores.fixture(4) as ExternalBridgeClient;
        final newer = ExternalBridgeClient(
            clientPkcs8Der: current.clientPkcs8Der,
            clientLeafDer: current.clientLeafDer,
            issuerCertificateDer: current.issuerCertificateDer,
            pinnedInstallationId: current.pinnedInstallationId,
            pinnedDiscoveryEpochHighWater: BigInt.from(3));
        h.calls.credentialFiles[4] =
            Uint8List.fromList([0xda, 1, ...newer.encode()]);
      }
    };
    expect(() => reader.readAndAdvanceExistingPin(trusted()),
        throwsA(stores.failure(ExternalCredentialFailure.conflict)));
    expect(
        (bridgeStore.read(4)! as ExternalBridgeClient)
            .pinnedDiscoveryEpochHighWater,
        BigInt.from(3));
    pin();
    h.calls.associationCommitStatus = 4;
    expect(
        () => reader.readAndAdvanceExistingPin(trusted()),
        throwsA(
            stores.failure(ExternalCredentialFailure.temporarilyUnavailable)));
    h.calls.associationCommitStatus = 0;
    h.calls.unknownAfterCommit = true;
    expect(() => reader.readAndAdvanceExistingPin(trusted()),
        throwsA(stores.failure(ExternalCredentialFailure.commitUnknown)));
    expect(
        (bridgeStore.read(4)! as ExternalBridgeClient)
            .pinnedDiscoveryEpochHighWater,
        BigInt.two);
  });
}
