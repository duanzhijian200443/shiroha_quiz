import 'dart:convert';
import 'dart:io';

import 'train_c_evidence_collector.dart';
import 'train_c_evidence_probe.dart';
import 'train_c_isolated_runtime.dart';
import 'train_c_review_authorization.dart';
import 'train_c_runtime_evidence_source.dart';
import 'train_c_l1b_production_diff_authority.dart';

const trainCL1BaseMaster = 'f1d58a278180eff38686338c28f26e4d1d7b8b7a';
const trainCL1BBaseMaster = '2f0aee1a7b81cd7a694b4de10702c6e798b9dd04';
const trainCL1TrainBMerge = '711fd33f564b9fb6bb3c992d6458b0075990646c';

typedef TrainCProductionDiffReader = int Function();
typedef TrainCGitFetch = void Function();

/// Explicit pre-execution gate for any future L1B runner.
///
/// This gate is intentionally separate from the collector's final
/// authorization gate. It must run before isolated runtime creation and before
/// any future provider boundary. When [reviewedIdentity] is omitted, authority
/// must come from the out-of-band review environment rather than repository
/// source.
final class TrainCPreExecutionGitGate {
  TrainCPreExecutionGitGate({
    this.executionStateGate = const GitTrainCExecutionStateGate(),
    this.productionDiffReader,
    this.productionDiffAuthority,
    this.masterReader = _readOriginMaster,
    this.currentHeadReader = _readCurrentHead,
    this.fetchMaster = _fetchOriginMaster,
    TrainCReviewedIdentity? reviewedIdentity,
  }) : reviewedIdentity = reviewedIdentity ??
            TrainCReviewAuthorization.requireFromEnvironment();

  final TrainCExecutionStateGate executionStateGate;
  final TrainCProductionDiffReader? productionDiffReader;
  final TrainCL1BProductionDiffAuthority? productionDiffAuthority;
  final String Function() masterReader;
  final String Function() currentHeadReader;
  final TrainCGitFetch fetchMaster;
  final TrainCReviewedIdentity reviewedIdentity;

  void verify() {
    try {
      executionStateGate.verify();
      try {
        fetchMaster();
      } on TrainCEvidenceProbeException {
        rethrow;
      } catch (_) {
        throw const _TrainCRemoteStateException();
      }
      if (currentHeadReader().trim() != reviewedIdentity.approvedHarnessHead) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
      }
      if (masterReader().trim() != reviewedIdentity.approvedBase) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
      }
      if (productionDiffAuthority != null) {
        productionDiffAuthority!.verify();
      } else {
        final productionDiff = productionDiffReader?.call() ??
            _readProductionDiff(reviewedIdentity.approvedProductionBase);
        if (productionDiff != 0) {
          throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
        }
      }
    } on TrainCEvidenceProbeException {
      rethrow;
    } on _TrainCRemoteStateException {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_REMOTE_STATE_UNAVAILABLE',
      );
    } catch (_) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
  }

  static int _readProductionDiff(String productionBase) {
    final result = Process.runSync(
      'git',
      <String>[
        'diff',
        '--name-only',
        '$productionBase..HEAD',
        '--',
        'lib',
      ],
    );
    if (result.exitCode != 0 || result.stdout is! String) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }
    return (result.stdout as String)
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .length;
  }

  static String _readCurrentHead() {
    final result = Process.runSync('git', <String>['rev-parse', 'HEAD']);
    if (result.exitCode != 0 || result.stdout is! String) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return (result.stdout as String).trim();
  }

  static void _fetchOriginMaster() {
    final result = Process.runSync('git', <String>[
      'fetch',
      'origin',
      'master',
    ]);
    if (result.exitCode != 0) {
      throw const _TrainCRemoteStateException();
    }
  }

  static String _readOriginMaster() {
    final result = Process.runSync('git', <String>[
      'rev-parse',
      'origin/master',
    ]);
    if (result.exitCode != 0 || result.stdout is! String) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return (result.stdout as String).trim();
  }
}

