import 'dart:io';

import 'train_c_evidence_probe.dart';
import 'train_c_http_observer.dart';
import 'train_c_runtime_evidence_source.dart';

abstract interface class TrainCExecutionStateGate {
  void verify();
}

final class GitTrainCExecutionStateGate implements TrainCExecutionStateGate {
  const GitTrainCExecutionStateGate({this.workingDirectory});

  final String? workingDirectory;

  @override
  void verify() {
    try {
      final result = Process.runSync(
          'git',
          <String>[
            'status',
            '--porcelain=v1',
            '--untracked-files=all',
          ],
          workingDirectory: workingDirectory);
      if (result.exitCode != 0 || result.stdout is! String) {
        throw const TrainCEvidenceProbeException(
          'TRAIN_C_CODE_IDENTITY_MISMATCH',
        );
      }
      if ((result.stdout as String).trim().isNotEmpty) {
        throw const TrainCEvidenceProbeException('TRAIN_C_DIRTY_WORKTREE');
      }
    } on TrainCEvidenceProbeException {
      rethrow;
    } catch (_) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
  }
}

final class TrainCTrustedEvidenceCollector {
  TrainCTrustedEvidenceCollector({
    required this.reviewedIdentity,
    this.expectedRunNumber = 1,
    this.executionStateGate = const GitTrainCExecutionStateGate(),
  }) : _probe = TrainCEvidenceProbe(
          expectedIdentity: reviewedIdentity.toExpectedCodeIdentity(),
          expectedRunNumber: expectedRunNumber,
        );

  final TrainCEvidenceProbe _probe;
  final TrainCReviewedIdentity reviewedIdentity;
  final int expectedRunNumber;
  final TrainCExecutionStateGate executionStateGate;

  /// Synthetic maps remain schema-test inputs only and can never authorize a
  /// final TRAIN C result.
  TrainCEvidenceProbeResult inspectSchema(Map<String, dynamic> rawSnapshot) {
    return _probe.inspect(_bindProductionRequestAuthority(rawSnapshot));
  }

  Future<TrainCEvidenceProbeResult> collect(
    TrainCTrustedEvidenceSource source,
  ) async {
    if (!_sameReviewedIdentity(source.reviewedIdentity, reviewedIdentity)) {
      return _identityBlockedResult();
    }
    final rawSnapshot = await source.readAuthoritativeSnapshot();
    final snapshot = _bindProductionRequestAuthority(rawSnapshot);
    final schemaResult = _probe.inspect(snapshot);
    if (!schemaResult.schemaValid) return schemaResult;

    try {
      executionStateGate.verify();
    } on TrainCEvidenceProbeException catch (error) {
      return _blockedResult(schemaResult, _safeFailureCode(error.code));
    } catch (_) {
      return _blockedResult(schemaResult, 'TRAIN_C_CODE_IDENTITY_MISMATCH');
    }

    return TrainCEvidenceProbeResult(
      schemaValid: true,
      acceptanceAuthorized: true,
      evidence: <String, dynamic>{
        ...schemaResult.evidence,
        'authority': 'trusted_collector',
        'result': 'PASS',
        'failureCode': null,
        'firstLoss': <String, dynamic>{'status': 'NONE', 'checkpoint': null},
      },
    );
  }

  Map<String, dynamic> _bindProductionRequestAuthority(
    Map<String, dynamic> snapshot,
  ) {
    // Live run identity is control-plane authority. A source snapshot cannot
    // self-report or override which reviewed attempt is being finalized.
    final attempt = snapshot['attempt'];
    if (attempt is! Map) {
      return <String, dynamic>{
        ...snapshot,
        'runNumber': expectedRunNumber,
      };
    }
    return <String, dynamic>{
      ...snapshot,
      'runNumber': expectedRunNumber,
      'attempt': <String, dynamic>{
        ...Map<String, dynamic>.from(attempt),
        'layoutChunkSize': trainCProductionPdfPageChunkSize,
      },
    };
  }

  bool _sameReviewedIdentity(
    TrainCReviewedIdentity left,
    TrainCReviewedIdentity right,
  ) {
    return left.approvedHarnessHead == right.approvedHarnessHead &&
        left.approvedBase == right.approvedBase &&
        left.approvedProductionBase == right.approvedProductionBase;
  }

  TrainCEvidenceProbeResult _identityBlockedResult() {
    return const TrainCEvidenceProbeResult(
      schemaValid: false,
      acceptanceAuthorized: false,
      evidence: <String, dynamic>{
        'schemaVersion': 3,
        'authority': 'trusted_collector_blocked',
        'result': 'AUTHORIZATION_BLOCKED',
        'failureCode': 'TRAIN_C_CODE_IDENTITY_MISMATCH',
        'firstLoss': <String, dynamic>{'status': 'PROVEN', 'checkpoint': 'P0'},
      },
    );
  }

  TrainCEvidenceProbeResult _blockedResult(
    TrainCEvidenceProbeResult schemaResult,
    String failureCode,
  ) {
    return TrainCEvidenceProbeResult(
      schemaValid: true,
      acceptanceAuthorized: false,
      evidence: <String, dynamic>{
        ...schemaResult.evidence,
        'authority': 'trusted_collector_blocked',
        'result': 'AUTHORIZATION_BLOCKED',
        'failureCode': failureCode,
        'firstLoss': <String, dynamic>{
          'status': 'PROVEN',
          'checkpoint': failureCode == 'TRAIN_C_RESTART_FAILURE' ? 'P12' : 'P0',
        },
      },
    );
  }

  String _safeFailureCode(String code) {
    return switch (code) {
      'TRAIN_C_DIRTY_WORKTREE' => code,
      'TRAIN_C_CODE_IDENTITY_MISMATCH' => code,
      'TRAIN_C_RESTART_FAILURE' => code,
      _ => 'TRAIN_C_CODE_IDENTITY_MISMATCH',
    };
  }
}
