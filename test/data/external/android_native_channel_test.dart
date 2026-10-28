import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_boundary.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/external/android_native_association_backend.dart';
import 'package:shiroha_quiz/data/external/android_native_channel.dart';
import '../../application/external/external_credential_test_support.dart';
import '../../application/external/external_trust_test_support.dart';

final class _Native implements AndroidNativeCalls {
  bool live = true;
  Object? readReply;
  Completer<void>? attesting, release;
  @override
  Future<Object?> invoke(String method,
      [Map<String, Object?>? arguments]) async {
    if (method == 'attest') {
      if (attesting?.isCompleted == false) attesting!.complete();
      await release?.future;
      return live;
    }
    if (method == 'channelClose') return true;
    if (method == 'read') return readReply;
    throw StateError('unexpected_native_call');
  }
}

void main() {
  initializeGeneratedTests();
  test('link nonces reject noncanonical base64url aliases', () {
    expect(androidNonceIsValid(androidNonce()), isTrue);
    expect(androidNonceIsValid('${'A' * 42}B'), isFalse);
    expect(androidNonceIsValid('${'A' * 43}='), isFalse);
  });
  test('strict link JSON rejects escaped/nested duplicates and malformed UTF8',
      () {
    for (final text in [
      r'{"x":1,"\u0078":2}',
      '{"x":{"y":1,"y":2}}',
      '[]',
      '${'[' * 33}0${']' * 33}'
    ]) {
      expect(() => androidStrictObject(Uint8List.fromList(utf8.encode(text))),
          throwsA(anything));
    }
    expect(() => androidStrictObject(Uint8List.fromList([0xff])),
        throwsFormatException);
    expect(
        androidStrictObject(Uint8List.fromList(utf8.encode('{"x":[1,2]}'))), {
      'x': [1, 2]
    });
  });

  test('Native immutable codec buffer is decoded without mutating its owner',
      () async {
    final borrowed = Uint8List.fromList(utf8.encode('{"type":"hello"}'))
        .asUnmodifiableView();
    final native = _Native()..readReply = {'kind': 1, 'payload': borrowed};
    final verifier = AndroidChannelVerification(native,
        elapsed: () => Duration.zero,
        current: () => true,
        installationId: 'test-install',
        expiresAt: DateTime.utc(2035));
    final channel = verifier.accept({
      'channel': '10000000-0000-4000-8000-000000000001',
      'peer': 'a' * 64,
      'installationId': 'test-install'
    });
    final (kind, message) = await channel.read();
    expect(kind, 1);
    expect(message, {'type': 'hello'});
    expect(utf8.decode(borrowed), '{"type":"hello"}');
    await verifier.retire(channel);
    await verifier.close();
  });

  group('Native channel events enter original P15/P0', () {
    late OfflineTrustHarness f;
    late _Native native;
    late AndroidChannelVerification verifier;
    late ExternalCredentialBoundary boundary;
    late MemoryExternalAssociations store;
    Duration elapsed = Duration.zero;
    final peer = 'a' * 64;
    int sequence = 0;
    Future<void> compose() async {
      final id = f.reference.profileId;
      await f.coordinator.shutdown();
      f.management.invalidate();
      f.localSession.close();
      f.localFactory.invalidate();
      verifier = AndroidChannelVerification(native,
          elapsed: () => elapsed,
          current: () => f.current,
          installationId: 'android-test-install',
          expiresAt: DateTime.utc(2035));
      await f.compose(
          credentialFactory: (management) => boundary =
              ExternalCredentialBoundary.offline(
                  associations: store,
                  verification: verifier,
                  management: management,
                  clock: f.clock,
                  installationId: 'android-test-install',
                  monotonicNow: () => elapsed,
                  compositionIsCurrent: () => f.current));
      boundary.attach(f.coordinator, f.trust);
      f.reference = await f.management.selectProfile(id);
      f.profile = await f.coordinator.registerProfile(f.reference);
    }

    AndroidNativeChannel channel() => verifier.accept({
          'channel':
              '10000000-0000-4000-8000-${(++sequence).toString().padLeft(12, '0')}',
          'peer': peer,
          'installationId': 'android-test-install'
        });
    Future<void> pair() async {
      final original = channel();
      final request = await boundary.requestPairing(f.reference,
          requestId: 'test-request',
          credentialIdentity: peer,
          expectedRevision: 0);
      await boundary.approvePairing(request);
      final evidence = await verifier.event(original, f.reference,
          purpose: 'pairing', revision: 0);
      await boundary.completePairing(request, evidence);
      expect((await boundary.confirmedPairing(request)).revision, 1);
      expect(f.trust.snapshot(f.profile.principal).state,
          PairingState.pairedDisabled);
      await verifier.retire(original);
    }

    setUp(() async {
      elapsed = Duration.zero;
      f = OfflineTrustHarness();
      await f.open();
      native = _Native();
      store = MemoryExternalAssociations();
      await compose();
    });
    tearDown(() async {
      await verifier.close();
      await boundary.shutdown();
      await f.close();
    });

    test('a certificate digest/claimed verified DTO never creates P15 proof',
        () async {
      for (final claim in [
        peer,
        {'peer': peer, 'verified': true},
        AuthenticatedPeerEvidence(peer)
      ]) {
        expect(verifier.isLive(claim), isFalse);
        expect(boundary.authenticate(claim), isNull);
        expect(boundary.provePossession(claim), isNull);
      }
      expect(store.records, isEmpty);
    });
    test(
        'pairing uses original association CAS; fresh existing proof restores P0 only disabled',
        () async {
      await pair();
      await verifier.close();
      await compose();
      final original = channel(),
          snapshot = await store.read(f.reference.profileId);
      final evidence = await verifier.event(original, f.reference,
          purpose: 'enable-proof', revision: 1, association: snapshot);
      final confirmation =
          await boundary.prepareExistingConfirmation(f.reference, evidence);
      await boundary.confirmExistingCredential(confirmation);
      expect(f.trust.snapshot(f.profile.principal).state,
          PairingState.pairedDisabled);
      expect(store.records[f.reference.profileId]!.revision, 1);
      await verifier.retire(original);
      boundary.releaseExistingConfirmation(confirmation);
      await f.save();
      await f.enable();
      final business = channel();
      final auth = await verifier.event(business, f.reference,
          purpose: 'business',
          revision: 1,
          association: await store.read(f.reference.profileId));
      final session = await boundary.openSession(f.reference, auth);
      verifier.bindSession(auth, session);
      expect(session.failure, isNull);
      verifier.invalidate(business.id);
      native.live = true;
      expect(verifier.isLive(auth), isFalse);
      expect(await business.attest(), isFalse);
      await verifier.retire(business);
    });
    test('closed original channel cannot pass a late Native attestation',
        () async {
      final original = channel();
      native.attesting = Completer<void>();
      native.release = Completer<void>();
      final pending = verifier.event(original, f.reference,
          purpose: 'pairing', revision: 0);
      final rejected = expectLater(pending, throwsStateError);
      await native.attesting!.future;
      verifier.invalidate(original.id);
      native.release!.complete();
      await rejected;
      await verifier.retire(original);
    });
    test(
        'wrong purpose cannot substitute business authentication for enable proof',
        () async {
      await pair();
      await verifier.close();
      await compose();
      final original = channel();
      final wrong = await verifier.event(original, f.reference,
          purpose: 'business',
          revision: 1,
          association: await store.read(f.reference.profileId));
      await expectLater(
          boundary.prepareExistingConfirmation(f.reference, wrong),
          throwsA(isA<ExternalCredentialException>()));
      expect(
          f.trust.snapshot(f.profile.principal).state, PairingState.unpaired);
      await verifier.retire(original);
    });
    test('original proof budget expires despite a still-live TLS channel',
        () async {
      final original = channel();
      final evidence = await verifier.event(original, f.reference,
          purpose: 'pairing', revision: 0);
      elapsed = const Duration(seconds: 30);
      expect(verifier.isLive(evidence), isFalse);
      elapsed = Duration.zero;
      expect(verifier.isLive(evidence), isFalse);
      await verifier.retire(original);
    });
  });
}
