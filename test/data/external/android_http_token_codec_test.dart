import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/application/external/external_runtime_admission.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/external/android_association_store.dart';
import 'package:shiroha_quiz/data/external/android_http_token_codec.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:uuid/uuid.dart';

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
  bool occupied = false;

  @override
  Future<AndroidAssociationLease> begin() async {
    if (occupied) throw StateError('overlap');
    occupied = true;
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
  }

  @override
  Future<void> close() async {
    owner.occupied = false;
  }
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
    var enableWithdrawnCount = 0;
    final revokedCallbacks = <String>[];

    const installationId = '30000000-0000-4000-8000-000000000001';

    AndroidHttpClientCredentials buildCredentials(
      AndroidAssociationStore targetStore,
      ExternalAuthorizationManagement targetMgmt,
    ) {
      port = AndroidHttpCredentialPort();
      trust = ExternalTrustCore(
        credentials: port,
        clock: clock,
        mintProfileId: const Uuid().v4,
        maxProfiles: 64,
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
        installationId: installationId,
        mintRequestId: () => 'req-${++req}',
        onRevokeFailureWithdrawEnable: () async {
          enableWithdrawnCount++;
        },
        onProfileRevoked: (profileId, _) async {
          revokedCallbacks.add(profileId);
        },
      );
    }

    setUp(() async {
      enableWithdrawnCount = 0;
      revokedCallbacks.clear();
      db = GeneratedHarness();
      await db.open();
      clock = _Clock(DateTime.utc(2026, 11, 26, 12, 0));
      backend = _MemoryBackend();
      store = AndroidAssociationStore.forHttp(
        backend,
        nowUtcMs: () => clock.now().millisecondsSinceEpoch,
      );
      management = ExternalAuthorizationManagement(
        repository: SqliteExternalAuthorizationRepository(
          databaseHelper: db.helper,
        ),
        compositionIsCurrent: () => db.db.isOpen,
        mintProfileId: const Uuid().v4,
        clock: clock.now,
      );
      credentials = buildCredentials(store, management);
    });

    tearDown(() async {
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

      final enabled = await credentials.enableActiveClients(
        duration: const Duration(hours: 1),
      );
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

    test(
        'tokens survive stop/restart/re-enable and reissue revokes old with tombstone',
        () async {
      final clientA = await credentials.issueClient(displayName: 'Codex Main');
      await credentials.enableActiveClients(duration: const Duration(hours: 1));
      expect(
        await credentials
            .authenticateAuthorizationHeader(['Bearer ${clientA.token}']),
        isNotNull,
      );

      credentials.disableAllActiveClients();
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
      await credentials.enableActiveClients(duration: const Duration(hours: 1));
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
  });
}
