import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/association_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_credential_association_store.dart';
import 'external_native_test_support.dart';

const profile = '00000000-0000-4000-8000-000000000001';
const other = '00000000-0000-4000-8000-000000000002';
const installation = '00000000-0000-4000-8000-000000000003';
final identity = 'ab' * 32;
Future<void> management() async {}
Matcher failure(ExternalCredentialFailure f) => throwsA(
    isA<ExternalCredentialException>().having((e) => e.failure, 'failure', f));

void main() {
  late FakeExternalNativeCalls calls;
  late ExternalProtectedObjects owner;
  late WindowsCredentialAssociationStore store;
  Future<ExternalCredentialAssociationSnapshot> register(
          {String id = profile,
          int revision = 0,
          String? credential,
          Future<void> Function()? validate}) =>
      store.register(
          profileId: id,
          installationId: installation,
          credentialIdentity: credential ?? identity,
          expectedRevision: revision,
          validateManagement: validate ?? management);
  setUp(() {
    calls = FakeExternalNativeCalls()..associationCrypto = true;
    final native = WindowsExternalNative.openForTesting(
        windows: true,
        executable: r'C:\synthetic\app.exe',
        exists: (_) => true,
        load: (_) => calls);
    owner = native.acquireAppObjects();
    store = WindowsCredentialAssociationStore(owner, nowUtcMs: () => 42);
  });
  tearDown(() async {
    await store.close();
    owner.close();
    expect(calls.allocations, isEmpty);
    expect(calls.tickets, isEmpty);
    expect(calls.owners, isEmpty);
  });
  test(
      'read-only identity lookup shares protected uniqueness and monotonic snapshots',
      () async {
    expect((await store.findCredential(identity)).record, isNull);
    await register();
    final selected = await store.findCredential(identity);
    expect(selected.record!.profileId, profile);
    expect(selected.isCurrent, isTrue);
    expect((await store.findCredential('cd' * 32)).record, isNull);
    await expectLater(store.findCredential(identity.toUpperCase()),
        failure(ExternalCredentialFailure.invalidInput));
    await store.revoke(
        profileId: profile,
        expectedRevision: 1,
        validateManagement: management);
    expect(selected.isCurrent, isFalse);
    expect((await store.findCredential(identity)).record, isNull);
    expect(calls.commits, 2);
  });
  test('no constructor store access; every read reloads actual ciphertext',
      () async {
    expect(calls.tickets, isEmpty);
    expect(calls.commits, 0);
    final absent = await store.read(profile);
    expect(absent.record, isNull);
    expect(absent.isCurrent, isTrue);
    final first = await register();
    expect(first.record!.revision, 1);
    expect(first.isCurrent, isTrue);
    expect(absent.isCurrent, isFalse);
    final fresh = await store.read(profile);
    expect(fresh.record!.credentialIdentity, identity);
    calls.associationReadStatus = 4;
    await expectLater(store.read(profile),
        failure(ExternalCredentialFailure.temporarilyUnavailable));
    expect(first.isCurrent, isFalse);
    expect(fresh.isCurrent, isFalse);
    calls.associationReadStatus = 0;
    expect((await store.read(profile)).isCurrent, isTrue);
    expect(first.isCurrent, isFalse);
  });
  test(
      'CAS before idempotency, uniqueness, explicit revoke and tombstone revision',
      () async {
    final first = await register();
    await expectLater(
        register(), failure(ExternalCredentialFailure.staleRevision));
    await register(revision: 1);
    expect(calls.commits, 1);
    expect(first.isCurrent, isTrue);
    await expectLater(
        register(id: other), failure(ExternalCredentialFailure.conflict));
    await expectLater(register(revision: 1, credential: 'cd' * 32),
        failure(ExternalCredentialFailure.conflict));
    final tombstone = await store.revoke(
        profileId: profile,
        expectedRevision: 1,
        validateManagement: management);
    expect(tombstone.record!.revoked, isTrue);
    expect(tombstone.record!.revision, 2);
    expect(first.isCurrent, isFalse);
    await expectLater(
        register(), failure(ExternalCredentialFailure.staleRevision));
    await store.revoke(
        profileId: profile,
        expectedRevision: 2,
        validateManagement: management);
    expect(calls.commits, 2);
    final next = await register(revision: 2, credential: 'cd' * 32);
    expect(next.record!.revision, 3);
    expect(next.record!.revoked, isFalse);
  });
  test('concurrent expected-zero mutations have exactly one commit', () async {
    final reached = Completer<void>(), resume = Completer<void>();
    final first = register(validate: () async {
      reached.complete();
      await resume.future;
    });
    await reached.future;
    final second = register();
    final assertion =
        expectLater(second, failure(ExternalCredentialFailure.staleRevision));
    resume.complete();
    await first;
    await assertion;
    expect(calls.commits, 1);
  });
  test('management is rechecked after protection and before native commit',
      () async {
    await expectLater(register(validate: () async {
      expect(calls.capturedInput, isNotNull);
      expect(calls.commits, 0);
      throw const ExternalCredentialException(
          ExternalCredentialFailure.unauthorized);
    }), failure(ExternalCredentialFailure.unauthorized));
    expect(calls.associationFile, isNull);
    expect(calls.tickets, isEmpty);
  });
  test('lock/owner invalidation during management forbids mutation permanently',
      () async {
    final snapshot = await store.read(profile);
    await expectLater(register(validate: () async {
      calls.ownerStatus = 4;
    }), failure(ExternalCredentialFailure.temporarilyUnavailable));
    expect(calls.commits, 0);
    expect(snapshot.isCurrent, isFalse);
    calls.ownerStatus = 0;
    await expectLater(store.read(profile),
        failure(ExternalCredentialFailure.temporarilyUnavailable));
    expect(snapshot.isCurrent, isFalse);
  });
  test('corruption and failed decryption never become Missing or reset bytes',
      () async {
    await register();
    final snapshot = await store.read(profile);
    final malformed = Uint8List.fromList([0xda, 1, 0, 0, 0]);
    calls.associationFile = malformed;
    await expectLater(
        store.read(profile), failure(ExternalCredentialFailure.dataCorrupt));
    expect(calls.associationFile, same(malformed));
    expect(snapshot.isCurrent, isFalse);
    calls.associationFile = Uint8List.fromList([1, 2, 3]);
    await expectLater(
        store.read(profile), failure(ExternalCredentialFailure.dataCorrupt));
    expect(calls.commits, 1);
  });
  test(
      'unknown before/after replace never succeeds; fresh read resolves residue',
      () async {
    final missing = await store.read(profile);
    calls.associationCommitStatus = 7;
    await expectLater(
        register(), failure(ExternalCredentialFailure.commitUnknown));
    expect(calls.associationFile, isNull);
    expect(missing.isCurrent, isFalse);
    calls.associationCommitStatus = 0;
    calls.unknownAfterCommit = true;
    await expectLater(
        register(), failure(ExternalCredentialFailure.commitUnknown));
    calls.unknownAfterCommit = false;
    final current = await store.read(profile);
    expect(current.record!.revision, 1);
    await expectLater(
        register(), failure(ExternalCredentialFailure.staleRevision));
    await register(revision: 1);
    expect(calls.commits, 1);
  });
  test(
      'close while management awaits drains then rejects and kills old snapshots',
      () async {
    final old = await store.read(profile),
        reached = Completer<void>(),
        resume = Completer<void>();
    final writing = register(validate: () async {
      reached.complete();
      await resume.future;
    });
    await reached.future;
    final assertion = expectLater(
        writing, failure(ExternalCredentialFailure.temporarilyUnavailable));
    final closing = store.close();
    expect(old.isCurrent, isFalse);
    resume.complete();
    await assertion;
    await closing;
    expect(calls.commits, 0);
    expect(calls.tickets, isEmpty);
  });
  test('64 tombstones count towards cap; no deletion to bypass CAS', () async {
    final rows = [
      for (var n = 1; n <= 64; n++)
        AssociationObjectRecord(
            ExternalCredentialAssociation(
                profileId:
                    '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}',
                installationId: installation,
                credentialIdentity: identity,
                revision: 2,
                revoked: true),
            42)
    ];
    calls.associationFile =
        owner.protectAssociation(AssociationObjectCodec.encode(rows));
    await expectLater(register(id: '00000000-0000-4000-8000-000000000065'),
        failure(ExternalCredentialFailure.resourceLimit));
    final row = await store.read(profile);
    expect(row.record!.revoked, isTrue);
    expect(row.record!.revision, 2);
  });
  test(
      'same-runtime rollback and missing-after-existing reject without cached reads',
      () async {
    final older = await register();
    final bytes = Uint8List.fromList(calls.associationFile!);
    await store.revoke(
        profileId: profile,
        expectedRevision: 1,
        validateManagement: management);
    calls.associationFile = bytes;
    await expectLater(
        store.read(profile), failure(ExternalCredentialFailure.dataCorrupt));
    calls.associationFile = null;
    await expectLater(
        store.read(profile), failure(ExternalCredentialFailure.dataCorrupt));
    expect(older.isCurrent, isFalse);
  });
  test('multiple Store instances cannot interleave on one App owner', () async {
    final second = WindowsCredentialAssociationStore(owner),
        reached = Completer<void>(),
        resume = Completer<void>();
    final writing = register(validate: () async {
      reached.complete();
      await resume.future;
    });
    await reached.future;
    await expectLater(
        second.read(profile), failure(ExternalCredentialFailure.resourceLimit));
    resume.complete();
    await writing;
    final snap = await second.read(profile);
    await store.revoke(
        profileId: profile,
        expectedRevision: 1,
        validateManagement: management);
    expect(snap.isCurrent, isFalse);
    await second.close();
  });
  test('store re-initialization on the same owner retains revision high-water',
      () async {
    await register();
    final bytes = Uint8List.fromList(calls.associationFile!);
    await store.revoke(
        profileId: profile,
        expectedRevision: 1,
        validateManagement: management);
    await store.close();
    store = WindowsCredentialAssociationStore(owner);
    calls.associationFile = bytes;
    await expectLater(
        store.read(profile), failure(ExternalCredentialFailure.dataCorrupt));
  });
  test(
      'commit exception after durable mutation remains unknown through cleanup',
      () async {
    calls.throwAssociationAfterCommit = true;
    await expectLater(
        register(), failure(ExternalCredentialFailure.commitUnknown));
    expect(calls.commits, 1);
    expect(calls.tickets, isEmpty);
    calls.throwAssociationAfterCommit = false;
    expect((await store.read(profile)).record!.revision, 1);
  });
  test('unknown commit status and abort failure preserve unknown semantics',
      () async {
    calls.associationCommitStatus = 99;
    await expectLater(
        register(), failure(ExternalCredentialFailure.commitUnknown));
    calls.associationCommitStatus = 0;
    calls.throwAssociationAfterCommit = true;
    calls.throwAssociationAbort = true;
    await expectLater(
        register(), failure(ExternalCredentialFailure.commitUnknown));
    expect(calls.tickets, isEmpty);
    calls.throwAssociationAfterCommit = false;
    calls.throwAssociationAbort = false;
  });
  test('begin exception after acquisition releases ticket and native buffers',
      () async {
    calls.throwAssociationBegin = true;
    await expectLater(store.read(profile),
        failure(ExternalCredentialFailure.temporarilyUnavailable));
    expect(calls.tickets, isEmpty);
    expect(calls.allocations, isEmpty);
    calls.throwAssociationBegin = false;
  });
  test('DPAPI failure and queue exhaustion leave the old object untouched',
      () async {
    await register();
    final old = Uint8List.fromList(calls.associationFile!);
    calls.status = 3;
    await expectLater(
        store.revoke(
            profileId: profile,
            expectedRevision: 1,
            validateManagement: management),
        failure(ExternalCredentialFailure.resourceLimit));
    expect(calls.associationFile, old);
    calls.status = 0;
    final reached = Completer<void>(), resume = Completer<void>();
    final writing = store.revoke(
        profileId: profile,
        expectedRevision: 1,
        validateManagement: () async {
          reached.complete();
          await resume.future;
        });
    await reached.future;
    final reads = [for (var n = 0; n < 15; n++) store.read(profile)];
    await expectLater(
        store.read(profile), failure(ExternalCredentialFailure.resourceLimit));
    resume.complete();
    await writing;
    await Future.wait(reads);
  });
  test('invalid IDs, identity and revision deny without a Native transaction',
      () async {
    await expectLater(register(id: 'invalid'),
        failure(ExternalCredentialFailure.invalidInput));
    await expectLater(register(credential: 'invalid'),
        failure(ExternalCredentialFailure.invalidInput));
    await expectLater(register(revision: -1),
        failure(ExternalCredentialFailure.invalidInput));
    expect(calls.nextTicket, 1);
    expect(calls.commits, 0);
  });
}
