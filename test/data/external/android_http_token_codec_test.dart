import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/application/external/external_runtime_admission.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/external/android_association_store.dart';
import 'package:shiroha_quiz/data/external/android_http_token_codec.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:uuid/uuid.dart';

import '../../application/external/external_trust_test_support.dart'
    show TrustManagementBarrier;
import '../../application/generated_question/generated_test_support.dart';

final class _Clock implements ExternalClock {
  _Clock(this.current);
  DateTime current;
  @override
  DateTime now() => current;
}

final class _MemoryBackend implements AndroidAssociationBackend {
  @override
  bool isCurrent = true;
  Uint8List? bytes;
  bool failCommit = false;
  bool loseCommitAcknowledgment = false;
  bool occupied = false;
  Future<void> Function()? beforeBegin;
  void Function()? afterCommit;

  @override
  Future<AndroidAssociationLease> begin() async {
    if (occupied) throw StateError('overlap');
    occupied = true;
    await beforeBegin?.call();
    return _MemoryLease(this);
  }
}

final class _MemoryLease implements AndroidAssociationLease {
  _MemoryLease(this.owner);
  final _MemoryBackend owner;

  @override
  bool get isCurrent => owner.isCurrent && owner.occupied;

  @override
  Uint8List? get plaintext =>
      owner.bytes == null ? null : Uint8List.fromList(owner.bytes!);

  @override
  Future<void> commit(Uint8List plaintext) async {
    if (owner.failCommit) {
      credentialFail(ExternalCredentialFailure.commitUnknown);
    }
    owner.bytes = Uint8List.fromList(plaintext);
    owner.afterCommit?.call();
    if (owner.loseCommitAcknowledgment) {
      owner.loseCommitAcknowledgment = false;
      credentialFail(ExternalCredentialFailure.commitUnknown);
    }
  }

  @override
  Future<void> close() async {
    owner.occupied = false;
  }
}

final class _InvalidateAfterCreate extends Fake
    implements ExternalAuthorizationRepository {
  _InvalidateAfterCreate(this.repository, this.invalidate);

  final SqliteExternalAuthorizationRepository repository;
  final void Function() invalidate;

  @override
  Future<ExternalAuthorizationRecord> create(
      ExternalClientProfile profile, void Function() validateManagement) async {
    final record = await repository.create(profile, validateManagement);
    invalidate();
    return record;
  }
}

final class _AccessPreparation
    implements AndroidAccessPreparation, AndroidAccessResources {
  @override
  Future<AndroidAccessResources> get result async => this;

  @override
  Future<void> get settled async {}

  @override
  void cancel() {}

  @override
  void withdraw() {}

  @override
  Future<void> close() async {}
}

