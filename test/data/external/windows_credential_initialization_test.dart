import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/external_bootstrap_bytes.dart';
import 'package:shiroha_quiz/data/external/external_certificate_der.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_crypto.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_credential_object_store.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';

import 'bootstrap_test_support.dart';
import 'external_native_test_support.dart';
import 'windows_credential_object_store_test.dart' as store_test;

// Only the unchanged public RFC6979/P21 fixture key exists in these tests.
Uint8List publicFixtureKey() => unhex(
    '3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721');
String digestHex(List<int> bytes) =>
    (StreamingSha256()..update(bytes)).digestHex();
Uint8List digest(List<int> bytes) => unhex(digestHex(bytes));
Matcher failure(ExternalCredentialFailure f) => store_test.failure(f);

class Harness {
  Harness([FakeExternalNativeCalls? backend])
      : calls =
            backend ?? (FakeExternalNativeCalls()..associationCrypto = true) {
    owner = store_test.adapter(calls).acquireAppObjects();
    store = WindowsCredentialObjectStore(owner);
    service = WindowsCredentialInitialization.withPrimitives(
        owner: owner,
        generateKey: generate,
        signDigest: sign,
        verifyDigest: verify,
        utcNow: () => now,
        randomBytes: (count) {
          randomCalls++;
          if (randomError) throw StateError('synthetic secret random error');
          if (randomOverride != null) return randomOverride!(count);
          return unhex('112233445566778899aabbccddeeff00');
        });
  }
  final FakeExternalNativeCalls calls;
  late ExternalProtectedObjects owner;
  late WindowsCredentialObjectStore store;
  late WindowsCredentialInitialization service;
  DateTime now = DateTime.utc(2026, 10, 15);
  int generated = 0, randomCalls = 0, signs = 0, verified = 0;
  bool randomError = false, badSign = false;
  Uint8List Function(int)? randomOverride;
  void Function(int)? onGenerate;
  final privateBuffers = <Uint8List>[];

  ExternalP256KeyPair generate() {
    generated++;
    onGenerate?.call(generated);
    final bytes = publicFixtureKey();
    privateBuffers.add(bytes);
    return ExternalP256KeyPair(bytes, vectorBytes('point'));
  }

  Uint8List sign(
      {required Uint8List pkcs8Der,
      required Uint8List publicPoint,
      required Uint8List digest}) {
    signs++;
    if (digestHex(pkcs8Der) != digestHex(publicFixtureKey()) || badSign) {
      // A valid scalar signature for a different message fails real verification.
      return unhex('01'.padLeft(64, '0') * 2);
    }
    if (!bootstrapEqual(publicPoint, vectorBytes('point'))) {
      throw StateError('Synthetic public point mismatch');
    }
    for (final role in ExternalCertificateRole.values) {
      final cert = ExternalCertificateDer.inspect(
          vectorBytes('${role.name == 'issuer' ? 'issuer' : role.name}Der'),
          role: role);
      if (digestHex(cert.tbs) == _hex(digest)) return cert.rawSignature;
    }
    throw StateError('No fixed public signing vector for this digest');
  }

  void verify(
      {required Uint8List publicPoint,
      required Uint8List digest,
      required Uint8List rawSignature}) {
    verified++;
    // Independent test-only mathematical verifier, not a boolean-accepting fake.
    if (!offlineVerify(
        publicPoint: publicPoint, digest: digest, rawSignature: rawSignature)) {
      throw const ExternalNativeException(
          ExternalNativeFailure.verificationRejected);
    }
  }

  void seed(int kind, [ExternalCredentialObject? object]) =>
      store.write(object ?? store_test.fixture(kind));
  void dispose() {
    if (calls.allocations.isNotEmpty ||
        calls.credentialTickets.isNotEmpty ||
        privateBuffers.any((bytes) => bytes.any((value) => value != 0))) {
      throw StateError('Synthetic native custody did not settle');
    }
    owner.close();
    if (calls.owners.isNotEmpty) {
      throw StateError('Synthetic native owner did not settle');
    }
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.dispose());

