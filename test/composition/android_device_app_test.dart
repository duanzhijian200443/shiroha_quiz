import 'dart:async';
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
      final enabling = app.enable();
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
}
