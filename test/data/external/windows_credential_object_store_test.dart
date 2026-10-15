import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_credential_object_store.dart';

import 'bootstrap_test_support.dart';
import 'external_native_test_support.dart';

WindowsExternalNative adapter(FakeExternalNativeCalls calls) =>
    WindowsExternalNative.openForTesting(
        windows: true,
        executable: r'C:\offline\app.exe',
        exists: (_) => true,
        load: (_) => calls);

ExternalCredentialObject fixture(int kind) => switch (kind) {
      1 => ExternalIssuerKeyPair(
          installationId: bootstrapVector['installationId'] as String,
          publicationEpoch: BigInt.zero,
          issuerPkcs8Der: unhex(
              '3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721'),
          issuerCertificateDer: vectorBytes('issuerDer')),
      2 => ExternalServerKeyChain(
          serverPkcs8Der: unhex(
              '3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721'),
          serverLeafDer: vectorBytes('serverDer'),
          issuerCertificateDer: vectorBytes('issuerDer')),
      _ => ExternalBridgeClient(
          clientPkcs8Der: unhex(
              '3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721'),
          clientLeafDer: vectorBytes('clientDer'),
          issuerCertificateDer: vectorBytes('issuerDer'),
          pinnedInstallationId: bootstrapVector['installationId'] as String,
          pinnedDiscoveryEpochHighWater: BigInt.one),
    };
Matcher failure(ExternalCredentialFailure value) =>
    isA<ExternalCredentialException>()
        .having((e) => e.failure, 'failure', value);