  test('first create verifies exact P21 certs, zero epoch, UUID and reuse', () {
    final first = h.service.initialize();
    expect(first.state, ExternalInitializationState.initialized);
    expect(first.installationId, '11223344-5566-4788-99aa-bbccddeeff00');
    expect(first.publicationEpoch, BigInt.zero);
    expect(first.issuerCertificateDer, vectorBytes('issuerDer'));
    expect(first.serverLeafDer, vectorBytes('serverDer'));
    expect(h.calls.credentialFiles.keys, [1, 2]);
    expect(h.generated, 2);
    final repeat = h.service.initialize();
    expect(repeat.state, ExternalInitializationState.existing);
    expect(repeat.installationId, first.installationId);
    expect(h.generated, 2);
    expect(h.calls.commits, 2);
    expect(h.verified, greaterThan(8));
    expect(h.calls.associationFile, isNull);
    expect(h.calls.exchangeFiles, isEmpty);
    expect(h.calls.tickets, isEmpty);
    expect(first.toString(), isNot(contains(first.installationId)));
  });

  test('restricted Client issuance matches fixed DER and independent digest',
      () {
    h.service.initialize();
    final client = h.service.issueClientLeaf(vectorBytes('point'));
    expect(client.clientLeafDer, vectorBytes('clientDer'));
    expect(client.issuerCertificateDer, vectorBytes('issuerDer'));
    expect(client.credentialIdentity, bootstrapVector['credentialIdentity']);
    expect(h.generated, 2); // App never generates a Client private key.
    expect(h.calls.commits, 2);
    expect(h.calls.associationFile, isNull);
    expect(h.calls.exchangeFiles, isEmpty);
    expect(() => client.clientLeafDer[0] = 0, throwsUnsupportedError);
    expect(client.toString(), 'ExternalClientLeaf(REDACTED)');
  });

  test('partial Issuer is not implicitly repaired; explicit recovery reuses it',
      () {
    h.seed(1);
    final saved = Uint8List.fromList(h.calls.credentialFiles[1]!);
    final partial = h.service.initialize();
    expect(partial.state, ExternalInitializationState.incomplete);
    expect(partial.serverLeafDer, isNull);
    expect(h.generated, 0);
    expect(() => h.service.issueClientLeaf(vectorBytes('point')),
        throwsA(failure(ExternalCredentialFailure.unauthorized)));
    final restored = h.service.recoverServer();
    expect(restored.state, ExternalInitializationState.initialized);
    expect(h.generated, 1);
    expect(h.calls.credentialFiles[1], saved);
    expect(
        h.service.recoverServer().state, ExternalInitializationState.existing);
    expect(h.generated, 1);
  });

