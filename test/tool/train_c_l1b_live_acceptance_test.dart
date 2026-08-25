import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_live_entrypoint.dart';
import '../../tool/train_c_l1b_review_authorization.dart';
import '../../tool/train_c_review_authorization.dart';

void main() {
  final baseEnvironment = <String, String>{
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
  };

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
}

Matcher _code(String expected) => throwsA(
      predicate<TrainCEvidenceProbeException>(
        (error) => error.code == expected,
      ),
    );
