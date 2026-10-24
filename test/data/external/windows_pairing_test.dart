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
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
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
import 'fixtures/public_pairing_cases.dart';
import 'fixtures/public_fixture_crypto.dart';
export 'fixtures/public_fixture_crypto.dart' show signPublicFixture, hex;

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
    if (keys.any((key) => key.any((value) => value != 0)) ||
        native.calls.exchangeReadTickets.isNotEmpty ||
        native.calls.credentialTickets.isNotEmpty) {
      throw StateError('Synthetic pairing custody did not settle');
    }
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
  publicPairingCases(() => h);
  final rejected = throwsA(anything);

  group('first-party public pairing ports', () {
    late FirstPartyPublicPairingPort app;
    late FirstPartyBridgePairingPort bridge;
    late FirstPartyPairingRequest request;
    late String id;

    setUp(() {
      app = WindowsAppPublicPairingHandoff(owner: h.app);
      bridge = WindowsBridgePublicPairing(owner: h.bridge);
    });
    tearDown(() async {
      await bridge.close();
      await app.close();
    });

    void begin() {
      bridge.beginEnrollment(
          displayLabel: 'PUBLIC FIXTURE', clientBuild: 'offline');
      id = bridge.display().submissionId!;
    }

    Future<void> challenge() async {
      begin();
      request = await app.requestSubmission(h.local.reference, id);
    }

    Future<void> proof() async {
      await challenge();
      await bridge.importTrust(await app.exportPublicTrust());
      bridge.confirmInitial(bridge.display().initialDigest!);
      await request.approve();
    }

    Future<void> complete() async {
      await proof();
      await request.complete();
    }

    test(
        'public strings preserve original ID, two decisions and actual revision',
        () async {
      expect(h.keys, isEmpty);
      await challenge();
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      final initial = await request.display();
      expect(initial.submissionId, id);
      expect(h.appExchange.readSubmission(unhex(id)), isNull);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.requestPending);
      final trust = await app.exportPublicTrust();
      expect(utf8.encode(trust),
          await (app as WindowsAppPublicPairingHandoff).exportTrust(unhex(id)));
      await bridge.importTrust(trust);
      expect(bridge.display().initialDigest, initial.digest);
      expect(initial.digest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(h.appExchange.readProof(unhex(id)), isNull);
      expect(h.native.calls.credentialFiles[4], isNull);
      bridge.confirmInitial(initial.digest!);
      expect(h.appExchange.readProof(unhex(id)), isNotNull);
      await request.approve();
      await request.complete();
      final actual =
          (await h.associations.read(h.local.reference.profileId)).record!;
      final exported = await app.exportPublicCompletion();
      expect(
          utf8.encode(exported),
          await (app as WindowsAppPublicPairingHandoff)
              .exportCompletion(unhex(id)));
      await bridge.importCompletion(exported);
      final display = bridge.display();
      expect(display.revision, actual.revision);
      expect(display.completionDigest, (await request.display()).digest);
      expect(display.completionDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(h.native.calls.credentialFiles[4], isNull);
      bridge.confirmCompletion(display.completionDigest!, display.revision!);
      expect(bridge.display().pinSaved, isTrue);
      expect(bridge.display().submissionId, isNull);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.pairedDisabled);
    });

    test('optional callback request remains compatible and reports original ID',
        () async {
      begin();
      final callbackApp = WindowsAppPublicPairingHandoff(
          owner: h.app, submissionId: () async => unhex(id));
      addTearDown(callbackApp.close);
      final callbackRequest = await callbackApp.request(h.local.reference);
      expect((await callbackRequest.display()).submissionId, id);
      expect(await callbackApp.exportPublicTrust(), isNotEmpty);
    });

    for (final invalid in {
      'empty': '',
      'short': 'a' * 31,
      'uppercase': 'A' * 32,
      'leading-space': ' ${'a' * 32}',
      'trailing-newline': '${'a' * 32}\n',
      'non-hex': 'g' * 32,
      'missing-submission': '0' * 32,
    }.entries) {
      test('strict public ID rejects ${invalid.key} and latches', () async {
        begin();
        await expectLater(
            app.requestSubmission(h.local.reference, invalid.value), rejected);
        await expectLater(
            app.requestSubmission(h.local.reference, id), rejected);
        await expectLater(app.exportPublicTrust(), rejected);
        expect(h.appExchange.readSubmission(unhex(id)), isNotNull);
        expect(h.native.calls.associationFile, isNull);
      });
    }

    test('duplicate explicit request cannot reset P0 or reuse old handle',
        () async {
      await challenge();
      await expectLater(app.requestSubmission(h.local.reference, id), rejected);
      await expectLater(request.approve(), rejected);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.requestPending);
    });

    test('public completion never predicts or caches success', () async {
      await complete();
      expect(await app.exportPublicCompletion(), isNotEmpty);
      await h.boundary.revoke(h.local.reference, 1);
      await expectLater(app.exportPublicCompletion(), rejected);
      await expectLater(request.display(), rejected);
    });

    test('premature completion export locks the original request', () async {
      await challenge();
      await expectLater(app.exportPublicCompletion(), rejected);
      await expectLater(request.approve(), rejected);
      expect(h.native.calls.associationFile, isNull);
    });

    for (final mode in [
      'noncanonical',
      'foreign',
      'oversize',
      'utf8-size',
      'malformed'
    ]) {
      test('Bridge rejects $mode public Trust without replacing Enrollment',
          () async {
        await challenge();
        var input = await app.exportPublicTrust();
        if (mode == 'noncanonical') input = '$input ';
        if (mode == 'foreign') {
          final fields = jsonDecode(input) as List<dynamic>;
          fields[2] = base64Encode(Uint8List(16));
          input = jsonEncode(fields);
        }
        if (mode == 'oversize') input = 'x' * 4097;
        if (mode == 'utf8-size') input = '界' * 1366;
        if (mode == 'malformed') input = '\uD800';
        await expectLater(bridge.importTrust(input), rejected);
        expect(bridge.display().closed, isTrue);
        expect(bridge.display().initialDigest, isNull);
        expect(() => bridge.beginEnrollment(displayLabel: '', clientBuild: ''),
            rejected);
        expect(h.keys, hasLength(1));
        expect(h.keys.single, everyElement(0));
        expect(h.appExchange.readProof(unhex(id)), isNull);
      });
    }

    test('duplicate import fails closed and cannot reuse retained public input',
        () async {
      await challenge();
      final input = await app.exportPublicTrust();
      await bridge.importTrust(input);
      await expectLater(bridge.importTrust(input), rejected);
      expect(bridge.display().closed, isTrue);
      expect(h.native.calls.exchangeReadTickets, isEmpty);
      expect(h.native.calls.credentialFiles[4], isNull);
    });

    for (final stage in ['trust', 'completion']) {
      for (final action in ['close', 'duplicate', 'expire']) {
        test('$action during $stage import drains and denies late data',
            () async {
          if (stage == 'trust') {
            await challenge();
          } else {
            await complete();
          }
          final input = stage == 'trust'
              ? await app.exportPublicTrust()
              : await app.exportPublicCompletion();
          Future<void> importCurrent() => stage == 'trust'
              ? bridge.importTrust(input)
              : bridge.importCompletion(input);
          final reading = expectLater(importCurrent(), rejected);
          Future<void>? closing;
          if (action == 'close') closing = bridge.close();
          if (action == 'duplicate') {
            await expectLater(importCurrent(), rejected);
          }
          if (action == 'expire') h.advance(const Duration(seconds: 600));
          await reading;
          await closing;
          expect(bridge.display().closed, isTrue);
          expect(bridge.display().submissionId, isNull);
          expect(h.native.calls.exchangeReadTickets, isEmpty);
          expect(h.native.calls.credentialFiles[4], isNull);
        });
      }
    }

    test('refresh withdraws expired Bridge digest permanently', () async {
      await challenge();
      await bridge.importTrust(await app.exportPublicTrust());
      h.advance(const Duration(seconds: 300));
      expect(bridge.display, rejected);
      h.advance(const Duration(seconds: -300));
      expect(bridge.display().closed, isTrue);
      expect(bridge.display().initialDigest, isNull);
      expect(h.keys.single, everyElement(0));
    });

    for (final wrong in [
      'initial',
      'completion',
      'revision',
      'foreign-completion'
    ]) {
      test('$wrong comparison cannot publish or save through the UI port',
          () async {
        if (wrong == 'initial') {
          await challenge();
          await bridge.importTrust(await app.exportPublicTrust());
          expect(() => bridge.confirmInitial('0' * 64), rejected);
          expect(h.appExchange.readProof(unhex(id)), isNull);
        } else {
          await complete();
          var input = await app.exportPublicCompletion();
          if (wrong == 'foreign-completion') {
            final fields = jsonDecode(input) as List<dynamic>;
            fields[2] = base64Encode(Uint8List(16));
            input = jsonEncode(fields);
            await expectLater(bridge.importCompletion(input), rejected);
          } else {
            await bridge.importCompletion(input);
            final display = bridge.display();
            expect(
                () => bridge.confirmCompletion(
                    wrong == 'completion'
                        ? '0' * 64
                        : display.completionDigest!,
                    wrong == 'revision'
                        ? display.revision! + 1
                        : display.revision!),
                rejected);
          }
        }
        expect(bridge.display().closed, isTrue);
        expect(h.native.calls.credentialFiles[4], isNull);
      });
    }
  });

  group('inactive App-Bridge public handoff adapter', () {
    late WindowsPairingHandoff handoff;
    late FirstPartyPairingRequest request;
    late Uint8List id;

    setUp(() {
      handoff = WindowsPairingHandoff(appOwner: h.app, bridgeOwner: h.bridge);
    });
    tearDown(() => handoff.close());

    void begin() {
      handoff.bridge.beginEnrollment(
          displayLabel: 'PUBLIC FIXTURE', clientBuild: 'offline');
      id = handoff.bridge.display().submissionId!;
    }

    Future<void> challenge() async {
      begin();
      request = await handoff.request(h.local.reference);
    }

    Future<void> proof() async {
      await challenge();
      await handoff.bridge.inspectAppTrust();
      await request.approve();
      handoff.bridge.confirmInitialAndPublishProof(
          comparedDigest: (await request.display()).digest!);
    }

    Future<void> complete() async {
      await proof();
      await request.complete();
      await handoff.bridge.inspectAppCompletion();
    }

    test('original E0 Submission, independent digests and two manual actions',
        () async {
      expect(
          h.keys, isEmpty); // Construction did not publish or generate a key.
      begin();
      final original = h.appExchange.readSubmission(id)!;
      expect(original.submissionId, id);
      final files = h.native.calls.exchangeFiles;
      expect(files.keys.where((key) => key.$1 == 1), hasLength(1));
      request = await handoff.request(h.local.reference);
      expect(h.appExchange.readSubmission(id), isNull);
      expect(files.keys.where((key) => key.$1 == 1), isEmpty);
      expect(h.bridgeExchange.readChallenge(id)!.submissionId, id);
      final material = await handoff.readAppPublicTrust(id);
      expect(material.issuerDer, vectorBytes('issuerDer'));
      // Public exports retain the existing immutable-copy contract.
      expect(() => material.issuerDer[0] = 0, throwsUnsupportedError);
      await handoff.bridge.inspectAppTrust();
      final appInitial = await request.display();
      expect(handoff.bridge.display().initialDigest, appInitial.digest);
      expect(appInitial.digest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(h.appExchange.readProof(id), isNull);
      await request.approve();
      expect(h.appExchange.readProof(id), isNull);
      handoff.bridge
          .confirmInitialAndPublishProof(comparedDigest: appInitial.digest!);
      await request.complete();
      final actual =
          (await h.associations.read(h.local.reference.profileId)).record!;
      final imported = await handoff.readAppCompletion(id);
      expect(imported.revision, actual.revision);
      expect(imported.digest, (await request.display()).digest);
      await handoff.bridge.inspectAppCompletion();
      final displayed = handoff.bridge.display();
      expect(displayed.completionDigest, imported.digest);
      expect(h.native.calls.credentialFiles[4], isNull);
      handoff.bridge.confirmCompletionAndSave(
          comparedDigest: displayed.completionDigest!,
          comparedRevision: displayed.revision!);
      expect(handoff.bridge.display().pinSaved, isTrue);
      // Successful Bridge closure does not replace or invalidate the App owner.
      expect((await request.display()).revision, actual.revision);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.pairedDisabled);
    });

    test('exact-revision idempotency exports 1, never predicts revision 2',
        () async {
      final leaf = h.native.service.issueClientLeaf(vectorBytes('point'));
      await h.associations.register(
          profileId: h.local.reference.profileId,
          installationId: bootstrapVector['installationId'] as String,
          credentialIdentity: leaf.credentialIdentity,
          expectedRevision: 0,
          validateManagement: () async {});
      await proof();
      expect(h.appExchange.readProof(id), isNotNull);
      await request.complete();
      await handoff.bridge.inspectAppCompletion();
      expect(handoff.bridge.display().revision, 1);
      expect((await handoff.readAppCompletion(id)).revision, 1);
    });

    for (final reader in ['trust', 'completion']) {
      for (final foreign in [false, true]) {
        test('$reader rejects ${foreign ? 'cross Enrollment' : 'wrong ID'}',
            () async {
          await complete();
          final wrong = foreign
              ? h.bridge
                  .beginEnrollment(
                      displayLabel: 'OTHER', clientBuild: 'offline')
                  .submissionId
              : (Uint8List.fromList(id)..[0] ^= 255);
          await expectLater(
              reader == 'trust'
                  ? handoff.readAppPublicTrust(wrong)
                  : handoff.readAppCompletion(wrong),
              rejected);
          expect(handoff.bridge.display().completionDigest, isNull);
          expect(h.native.calls.credentialFiles[4], isNull);
          await expectLater(request.display(), rejected);
        });
      }
    }

    test('missing original Submission is not replaced or retried', () async {
      begin();
      h.native.calls.exchangeFiles.clear();
      await expectLater(handoff.request(h.local.reference), rejected);
      expect(handoff.bridge.display().closed, isTrue);
      await expectLater(handoff.request(h.local.reference), rejected);
      expect(h.keys, hasLength(1));
    });

    test('missing public export fails closed without starting an App request',
        () async {
      begin();
      await expectLater(handoff.bridge.inspectAppTrust(), rejected);
      await expectLater(handoff.request(h.local.reference), rejected);
      expect(h.native.calls.associationFile, isNull);
      expect(h.native.calls.exchangeFiles.keys.where((key) => key.$1 == 2),
          isEmpty);
    });

    test('missing Challenge cannot use exported public bytes as success',
        () async {
      await challenge();
      h.native.calls.exchangeFiles.clear();
      await expectLater(handoff.bridge.inspectAppTrust(), rejected);
      expect(handoff.bridge.display().initialDigest, isNull);
      await expectLater(request.approve(), rejected);
    });

    test('completion before App completion fails without predicted success',
        () async {
      await proof();
      await expectLater(handoff.bridge.inspectAppCompletion(), rejected);
      expect(h.native.calls.associationFile, isNull);
      expect(h.native.calls.credentialFiles[4], isNull);
    });

    for (final failure in ['missing Proof', 'CAS failed', 'CAS unknown']) {
      test('$failure never releases completion or saves a Pin', () async {
        await proof();
        if (failure == 'missing Proof') {
          h.native.calls.exchangeFiles.clear();
        } else {
          h.native.calls.associationCommitStatus =
              failure == 'CAS failed' ? 4 : 7;
        }
        await expectLater(request.complete(), rejected);
        await expectLater(handoff.bridge.inspectAppCompletion(), rejected);
        expect(handoff.bridge.display().completionDigest, isNull);
        expect(h.native.calls.credentialFiles[4], isNull);
      });
    }

    test('wrong compared Revision spends save without storing a Pin', () async {
      await complete();
      final display = handoff.bridge.display();
      expect(
          () => handoff.bridge.confirmCompletionAndSave(
              comparedDigest: display.completionDigest!,
              comparedRevision: display.revision! + 1),
          rejected);
      expect(h.native.calls.credentialFiles[4], isNull);
      expect(handoff.bridge.display().completionDigest, isNull);
    });

    for (final stage in ['trust', 'completion']) {
      test('$stage expired input stays rejected after clock restoration',
          () async {
        if (stage == 'trust') {
          await challenge();
          h.advance(const Duration(seconds: 300));
        } else {
          await proof();
          await request.complete();
          h.advance(const Duration(seconds: 120));
        }
        await expectLater(
            stage == 'trust'
                ? handoff.bridge.inspectAppTrust()
                : handoff.bridge.inspectAppCompletion(),
            rejected);
        h.advance(const Duration(seconds: -300));
        await expectLater(request.display(), rejected);
        expect(handoff.bridge.display().closed, isTrue);
        expect(h.native.calls.credentialFiles[4], isNull);
      });
    }

    for (final invalidation in ['cancel', 'close', 'revoke', 'rebuild']) {
      test('$invalidation withdraws old completion and cannot revive request',
          () async {
        await proof();
        await request.complete();
        final old = await request.display();
        if (invalidation == 'cancel') await handoff.bridge.close();
        if (invalidation == 'close') await handoff.close();
        if (invalidation == 'revoke') {
          await h.boundary.revoke(h.local.reference, 1);
        }
        if (invalidation == 'rebuild') {
          await handoff.close();
          final replacement =
              WindowsPairingHandoff(appOwner: h.app, bridgeOwner: h.bridge);
          addTearDown(replacement.close);
          expect(replacement.bridge.display().initialDigest, isNull);
          await expectLater(replacement.readAppCompletion(id), rejected);
        }
        await expectLater(handoff.bridge.inspectAppCompletion(), rejected);
        await expectLater(request.display(), rejected);
        expect(
            () => handoff.bridge.confirmCompletionAndSave(
                comparedDigest: old.digest!, comparedRevision: old.revision!),
            rejected);
        expect(h.native.calls.credentialFiles[4], isNull);
      });
    }

    for (final stage in ['trust', 'completion']) {
      for (final action in ['close', 'expire']) {
        test('$action settles delayed $stage read and denies its late result',
            () async {
          if (stage == 'trust') {
            await challenge();
          } else {
            await proof();
            await request.complete();
          }
          h.local.barrier.reached = Completer<void>();
          h.local.barrier.resume = Completer<void>();
          final reading = expectLater(
              stage == 'trust'
                  ? handoff.bridge.inspectAppTrust()
                  : handoff.bridge.inspectAppCompletion(),
              rejected);
          await h.local.barrier.reached!.future;
          var settled = false;
          Future<void>? closing;
          if (action == 'close') {
            closing = handoff.close().then((_) => settled = true);
            await Future<void>.value();
            expect(settled, isFalse);
            expect(handoff.bridge.display().initialDigest, isNull);
          } else {
            h.advance(const Duration(seconds: 300));
          }
          h.local.barrier.resume!.complete();
          await reading;
          await closing;
          expect(handoff.bridge.display().closed, isTrue);
          expect(h.native.calls.exchangeReadTickets, isEmpty);
          await expectLater(request.approve(), rejected);
        });
      }
    }

    test('duplicate request never publishes a second Submission or Challenge',
        () async {
      await challenge();
      final files = h.native.calls.exchangeFiles.keys.toSet();
      await expectLater(handoff.request(h.local.reference), rejected);
      expect(h.native.calls.exchangeFiles.keys.toSet(), files);
      await expectLater(request.approve(), rejected);
    });
  });

  group('first-party Bridge onboarding local controls', () {
    late WindowsBridgeOnboarding controls;
    PairingTrustDisplay? exported;
    FirstPartyPairingRequest? appRequest;
    Future<BridgeAppPublicMaterial> Function()? trustReader;
    Future<FirstPartyPairingDisplay> Function()? completionReader;
    late Uint8List id;

    BridgeAppPublicMaterial publicMaterial() => BridgeAppPublicMaterial(
        issuerDer: exported!.issuerDer,
        serverLeafDigest: exported!.serverLeafDigest);

    setUp(() {
      exported = null;
      appRequest = null;
      trustReader = null;
      completionReader = null;
      controls = WindowsBridgeOnboarding(
          owner: h.bridge,
          readAppPublicTrust: (submission) async {
            expect(submission, id);
            return trustReader == null
                ? publicMaterial()
                : await trustReader!();
          },
          readAppCompletion: (submission) async {
            expect(submission, id);
            return completionReader == null
                ? await appRequest!.display()
                : await completionReader!();
          });
    });
    tearDown(() => controls.close());

    Future<void> challenge() async {
      controls.beginEnrollment(
          displayLabel: 'PUBLIC FIXTURE', clientBuild: 'offline');
      id = controls.display().submissionId!;
      final app = WindowsFirstPartyPairing(
          owner: h.app,
          submissionId: () async => id,
          exportPublicTrust: (display) async => exported = display);
      appRequest = await app.request(h.local.reference);
    }

    Future<void> proof() async {
      await challenge();
      await controls.inspectAppTrust();
      controls.confirmInitialAndPublishProof(comparedDigest: exported!.digest);
      await appRequest!.approve();
    }

    Future<void> complete() async {
      await proof();
      await appRequest!.complete();
      await controls.inspectAppCompletion();
    }

    void expectClosed({bool pinAbsent = true}) {
      final display = controls.display();
      expect(display.closed, isTrue);
      expect(display.submissionId, isNull);
      expect(display.initialDigest, isNull);
      expect(display.completionDigest, isNull);
      expect(display.revision, isNull);
      expect(display.pinSaved, isFalse);
      for (final key in h.keys) {
        expect(key, everyElement(0));
      }
      if (pinAbsent) expect(h.native.calls.credentialFiles[4], isNull);
    }

    test(
        'App adapter to two manual actions to Missing-only Pin, never auto-confirm',
        () async {
      expect(controls.display().submissionId, isNull);
      expect(h.keys, isEmpty);
      await challenge();
      await controls.inspectAppTrust();
      final initial = controls.display();
      expect(initial.initialDigest, exported!.digest);
      expect(initial.initialDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(initial.proofPublished, isFalse);
      expect(h.appExchange.readProof(id), isNull);
      expect(h.native.calls.credentialFiles[4], isNull);
      await appRequest!.approve();
      controls.confirmInitialAndPublishProof(
          comparedDigest: initial.initialDigest!);
      expect(controls.display().proofPublished, isTrue);
      await appRequest!.complete();
      await controls.inspectAppCompletion();
      final completion = controls.display();
      final actual =
          (await h.associations.read(h.local.reference.profileId)).record!;
      expect(completion.revision, actual.revision);
      expect(completion.completionDigest, (await appRequest!.display()).digest);
      expect(completion.completionDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(h.native.calls.credentialFiles[4], isNull);
      expect(h.local.trust.snapshot(h.local.profile.principal).state,
          PairingState.pairedDisabled);
      controls.confirmCompletionAndSave(
          comparedDigest: completion.completionDigest!,
          comparedRevision: completion.revision!);
      expect(controls.display().pinSaved, isTrue);
      expect(controls.display().closed, isTrue);
      expect(controls.display().initialDigest, isNull);
      final pin = h.bridgeStore.read(4)! as ExternalBridgeClient;
      expect(pin.clientPkcs8Der, initialization.publicFixtureKey());
      pin.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
      final commits = h.native.calls.commits;
      expect(
          () => controls.confirmCompletionAndSave(
              comparedDigest: completion.completionDigest!,
              comparedRevision: completion.revision!),
          rejected);
      expect(h.native.calls.commits, commits);
      expect(h.native.calls.exchangeReadTickets, isEmpty);
      expect(h.keys.single, everyElement(0));
    });

    for (final variant in ['wrong', 'short', 'uppercase']) {
      test('initial $variant digest rejects Proof and wipes Enrollment',
          () async {
        await challenge();
        await controls.inspectAppTrust();
        final digest = exported!.digest;
        expect(
            () => controls.confirmInitialAndPublishProof(
                    comparedDigest: switch (variant) {
                  'wrong' => '0' * 64,
                  'short' => digest.substring(0, 63),
                  _ => digest.toUpperCase(),
                }),
            rejected);
        expect(h.appExchange.readProof(id), isNull);
        expect(h.native.calls.exchangeReadTickets, isEmpty);
        expectClosed();
      });
    }

    for (final phase in ['before initial', 'before completion read']) {
      test('save $phase cannot bypass either human confirmation', () async {
        if (phase == 'before initial') {
          await challenge();
          await controls.inspectAppTrust();
        } else {
          await proof();
          await appRequest!.complete();
        }
        expect(
            () => controls.confirmCompletionAndSave(
                comparedDigest: '0' * 64, comparedRevision: 1),
            rejected);
        expectClosed();
      });
    }

    for (final variant in ['digest', 'revision', 'missing', 'initial only']) {
      test('incorrect App completion $variant fails closed', () async {
        await proof();
        if (variant != 'initial only') await appRequest!.complete();
        final actual = await appRequest!.display();
        completionReader = () async => switch (variant) {
              'digest' => FirstPartyPairingDisplay(
                  digest: '0' * 64, revision: actual.revision),
              'revision' =>
                FirstPartyPairingDisplay(digest: actual.digest, revision: 5),
              'missing' => const FirstPartyPairingDisplay(),
              _ => actual,
            };
        await expectLater(controls.inspectAppCompletion(), rejected);
        expectClosed();
      });
    }

    for (final field in ['digest', 'revision']) {
      test('second human comparison wrong $field spends save without write',
          () async {
        await complete();
        final display = controls.display();
        expect(
            () => controls.confirmCompletionAndSave(
                comparedDigest:
                    field == 'digest' ? '0' * 64 : display.completionDigest!,
                comparedRevision: field == 'revision'
                    ? display.revision! + 1
                    : display.revision!),
            rejected);
        expectClosed();
      });
    }

    for (final operation in ['begin', 'inspect', 'proof', 'completion']) {
      test('duplicate $operation terminates original attempt', () async {
        await challenge();
        if (operation != 'begin') await controls.inspectAppTrust();
        if (operation == 'proof' || operation == 'completion') {
          controls.confirmInitialAndPublishProof(
              comparedDigest: exported!.digest);
        }
        if (operation == 'completion') {
          await appRequest!.approve();
          await appRequest!.complete();
          await controls.inspectAppCompletion();
        }
        switch (operation) {
          case 'begin':
            expect(
                () =>
                    controls.beginEnrollment(displayLabel: '', clientBuild: ''),
                rejected);
          case 'inspect':
            await expectLater(controls.inspectAppTrust(), rejected);
          case 'proof':
            expect(
                () => controls.confirmInitialAndPublishProof(
                    comparedDigest: exported!.digest),
                rejected);
          case 'completion':
            await expectLater(controls.inspectAppCompletion(), rejected);
        }
        expectClosed();
      });
    }

    for (final phase in ['challenge', 'completion', 'context']) {
      test('$phase expiry/invalidation clears display and never revives',
          () async {
        if (phase == 'completion') {
          await complete();
          h.advance(const Duration(seconds: 120), wall: false);
        } else {
          await challenge();
          await controls.inspectAppTrust();
          if (phase == 'context') {
            h.current = false;
          } else {
            h.advance(const Duration(seconds: 300));
          }
        }
        expect(controls.display, rejected);
        h.current = true;
        h.elapsed = Duration.zero;
        h.native.now = h.native.now.subtract(const Duration(seconds: 300));
        expect(
            () => controls.confirmInitialAndPublishProof(
                comparedDigest: exported!.digest),
            rejected);
        expectClosed();
      });
    }

    test(
        '600-second pre-Challenge expiry cannot be refreshed into a new Enrollment',
        () {
      controls.beginEnrollment(displayLabel: '', clientBuild: '');
      h.advance(const Duration(seconds: 600));
      expect(controls.display, rejected);
      h.elapsed = Duration.zero;
      expect(() => controls.beginEnrollment(displayLabel: '', clientBuild: ''),
          rejected);
      expectClosed();
    });

    test('malformed Challenge is retained inert with no Proof or live key',
        () async {
      await challenge();
      final file =
          h.native.calls.exchangeFiles.keys.singleWhere((k) => k.$1 == 2);
      h.native.calls.exchangeFiles[file] = Uint8List.fromList([1, 2, 3]);
      await expectLater(controls.inspectAppTrust(), rejected);
      expect(h.native.calls.exchangeFiles[file], [1, 2, 3]);
      expect(h.native.calls.exchangeReadTickets, isEmpty);
      expect(h.appExchange.readProof(id), isNull);
      expectClosed();
    });

    test('malformed Proof cannot supply an App completion for Bridge saving',
        () async {
      await proof();
      final file =
          h.native.calls.exchangeFiles.keys.singleWhere((k) => k.$1 == 3);
      h.native.calls.exchangeFiles[file] = Uint8List.fromList([1, 2, 3]);
      await expectLater(appRequest!.complete(), rejected);
      await expectLater(controls.inspectAppCompletion(), rejected);
      expect(h.native.calls.associationFile, isNull);
      expect(h.native.calls.exchangeReadTickets, isEmpty);
      expectClosed();
    });

    test('invalid independently imported public inputs never become trust',
        () async {
      await challenge();
      trustReader = () async => BridgeAppPublicMaterial(
          issuerDer: Uint8List.fromList([1, 2, 3]),
          serverLeafDigest: Uint8List(32));
      await expectLater(controls.inspectAppTrust(), rejected);
      expect(h.appExchange.readProof(id), isNull);
      expect(h.native.calls.exchangeReadTickets, isEmpty);
      expectClosed();
    });

    test('concurrent local input is rejected without a second read or revival',
        () async {
      await challenge();
      final reached = Completer<void>(), release = Completer<void>();
      var reads = 0;
      trustReader = () async {
        reads++;
        reached.complete();
        await release.future;
        return publicMaterial();
      };
      final pending = controls.inspectAppTrust();
      final rejection = expectLater(pending, rejected);
      await reached.future;
      await expectLater(controls.inspectAppTrust(), rejected);
      expectClosed();
      release.complete();
      await rejection;
      expect(reads, 1);
      expectClosed();
    });

    for (final stage in ['initial', 'completion']) {
      test(
          'close during $stage input wipes now, drains and rejects late result',
          () async {
        final reached = Completer<void>(), release = Completer<void>();
        if (stage == 'initial') {
          await challenge();
          trustReader = () async {
            reached.complete();
            await release.future;
            return publicMaterial();
          };
        } else {
          await proof();
          await appRequest!.complete();
          completionReader = () async {
            reached.complete();
            await release.future;
            return appRequest!.display();
          };
        }
        final pending = stage == 'initial'
            ? controls.inspectAppTrust()
            : controls.inspectAppCompletion();
        final rejection = expectLater(pending, rejected);
        await reached.future;
        var drained = false;
        final closing = controls.close().then((_) => drained = true);
        await Future<void>.value();
        expect(drained, isFalse);
        expectClosed();
        release.complete();
        await rejection;
        await closing;
        expect(drained, isTrue);
        expectClosed();
      });
    }

    test('cancel releases inspected E0 read without deleting Challenge',
        () async {
      await challenge();
      await controls.inspectAppTrust();
      expect(h.native.calls.exchangeReadTickets, isNotEmpty);
      await controls.close();
      expect(h.native.calls.exchangeReadTickets, isEmpty);
      expect(h.bridgeExchange.readChallenge(id), isNotNull);
      expectClosed();
    });

    test('local input failure is redacted, terminal and never retried',
        () async {
      await challenge();
      var reads = 0;
      trustReader = () async {
        reads++;
        throw StateError('untrusted input details');
      };
      await expectLater(controls.inspectAppTrust(),
          throwsA(isA<ExternalCredentialException>()));
      await expectLater(controls.inspectAppTrust(), rejected);
      expect(reads, 1);
      expectClosed();
    });

    for (final variant in ['existing', 'corrupt', 'unknown']) {
      test('Pin $variant never overwrites or retries or reports success',
          () async {
        await complete();
        final display = controls.display();
        if (variant == 'existing') h.bridgeStore.write(objects.fixture(4));
        if (variant == 'corrupt') {
          h.native.calls.credentialFiles[4] = Uint8List.fromList([1, 2, 3]);
        }
        final before = h.native.calls.credentialFiles[4]?.toList();
        if (variant == 'unknown') h.native.calls.unknownAfterCommit = true;
        expect(
            () => controls.confirmCompletionAndSave(
                comparedDigest: display.completionDigest!,
                comparedRevision: display.revision!),
            rejected);
        final commits = h.native.calls.commits;
        expect(
            () => controls.confirmCompletionAndSave(
                comparedDigest: display.completionDigest!,
                comparedRevision: display.revision!),
            rejected);
        expect(h.native.calls.commits, commits);
        if (variant != 'unknown') {
          expect(h.native.calls.credentialFiles[4], before);
        }
        expectClosed(pinAbsent: false);
      });
    }
  });

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
  test('P27 has no normal startup consumer and stands exactly once in CI', () {
    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') ||
          file.path.replaceAll('\\', '/').endsWith('/windows_pairing.dart') ||
          file.path.replaceAll('\\', '/') ==
              'lib/data/external/windows_tls_transport.dart' ||
          file.path.replaceAll('\\', '/') ==
              'lib/composition/mcp_vnext_windows_startup.dart' ||
          file.path.replaceAll('\\', '/') ==
              'lib/composition/mcp_vnext_windows_acquisition.dart' ||
          file.path.replaceAll('\\', '/') ==
              'lib/composition/bridge_ui_host.dart') {
        continue;
      }
      expect(file.readAsStringSync(), isNot(contains('windows_pairing.dart')),
          reason: file.path);
    }
    // The explicit Bridge host is reachable only through its own construction;
    // normal App startup, the authorization page and the MCP composition add no
    // consumer, no automatic enrollment and no production switch.
    for (final path in [
      'lib/main.dart',
      'lib/composition/mcp_vnext_app_integration.dart',
      'lib/mcp/vnext_mcp_composition_root.dart',
      'lib/ui/pages/first_party_external_control.dart',
      'lib/ui/pages/external_authorization_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('bridge_ui_host.dart')), reason: path);
      expect(source, isNot(contains('BridgeUiHost')), reason: path);
    }
    expect(File('lib/composition/bridge_ui_host.dart').readAsStringSync(),
        contains('WindowsBridgePublicPairing('));
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