void main() {
  for (final kind in [1, 2, 4]) {
    test('kind $kind fake Protect/Commit/Read/Unprotect independent snapshot',
        () {
      final calls = FakeExternalNativeCalls()..associationCrypto = true;
      final native = adapter(calls);
      final owner = kind == 4
          ? native.acquireBridgeObjects()
          : native.acquireAppObjects();
      final store = WindowsCredentialObjectStore(owner);
      expect(store.read(kind), isNull);
      final object = fixture(kind), expected = fixture(kind).encode();
      store.write(object);
      expect(calls.credentialFiles.keys, [kind]);
      expect(calls.credentialFiles[kind], isNot(expected));
      final snapshot = store.read(kind)!;
      expect(snapshot.encode(), expected);
      final privateBytes = switch (snapshot) {
        ExternalIssuerKeyPair() => snapshot.issuerPkcs8Der,
        ExternalServerKeyChain() => snapshot.serverPkcs8Der,
        ExternalBridgeClient() => snapshot.clientPkcs8Der,
      };
      privateBytes.fillRange(0, privateBytes.length, 0);
      expect(store.read(kind)!.encode(), expected);
      store.write(
          object); // Existing-target replacement, without initialization.
      expect(calls.commits, 2);
      expect(calls.credentialTickets, isEmpty);
      expect(calls.allocations, isEmpty);
      expect(store.toString(), 'WindowsCredentialObjectStore(REDACTED)');
      owner.close();
      expect(calls.owners, isEmpty);
    });

    test('kind $kind corruption cannot be repaired by write', () {
      final calls = FakeExternalNativeCalls()..associationCrypto = true;
      final native = adapter(calls);
      final owner = kind == 4
          ? native.acquireBridgeObjects()
          : native.acquireAppObjects();
      final store = WindowsCredentialObjectStore(owner);
      final valid = fixture(kind).encode();
      final malformed = <Uint8List>[
        Uint8List.fromList([1, 2]), // DPAPI rejection.
        Uint8List.fromList([0xda, 1, ...valid.sublist(0, valid.length - 1)]),
        Uint8List.fromList([0xda, 1, ...valid, 0]),
        Uint8List.fromList([0xda, 1, ...(Uint8List.fromList(valid)..[0] ^= 1)]),
        Uint8List.fromList([0xda, 1, ...(Uint8List.fromList(valid)..[8] = 2)]),
        Uint8List.fromList([0xda, 1, ...(Uint8List.fromList(valid)..[9] = 3)]),
        Uint8List.fromList([0xda, 1, ...fixture(kind == 1 ? 2 : 1).encode()]),
        Uint8List(65537),
      ];
      // Invalid outer DER tag inside a correctly framed object.
      final invalidDer = Uint8List.fromList(valid);
      final derOffset = kind == 1 ? 10 + 2 + 36 + 8 + 2 : 12;
      invalidDer[derOffset] = 0x31;
      malformed.add(Uint8List.fromList([0xda, 1, ...invalidDer]));
      for (final bytes in malformed) {
        calls.credentialFiles[kind] = bytes;
        expect(() => store.read(kind),
            throwsA(failure(ExternalCredentialFailure.dataCorrupt)));
        expect(() => store.write(fixture(kind)),
            throwsA(failure(ExternalCredentialFailure.dataCorrupt)));
        expect(calls.credentialFiles[kind], same(bytes));
        expect(calls.commits, 0);
        expect(calls.credentialTickets, isEmpty);
        expect(calls.allocations, isEmpty);
      }
      owner.close();
    });

    test('kind $kind distinguishes I/O, uncertain commit and no retry', () {
      final calls = FakeExternalNativeCalls()..associationCrypto = true;
      final native = adapter(calls);
      final owner = kind == 4
          ? native.acquireBridgeObjects()
          : native.acquireAppObjects();
      final store = WindowsCredentialObjectStore(owner);
      calls.associationReadStatus = 4;
      expect(() => store.read(kind),
          throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
      calls.associationReadStatus = 0;
      calls.unknownAfterCommit = true;
      expect(() => store.write(fixture(kind)),
          throwsA(failure(ExternalCredentialFailure.commitUnknown)));
      expect(calls.commits, 1);
      expect(store.read(kind)!.kind,
          kind); // Explicit reconciliation, never automatic retry.
      calls.unknownAfterCommit = false;
      calls.throwAssociationAfterCommit = true;
      expect(() => store.write(fixture(kind)),
          throwsA(failure(ExternalCredentialFailure.commitUnknown)));
      expect(calls.commits, 2);
      expect(calls.credentialTickets, isEmpty);
      expect(calls.allocations, isEmpty);
      owner.close();
    });
  }

  test('role isolation, ticket exclusion, Abort and Owner Close', () {
    final calls = FakeExternalNativeCalls()..associationCrypto = true;
    final native = adapter(calls),
        app = native.acquireAppObjects(),
        bridge = native.acquireBridgeObjects();
    final appStore = WindowsCredentialObjectStore(app),
        bridgeStore = WindowsCredentialObjectStore(bridge);
    for (final kind in [0, 3, 4, 5, -1]) {
      expect(() => appStore.read(kind),
          throwsA(failure(ExternalCredentialFailure.invalidInput)));
    }
    for (final kind in [1, 2]) {
      expect(() => bridgeStore.write(fixture(kind)),
          throwsA(failure(ExternalCredentialFailure.invalidInput)));
    }
    final txn = app.beginCredential(1);
    expect(() => appStore.read(2),
        throwsA(failure(ExternalCredentialFailure.resourceLimit)));
    final other = bridge.beginCredential(4); // Independent root.
    other.abort();
    other.abort();
    txn.abort();
    txn.abort();
    final pending = app.beginCredential(2);
    app.close();
    pending.abort();
    expect(calls.credentialTickets, isEmpty);
    expect(() => appStore.read(1),
        throwsA(failure(ExternalCredentialFailure.invalidInput)));
    bridge.close();
    expect(calls.allocations, isEmpty);
  });

  test('throwing Begin, allocation and abort failures release once and redact',
      () {
    final calls = FakeExternalNativeCalls()..associationCrypto = true;
    final owner = adapter(calls).acquireAppObjects();
    final store = WindowsCredentialObjectStore(owner);
    calls.throwAssociationBegin = true;
    expect(() => store.read(1),
        throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(calls.credentialTickets, isEmpty);
    calls.throwAssociationBegin = false;
    calls.failAllocation = calls.allocationCount + 2;
    expect(() => store.read(1),
        throwsA(failure(ExternalCredentialFailure.resourceLimit)));
    expect(calls.allocations, isEmpty);
    calls.failAllocation = null;
    calls.throwAssociationAbort = true;
    expect(() => store.read(1),
        throwsA(failure(ExternalCredentialFailure.temporarilyUnavailable)));
    expect(calls.credentialTickets, isEmpty);
    expect(calls.allocations, isEmpty);
    expect(
        const ExternalNativeException(ExternalNativeFailure.dataCorrupt)
            .toString(),
        'ExternalNativeException(dataCorrupt)');
    owner.close();
  });
  test('uncertain transaction cannot retry Commit and owner remains held', () {
    final calls = FakeExternalNativeCalls()..associationCrypto = true;
    final owner = adapter(calls).acquireAppObjects();
    final transaction = owner.beginCredential(1);
    calls.throwAssociationAfterCommit = true;
    expect(
        () => transaction.commit(Uint8List.fromList([9])),
        throwsA(isA<ExternalNativeException>().having(
            (e) => e.failure, 'failure', ExternalNativeFailure.commitUnknown)));
    expect(
        () => transaction.commit(Uint8List.fromList([9])),
        throwsA(isA<ExternalNativeException>().having(
            (e) => e.failure, 'failure', ExternalNativeFailure.invalidInput)));
    expect(calls.commits, 1);
    expect(calls.owners, isNotEmpty);
    transaction.abort();
    transaction.abort();
    owner.close();
    expect(calls.allocations, isEmpty);
  });
}
