import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'train_c_evidence_probe.dart';
import 'train_c_http_observer.dart';
import 'train_c_l1_preflight.dart';
import 'train_c_l1b_phase_controller.dart';
import 'train_c_l1b_production_diff_authority.dart';
import 'train_c_l1b_review_authorization.dart';
import 'train_c_l1b_supervisor.dart';
import 'train_c_live_attempt_authority.dart';
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
const trainCL1BContinuationEnvironment = 'TRAIN_C_L1B_CONTINUATION';

typedef TrainCL1BGitVerification = void Function(
  TrainCReviewedIdentity reviewedIdentity,
);

/// Explicit live-side-effect authorization gate.
///
/// This class performs only bounded, safe checks. It never reads the private
/// input, opens a credential store, creates a runtime, or starts a provider
/// process. The provider-capable parse child is launched only after all checks
/// pass and is owned by the in-memory supervisor.
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
    final attemptCapability =
        values[trainCLiveAttemptCapabilityEnvironment]?.trim() ?? '';
    if (attemptCapability.isEmpty) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
    final capability =
        TrainCLiveAttemptAuthority.fromCapability(attemptCapability);
    _verifyCapabilityIdentity(capability, reviewed);
    capability.verifyUnused(
      reviewedHarnessHead: reviewed.approvedHarnessHead,
      reviewedBase: reviewed.approvedBase,
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

    return TrainCL1BSupervisor.run(
      liveEnvironment: buildLiveTargetEnvironment(environment: values),
      continuationEnvironment:
          buildContinuationTargetEnvironment(environment: values),
    );
  }

  static TrainCReviewedIdentity verifyContinuation({
    Map<String, String>? environment,
    TrainCL1BGitVerification? verifyGit,
  }) {
    final values = environment ?? Platform.environment;
    if (values[trainCL1BLiveRunEnvironment] != '1' ||
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
    final attemptCapability =
        values[trainCLiveAttemptCapabilityEnvironment]?.trim() ?? '';
    if (attemptCapability.isEmpty) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
    final capability =
        TrainCLiveAttemptAuthority.fromCapability(attemptCapability);
    _verifyCapabilityIdentity(capability, reviewed);
    TrainCL1BPhaseController.forContinuation(
      capability: capability,
      reviewedHarnessHead: reviewed.approvedHarnessHead,
      reviewedBase: reviewed.approvedBase,
    );
    (verifyGit ?? _verifyGit).call(reviewed);
    return reviewed;
  }

  /// Continuation processes are supervisor-owned. Keeping this method for
  /// injected mechanical tests avoids a second public launch path that could
  /// lose same-parse source authority.
  static Future<int> launchContinuation({
    Map<String, String>? environment,
    TrainCL1BGitVerification? verifyGit,
    Future<int> Function(TrainCReviewedIdentity reviewedIdentity)? start,
  }) async {
    final values = environment ?? Platform.environment;
    final reviewed = verifyContinuation(
      environment: values,
      verifyGit: verifyGit,
    );
    if (start != null) return start(reviewed);
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
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
      trainCL1BApprovedProductionSeamBlobEnvironment,
      trainCLiveAttemptCapabilityEnvironment,
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

  static Map<String, String> buildContinuationTargetEnvironment({
    Map<String, String>? environment,
  }) {
    final result = buildLiveTargetEnvironment(environment: environment)
      ..remove(trainCL1BPrivateInputPathEnvironment)
      ..remove(trainCL1BCredentialReadyEnvironment)
      ..[trainCL1BContinuationEnvironment] = '1';
    return result;
  }

  static void _verifyCapabilityIdentity(
    TrainCLiveAttemptAuthority capability,
    TrainCReviewedIdentity reviewed,
  ) {
    final durable = capability.snapshot;
    if (durable.approvedHarnessHead != reviewed.approvedHarnessHead ||
        durable.approvedBase != reviewed.approvedBase) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }
  }

  static void _verifyGit(TrainCReviewedIdentity reviewed) {
    TrainCPreExecutionGitGate(
      reviewedIdentity: reviewed,
      productionDiffAuthority: TrainCL1BProductionDiffAuthority(
        approvedHarnessHead: reviewed.approvedHarnessHead,
        approvedBase: reviewed.approvedBase,
        approvedProductionBase: reviewed.approvedProductionBase,
        approvedProductionSeamBlobSha: reviewed.approvedProductionSeamBlobSha,
      ),
    ).verify();
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
      } else if (error is TrainCL1BSupervisorException) {
        stderr.writeln(error.code);
      } else {
        stderr.writeln('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED');
      }
      exitCode = 1;
    });
    return;
  }

  if (args.length == 1 && args.single == '--authorize-run1') {
    try {
      final head =
          Platform.environment[trainCApprovedHarnessHeadEnvironment]?.trim() ??
              '';
      final base =
          Platform.environment[trainCL1BApprovedBaseEnvironment]?.trim() ?? '';
      final directoryPath =
          Platform.environment['TRAIN_C_ATTEMPT_STATE_DIRECTORY']?.trim() ?? '';
      if (head.isEmpty || base.isEmpty || directoryPath.isEmpty) {
        throw const TrainCEvidenceProbeException(
          'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
        );
      }
      final directory = Directory(p.normalize(p.absolute(directoryPath)));
      final capability = TrainCLiveAttemptAuthority.authorize(
        stateDirectory: directory,
        approvedHarnessHead: head,
        approvedBase: base,
      );
      File(p.join(directory.path, 'capability.v1')).writeAsStringSync(
        capability,
        flush: true,
      );
      stdout.writeln('TRAIN_C_RUN1_AUTHORIZED');
    } on TrainCEvidenceProbeException catch (error) {
      stderr.writeln(error.code);
      exitCode = 1;
    } catch (_) {
      stderr.writeln('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED');
      exitCode = 1;
    }
    return;
  }

  if (args.length == 1 && args.single == '--status') {
    try {
      final capabilityValue =
          Platform.environment[trainCLiveAttemptCapabilityEnvironment]?.trim();
      if (capabilityValue == null || capabilityValue.isEmpty) {
        throw const TrainCEvidenceProbeException(
          'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
        );
      }
      final reviewed = TrainCL1BReviewAuthorization.requireFromEnvironment();
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(
          TrainCLiveAttemptAuthority.fromCapability(capabilityValue).safeStatus(
            reviewedHarnessHead: reviewed.approvedHarnessHead,
            reviewedBase: reviewed.approvedBase,
          ),
        ),
      );
    } on TrainCEvidenceProbeException catch (error) {
      stderr.writeln(error.code);
      exitCode = 1;
    } catch (_) {
      stderr.writeln('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED');
      exitCode = 1;
    }
    return;
  }

  if (args.length == 1 && args.single == '--continue') {
    stderr.writeln('TRAIN_C_HARNESS_NOT_READY');
    exitCode = 2;
    return;
  }

  stderr.writeln('TRAIN_C_HARNESS_NOT_READY');
  exitCode = 2;
}
