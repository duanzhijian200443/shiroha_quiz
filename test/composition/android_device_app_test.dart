import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/android_device_access.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/composition/android_device_app.dart';
import 'package:shiroha_quiz/data/external/association_object_codec.dart';
import '../application/external/local_authorization_test_support.dart';
import '../mcp/fixtures/first_party_app_integration_cases.dart';

void main() {
  initializeGeneratedTests();
  test('background predicate retains READ scope and excludes all wider grants',
      () {
    expect(androidBackgroundQuestionRead(androidQuestionReadPolicy()), isTrue);
    for (final category in [
      ExternalContentCategory.fileContent,
      ExternalContentCategory.studyStatistics,
      ExternalContentCategory.proposalMetadata
    ]) {
      expect(
          androidBackgroundQuestionRead(ExternalGrantPolicy(
              permissions: const [CapabilityPermission.read],
              allContent: true,
              scopes: const [],
              categories: [ExternalContentCategory.questionContent, category])),
          isFalse);
    }
    expect(
        androidBackgroundQuestionRead(ExternalGrantPolicy(
            permissions: const [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ],
            allContent: true,
            scopes: const [],
            categories: const [ExternalContentCategory.questionContent])),
        isFalse);
  });
  test(
      'phone policy cancellation/CAS never creates replacement runtime or changes identity',
      () async {
    final local = LocalAuthorizationHarness();
    await local.open();
    const profile = '10000000-0000-4000-8000-000000000001';
    const installation = '20000000-0000-4000-8000-000000000001';
    final management = ExternalAuthorizationManagement(
        repository: local.repository,
        compositionIsCurrent: () => local.h.db.isOpen,
        mintProfileId: () => profile);
    final ref = await management.createProfile(
        displayName: 'Synthetic Android',
        adapter: 'android-device',
        protocol: 'android-device-link');
    await management.replaceGrant(ref, 0, androidQuestionReadPolicy());
    final calls = <String>[];
    final prepareEntered = Completer<void>();
    final prepareReply = Completer<Object?>();
    const channel = MethodChannel('shiroha/android_device_foundation');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'status' => {
            'runtimeAvailable': true,
            'observation': {
              'sequence': 1,
              'resumed': true,
              'focused': true,
              'interactive': true,
              'unlocked': true,
              'visible': true,
              'network': 'synthetic-network',
              'address': '192.0.2.1',
              'elapsedMs': 1
            }
          },
        'identity' => {
            'installationId': installation,
            'deviceId': 'b' * 64,
            'certificateDigest': 'c' * 64,
            'expiresAt': DateTime.utc(2027).millisecondsSinceEpoch
          },
        'associationBegin' => {
            'lease': 1,
            'plaintext': AssociationObjectCodec.encode([
              AssociationObjectRecord(
                  ExternalCredentialAssociation(
                      profileId: profile,
                      installationId: installation,
                      credentialIdentity: 'a' * 64,
                      revision: 1,
                      revoked: false),
                  1)
            ])
          },
        'associationClose' => true,
        'backgroundPrepare' => () {
            prepareEntered.complete();
            return prepareReply.future;
          }(),
        'backgroundWithdraw' || 'backgroundStop' => true,
        _ => throw StateError('Unexpected synthetic native call'),
      };
    });
    var runtimes = 0;
    final app = AndroidDeviceApp(
        policy: local.service,
        applicationCurrent: () => local.h.db.isOpen,
        mintId: () => profile,
        createIntegration: () {
          runtimes++;
          throw StateError('No runtime requested');
        });
    try {
      await app.inspect();
      expect(app.state.paired, isTrue);
      expect(app.state.generationMode, isNull);
      expect(app.state.fileContentAllowed, isFalse);
      expect(app.state.allContent, isTrue);
      expect((await management.read(ref)).profile.grantRevision, 1);
      final enabling =
          app.enable(duration: AndroidAccessDuration.untilAppStops);
      await prepareEntered.future;
      expect(app.state.phase, AndroidAccessPhase.off);
      expect(app.state.expiresAt, isNull);
      expect(runtimes, 0);
      await app.cancelPending();
      prepareReply
          .complete(true); // Late promotion cannot resurrect this owner.
      await enabling;
      expect(app.state.phase, AndroidAccessPhase.off);
      expect(app.state.backgroundRead, isFalse);
      expect(app.state.untilAppStops, isFalse);
      expect(app.state.expiresAt, isNull);
      expect(runtimes, 0);
      final cancelled = app.setGenerationMode(ExternalGenerationMode.review);
      final failure = expectLater(cancelled, throwsStateError);
      await app.cancelPending();
      await failure;
      expect((await management.read(ref)).profile.grantRevision, 1);
      await app.inspect();
      await app.setGenerationMode(ExternalGenerationMode.review);
      expect(app.state.generationMode, ExternalGenerationMode.review);
      expect(app.state.phase, AndroidAccessPhase.off);
      await expectLater(
          app.enable(duration: AndroidAccessDuration.untilAppStops),
          throwsStateError);
      expect(app.state.untilAppStops, isFalse);
      await app.setGenerationMode(ExternalGenerationMode.direct);
      expect(app.state.phase, AndroidAccessPhase.off);
      expect(app.state.generationMode, ExternalGenerationMode.direct);
      final fileCancellation = app.setFileContentAllowed(true);
      final fileFailure = expectLater(fileCancellation, throwsStateError);
      await app.cancelPending();
      await fileFailure;
      expect((await management.read(ref)).profile.grantRevision, 3);
      await app.inspect();
      await app.setFileContentAllowed(true);
      expect(app.state.fileContentAllowed, isTrue);
      expect(app.state.generationMode, ExternalGenerationMode.direct);
      expect(app.state.phase, AndroidAccessPhase.off);
      await app.inspect();
      expect(app.state.fileContentAllowed, isTrue);
      await app.setFileContentAllowed(false);
      expect(app.state.fileContentAllowed, isFalse);
      expect(app.state.generationMode, ExternalGenerationMode.direct);
      final statsCancellation = app.setStudyStatisticsAllowed(true);
      final statsFailure = expectLater(statsCancellation, throwsStateError);
      await app.cancelPending();
      await statsFailure;
      expect((await management.read(ref)).profile.grantRevision, 5);
      await app.inspect();
      await app.setStudyStatisticsAllowed(true);
      expect(app.state.studyStatisticsAllowed, isTrue);
      expect(app.state.generationMode, ExternalGenerationMode.direct);
      expect(app.state.fileContentAllowed, isFalse);
      expect(app.state.phase, AndroidAccessPhase.off);
      await app.setStudyStatisticsAllowed(false);
      expect(app.state.studyStatisticsAllowed, isFalse);
      expect(app.state.generationMode, ExternalGenerationMode.direct);
      await management.replaceGrant(ref, 7, androidQuestionReadPolicy());
      await expectLater(app.setGenerationMode(ExternalGenerationMode.review),
          throwsA(isA<ExternalAuthException>()));
      expect((await management.read(ref)).profile.grantRevision, 8);
      await app.inspect();
      expect(app.state.generationMode, isNull);
      expect(app.state.profileId, profile);
      expect(app.state.deviceId, 'b' * 64);
      expect(runtimes, 0);
      expect(calls.toSet(), {
        'status',
        'identity',
        'associationBegin',
        'associationClose',
        'backgroundPrepare',
        'backgroundWithdraw',
        'backgroundStop'
      });
    } finally {
      await app.close();
      management.invalidate();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await local.close();
    }
  });

  for (final peerEof in [false, true]) {
    test(
        peerEof
            ? 'Profile 2 peer EOF stops the original background owner in recovery'
            : 'local withdrawal stops the original background owner cleanly',
        () async {
      final fixture = FirstPartyAppHarness();
      await fixture.open(attach: false);
      addTearDown(fixture.close);
      const profile = '10000000-0000-4000-8000-000000000001';
      const installation = '20000000-0000-4000-8000-000000000001';
      const proof = '30000000-0000-4000-8000-000000000001';
      const business = '40000000-0000-4000-8000-000000000001';
      final management = ExternalAuthorizationManagement(
          repository: fixture.files.s.authorization,
          compositionIsCurrent: () => fixture.files.s.h.db.isOpen,
          mintProfileId: () => profile);
      addTearDown(management.invalidate);
      final ref = await management.createProfile(
          displayName: 'Synthetic Android',
          adapter: 'android-device',
          protocol: 'android-device-link');
      await management.replaceGrant(ref, 0, androidQuestionReadPolicy());

      const channel = MethodChannel('shiroha/android_device_foundation');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final listener = Completer<void>();
      final proofClose = Completer<Object?>();
      final reading = Completer<void>();
      final businessRead = Completer<Object?>();
      final stopping = Completer<void>();
      final serviceStopped = Completer<Object?>();
      final helloRead = <Object?>{};
      final calls = <String>[];
      const stepTimeout = Duration(seconds: 5);
      const foreground = {
        'sequence': 1,
        'resumed': true,
        'focused': true,
        'interactive': true,
        'unlocked': true,
        'visible': true,
        'network': 'synthetic-network',
        'address': '192.0.2.1',
        'elapsedMs': 1,
      };
      Map<String, Object?> control(Map<String, Object?> body) => {
            'kind': 1,
            'payload': const Utf8Encoder().convert(jsonEncode(body)),
          };

      messenger.setMockMethodCallHandler(channel, (call) async {
        final arguments = call.arguments as Map<Object?, Object?>?;
        final id = arguments?['channel'];
        calls.add(
            call.method == 'channelClose' ? 'channelClose:$id' : call.method);
        switch (call.method) {
          case 'status':
            return {
              'runtimeAvailable': true,
              'observation': foreground,
            };
          case 'identity':
            return {
              'installationId': installation,
              'deviceId': 'b' * 64,
              'certificateDigest': 'c' * 64,
              'expiresAt': DateTime.utc(2100).millisecondsSinceEpoch,
            };
          case 'associationBegin':
            return {
              'lease': 1,
              'plaintext': AssociationObjectCodec.encode([
                AssociationObjectRecord(
                    ExternalCredentialAssociation(
                        profileId: profile,
                        installationId: installation,
                        credentialIdentity: 'a' * 64,
                        revision: 1,
                        revoked: false),
                    1)
              ]),
            };
          case 'linkOpen':
            expect(arguments?['untilAppStops'], isTrue);
            listener.complete();
            return {'port': 46443, 'link': 'original-link'};
          case 'read':
            expect(id, anyOf(proof, business));
            if (helloRead.add(id)) {
              return control({
                'type': 'hello',
                'purpose': id == proof ? 'enable-proof' : 'business',
                'expectedDeviceId': 'b' * 64,
                'expectedProfileId': profile,
                'clientNonce': 'A' * 43,
                'linkVersions': [1],
              });
            }
            if (id == proof) return proofClose.future;
            reading.complete();
            return businessRead.future;
          case 'write':
            final body =
                jsonDecode(utf8.decode(arguments!['payload'] as List<int>))
                    as Map<String, Object?>;
            if (body['type'] == 'proof-complete') {
              proofClose.complete(control({
                'type': 'closing',
                for (final key in [
                  'connectionId',
                  'clientNonce',
                  'serverNonce',
                  'settlementNonce'
                ])
                  key: body[key],
              }));
            }
            return true;
          case 'channelClose':
            if (id == business &&
                reading.isCompleted &&
                !businessRead.isCompleted) {
              businessRead
                  .completeError(PlatformException(code: 'connection_closed'));
            }
            return true;
          case 'backgroundStop':
            stopping.complete();
            return serviceStopped.future;
          case 'associationClose':
          case 'backgroundPrepare':
          case 'backgroundWithdraw':
          case 'linkEnabled':
          case 'linkClose':
          case 'linkRelease':
          case 'established':
          case 'proofStarted':
          case 'peerClosed':
          case 'attest':
            return true;
          default:
            throw StateError('Unexpected synthetic native call');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      Future<void> emit(String method, Map<String, Object?> body) async {
        await messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec()
                .encodeMethodCall(MethodCall(method, body)),
            null);
      }

      Future<void> connect(String id) => emit('connected', {
            'channel': id,
            'peer': 'a' * 64,
            'installationId': installation,
          });

      final app = AndroidDeviceApp(
          createIntegration: () => fixture.integration,
          policy: fixture.policy,
          applicationCurrent: () => fixture.files.s.h.db.isOpen,
          mintId: fixture.integration.mintId);
      try {
        await app.inspect();
        final enabling =
            app.enable(duration: AndroidAccessDuration.untilAppStops);
        await listener.future.timeout(stepTimeout);
        await connect(proof);
        await enabling.timeout(stepTimeout);
        expect(app.state.phase, AndroidAccessPhase.ready);
        await emit('foreground', {
          ...foreground,
          'sequence': 2,
          'backgroundRead': true,
        });
        await connect(business);
        await reading.future.timeout(stepTimeout);
        expect(app.state.connected, isTrue);

        if (peerEof) {
          businessRead
              .completeError(PlatformException(code: 'connection_closed'));
        } else {
          unawaited(app.disable());
        }
        await stopping.future.timeout(stepTimeout);
        expect(calls.where((call) => call == 'channelClose:$business'),
            hasLength(1));
        expect(calls, containsAllInOrder(['linkRelease', 'backgroundStop']));
        expect(app.state.listening, isFalse);
        expect(app.state.connected, isFalse);
        final joined = app.disable(); // An overlapping stop joins this owner.
        serviceStopped.complete(true);
        await joined.timeout(stepTimeout);
        expect(app.state.phase,
            peerEof ? AndroidAccessPhase.recovery : AndroidAccessPhase.off);
        expect(app.state.backgroundRead, isFalse);
        expect(calls.where((call) => call == 'backgroundStop'), hasLength(1));
        if (peerEof) await expectLater(app.enable(), throwsStateError);
      } finally {
        if (!serviceStopped.isCompleted) serviceStopped.complete(true);
        if (app.state.phase == AndroidAccessPhase.recovery) {
          await expectLater(app.close(), throwsStateError);
        } else {
          await app.close();
        }
      }
    });
  }
}