Future<Map<String, Object?>> runTrainCL1AOfflinePreflight() async {
  final gate = TrainCPreExecutionGitGate(
    reviewedIdentity: TrainCReviewedIdentity.forOfflineCurrentRepository(),
    // Offline mode may use the frozen remote state, but never grants live
    // authority. A future live runner must use the default fetch callback.
    fetchMaster: () {},
    masterReader: () => trainCL1BaseMaster,
  );
  gate.verify();

  final runtime = await TrainCIsolatedRuntime.create();
  try {
    await runtime.open();
    final blank = await runtime.verifyBlankStore();
    return <String, Object?>{
      'stage': 'TRAIN-C-L1A',
      'status': blank.passed ? 'PASS' : 'FAIL',
      'liveRun': 'BLOCKED',
      'gitClean': true,
      'isolatedStore': true,
      'blank': blank.passed,
      'questionRows': blank.questionRows,
      'v2Sidecars': blank.v2Sidecars,
      'contentAssets': blank.contentAssets,
      'providerDispatchCount': 0,
      'providerResponseCount': 0,
      'remoteCropRequestCount': 0,
    };
  } finally {
    await runtime.dispose();
  }
}

/// Offline preflight for the L1B branch. L1B is allowed one exact,
/// default-disabled production observation seam; every other production
/// change remains a hard identity failure.
Future<Map<String, Object?>> runTrainCL1BOfflinePreflight() async {
  final baseIdentity = TrainCReviewedIdentity.forOfflineCurrentRepository();
  final reviewed = TrainCReviewedIdentity(
    approvedHarnessHead: baseIdentity.approvedHarnessHead,
    approvedBase: trainCL1BBaseMaster,
    approvedProductionBase: baseIdentity.approvedProductionBase,
    approvedProductionSeamBlobSha:
        TrainCL1BProductionDiffAuthority.readProductionSeamBlobSha(
      baseIdentity.approvedHarnessHead,
    ),
  );
  final gate = TrainCPreExecutionGitGate(
    reviewedIdentity: reviewed,
    fetchMaster: () {},
    masterReader: () => trainCL1BBaseMaster,
    productionDiffAuthority: TrainCL1BProductionDiffAuthority(
      approvedHarnessHead: reviewed.approvedHarnessHead,
      approvedBase: reviewed.approvedBase,
      approvedProductionBase: reviewed.approvedProductionBase,
      approvedProductionSeamBlobSha: reviewed.approvedProductionSeamBlobSha,
      masterReader: () => trainCL1BBaseMaster,
    ),
  );
  gate.verify();

  final runtime = await TrainCIsolatedRuntime.create();
  try {
    await runtime.open();
    final blank = await runtime.verifyBlankStore();
    return <String, Object?>{
      'stage': 'TRAIN-C-L1B',
      'status': blank.passed ? 'PASS' : 'FAIL',
      'liveRun': 'BLOCKED',
      'gitClean': true,
      'isolatedStore': true,
      'blank': blank.passed,
      'questionRows': blank.questionRows,
      'v2Sidecars': blank.v2Sidecars,
      'contentAssets': blank.contentAssets,
      'providerDispatchCount': 0,
      'providerResponseCount': 0,
      'remoteCropRequestCount': 0,
    };
  } finally {
    await runtime.dispose();
  }
}

final class _TrainCRemoteStateException implements Exception {
  const _TrainCRemoteStateException();
}

Future<void> main(List<String> args) async {
  if (args.length != 1 ||
      (args.single != '--offline' && args.single != '--preflight')) {
    stderr.writeln('TRAIN_C_HARNESS_NOT_READY');
    exitCode = 2;
    return;
  }
  try {
    final result = args.single == '--preflight'
        ? await runTrainCL1BOfflinePreflight()
        : await runTrainCL1AOfflinePreflight();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  } on TrainCEvidenceProbeException catch (error) {
    stderr.writeln(error.code);
    exitCode = 1;
  } on TrainCIsolationException catch (error) {
    stderr.writeln(error.toString());
    exitCode = 1;
  } catch (_) {
    stderr.writeln('TRAIN_C_ISOLATION_FAILURE');
    exitCode = 1;
  }
}
