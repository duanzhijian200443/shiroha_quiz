import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/android_association_store.dart';

final class Backend implements AndroidAssociationBackend {
  @override
  bool isCurrent = true;
  Uint8List? bytes;
  int writes = 0;
  bool uncertain = false, occupied = false;
  @override
  Future<AndroidAssociationLease> begin() async {
    if (occupied) throw StateError('overlap');
    occupied = true;
    return Lease(this);
  }
}

final class Lease implements AndroidAssociationLease {
  Lease(this.owner);
  final Backend owner;
  @override
  bool get isCurrent => owner.isCurrent && owner.occupied;
  @override
  Uint8List? get plaintext =>
      owner.bytes == null ? null : Uint8List.fromList(owner.bytes!);
  @override
  Future<void> commit(Uint8List value) async {
    owner.bytes = Uint8List.fromList(value);
    owner.writes++;
    if (owner.uncertain) {
      credentialFail(ExternalCredentialFailure.commitUnknown);
    }
  }

  @override
  Future<void> close() async {
    owner.occupied = false;
  }
}

void main() {
  const profile = '10000000-0000-4000-8000-000000000001';
  const other = '10000000-0000-4000-8000-000000000002';
  const installation = '20000000-0000-4000-8000-000000000001';
  final credential = 'a' * 64;
  late Backend backend;
  late AndroidAssociationStore store;
  setUp(() {
    backend = Backend();
    store = AndroidAssociationStore(backend, nowUtcMs: () => 12345);
  });
  Future<ExternalCredentialAssociationSnapshot> register(
          {String id = profile,
          int revision = 0,
          Future<void> Function()? validate}) =>
      store.register(
          profileId: id,
          installationId: installation,
          credentialIdentity: credential,
          expectedRevision: revision,
          validateManagement: validate ?? () async {});
  Matcher failure(ExternalCredentialFailure code) =>
      throwsA(isA<ExternalCredentialException>()
          .having((e) => e.failure, 'fixed category', code));

  test(
      'same revision idempotency, CAS before idempotency and one active association',
      () async {
    final first = await register();
    expect(first.record!.revision, 1);
    await register(revision: 1);
    expect(backend.writes, 1);
    await expectLater(
        register(), failure(ExternalCredentialFailure.staleRevision));
    await expectLater(
        register(id: other), failure(ExternalCredentialFailure.conflict));
    expect(backend.writes, 1);
  });
  test('revoke keeps tombstone and invalidates old snapshots across reopen',
      () async {
    final first = await register();
    await store.revoke(
        profileId: profile,
        expectedRevision: 1,
        validateManagement: () async {});
    expect(first.isCurrent, isFalse);
    await store.close();
    store = AndroidAssociationStore(backend, nowUtcMs: () => 12346);
    final revoked = await store.read(profile);
    expect(revoked.record!.revoked, isTrue);
    expect(revoked.record!.revision, 2);
    expect((await store.findCredential(credential)).record, isNull);
    await expectLater(
        register(), failure(ExternalCredentialFailure.staleRevision));
  });
  test('management rejection at final boundary makes no write', () async {
    var calls = 0;
    await expectLater(register(validate: () async {
      if (++calls == 2) credentialFail(ExternalCredentialFailure.unauthorized);
    }), failure(ExternalCredentialFailure.unauthorized));
    expect(backend.writes, 0);
  });
  test('unknown commit never becomes success or an automatic retry', () async {
    backend.uncertain = true;
    await expectLater(
        register(), failure(ExternalCredentialFailure.commitUnknown));
    expect(backend.writes, 1);
    backend.uncertain = false;
    expect((await store.read(profile)).record!.revision, 1);
    expect(backend.writes, 1);
  });
  test('corruption and an observed outage permanently kill old snapshots',
      () async {
    final first = await register();
    backend.isCurrent = false;
    expect(first.isCurrent, isFalse);
    backend.isCurrent = true;
    expect(first.isCurrent, isFalse);
    backend.bytes = Uint8List.fromList([1, 2, 3]);
    await expectLater(
        store.read(profile), failure(ExternalCredentialFailure.dataCorrupt));
    expect(backend.writes, 1);
  });
  test('concurrent same expected revision has only one writer', () async {
    final results = await Future.wait([
      register().then((_) => true).catchError((_) => false),
      register().then((_) => true).catchError((_) => false)
    ]);
    expect(results.where((ok) => ok).length, 1);
    expect(backend.writes, 1);
  });
}
