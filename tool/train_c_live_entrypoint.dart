import 'dart:convert';
import 'dart:io';

import 'train_c_evidence_probe.dart';
import 'train_c_http_observer.dart';
import 'train_c_l1_preflight.dart';
import 'train_c_l1b_review_authorization.dart';
import 'train_c_review_authorization.dart';

const trainCL1BLiveRunEnvironment = 'TRAIN_C_LIVE_RUN';
const trainCL1BPrivateInputPathEnvironment = 'TRAIN_C_PRIVATE_INPUT_PATH';
const trainCL1BCredentialReadyEnvironment = 'TRAIN_C_CREDENTIAL_READY';
const trainCL1BIsolatedRuntimeEnvironment =
    'TRAIN_C_ISOLATED_RUNTIME_AUTHORIZED';
const trainCL1BProviderKindEnvironment = 'TRAIN_C_PROVIDER_KIND';
const trainCL1BProviderModelEnvironment = 'TRAIN_C_PROVIDER_MODEL';
const trainCL1BRunConsumedEnvironment = 'TRAIN_C_RUN_CONSUMED';
const trainCL1BTextProviderEnvironment = 'TRAIN_C_TEXT_PROVIDER_ENABLED';
const trainCL1BVisionProviderEnvironment = 'TRAIN_C_VISION_PROVIDER_ENABLED';
const trainCL1BAnswerRepairEnvironment =
    'TRAIN_C_ANSWER_REPAIR_PROVIDER_ENABLED';

typedef TrainCL1BGitVerification = void Function(
  TrainCReviewedIdentity reviewedIdentity,
);

/// Explicit live-side-effect authorization gate.
///
/// This class performs only bounded, safe checks. It never reads the private
/// input, opens a credential store, creates a runtime, or starts a provider
/// process. The provider-capable target is launched only by [launch] after all
/// checks pass.
final class TrainCL1BLiveLaunchGuard {
  const TrainCL1BLiveLaunchGuard._();

  static TrainCReviewedIdentity verify({
    Map<String, String>? environment,
    TrainCL1BGitVerification? verifyGit,
  }) {
    final values = environment ?? Platform.environment;
    if (values[trainCL1BLiveRunEnvironment] != '1') {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
    if (values[trainCL1BRunConsumedEnvironment] == '1') {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED',
      );
    }
    if ((values[trainCL1BPrivateInputPathEnvironment] ?? '').trim().isEmpty) {
      throw const TrainCEvidenceProbeException('TRAIN_C_INPUT_INVALID');
    }
    if (values[trainCL1BCredentialReadyEnvironment] != '1' ||
        values[trainCL1BIsolatedRuntimeEnvironment] != '1' ||
        values[trainCL1BProviderKindEnvironment] != 'zhipu' ||
        values[trainCL1BProviderModelEnvironment] != 'glm-ocr' ||
        values[trainCL1BTextProviderEnvironment] == '1' ||
        values[trainCL1BVisionProviderEnvironment] == '1' ||
        values[trainCL1BAnswerRepairEnvironment] == '1') {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }

    final reviewed = TrainCL1BReviewAuthorization.requireFromEnvironment(
      environment: values,
    );
    (verifyGit ?? _verifyGit).call(reviewed);
    return reviewed;
  }

  static Future<int> launch({
    Map<String, String>? environment,
    TrainCL1BGitVerification? verifyGit,
    Future<int> Function(TrainCReviewedIdentity reviewedIdentity)? start,
  }) async {
    final values = environment ?? Platform.environment;
    final reviewed = verify(environment: values, verifyGit: verifyGit);
    if (start != null) return start(reviewed);

    final process = await Process.start(
      'flutter',
      const <String>[
        'run',
        '-d',
        'windows',
        '-t',
        'tool/train_c_l1b_live_runtime.dart',
      ],
      mode: ProcessStartMode.inheritStdio,
      environment: buildLiveTargetEnvironment(environment: values),
      includeParentEnvironment: false,
    );
    return process.exitCode;
  }

  /// Passes only the live-run capability values and the minimal Windows/Dart
  /// bootstrap environment. In particular, arbitrary parent variables (and
  /// any provider secret accidentally present there) are not inherited by the
  /// provider-capable target.
  static Map<String, String> buildLiveTargetEnvironment({
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    const capabilityKeys = <String>[
      trainCL1BLiveRunEnvironment,
      trainCL1BPrivateInputPathEnvironment,
      trainCL1BCredentialReadyEnvironment,
      trainCL1BIsolatedRuntimeEnvironment,
      trainCL1BProviderKindEnvironment,
      trainCL1BProviderModelEnvironment,
      trainCL1BRunConsumedEnvironment,
      trainCL1BTextProviderEnvironment,
      trainCL1BVisionProviderEnvironment,
      trainCL1BAnswerRepairEnvironment,
      trainCApprovedHarnessHeadEnvironment,
      trainCL1BApprovedBaseEnvironment,
    ];
    const bootstrapKeys = <String>[
      'PATH',
      'Path',
      'PATHEXT',
      'COMSPEC',
      'SystemRoot',
      'WINDIR',
      'TEMP',
      'TMP',
      'USERPROFILE',
      'APPDATA',
      'LOCALAPPDATA',
      'FLUTTER_ROOT',
      'DART_SDK',
      'PUB_CACHE',
    ];
    final result = <String, String>{};
    for (final key in <String>[...capabilityKeys, ...bootstrapKeys]) {
      final value = values[key];
      if (value != null && value.isNotEmpty) result[key] = value;
    }
    final path = result['PATH'] ?? result['Path'];
    if (path != null) result['PATH'] = path;
    return result;
  }

  static void _verifyGit(TrainCReviewedIdentity reviewed) {
    TrainCPreExecutionGitGate(reviewedIdentity: reviewed).verify();
  }
}

/// The live entrypoint is safe by default. Offline mode is a harmless proof;
/// live mode requires the complete out-of-band authorization gate.
final class TrainCLiveEntrypoint {
  const TrainCLiveEntrypoint._();

  static Map<String, Object?> offlineProof() {
    final ledger = TrainCRequestLedger();
    return <String, Object?>{
      'stage': 'TRAIN-C-H0',
      'status': 'PASS',
      'liveRun': 'BLOCKED',
      'authority': 'offline_harness_only',
      ...ledger.safeSummary(),
    };
  }
}

void main(List<String> args) {
  if (args.length == 1 && args.single == '--offline') {
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(TrainCLiveEntrypoint.offlineProof()),
    );
    return;
  }

  if (args.length == 1 && args.single == '--live') {
    TrainCL1BLiveLaunchGuard.launch().then<void>((code) {
      exitCode = code;
    }).catchError((Object error) {
      if (error is TrainCEvidenceProbeException) {
        stderr.writeln(error.code);
      } else {
        stderr.writeln('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED');
      }
      exitCode = 1;
    });
    return;
  }

  stderr.writeln('TRAIN_C_HARNESS_NOT_READY');
  exitCode = 2;
}