void main() {
  initializeGeneratedTests();

  group('AndroidHttpTokenCodec', () {
    test('mints canonical 256-bit shq_ tokens with domain-separated SHA-256',
        () {
      final token = AndroidHttpTokenCodec.mint(random: Random(42));
      expect(token, startsWith('shq_'));
      expect(token.length, 47);
      expect(AndroidHttpTokenCodec.isWellFormedToken(token), isTrue);
      expect(AndroidHttpTokenCodec.parseBearerHeader(['Bearer $token']), token);
      expect(
          AndroidHttpTokenCodec.parseBearerHeader(['Bearer $token ']), isNull);
      expect(AndroidHttpTokenCodec.parseBearerHeader(['Basic $token']), isNull);
      expect(
          AndroidHttpTokenCodec.parseBearerHeader(
              ['Bearer $token', 'Bearer $token']),
          isNull);
      expect(AndroidHttpTokenCodec.parseBearerHeader(null), isNull);

      final badTail = '${token.substring(0, 46)}B';
      expect(AndroidHttpTokenCodec.isWellFormedToken(badTail), isFalse);
      expect(
        () => AndroidHttpTokenCodec.digestToken(badTail),
        throwsFormatException,
      );

      final digest = AndroidHttpTokenCodec.digestToken(token);
      expect(AndroidHttpTokenCodec.isValidDigest(digest), isTrue);
      final rawSha = sha256Hex(ascii.encode(token));
      final domainSha =
          sha256Hex(ascii.encode('shiroha-http-bearer-v1:$token'));
      expect(digest, domainSha);
      expect(digest, isNot(rawSha));

      expect(AndroidHttpTokenCodec.constantTimeDigestEquals(digest, digest),
          isTrue);
      final flipped =
          '${digest.substring(0, 63)}${digest.endsWith('0') ? '1' : '0'}';
      expect(AndroidHttpTokenCodec.constantTimeDigestEquals(digest, flipped),
          isFalse);
      expect(
          AndroidHttpTokenCodec.constantTimeDigestEquals(
              digest, digest.toUpperCase()),
          isFalse);
      expect(
          AndroidHttpTokenCodec.constantTimeDigestEquals(
              digest, digest.substring(0, 63)),
          isFalse);
    });
  });

  group('AndroidHttpClientCredentials', () {
    late GeneratedHarness db;
    late _Clock clock;
    late _MemoryBackend backend;
    late AndroidAssociationStore store;
    late ExternalAuthorizationManagement management;
    late AndroidHttpCredentialPort port;
    late ExternalTrustCore trust;
    late ExternalRuntimeAdmission admission;
    late AndroidHttpClientCredentials credentials;
    late AndroidForegroundAccess foreground;
    late SqliteExternalAuthorizationRepository repository;
    late TrustManagementBarrier managementBarrier;
    var enableWithdrawnCount = 0;
    var observationSequence = 0;
    var failPairing = false;
    final revokedCallbacks = <String>[];

    const installationId = '30000000-0000-4000-8000-000000000001';

    AndroidHttpClientCredentials buildCredentials(
      AndroidAssociationStore targetStore,
      ExternalAuthorizationManagement targetMgmt, {
      int maxProfiles = 16,
    }) {
      port = AndroidHttpCredentialPort();
      trust = ExternalTrustCore(
        credentials: port,
        clock: clock,
        mintProfileId: const Uuid().v4,
        maxProfiles: maxProfiles,
        maxEnableDuration: const Duration(hours: 8),
      );
      admission = ExternalRuntimeAdmission(
        trust: trust,
        management: targetMgmt,
        compositionIsCurrent: () => db.db.isOpen,
      );
      var req = 0;
      return AndroidHttpClientCredentials(
        associations: targetStore,
        management: targetMgmt,
        trust: trust,
        credentialPort: port,
        admission: admission,
        foreground: foreground,
        installationId: installationId,
        mintRequestId: () => failPairing ? '' : 'req-${++req}',
        onRevokeFailureWithdrawEnable: () async {
          enableWithdrawnCount++;
          await foreground.disable();
        },
        onProfileRevoked: (profileId, _) async {
          revokedCallbacks.add(profileId);
        },
      );
    }

    Future<void> prepareForeground() async {
      foreground.observe(AndroidForegroundObservation(
        sequence: ++observationSequence,
        resumed: true,
        focused: true,
        interactive: true,
        unlocked: true,
        visible: true,
        network: 'lab',
      ));
      await foreground.enable(
        (_) => _AccessPreparation(),
        duration: const Duration(hours: 1),
      );
    }

    Future<List<String>> enable() async {
      await prepareForeground();
      return credentials.enableActiveClients();
    }

    setUp(() async {
      enableWithdrawnCount = 0;
      observationSequence = 0;
      failPairing = false;
      revokedCallbacks.clear();
      db = GeneratedHarness();
      await db.open();
      clock = _Clock(DateTime.utc(2026, 11, 26, 12, 0));
      backend = _MemoryBackend();
      store = AndroidAssociationStore.forHttp(
        backend,
        nowUtcMs: () => clock.now().millisecondsSinceEpoch,
      );
      repository =
          SqliteExternalAuthorizationRepository(databaseHelper: db.helper);
      foreground = AndroidForegroundAccess(elapsed: () => Duration.zero);
      managementBarrier = TrustManagementBarrier(repository);
      management = ExternalAuthorizationManagement(
        repository: managementBarrier,
        compositionIsCurrent: () => db.db.isOpen,
        mintProfileId: const Uuid().v4,
        clock: clock.now,
      );
      credentials = buildCredentials(store, management);
    });

    tearDown(() async {
      credentials.disableAllActiveClients();
      await foreground.disable();
      await store.close();
      await db.close();
    });

    test(
        'default policy grants READ + questionContent only and redacts toString',
        () async {
      final issued = await credentials.issueClient(displayName: 'Codex Laptop');
      expect(issued.toString(), isNot(contains(issued.token)));
      expect(issued.toString(), contains('REDACTED'));

      final record = await management.read(issued.profileReference);
      expect(record.profile.adapter, AndroidHttpTokenCodec.adapterName);
      expect(record.profile.protocol, AndroidHttpTokenCodec.protocolName);
      expect(record.grant!.policy.permissions, {CapabilityPermission.read});
      expect(record.grant!.policy.categories,
          {ExternalContentCategory.questionContent});
      expect(record.grant!.policy.categories,
          isNot(contains(ExternalContentCategory.studyStatistics)));
      expect(record.grant!.policy.categories,
          isNot(contains(ExternalContentCategory.fileContent)));
    });

    test(
        'multi-client alternating auth, isolated single-client revoke, and fail-closed on durable revoke error',
        () async {
      final clientA = await credentials.issueClient(displayName: 'Client A');
      final clientB = await credentials.issueClient(displayName: 'Client B');
      final clientC = await credentials.issueClient(displayName: 'Client C');

      final enabled = await enable();
      expect(enabled, hasLength(3));

      final sA1 = await credentials
          .authenticateAuthorizationHeader(['Bearer ${clientA.token}']);
      final sB1 = await credentials
          .authenticateAuthorizationHeader(['Bearer ${clientB.token}']);
      final sA2 = await credentials
          .authenticateAuthorizationHeader(['Bearer ${clientA.token}']);
      expect(sA1, isNotNull);
      expect(sB1, isNotNull);
      expect(identical(sA1, sA2), isTrue);
      expect(sA1!.principal.profileId, clientA.clientProfileId);
      expect(sB1!.principal.profileId, clientB.clientProfileId);

      // Revoke A only: A is immediately denied; B and C stay live.
      await credentials.revokeClient(clientA.clientProfileId);
      expect(revokedCallbacks, [clientA.clientProfileId]);
      expect(enableWithdrawnCount, 0);
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientA.token}']),
        isNull,
      );
      expect(
          (await store.read(clientA.clientProfileId)).record!.revoked, isTrue);
      expect(
        (await management.read(clientA.profileReference))
            .profile
            .revokedAtUtcMs,
        isNotNull,
      );
      final sB2 = await credentials
          .authenticateAuthorizationHeader(['Bearer ${clientB.token}']);
      expect(sB2, isNotNull);
      expect(identical(sB2, sB1), isTrue);

      // Durable revoke failure on B fails closed and withdraws whole Enable.
      backend.failCommit = true;
      await expectLater(
        credentials.revokeClient(clientB.clientProfileId),
        throwsA(isA<ExternalCredentialException>()),
      );
      expect(enableWithdrawnCount, 1);
      expect(credentials.enableWindowOpen, isFalse);
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientC.token}']),
        isNull,
      );
    });

    test('withdrawal invalidates Enable before its pending store read settles',
        () async {
      final client =
          await credentials.issueClient(displayName: 'Delayed Enable');
      await prepareForeground();
      final entered = Completer<void>();
      final release = Completer<void>();
      backend.beforeBegin = () {
        entered.complete();
        return release.future;
      };
      final enabling = credentials.enableActiveClients();
      final refused = expectLater(
          enabling,
          throwsA(isA<ExternalCoreException>().having(
              (error) => error.failure, 'failure', ExternalFailure.cancelled)));
      await entered.future;
      credentials.disableAllActiveClients();
      await foreground.disable();
      backend.beforeBegin = null;
      release.complete();
      await refused;
      expect(credentials.enableWindowOpen, isFalse);
      expect(
          await credentials
              .authenticateAuthorizationHeader(['Bearer ${client.token}']),
          isNull);

      await enable();
      final original = await credentials
          .authenticateAuthorizationHeader(['Bearer ${client.token}']);
      expect(original, isNotNull);
      await expectLater(
        credentials.enableActiveClients(),
        throwsA(isA<ExternalCoreException>()),
      );

      // The lifecycle owner can withdraw on its own before HTTP sees another
      // request. An explicit new generation can reuse the same durable token.
      await foreground.disable();
      expect(original!.failure, isNotNull);
      await enable();
      final replacement = await credentials
          .authenticateAuthorizationHeader(['Bearer ${client.token}']);
      expect(replacement, isNotNull);
      expect(identical(original, replacement), isFalse);
    });

    for (final rebuildRuntime in [false, true]) {
      test(
          rebuildRuntime
              ? 'revocation during registration leaves Enable available to other clients'
              : 'revocation during binding leaves Enable available to other clients',
          () async {
        final target = await credentials.issueClient(displayName: 'Target');
        final sibling = await credentials.issueClient(displayName: 'Sibling');
        if (rebuildRuntime) {
          credentials = buildCredentials(store, management, maxProfiles: 1);
        }
        await prepareForeground();
        final entered = Completer<void>();
        final resume = Completer<void>();
        var reads = 0;
        managementBarrier.afterRead = (record) async {
          // A fresh runtime selects the Profile before registration. With
          // an existing Principal the third read instead belongs to binding.
          if (record.profile.clientProfileId != target.clientProfileId ||
              ++reads != 3) {
            return;
          }
          managementBarrier.afterRead = null;
          entered.complete();
          await resume.future;
        };
        final enabling = credentials.enableActiveClients();
        final enabled =
            expectLater(enabling, completion([sibling.clientProfileId]));
        await entered.future;
        try {
          await credentials.revokeClient(target.clientProfileId);
        } finally {
          resume.complete();
        }
        await enabled;
        expect(enableWithdrawnCount, 0);
        expect(
            await credentials
                .authenticateAuthorizationHeader(['Bearer ${target.token}']),
            isNull);
        expect(
            await credentials
                .authenticateAuthorizationHeader(['Bearer ${sibling.token}']),
            isNotNull);
      });
    }

    test('reserves the last slot and reissues a client at the active limit',
        () async {
      final old = await credentials.issueClient(displayName: 'Replaceable');
      final sibling = await credentials.issueClient(displayName: 'Sibling');
      for (var i = 2;
          i < AndroidAssociationStore.defaultHttpMaxActiveAssociations - 1;
          i++) {
        await credentials.issueClient(displayName: 'Synthetic $i');
      }
      final first = credentials.issueClient(displayName: 'Last slot');
      final rejected = expectLater(
        credentials.issueClient(displayName: 'Over capacity'),
        throwsA(isA<ExternalCredentialException>().having(
            (error) => error.failure,
            'failure',
            ExternalCredentialFailure.resourceLimit)),
      );
      await first;
      await rejected;
      final profiles = await repository.listProfiles();
      expect(profiles.items,
          hasLength(AndroidAssociationStore.defaultHttpMaxActiveAssociations));
      expect(profiles.items.map((item) => item.displayName),
          isNot(contains('Over capacity')));

      await enable();
      final oldSession = await credentials
          .authenticateAuthorizationHeader(['Bearer ${old.token}']);
      final siblingSession = await credentials
          .authenticateAuthorizationHeader(['Bearer ${sibling.token}']);
      expect(oldSession, isNotNull);
      expect(siblingSession, isNotNull);

      final replacement = credentials.reissueClient(
        oldProfileId: old.clientProfileId,
      );
      final overlapping = expectLater(
        credentials.issueClient(displayName: 'Overlapping issuance'),
        throwsA(isA<ExternalCredentialException>().having(
            (error) => error.failure,
            'failure',
            ExternalCredentialFailure.resourceLimit)),
      );
      final issued = await replacement;
      await overlapping;
      expect((await store.listActive()).records,
          hasLength(AndroidAssociationStore.defaultHttpMaxActiveAssociations));
      expect((await store.read(old.clientProfileId)).record?.revoked, isTrue);
      expect(
          (await repository.read(old.clientProfileId)).profile.revokedAtUtcMs,
          isNotNull);
      expect(oldSession!.failure, ExternalFailure.revoked);
      expect(
          await credentials
              .authenticateAuthorizationHeader(['Bearer ${old.token}']),
          isNull);
      expect(
          await credentials
              .authenticateAuthorizationHeader(['Bearer ${sibling.token}']),
          same(siblingSession));
      final session = await credentials
          .authenticateAuthorizationHeader(['Bearer ${issued.token}']);
      expect(session?.principal.profileId, issued.clientProfileId);
    });

    test('reissue at the durable record limit keeps the original client',
        () async {
      final old = await credentials.issueClient(displayName: 'Original');
      for (var i = 1; i < AndroidAssociationStore.maxRecords; i++) {
        final id = const Uuid().v4();
        await store.register(
          profileId: id,
          installationId: installationId,
          credentialIdentity: 'a' * 64,
          expectedRevision: 0,
          validateManagement: () async {},
        );
        await store.revoke(
          profileId: id,
          expectedRevision: 1,
          validateManagement: () async {},
        );
      }
      await enable();
      final oldSession = await credentials
          .authenticateAuthorizationHeader(['Bearer ${old.token}']);
      expect(oldSession, isNotNull);
      await expectLater(
        credentials.reissueClient(oldProfileId: old.clientProfileId),
        throwsA(isA<ExternalCredentialException>().having(
            (error) => error.failure,
            'failure',
            ExternalCredentialFailure.resourceLimit)),
      );
      expect((await store.listActive()).records.single.profileId,
          old.clientProfileId);
      expect((await repository.listProfiles()).items.single.revokedAtUtcMs,
          isNull);
      expect(
          await credentials
              .authenticateAuthorizationHeader(['Bearer ${old.token}']),
          same(oldSession));
      expect(revokedCallbacks, isEmpty);
    });

    test('reissue of a revoked Grant requires an explicit new policy',
        () async {
      final original = await credentials.issueClient(
        displayName: 'Original',
        initialPolicy: ExternalGrantPolicy(
          permissions: [CapabilityPermission.read],
          scopes: const [],
          categories: [ExternalContentCategory.studyStatistics],
        ),
      );
      await management.revokeGrant(original.profileReference, 1);

      await expectLater(
        credentials.reissueClient(oldProfileId: original.clientProfileId),
        throwsA(isA<ExternalCredentialException>().having(
            (error) => error.failure,
            'failure',
            ExternalCredentialFailure.unauthorized)),
      );
      expect((await store.read(original.clientProfileId)).record?.revoked,
          isFalse);
      expect((await repository.listProfiles()).items, hasLength(1));
      expect(revokedCallbacks, isEmpty);

      final replacement = await credentials.reissueClient(
        oldProfileId: original.clientProfileId,
        policyOverride: androidHttpDefaultReadPolicy(),
      );
      final newRecord = await management.read(replacement.profileReference);
      expect(newRecord.grant?.policy.categories,
          {ExternalContentCategory.questionContent});
    });

    test('a Grant change during capacity preflight rejects implicit reissue',
        () async {
      final original = await credentials.issueClient(displayName: 'Original');
      final entered = Completer<void>();
      final resume = Completer<void>();
      backend.beforeBegin = () {
        backend.beforeBegin = null;
        entered.complete();
        return resume.future;
      };
      final rejected = expectLater(
        credentials.reissueClient(oldProfileId: original.clientProfileId),
        throwsA(isA<ExternalCredentialException>().having(
            (error) => error.failure,
            'failure',
            ExternalCredentialFailure.staleRevision)),
      );
      await entered.future;
      try {
        await management.replaceGrant(
            original.profileReference, 1, androidHttpDefaultReadPolicy());
      } finally {
        resume.complete();
      }

      await rejected;
      final old = (await repository.listProfiles()).items.single;
      expect(old.grantRevision, 2);
      expect(old.revokedAtUtcMs, isNull);
      expect((await store.read(original.clientProfileId)).record?.revoked,
          isFalse);
      expect(revokedCallbacks, isEmpty);
    });

    test('a Grant change at the final SQLite CAS prevents implicit reissue',
        () async {
      final original = await credentials.issueClient(displayName: 'Original');
      await enable();
      backend.afterCommit = () {
        backend.afterCommit = null;
        managementBarrier.afterRead = (record) async {
          if (record.profile.clientProfileId != original.clientProfileId) {
            return;
          }
          managementBarrier.afterRead = null;
          await management.replaceGrant(
              original.profileReference, 1, androidHttpDefaultReadPolicy());
        };
      };

      await expectLater(
        credentials.reissueClient(oldProfileId: original.clientProfileId),
        throwsA(isA<ExternalAuthException>().having((error) => error.failure,
            'failure', ExternalAuthFailure.staleRevision)),
      );
      final old = (await repository.listProfiles()).items.single;
      expect(old.grantRevision, 2);
      expect(old.revokedAtUtcMs, isNull);
      expect(
          (await store.read(original.clientProfileId)).record?.revoked, isTrue);
      expect(enableWithdrawnCount, 1);
      expect(credentials.enableWindowOpen, isFalse);
    });

    test('failed local pairing releases its revoked P0 slot for the next issue',
        () async {
      credentials = buildCredentials(store, management, maxProfiles: 1);
      failPairing = true;
      await expectLater(
        credentials.issueClient(displayName: 'Failed preparation'),
        throwsA(isA<ExternalCredentialException>()),
      );
      expect((await store.listActive()).records, isEmpty);
      final afterFailure = await repository.listProfiles();
      expect(afterFailure.items.single.revokedAtUtcMs, isNotNull);
      failPairing = false;
      final issued = await credentials.issueClient(displayName: 'Replacement');
      expect((await store.listActive()).records.single.profileId,
          issued.clientProfileId);
      await expectLater(
        credentials.issueClient(displayName: 'P0 full'),
        throwsA(isA<ExternalCredentialException>().having(
            (error) => error.failure,
            'failure',
            ExternalCredentialFailure.resourceLimit)),
      );
      expect((await repository.listProfiles()).items, hasLength(2));
    });

    test(
        'withdrawal after SQLite create reports the original Profile for recovery',
        () async {
      final originalId = const Uuid().v4();
      late final ExternalAuthorizationManagement invalidatedManagement;
      invalidatedManagement = ExternalAuthorizationManagement(
        repository: _InvalidateAfterCreate(
            repository, () => invalidatedManagement.invalidate()),
        compositionIsCurrent: () => db.db.isOpen,
        mintProfileId: () => originalId,
        clock: clock.now,
      );
      credentials = buildCredentials(store, invalidatedManagement);

      await expectLater(
        credentials.issueClient(displayName: 'Interrupted after create'),
        throwsA(isA<AndroidHttpIssuanceRecoveryRequired>().having(
            (error) => error.profileId, 'original Profile', originalId)),
      );
      final original = await repository.read(originalId);
      expect(original.grant, isNull);
      expect(original.profile.revokedAtUtcMs, isNull);
      expect((await store.read(originalId)).record, isNull);

      credentials = buildCredentials(store, management);
      await credentials.revokeClient(originalId);
      final profiles = (await repository.listProfiles()).items;
      expect(profiles.single.clientProfileId, originalId);
      expect(profiles.single.revokedAtUtcMs, isNotNull);
      expect((await store.listActive()).records, isEmpty);
    });

    test('lost issuance acknowledgment reconciles only the unpublished Profile',
        () async {
      final sibling = await credentials.issueClient(displayName: 'Existing');
      backend.loseCommitAcknowledgment = true;
      await expectLater(
        credentials.issueClient(displayName: 'Unpublished'),
        throwsA(isA<ExternalCredentialException>().having(
            (error) => error.failure,
            'failure',
            ExternalCredentialFailure.commitUnknown)),
      );
      final failed = (await repository.listProfiles())
          .items
          .singleWhere((profile) => profile.displayName == 'Unpublished');
      expect(failed.revokedAtUtcMs, isNotNull);
      final tombstone = (await store.read(failed.clientProfileId)).record;
      expect(tombstone?.revoked, isTrue);
      expect(tombstone?.revision, 2);
      expect((await store.listActive()).records.single.profileId,
          sibling.clientProfileId);
    });

    test(
        'tokens survive stop/restart/re-enable and reissue revokes old with tombstone',
        () async {
      final clientA = await credentials.issueClient(displayName: 'Codex Main');
      await enable();
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientA.token}']),
        isNotNull,
      );

      credentials.disableAllActiveClients();
      await foreground.disable();
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientA.token}']),
        isNull,
      );

      // Simulate restart / new runtime + reopened store (e.g., after IP change).
      await store.close();
      store = AndroidAssociationStore.forHttp(
        backend,
        nowUtcMs: () => clock.now().millisecondsSinceEpoch,
      );
      credentials = buildCredentials(store, management);

      // Startup performs zero automatic credential hydration or enablement.
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientA.token}']),
        isNull,
      );

      // Explicit local Enable restores access with the exact same Token.
      await enable();
      final resumed = await credentials
          .authenticateAuthorizationHeader(['Bearer ${clientA.token}']);
      expect(resumed, isNotNull);
      expect(resumed!.principal.profileId, clientA.clientProfileId);

      // Re-issue revokes old profile (tombstone preserved) and mints new profile/token.
      final reissued = await credentials.reissueClient(
        oldProfileId: clientA.clientProfileId,
      );
      expect(reissued.clientProfileId, isNot(clientA.clientProfileId));
      expect(reissued.token, isNot(clientA.token));
      expect(
          (await store.read(clientA.clientProfileId)).record!.revoked, isTrue);
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientA.token}']),
        isNull,
      );
      final newSession = await credentials
          .authenticateAuthorizationHeader(['Bearer ${reissued.token}']);
      expect(newSession, isNotNull);
      expect(newSession!.principal.profileId, reissued.clientProfileId);
    });

    test(
        'locked continueWhileLocked refuses brand-new clients without minting P0 sessions',
        () async {
      final clientA = await credentials.issueClient(displayName: 'Client A');
      final clientB = await credentials.issueClient(displayName: 'Client B');
      final clientC = await credentials.issueClient(displayName: 'Client C');

      foreground.observe(AndroidForegroundObservation(
        sequence: ++observationSequence,
        resumed: true,
        focused: true,
        interactive: true,
        unlocked: true,
        visible: true,
        backgroundRead: true,
        network: 'lab',
      ));
      await foreground.enable(
        (_) => _AccessPreparation(),
        duration: AndroidAccessDuration.untilAppStops.limit,
        allowBackgroundRead: true,
        continueWhileLocked: true,
      );
      await credentials.enableActiveClients();

      // Client A authenticates while unlocked; Client B and C do not.
      final sessionA = await credentials
          .authenticateAuthorizationHeader(['Bearer ${clientA.token}']);
      expect(sessionA, isNotNull);
      expect(
          identical(
              credentials.activeSessionFor(clientA.clientProfileId), sessionA),
          isTrue);
      expect(credentials.activeSessionFor(clientB.clientProfileId), isNull);

      // Revoke C before locking to verify revoked clients stay unauthenticated.
      await credentials.revokeClient(clientC.clientProfileId);

      // Lock device while foreground service keeps backgroundRead active.
      foreground.observe(AndroidForegroundObservation(
        sequence: ++observationSequence,
        resumed: false,
        focused: false,
        interactive: false,
        unlocked: false,
        visible: false,
        backgroundRead: true,
        network: 'lab',
      ));
      expect(foreground.allowsAuthenticatedUse, isTrue);
      expect(foreground.acceptsNew, isFalse);

      // Already-authenticated Client A continues with the exact same Session.
      final continuedA =
          await credentials.authenticateRequest(['Bearer ${clientA.token}']);
      expect(
        continuedA,
        isA<AndroidHttpAuthenticated>()
            .having((r) => r.session, 'session', same(sessionA)),
      );
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientA.token}']),
        same(sessionA),
      );

      // Brand-new Client B is refused without minting or caching a P0 Session.
      final refusedB =
          await credentials.authenticateRequest(['Bearer ${clientB.token}']);
      expect(
        refusedB,
        isA<AndroidHttpLockedNewClientRefused>()
            .having((r) => r.profileId, 'profileId', clientB.clientProfileId),
      );
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientB.token}']),
        isNull,
      );
      expect(credentials.activeSessionFor(clientB.clientProfileId), isNull);

      // Revoked Client C remains unauthenticated (not locked-new-client 403).
      expect(
        await credentials.authenticateRequest(['Bearer ${clientC.token}']),
        isA<AndroidHttpUnauthenticated>(),
      );
    });
  });
}