  test('orphan Server fails closed; recovery cannot mint a missing Issuer', () {
    expect(() => h.service.recoverServer(),
        throwsA(failure(ExternalCredentialFailure.unauthorized)));
    h.seed(2);
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.dataCorrupt)));
    expect(h.generated, 0);
  });

  for (final kind in [1, 2]) {
    test('corrupt kind $kind never becomes Missing or overwrite', () {
      if (kind == 2) h.seed(1);
      final corrupt = Uint8List.fromList([0xda, 1, 0x30, 0]);
      h.calls.credentialFiles[kind] = corrupt;
      expect(() => h.service.initialize(),
          throwsA(failure(ExternalCredentialFailure.dataCorrupt)));
      expect(h.generated, 0);
      expect(h.calls.credentialFiles[kind], same(corrupt));
    });

    test('kind $kind commitUnknown exits; next explicit read never rekeys', () {
      if (kind == 2) h.seed(1);
      h.calls.unknownAfterCommit = true;
      expect(
          () => h.service.initialize(),
          kind == 1
              ? throwsA(failure(ExternalCredentialFailure.commitUnknown))
              : returnsNormally);
      if (kind == 2) {
        expect(() => h.service.recoverServer(),
            throwsA(failure(ExternalCredentialFailure.commitUnknown)));
      }
      expect(h.generated, 1);
      final committed = Uint8List.fromList(h.calls.credentialFiles[1]!);
      h.calls.unknownAfterCommit = false;
      final result = h.service.initialize();
      expect(
          result.state,
          kind == 1
              ? ExternalInitializationState.incomplete
              : ExternalInitializationState.existing);
      expect(h.generated, 1);
      expect(h.calls.credentialFiles[1], committed);
    });
  }

  test('Server failure preserves committed Issuer without rollback', () {
    h.onGenerate = (n) {
      if (n == 2) h.calls.associationCommitStatus = 4;
    };
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(h.calls.credentialFiles.keys, [1]);
    final issuer = Uint8List.fromList(h.calls.credentialFiles[1]!);
    expect(
        h.service.initialize().state, ExternalInitializationState.incomplete);
    expect(h.generated, 2);
    h.calls.associationCommitStatus = 0;
    h.service.recoverServer();
    expect(h.calls.credentialFiles[1], issuer);
    expect(h.generated, 3);
  });

  test('actual private-key mismatch fails Issuer and Server validation', () {
    final issuer = store_test.fixture(1) as ExternalIssuerKeyPair;
    h.seed(
        1,
        ExternalIssuerKeyPair(
            installationId: issuer.installationId,
            publicationEpoch: issuer.publicationEpoch,
            issuerPkcs8Der: changed(issuer.issuerPkcs8Der, 66),
            issuerCertificateDer: issuer.issuerCertificateDer));
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.verificationRejected)));
    h.seed(1);
    final server = store_test.fixture(2) as ExternalServerKeyChain;
    h.seed(
        2,
        ExternalServerKeyChain(
            serverPkcs8Der: changed(server.serverPkcs8Der, 66),
            serverLeafDer: server.serverLeafDer,
            issuerCertificateDer: server.issuerCertificateDer));
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.verificationRejected)));
    expect(h.generated, 0);
  });

  test(
      'structure alone cannot admit bad self-signature or wrong Leaf signature',
      () {
    final issuer = store_test.fixture(1) as ExternalIssuerKeyPair;
    h.seed(
        1,
        ExternalIssuerKeyPair(
            installationId: issuer.installationId,
            publicationEpoch: issuer.publicationEpoch,
            issuerPkcs8Der: issuer.issuerPkcs8Der,
            issuerCertificateDer: changed(issuer.issuerCertificateDer,
                issuer.issuerCertificateDer.length - 1)));
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.verificationRejected)));
    h.seed(1);
    final server = store_test.fixture(2) as ExternalServerKeyChain;
    h.seed(
        2,
        ExternalServerKeyChain(
            serverPkcs8Der: server.serverPkcs8Der,
            serverLeafDer:
                changed(server.serverLeafDer, server.serverLeafDer.length - 1),
            issuerCertificateDer: server.issuerCertificateDer));
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.verificationRejected)));
    expect(h.generated, 0);
  });

  test('Server embedded Issuer must match exact persisted bytes', () {
    h.seed(1);
    final server = store_test.fixture(2) as ExternalServerKeyChain;
    h.seed(
        2,
        ExternalServerKeyChain(
            serverPkcs8Der: server.serverPkcs8Der,
            serverLeafDer: server.serverLeafDer,
            issuerCertificateDer: changed(server.issuerCertificateDer,
                server.issuerCertificateDer.length - 1)));
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.verificationRejected)));
  });

  test('wrong role, KU, EKU, SAN, curve and algorithm stored profiles reject',
      () {
    h.seed(1);
    for (final (old, replacement) in [
      ('551d130101ff04023000', '551d130101ff04023001'),
      ('551d0f0101ff040403020780', '551d0f0101ff040403020781'),
      ('2b06010505070301', '2b06010505070302'),
      ('87047f000001', '87047f000002'),
      ('2a8648ce3d030107', '2a8648ce3d030108'),
      ('2a8648ce3d040302', '2a8648ce3d040303'),
    ]) {
      final original = bootstrapVector['serverDer'] as String;
      expect(original, contains(old));
      h.seed(
          2,
          ExternalServerKeyChain(
              serverPkcs8Der: publicFixtureKey(),
              serverLeafDer: unhex(original.replaceFirst(old, replacement)),
              issuerCertificateDer: vectorBytes('issuerDer')));
      expect(() => h.service.initialize(),
          throwsA(failure(ExternalCredentialFailure.dataCorrupt)));
    }
    expect(h.generated, 0);
  });

  test('expired/not-yet-valid stored certificates reject without regeneration',
      () {
    h.seed(1);
    h.seed(2);
    for (final date in [
      DateTime.utc(2026, 10, 14),
      DateTime.utc(2028, 10, 14),
      DateTime.utc(2036, 10, 12)
    ]) {
      h.now = date;
      expect(() => h.service.initialize(),
          throwsA(failure(ExternalCredentialFailure.verificationRejected)));
    }
    expect(h.generated, 0);
  });

  test(
      'Client malformed/off-curve points are rejected before reading or signing',
      () {
    for (final point in [
      Uint8List(64),
      Uint8List(65)..[0] = 4,
      changed(vectorBytes('point'), 64),
      Uint8List(100000)
    ]) {
      expect(() => h.service.issueClientLeaf(point),
          throwsA(failure(ExternalCredentialFailure.verificationRejected)));
    }
    expect(h.signs, 0);
    expect(h.generated, 0);
  });

  test('time bounds, bad serial and random failure create no root', () {
    h.now = DateTime.utc(9999);
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.invalidInput)));
    h.now = DateTime.utc(2026, 10, 15);
    h.randomError = true;
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
    h.randomError = false;
    var calls = 0;
    h.randomOverride = (n) =>
        ++calls == 1 ? unhex('112233445566778899aabbccddeeff00') : Uint8List(n);
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.invalidInput)));
    expect(h.calls.commits, 0);
    expect(h.calls.credentialFiles, isEmpty);
  });

  test('failed generated signature clears key and does not commit', () {
    h.badSign = true;
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.verificationRejected)));
    expect(h.calls.commits, 0);
  });

  test('owner failure denies lifetime and never triggers retries', () {
    h.calls.ownerStatus = 4;
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(h.generated, 0);
    h.calls.ownerStatus = 0;
    expect(h.owner.isUsable, isFalse);
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.invalidInput)));
    expect(h.generated, 0);
  });

  test('DPAPI unavailable never triggers retries and clears generated key', () {
    h.calls.status = 4;
    expect(() => h.service.initialize(),
        throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(h.generated, 1);
    expect(h.calls.commits, 0);
  });

  for (final kind in [1, 2]) {
    test('competing kind $kind create is detected inside ticket without rekey',
        () {
      var begins = 0;
      h.calls.beforeCredentialBegin = (requestedKind) {
        if (requestedKind == kind && ++begins == (kind == 1 ? 2 : 3)) {
          h.calls.credentialFiles[kind] = Uint8List.fromList(
              [0xda, 1, ...store_test.fixture(kind).encode()]);
        }
      };
      expect(() => h.service.initialize(),
          throwsA(failure(ExternalCredentialFailure.conflict)));
      expect(h.generated, kind == 1 ? 0 : 1);
      expect(h.calls.commits, kind == 1 ? 0 : 1);
      expect(h.calls.credentialFiles[kind],
          [0xda, 1, ...store_test.fixture(kind).encode()]);
    });
  }

  test('reentrant initialize cannot create another trust root', () {
    h.onGenerate = (_) {
      expect(() => h.service.initialize(),
          throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
    };
    h.service.initialize();
    expect(h.generated, 2);
    expect(h.calls.commits, 2);
  });

  test('atomic create never invokes factory on existing/corrupt/held ticket',
      () {
    h.seed(1);
    expect(h.store.createIfMissing(1, () => fail('existing factory')), isFalse);
    final ticket = h.owner.beginCredential(2);
    expect(() => h.store.createIfMissing(1, () => fail('busy factory')),
        throwsA(failure(ExternalCredentialFailure.resourceLimit)));
    ticket.abort();
    h.calls.credentialFiles[1] = Uint8List.fromList([0]);
    expect(() => h.store.createIfMissing(1, () => fail('corrupt factory')),
        throwsA(failure(ExternalCredentialFailure.dataCorrupt)));
    expect(h.calls.commits, 1);
  });

  test(
      'atomic create has same-ticket exclusion, owns buffers and validates kind',
      () {
    final object = store_test.fixture(1) as ExternalIssuerKeyPair;
    expect(
        h.store.createIfMissing(1, () {
          expect(() => h.store.read(2),
              throwsA(failure(ExternalCredentialFailure.resourceLimit)));
          return object;
        }),
        isTrue);
    expect(object.issuerPkcs8Der, everyElement(0));
    expect(() => h.store.createIfMissing(2, () => store_test.fixture(1)),
        throwsA(failure(ExternalCredentialFailure.invalidInput)));
    expect(h.calls.commits, 1);
  });

  test('no inactive service consumer or authorization/IO surface is introduced',
      () {
    final own = 'lib/data/external/windows_credential_initialization.dart';
    final code = File(own).readAsStringSync();
    for (final token in [
      'dart:io',
      'PairingProof(',
      'Principal(',
      'Session(',
      'Association(',
      'print(',
      'debugPrint(',
      'Timer(',
      'SecurityContext',
      'Process.',
      'File(',
      'write('
    ]) {
      expect(code, isNot(contains(token)), reason: token);
    }
    for (final entry in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if ([
        own,
        'lib/data/external/windows_discovery.dart',
        'lib/data/external/windows_pairing.dart',
        'lib/data/external/windows_tls_credentials.dart',
        'lib/composition/mcp_vnext_windows_startup.dart',
        'lib/composition/mcp_vnext_windows_acquisition.dart'
      ].contains(entry.path.replaceAll('\\', '/'))) {
        continue;
      }
      expect(entry.readAsStringSync(),
          isNot(contains('WindowsCredentialInitialization')),
          reason: 'Inactive infrastructure must have no production consumer');
    }
  });
}
