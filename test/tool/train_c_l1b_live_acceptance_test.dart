import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_live_entrypoint.dart';
import '../../tool/train_c_l1b_review_authorization.dart';
import '../../tool/train_c_live_attempt_authority.dart';
import '../../tool/train_c_review_authorization.dart';

void main() {
  late Map<String, String> baseEnvironment;

  setUp(() {
    final stateDirectory = Directory.systemTemp.createTempSync(
      'train_c_attempt_test_',
    );
    addTearDown(() {
      if (stateDirectory.existsSync()) {
        stateDirectory.deleteSync(recursive: true);
      }
    });
    final capability = TrainCLiveAttemptAuthority.authorize(
      stateDirectory: stateDirectory,
      approvedHarnessHead: 'a000000000000000000000000000000000000000',
      approvedBase: 'b000000000000000000000000000000000000000',
    );
    baseEnvironment = <String, String>{
      trainCL1BLiveRunEnvironment: '1',
      trainCL1BPrivateInputPathEnvironment: 'opaque-input-authority',
      trainCL1BCredentialReadyEnvironment: '1',
      trainCL1BIsolatedRuntimeEnvironment: '1',
      trainCL1BProviderKindEnvironment: 'zhipu',
      trainCL1BProviderModelEnvironment: 'glm-ocr',
      trainCApprovedHarnessHeadEnvironment:
          'a000000000000000000000000000000000000000',
      trainCL1BApprovedBaseEnvironment:
          'b000000000000000000000000000000000000000',
      trainCL1BApprovedProductionSeamBlobEnvironment:
          'c000000000000000000000000000000000000000',
      trainCLiveAttemptCapabilityEnvironment: capability,
    };
  });

  test('live mode is blocked when explicit live authority is absent', () {
    expect(
      () => TrainCL1BLiveLaunchGuard.verify(
        environment: const <String, String>{},
      ),
      _code('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED'),
    );
  });

  test('missing reviewed head is blocked before git/provider boundary', () {
    final environment = Map<String, String>.from(baseEnvironment)
      ..remove(trainCApprovedHarnessHeadEnvironment);
    expect(
      () => TrainCL1BLiveLaunchGuard.verify(
        environment: environment,
        verifyGit: (_) => fail('git gate must not run'),
      ),
      _code('TRAIN_C_CODE_IDENTITY_MISMATCH'),
    );
  });

  test('wrong reviewed head is rejected by the reviewed git gate', () {
    expect(
      () => TrainCL1BLiveLaunchGuard.verify(
        environment: baseEnvironment,
        verifyGit: (_) => throw const TrainCEvidenceProbeException(
          'TRAIN_C_HEAD_DRIFT',
        ),
      ),
      _code('TRAIN_C_HEAD_DRIFT'),
    );
  });

  test('durable capability base must match out-of-band reviewed base', () {
    final environment = Map<String, String>.from(baseEnvironment)
      ..[trainCL1BApprovedBaseEnvironment] =
          'd000000000000000000000000000000000000000';
    expect(
      () => TrainCL1BLiveLaunchGuard.verify(
        environment: environment,
        verifyGit: (_) => fail('git gate must not run after identity drift'),
      ),
      _code('TRAIN_C_HEAD_DRIFT'),
    );
  });

  test('missing private input authority is blocked before file access', () {
    final environment = Map<String, String>.from(baseEnvironment)
      ..remove(trainCL1BPrivateInputPathEnvironment);
    expect(
      () => TrainCL1BLiveLaunchGuard.verify(
        environment: environment,
        verifyGit: (_) => fail('git gate must not run'),
      ),
      _code('TRAIN_C_INPUT_INVALID'),
    );
  });

  test('missing credential authority is blocked without invoking git', () {
    final environment = Map<String, String>.from(baseEnvironment)
      ..remove(trainCL1BCredentialReadyEnvironment);
    expect(
      () => TrainCL1BLiveLaunchGuard.verify(
        environment: environment,
        verifyGit: (_) => fail('git gate must not run'),
      ),
      _code('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED'),
    );
  });

  test('provider policy rejects text, vision, and repair enablement', () {
    for (final key in const <String>[
      trainCL1BTextProviderEnvironment,
      trainCL1BVisionProviderEnvironment,
      trainCL1BAnswerRepairEnvironment,
    ]) {
      final environment = Map<String, String>.from(baseEnvironment)
        ..[key] = '1';
      expect(
        () => TrainCL1BLiveLaunchGuard.verify(
          environment: environment,
          verifyGit: (_) => fail('git gate must not run'),
        ),
        _code('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED'),
      );
    }
  });

  test('consumed run cannot be launched again', () {
    final environment = Map<String, String>.from(baseEnvironment)
      ..[trainCL1BRunConsumedEnvironment] = '1';
    expect(
      () => TrainCL1BLiveLaunchGuard.verify(
        environment: environment,
        verifyGit: (_) => fail('git gate must not run'),
      ),
      _code('TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED'),
    );
  });

  test('successful gate invokes only the injected launcher', () async {
    TrainCReviewedIdentity? received;
    var started = false;
    final exitCode = await TrainCL1BLiveLaunchGuard.launch(
      environment: baseEnvironment,
      verifyGit: (reviewed) => received = reviewed,
      start: (reviewed) async {
        started = true;
        expect(reviewed.approvedHarnessHead,
            baseEnvironment[trainCApprovedHarnessHeadEnvironment]);
        return 0;
      },
    );

    expect(exitCode, 0);
    expect(started, isTrue);
    expect(received, isNotNull);
  });

  test('live target environment excludes arbitrary parent secrets', () {
    final environment = <String, String>{
      ...baseEnvironment,
      'TRAIN_C_SYNTHETIC_SECRET': 'must-not-cross',
      'PATH': r'C:\synthetic\bin',
    };

    final target = TrainCL1BLiveLaunchGuard.buildLiveTargetEnvironment(
      environment: environment,
    );

    expect(target['TRAIN_C_SYNTHETIC_SECRET'], isNull);
    expect(target['TRAIN_C_LIVE_RUN'], '1');
    expect(target['PATH'], r'C:\synthetic\bin');
  });

  test(
      'continuation requires consumed pending capability and strips input authority',
      () {
    final capability = TrainCLiveAttemptAuthority.fromCapability(
      baseEnvironment[trainCLiveAttemptCapabilityEnvironment]!,
    )
      ..verifyUnused(
        reviewedHarnessHead:
            baseEnvironment[trainCApprovedHarnessHeadEnvironment]!,
      )
      ..bindRuntimeCapability('runtime-a')
      ..markConfigured()
      ..markParseRunning()
      ..consumeAtDispatch()
      ..markPendingReview();
    expect(capability.snapshot.phase, TrainCLiveRunPhase.pendingReview);

    final continuation = <String, String>{
      ...baseEnvironment,
      trainCL1BContinuationEnvironment: '1',
    }..remove(trainCL1BPrivateInputPathEnvironment);

    final mismatchedBase = Map<String, String>.from(continuation)
      ..[trainCL1BApprovedBaseEnvironment] =
          'd000000000000000000000000000000000000000';
    expect(
      () => TrainCL1BLiveLaunchGuard.verifyContinuation(
        environment: mismatchedBase,
        verifyGit: (_) => fail('git gate must not run after identity drift'),
      ),
      _code('TRAIN_C_HEAD_DRIFT'),
    );

    final reviewed = TrainCL1BLiveLaunchGuard.verifyContinuation(
      environment: continuation,
      verifyGit: (_) {},
    );
    expect(reviewed.approvedHarnessHead,
        baseEnvironment[trainCApprovedHarnessHeadEnvironment]);
    final target = TrainCL1BLiveLaunchGuard.buildContinuationTargetEnvironment(
      environment: continuation,
    );
    expect(target[trainCL1BPrivateInputPathEnvironment], isNull);
    expect(target[trainCL1BCredentialReadyEnvironment], isNull);
    expect(target[trainCL1BContinuationEnvironment], '1');
  });
}

Matcher _code(String expected) => throwsA(
      predicate<TrainCEvidenceProbeException>(
        (error) => error.code == expected,
      ),
    );
