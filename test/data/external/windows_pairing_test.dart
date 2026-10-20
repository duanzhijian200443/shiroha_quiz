import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_credential_boundary.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/external/exchange_message_codec.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/external_bootstrap_bytes.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_credential_association_store.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_credential_object_store.dart';
import 'package:shiroha_quiz/data/external/windows_exchange_file_store.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';

import '../../application/external/external_trust_test_support.dart';
import 'bootstrap_test_support.dart';
import 'windows_credential_initialization_test.dart' as initialization;
import 'windows_credential_object_store_test.dart' as objects;

// PUBLIC RFC6979 fixture only. Deliberately fixed k=1 is NOT production crypto.
// Arbitrary locally reconstructed transcripts are checked by the independent
// existing mathematical P-256 verifier, rather than an accepting boolean fake.
Uint8List signPublicFixture(
    {required Uint8List pkcs8Der,
    required Uint8List publicPoint,
    required Uint8List digest}) {
  expect(pkcs8Der.length, initialization.publicFixtureKey().length);
  expect(publicPoint, vectorBytes('point'));
  final n = BigInt.parse(
      'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
      radix: 16);
  final r = BigInt.parse(
      '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
      radix: 16);
  final d =
      BigInt.parse(hex(pkcs8Der.sublist(pkcs8Der.length - 32)), radix: 16);
  final z = BigInt.parse(hex(digest), radix: 16);
  return unhex(r.toRadixString(16).padLeft(64, '0') +
      ((z + r * d) % n).toRadixString(16).padLeft(64, '0'));
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class PairingHarness {
  final native = initialization.Harness();
  final local = OfflineTrustHarness();
  late ExternalProtectedObjects bridgeOwner;
  late WindowsCredentialObjectStore bridgeStore;
  late WindowsCredentialAssociationStore associations;
  late WindowsExchangeFileStore appExchange, bridgeExchange;
  late ExternalCredentialBoundary boundary;
  late WindowsPairingVerification verification;
  late WindowsAppPairing app;
  late WindowsBridgePairing bridge;
  late BridgeEnrollment enrollment;
  late AppPairingRequest request;
  Duration elapsed = Duration.zero;
  int randomCounter = 0;
  bool current = true;
  final keys = <Uint8List>[];
  Uint8List random(int count) => Uint8List.fromList(
      List.generate(count, (i) => (i + ++randomCounter) & 255));

  Future<void> open(
      {Duration lifetime = const Duration(seconds: 300),
      bool duplicateRandom = false,
      ExternalCredentialVerificationPort Function(
              WindowsPairingVerification, ExternalAuthorizationManagement)?
          verifierFactory}) async {
    native.seed(
        1,
        ExternalIssuerKeyPair(
            installationId: bootstrapVector['installationId'] as String,
            publicationEpoch: BigInt.one,
            issuerPkcs8Der: initialization.publicFixtureKey(),
            issuerCertificateDer: vectorBytes('issuerDer')));
    native.seed(2);
    bridgeOwner = objects.adapter(native.calls).acquireBridgeObjects();
    bridgeStore = WindowsCredentialObjectStore(bridgeOwner);
    appExchange = WindowsExchangeFileStore(native.owner);
    bridgeExchange = WindowsExchangeFileStore(bridgeOwner);
    associations = WindowsCredentialAssociationStore(native.owner,
        nowUtcMs: () => native.now.millisecondsSinceEpoch);
    verification = WindowsPairingVerification.withPrimitives(
        verifyDigest: native.verify,
        utcNow: () => native.now,
        monotonicNow: () => elapsed,
        compositionIsCurrent: () => current && local.current);
    await local.open();
    await local.coordinator.shutdown();
    local.clock.current = native.now;
    await local.compose(
        credentialFactory: (management) => boundary =
            ExternalCredentialBoundary.offline(
                associations: associations,
                verification: verifierFactory?.call(verification, management) ??
                    verification,
                management: management,
                clock: local.clock,
                installationId: bootstrapVector['installationId'] as String,
                compositionIsCurrent: () => current && local.current,
                monotonicNow: () => elapsed,
                pairingRequestLifetime: lifetime));
    local.reference =
        await local.management.selectProfile(local.reference.profileId);
    local.profile = await local.coordinator.registerProfile(local.reference);
    boundary.attach(local.coordinator, local.trust);
    app = WindowsAppPairing.withPrimitives(
        exchange: appExchange,
        credentials: native.service,
        boundary: boundary,
        associations: associations,
        verification: verification,
        utcNow: () => native.now,
        monotonicNow: () => elapsed,
        compositionIsCurrent: () => current && local.current,
        randomBytes: duplicateRandom ? (count) => Uint8List(count) : random);
    bridge = WindowsBridgePairing.withPrimitives(
        exchange: bridgeExchange,
        store: bridgeStore,
        generateKey: () {
          final key = native.generate();
          keys.add(key.pkcs8Der);
          return key;
        },
        signDigest: signPublicFixture,
        verifyDigest: native.verify,
        utcNow: () => native.now,
        monotonicNow: () => elapsed,
        compositionIsCurrent: () => current,
        randomBytes: random);
  }

  void begin() => enrollment = bridge.beginEnrollment(
      displayLabel: 'PUBLIC FIXTURE', clientBuild: 'offline');
  Future<void> challenge() async {
    begin();
    request =
        await app.createChallenge(local.reference, enrollment.submissionId);
  }

  PairingChallengeMessage get wire =>
      bridgeExchange.readChallenge(enrollment.submissionId)!;
  Future<void> firstTrust() async {
    final display = await app.initialDisplay(request);
    final projected = bridge.inspectChallenge(enrollment,
        importedIssuerDer: display.issuerDer,
        independentlyObtainedServerDigest: display.serverLeafDigest);
    expect(projected.digest, display.digest);
    bridge.confirmIndependentlyComparedInitial(enrollment, display.digest);
  }

  Future<void> proof({bool approve = true}) async {
    await challenge();
    await firstTrust();
    if (approve) await app.approve(request);
    bridge.publishProof(enrollment);
  }

  Future<PairingCompletionDisplay> complete() async {
    await proof();
    await app.complete(request);
    return app.completionDisplay(request);
  }

  void advance(Duration value, {bool wall = true}) {
    elapsed += value;
    if (wall) {
      native.now = native.now.add(value);
      local.clock.current = native.now;
    }
  }

  Future<void> close() async {
    native.calls.consumptionStatus = 0;
    native.calls.releaseStatus = 0;
    native.calls.throwConsume = false;
    native.calls.throwRelease = false;
    native.calls.associationCommitStatus = 0;
    native.calls.unknownAfterCommit = false;
    native.calls.throwAssociationAbort = false;
    native.calls.throwFree = false;
    if (local.barrier.resume != null && !local.barrier.resume!.isCompleted) {
      local.barrier.resume!.complete();
    }
    bridge.close();
    await app.close();
    await associations.close();
    bridgeOwner.close();
    await local.close();
    native.dispose();
    for (final key in keys) {
      expect(key, everyElement(0));
    }
    expect(native.calls.exchangeReadTickets, isEmpty);
    expect(native.calls.credentialTickets, isEmpty);
  }
}

void main() {
  initializeGeneratedTests();
  late PairingHarness h;
  setUp(() async {
    h = PairingHarness();
    await h.open();
  });
  tearDown(() => h.close());
  final rejected = throwsA(anything);

  test(
      'first-party adapter delegates full P27 comparison/approval/proof and fresh confirmation',
      () async {
    h.begin();
    PairingTrustDisplay? exported;
    var exports = 0;
    final adapter = WindowsFirstPartyPairing(
        owner: h.app,
        submissionId: () async => h.enrollment.submissionId,
        exportPublicTrust: (display) async {
          exported = display;
          exports++;
        });
    final request = await adapter.request(h.local.reference);
    final initial = await request.display();
    final bridgeDisplay = h.bridge.inspectChallenge(h.enrollment,
        importedIssuerDer: exported!.issuerDer,
        independentlyObtainedServerDigest: exported!.serverLeafDigest);
    expect(initial.digest, bridgeDisplay.digest);
    expect((await request.display()).digest, initial.digest);
    expect(exports, 1);
    h.bridge.confirmIndependentlyComparedInitial(
        h.enrollment, bridgeDisplay.digest);
    expect(h.local.trust.snapshot(h.local.profile.principal).state,
        PairingState.requestPending);
    await request.approve();
    h.bridge.publishProof(h.enrollment);
    await request.complete();
    final completion = await request.display();
    final bridgeCompletion =
        h.bridge.completionDisplay(h.enrollment, completion.revision!);
    expect(completion.digest, bridgeCompletion.digest);
    h.bridge.confirmIndependentlyComparedCompletionAndSave(h.enrollment,
        committedRevision: completion.revision!,
        comparedDigest: completion.digest!);
    expect(h.local.trust.snapshot(h.local.profile.principal).state,
        PairingState.pairedDisabled);
    await expectLater(
        h.boundary.openSession(h.local.reference, Object()), rejected);
    h.current = false;
    await expectLater(request.display(), rejected);
  });

  test('A1-A4 real math, E0, P20 CAS, P0 disabled and Missing-only kind 4',
      () async {
    await h.challenge();
    expect(h.native.calls.exchangeConsumes, 1);
    final exact = h.bridgeExchange
        .readChallengeForConsumption(h.enrollment.submissionId)!;
    final raw = exact.bytes;
    exact.release();
    final display = await h.app.initialDisplay(h.request);
    final expected = bootstrapDigest([
      ...ascii.encode('SHIROHA-EXTERNAL-TRUST-CONFIRM-V1'),
      0,
      ...bootstrapDigest(display.issuerDer),
      ...display.serverLeafDigest,
      ...bootstrapDigest(raw)
    ]);
    expect(display.digest, hex(expected));
    expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    await h.firstTrust();
    await h.app.approve(h.request);
    h.bridge.publishProof(h.enrollment);
    expect(h.native.calls.exchangeConsumes, 2);
    expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    await h.app.complete(h.request);
    expect(h.native.calls.exchangeConsumes, 3);
    final completion = await h.app.completionDisplay(h.request);
    expect(h.local.trust.snapshot(h.local.profile.principal).state,
        PairingState.pairedDisabled);
    expect((await h.local.management.read(h.local.reference)).grant, isNull);
    final projected =
        h.bridge.completionDisplay(h.enrollment, completion.revision);
    expect(projected.digest, completion.digest);
    expect(completion.revision, 1);
    expect(
        completion.digest,
        hex(bootstrapDigest([
          ...ascii.encode('SHIROHA-EXTERNAL-COMPLETION-CONFIRM-V1'),
          0,
          ...expected,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          1
        ])));
    h.bridge.confirmIndependentlyComparedCompletionAndSave(h.enrollment,
        committedRevision: completion.revision,
        comparedDigest: completion.digest);
    final saved = h.bridgeStore.read(4)! as ExternalBridgeClient;
    expect(saved.pinnedInstallationId, bootstrapVector['installationId']);
    expect(saved.pinnedDiscoveryEpochHighWater, BigInt.one);
    expect(saved.clientPkcs8Der, initialization.publicFixtureKey());
    saved.clientPkcs8Der.fillRange(0, saved.clientPkcs8Der.length, 0);
    expect(h.boundary.provePossession(Object()), isNull);
    expect(h.boundary.authenticate(Object()), isNull);
    await expectLater(
        h.boundary.openSession(h.local.reference, Object()), rejected);
    await expectLater(h.app.complete(h.request), rejected);
    expect(
        () => h.bridge.confirmIndependentlyComparedCompletionAndSave(
            h.enrollment,
            committedRevision: completion.revision,
            comparedDigest: completion.digest),
        rejected);
  });

  for (final status in [4, 7]) {
    test(
        'A1 Challenge published but Submission consume $status blocks every local action',
        () async {
      h.begin();
      h.native.calls.consumptionStatus = status;
      await expectLater(
          h.app.createChallenge(h.local.reference, h.enrollment.submissionId),
          rejected);
      expect(h.native.calls.exchangeFiles.keys.any((k) => k.$1 == 2), isTrue);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.requestPending);
      expect(h.native.calls.associationFile, isNull);
      expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    });
    test('A2 failed Challenge consume $status never publishes Proof', () async {
      await h.challenge();
      await h.firstTrust();
      h.native.calls.consumptionStatus = status;
      expect(() => h.bridge.publishProof(h.enrollment), rejected);
      expect(h.native.calls.exchangeFiles.keys.any((k) => k.$1 == 3), isFalse);
      expect(h.keys.single, everyElement(0));
    });
    test('A3 failed Proof consume $status never CAS/P0', () async {
      await h.proof();
      h.native.calls.consumptionStatus = status;
      await expectLater(h.app.complete(h.request), rejected);
      expect(h.native.calls.associationFile, isNull);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.approvedPendingProof);
      await expectLater(h.app.complete(h.request), rejected);
    });
  }

  test(
      'A3 independent Approval is required, Bridge comparison cannot approve App',
      () async {
    await h.proof(approve: false);
    await expectLater(h.app.complete(h.request), rejected);
    expect(h.native.calls.exchangeConsumes, 2);
    expect(h.native.calls.associationFile, isNull);
    await h.app.approve(h.request);
    await h.app.complete(h.request);
  });
  for (final variant in ['signature', 'request', 'submission']) {
    test('A3 $variant substitution rejects and spends the completion',
        () async {
      await h.proof();
      final key =
          h.native.calls.exchangeFiles.keys.singleWhere((k) => k.$1 == 3);
      final changed = Uint8List.fromList(h.native.calls.exchangeFiles[key]!);
      changed[variant == 'signature'
          ? changed.length - 1
          : variant == 'request'
              ? 25
              : 9] ^= 1;
      h.native.calls.exchangeFiles[key] = changed;
      await expectLater(h.app.complete(h.request), rejected);
      await expectLater(h.app.complete(h.request), rejected);
      expect(h.native.calls.associationFile, isNull);
    });
  }
  for (final variant in [
    'nonce',
    'runtime',
    'generation',
    'profile',
    'identity',
    'deadline'
  ]) {
    test(
        'A2 exact original-byte comparison detects Challenge $variant replacement',
        () async {
      await h.challenge();
      final key =
          h.native.calls.exchangeFiles.keys.singleWhere((k) => k.$1 == 2);
      final bytes = Uint8List.fromList(h.native.calls.exchangeFiles[key]!);
      final offset = switch (variant) {
        'nonce' => 41,
        'profile' => 73,
        'generation' => 127,
        'runtime' => 135,
        'identity' => 159,
        _ => 199
      };
      bytes[offset] ^= 1;
      h.native.calls.exchangeFiles[key] = bytes;
      final app = await h.app.initialDisplay(h.request);
      try {
        final bridge = h.bridge.inspectChallenge(h.enrollment,
            importedIssuerDer: app.issuerDer,
            independentlyObtainedServerDigest: app.serverLeafDigest);
        expect(bridge.digest, isNot(app.digest));
        expect(
            () => h.bridge
                .confirmIndependentlyComparedInitial(h.enrollment, app.digest),
            rejected);
      } on ExternalExchangeException {
        // Strict P22/profile/digest rejection is also fail-closed, before trust.
      } on ExternalCredentialException {
        // A validity/binding rejection also prevents acceptance and signing.
      }
      expect(h.native.calls.exchangeFiles.keys.any((k) => k.$1 == 3), isFalse);
    });
  }
  for (final digest in ['0' * 64, 'A' * 64, 'a' * 63, '${'a' * 64}\n']) {
    test('A2 rejects incomplete/wrong/nonlowercase comparison ${digest.length}',
        () async {
      await h.challenge();
      final display = await h.app.initialDisplay(h.request);
      h.bridge.inspectChallenge(h.enrollment,
          importedIssuerDer: display.issuerDer,
          independentlyObtainedServerDigest: display.serverLeafDigest);
      expect(
          () => h.bridge
              .confirmIndependentlyComparedInitial(h.enrollment, digest),
          rejected);
      expect(h.keys.single, everyElement(0));
    });
  }
  test('A2 wrong independently imported issuer fails actual certificate math',
      () async {
    await h.challenge();
    final display = await h.app.initialDisplay(h.request);
    final wrong = Uint8List.fromList(display.issuerDer);
    wrong[wrong.length - 1] ^= 1;
    expect(
        () => h.bridge.inspectChallenge(h.enrollment,
            importedIssuerDer: wrong,
            independentlyObtainedServerDigest: display.serverLeafDigest),
        rejected);
  });
  test('A2 replaced independent Server digest cannot match App trust display',
      () async {
    await h.challenge();
    final display = await h.app.initialDisplay(h.request);
    final bridge = h.bridge.inspectChallenge(h.enrollment,
        importedIssuerDer: display.issuerDer,
        independentlyObtainedServerDigest: Uint8List(32));
    expect(bridge.digest, isNot(display.digest));
    expect(
        () => h.bridge
            .confirmIndependentlyComparedInitial(h.enrollment, display.digest),
        rejected);
  });
  test('A2 import alone cannot sign or persist; key stays memory-only',
      () async {
    await h.challenge();
    final display = await h.app.initialDisplay(h.request);
    h.bridge.inspectChallenge(h.enrollment,
        importedIssuerDer: display.issuerDer,
        independentlyObtainedServerDigest: display.serverLeafDigest);
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
    expect(() => h.bridge.completionDisplay(h.enrollment, 1), rejected);
    expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    final privateHex = hex(initialization.publicFixtureKey());
    for (final bytes in h.native.calls.exchangeFiles.values) {
      expect(hex(bytes), isNot(contains(privateHex)));
    }
    expect('${h.app}${h.bridge}${h.enrollment}${h.request}$display',
        isNot(contains(privateHex)));
  });
  test('A2 long trusted deadline agrees with wire and expires without revival',
      () async {
    await h.challenge();
    expect(
        h.wire.transcript.expiresAtUtcMs.toInt() -
            h.native.now.millisecondsSinceEpoch,
        300000);
    h.advance(const Duration(seconds: 31));
    await h.firstTrust();
    await h.app.approve(h.request);
    h.advance(const Duration(seconds: 269));
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
    h.advance(const Duration(seconds: -300));
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
  });
  test('A3 Challenge expiry at App rejects Proof and CAS', () async {
    await h.proof();
    h.advance(const Duration(seconds: 300));
    await expectLater(h.app.complete(h.request), rejected);
    expect(h.native.calls.associationFile, isNull);
  });
  for (final invalidate in ['runtime', 'generation', 'revoke']) {
    test('A3 $invalidate invalidation cannot complete or display success',
        () async {
      await h.proof();
      if (invalidate == 'runtime') {
        h.current = false;
      }
      if (invalidate == 'generation') {
        h.local.trust.restart();
      }
      if (invalidate == 'revoke') {
        final ref = await h.local.view.select(h.local.reference.profileId);
        final record = await h.local.view.read(ref);
        await h.local.view.revokeProfile(ref, record.profile.grantRevision);
      }
      await expectLater(h.app.complete(h.request), rejected);
      await expectLater(h.app.completionDisplay(h.request), rejected);
      expect(h.native.calls.associationFile, isNull);
    });
  }
  for (final status in [4, 7]) {
    test('A3 CAS failure/unknown $status supplies no completion or Bridge save',
        () async {
      await h.proof();
      h.native.calls.associationCommitStatus = status;
      await expectLater(h.app.complete(h.request), rejected);
      await expectLater(h.app.completionDisplay(h.request), rejected);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.approvedPendingProof);
      expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    });
  }
  test('A3 concurrent completion has exactly one P15 opportunity', () async {
    await h.proof();
    final results = await Future.wait([
      h.app
          .complete(h.request)
          .then((_) => true)
          .catchError((Object _) => false),
      h.app
          .complete(h.request)
          .then((_) => true)
          .catchError((Object _) => false)
    ]);
    expect(results.where((r) => r), hasLength(1));
    expect(
        (await h.associations.read(h.local.reference.profileId))
            .record!
            .revision,
        1);
  });
  test('A4 actual persisted revision is used for exact-revision idempotency',
      () async {
    await h.challenge();
    // Existing same identity can be paired after explicit fresh composition.
    final identity = hex(h.wire.transcript.credentialIdentity);
    await h.associations.register(
        profileId: h.local.reference.profileId,
        installationId: bootstrapVector['installationId'] as String,
        credentialIdentity: identity,
        expectedRevision: 0,
        validateManagement: () async {});
    await h.firstTrust();
    await h.app.approve(h.request);
    h.bridge.publishProof(h.enrollment);
    await expectLater(
        h.app.complete(h.request), rejected); // stale original revision 0
    expect(
        (await h.associations.read(h.local.reference.profileId))
            .record!
            .revision,
        1);
  });
  for (final seconds in [120, 121]) {
    test(
        'A4 monotonic confirmation expires at $seconds seconds despite wall rollback',
        () async {
      final completion = await h.complete();
      h.advance(Duration(seconds: seconds), wall: false);
      expect(
          () => h.bridge.confirmIndependentlyComparedCompletionAndSave(
              h.enrollment,
              committedRevision: completion.revision,
              comparedDigest: completion.digest),
          rejected);
      expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    });
  }
  for (final scenario in [
    'existing',
    'pin',
    'corrupt',
    'unknown',
    'failure',
    'release',
    'mismatch',
    'revision'
  ]) {
    test('A4 kind 4 $scenario fails closed, no retry/overwrite', () async {
      final completion = await h.complete();
      if (scenario == 'existing') h.bridgeStore.write(objects.fixture(4));
      if (scenario == 'pin') {
        final existing = objects.fixture(4) as ExternalBridgeClient;
        h.bridgeStore.write(ExternalBridgeClient(
            clientPkcs8Der: existing.clientPkcs8Der,
            clientLeafDer: existing.clientLeafDer,
            issuerCertificateDer: existing.issuerCertificateDer,
            pinnedInstallationId: '00000000-0000-4000-8000-000000000001',
            pinnedDiscoveryEpochHighWater: BigInt.one));
      }
      if (scenario == 'corrupt') {
        h.native.calls.credentialFiles[4] = Uint8List.fromList([1, 2, 3]);
      }
      final before = h.native.calls.credentialFiles[4]?.toList();
      if (scenario == 'unknown') h.native.calls.unknownAfterCommit = true;
      if (scenario == 'failure') h.native.calls.associationCommitStatus = 4;
      if (scenario == 'release') {
        h.native.calls.afterCredentialCommit =
            (_) => h.native.calls.throwFree = true;
      }
      expect(
          () => h.bridge.confirmIndependentlyComparedCompletionAndSave(
              h.enrollment,
              committedRevision:
                  scenario == 'revision' ? 5 : completion.revision,
              comparedDigest:
                  scenario == 'mismatch' ? '0' * 64 : completion.digest),
          rejected);
      final commits = h.native.calls.commits;
      expect(
          () => h.bridge.confirmIndependentlyComparedCompletionAndSave(
              h.enrollment,
              committedRevision: completion.revision,
              comparedDigest: completion.digest),
          rejected);
      expect(h.native.calls.commits, commits);
      if (before != null) expect(h.native.calls.credentialFiles[4], before);
      expect(h.keys.single, everyElement(0));
    });
  }
  test('A4 Bridge exit loses key; Association residue never restores Pairing',
      () async {
    await h.complete();
    h.bridge.close();
    expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    expect(h.keys.single, everyElement(0));
    await h.app.close();
    expect((await h.associations.read(h.local.reference.profileId)).record,
        isNotNull);
    await expectLater(h.app.completionDisplay(h.request), rejected);
    // Fresh P0/P12 composition discards in-memory pairing; no persisted record
    // participates in Principal construction. The old P15 remains closed.
    await h.local.compose(credentialPort: h.boundary);
    h.local.reference =
        await h.local.management.selectProfile(h.local.reference.profileId);
    h.local.profile =
        await h.local.coordinator.registerProfile(h.local.reference);
    expect(h.local.trust.snapshot(h.local.profile.principal).state,
        PairingState.unpaired);
    await expectLater(
        h.boundary.openSession(h.local.reference, Object()), rejected);
  });
  test('A4 Restore gate invalidates display and prevents pairing writes',
      () async {
    await h.proof();
    await BackupRestoreMutationGate.instance.enterQuiescence();
    try {
      await expectLater(h.app.complete(h.request), rejected);
      expect(h.native.calls.associationFile, isNull);
    } finally {
      BackupRestoreMutationGate.instance.exitQuiescence();
    }
  });
  test('A4 close drains blocked App work before Owner release', () async {
    await h.challenge();
    h.local.barrier.reached = Completer<void>();
    h.local.barrier.resume = Completer<void>();
    final work = h.app.approve(h.request);
    final workResult = expectLater(work, rejected);
    await h.local.barrier.reached!.future;
    var closed = false;
    final closing = h.app.close().then((_) => closed = true);
    await Future<void>.value();
    expect(closed, isFalse);
    h.local.barrier.resume!.complete();
    await workResult;
    await closing;
    expect(h.native.calls.exchangeReadTickets, isEmpty);
  });
  for (final seconds in [30, 600]) {
    test(
        'A2 trusted $seconds second binding matches wire, expiry is irreversible',
        () async {
      await h.close();
      h = PairingHarness();
      await h.open(lifetime: Duration(seconds: seconds));
      await h.challenge();
      expect(
          h.wire.transcript.expiresAtUtcMs.toInt() -
              h.native.now.millisecondsSinceEpoch,
          seconds * 1000);
      h.advance(Duration(seconds: seconds));
      await expectLater(h.app.initialDisplay(h.request), rejected);
      h.advance(Duration(seconds: -seconds));
      await expectLater(h.app.approve(h.request), rejected);
    });
  }
  test('A2 zero, negative and >600 deadlines reject at trusted construction',
      () {
    for (final seconds in [0, -1, 601]) {
      expect(
          () => ExternalCredentialBoundary.offline(
              associations: h.associations,
              verification: h.verification,
              management: h.local.management,
              clock: h.local.clock,
              installationId: bootstrapVector['installationId'] as String,
              compositionIsCurrent: () => true,
              pairingRequestLifetime: Duration(seconds: seconds)),
          rejected);
    }
    expect(ExternalCredentialBoundary.evidenceLifetime,
        const Duration(seconds: 30));
  });
  test(
      'A1 duplicated live nonce denies second publication and forces explicit recovery',
      () async {
    await h.close();
    h = PairingHarness();
    await h.open(duplicateRandom: true);
    await h.challenge();
    final second = h.bridge.beginEnrollment(displayLabel: '', clientBuild: '');
    final profile = await h.local.secondProfile();
    await expectLater(
        h.app.createChallenge(profile, second.submissionId), rejected);
    expect(h.native.calls.exchangeFiles.keys.where((k) => k.$1 == 2),
        hasLength(1));
    expect(h.native.calls.exchangeConsumes, 1);
  });
  test('A1 Enrollment resources and lifetime are bounded, no directory cleanup',
      () {
    for (var i = 0; i < 16; i++) {
      h.begin();
    }
    expect(() => h.bridge.beginEnrollment(displayLabel: '', clientBuild: ''),
        rejected);
    h.advance(const Duration(seconds: 600));
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
    expect(h.native.calls.exchangeDeletes, 0);
    expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
  });
  test(
      'A2 Challenge consumed but Proof publication fails: no retry or key persistence',
      () async {
    await h.challenge();
    await h.firstTrust();
    h.native.calls.exchangeStatus = 4;
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
    expect(h.native.calls.exchangeConsumes, 2);
    expect(h.native.calls.exchangeFiles.keys.any((k) => k.$1 == 3), isFalse);
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
    expect(h.keys.single, everyElement(0));
  });
  for (final failure in ['unknown', 'P0', 'evidence', 'revoke']) {
    test('A3 persisted CAS then $failure cannot report completion', () async {
      await h.proof();
      if (failure == 'unknown') {
        h.native.calls.unknownAfterCommit = true;
      }
      if (failure == 'P0') {
        h.native.calls.afterAssociationCommit =
            () => h.local.coordinatorCurrent = false;
      }
      if (failure == 'evidence') {
        h.native.calls.afterAssociationCommit =
            () => h.advance(const Duration(seconds: 30), wall: false);
      }
      if (failure == 'revoke') {
        h.native.calls.afterAssociationCommit =
            () => h.local.trust.revoke(h.local.profile.principal);
      }
      await expectLater(h.app.complete(h.request), rejected);
      expect(h.native.calls.associationFile, isNotNull);
      await expectLater(h.app.completionDisplay(h.request), rejected);
      expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
    });
  }
  test(
      'A3 29 seconds of Evidence Window still completes within the long Request',
      () async {
    await h.proof();
    h.native.calls.afterAssociationCommit =
        () => h.advance(const Duration(seconds: 29), wall: false);
    await h.app.complete(h.request);
    expect((await h.app.completionDisplay(h.request)).revision, 1);
  });
  test('A4 completion display is withdrawn after observed runtime invalidation',
      () async {
    await h.complete();
    h.current = false;
    await expectLater(h.app.completionDisplay(h.request), rejected);
    h.current = true;
    await expectLater(h.app.completionDisplay(h.request), rejected);
  });
  test('A4 Bridge local invalidation cannot revive an Enrollment or its key',
      () async {
    await h.challenge();
    await h.firstTrust();
    h.current = false;
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
    h.current = true;
    expect(() => h.bridge.publishProof(h.enrollment), rejected);
    expect(h.keys.single, everyElement(0));
  });
  test('A4 lost completion comparison never silently saves kind 4', () async {
    await h.proof();
    await h.app.complete(h.request);
    expect(h.local.trust.snapshot(h.local.profile.principal).state,
        PairingState.pairedDisabled);
    h.advance(const Duration(seconds: 120), wall: false);
    expect(() => h.bridge.completionDisplay(h.enrollment, 1), rejected);
    expect(h.native.calls.credentialFiles.containsKey(4), isFalse);
  });
  test(
      'A2 Client private/public mismatch fails mathematical key correspondence',
      () async {
    await h.challenge();
    final display = await h.app.initialDisplay(h.request);
    h.keys.single[h.keys.single.length - 1] ^= 1;
    expect(
        () => h.bridge.inspectChallenge(h.enrollment,
            importedIssuerDer: display.issuerDer,
            independentlyObtainedServerDigest: display.serverLeafDigest),
        rejected);
    expect(h.keys.single, everyElement(0));
    expect(h.native.calls.exchangeFiles.keys.any((k) => k.$1 == 3), isFalse);
  });
  test('A4 exact-revision idempotent registration displays actual revision 1',
      () async {
    final leaf = h.native.service.issueClientLeaf(vectorBytes('point'));
    await h.associations.register(
        profileId: h.local.reference.profileId,
        installationId: bootstrapVector['installationId'] as String,
        credentialIdentity: leaf.credentialIdentity,
        expectedRevision: 0,
        validateManagement: () async {});
    final completion = await h.complete();
    expect(completion.revision, 1); // NOT expectedRevision + 1 (2).
    final bridge =
        h.bridge.completionDisplay(h.enrollment, completion.revision);
    expect(bridge.digest, completion.digest);
  });
  test(
      'Package 1 integrated initial pin then signed Discovery high-water advance',
      () async {
    await h.challenge();
    final transcript = h.wire.transcript;
    final display = await h.app.initialDisplay(h.request);
    await h.firstTrust();
    await h.app.approve(h.request);
    h.bridge.publishProof(h.enrollment);
    await h.app.complete(h.request);
    final completion = await h.app.completionDisplay(h.request);
    h.bridge.confirmIndependentlyComparedCompletionAndSave(h.enrollment,
        committedRevision: completion.revision,
        comparedDigest: completion.digest);
    final credentials = WindowsCredentialInitialization.withPrimitives(
        owner: h.native.owner,
        generateKey: h.native.generate,
        signDigest: signPublicFixture,
        verifyDigest: h.native.verify,
        utcNow: () => h.native.now,
        randomBytes: h.random);
    final publisher = WindowsDiscoveryPublisher(
        owner: h.native.owner, credentials: credentials);
    final published = publisher.publish(
        runtimeInstanceId: transcript.runtimeInstanceId,
        generation: transcript.generation,
        port: 19001,
        publishedAtUtcMs: BigInt.from(h.native.now.millisecondsSinceEpoch));
    expect(published.publicationEpoch, BigInt.two);
    final reader =
        WindowsDiscoveryReader(h.bridgeOwner, verifier: offlineVerify);
    final read = reader.readAndAdvanceExistingPin(DiscoveryExpectations(
        trustedAnchorDer: display.issuerDer,
        installationId: transcript.installationId,
        serverLeafDigest: display.serverLeafDigest,
        verifiedEpochHighWater: BigInt.one));
    expect(read.publicationEpoch, BigInt.two);
    final pin = h.bridgeStore.read(4)! as ExternalBridgeClient;
    expect(pin.pinnedDiscoveryEpochHighWater, BigInt.two);
    expect(pin.clientPkcs8Der, initialization.publicFixtureKey());
    pin.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
    expect(h.local.trust.snapshot(h.local.profile.principal).state,
        PairingState.pairedDisabled);
    expect((await h.local.management.read(h.local.reference)).grant, isNull);
  });
  test('A3 slow E0 Proof consumption cannot renew the Evidence Window',
      () async {
    await h.proof();
    h.native.calls.beforeExchangeConsume = (kind) {
      if (kind == 3) {
        h.advance(const Duration(seconds: 30), wall: false);
      }
    };
    await expectLater(h.app.complete(h.request), rejected);
    expect(h.native.calls.exchangeConsumes, 3);
    expect(h.native.calls.associationFile, isNull);
    await expectLater(h.app.completionDisplay(h.request), rejected);
  });
  test('P27 has no production consumer and stands exactly once in CI', () {
    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') ||
          file.path.replaceAll('\\', '/').endsWith('/windows_pairing.dart') ||
          file.path.replaceAll('\\', '/') ==
              'lib/data/external/windows_tls_transport.dart') {
        continue;
      }
      expect(file.readAsStringSync(), isNot(contains('windows_pairing.dart')),
          reason: file.path);
    }
    final source =
        File('lib/data/external/windows_pairing.dart').readAsStringSync();
    for (final token in [
      'dart:io',
      'dart:ffi',
      'PairingProof(',
      'AuthenticatedPeerEvidence(',
      'SecurityContext',
      'Socket',
      'Timer(',
      'engine.',
      'print(',
      'debugPrint(',
      'Process.'
    ]) {
      expect(source, isNot(contains(token)));
    }
    expect(
        "'test/data/external/windows_pairing_test.dart'"
            .allMatches(File('.github/workflows/pr-contract-checks.yml')
                .readAsStringSync())
            .length,
        1);
  });
}
