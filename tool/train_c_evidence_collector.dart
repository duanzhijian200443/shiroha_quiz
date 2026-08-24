import 'dart:io';

import 'train_c_evidence_probe.dart';

/// The only source allowed to promote a schema-valid snapshot to final
/// acceptance is an isolated runtime collector implemented by the live runner.
/// It is intentionally not a JSON/file adapter.
abstract interface class TrainCTrustedEvidenceSource {
  Future<Map<String, dynamic>> readAuthoritativeSnapshot();
}

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
        <String>['status', '--porcelain=v1', '--untracked-files=all'],
        workingDirectory: workingDirectory,
      );
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
  const TrainCTrustedEvidenceCollector(
    this._probe, {
    this.executionStateGate = const GitTrainCExecutionStateGate(),
  });

  final TrainCEvidenceProbe _probe;
  final TrainCExecutionStateGate executionStateGate;

  Future<TrainCEvidenceProbeResult> collect(
    TrainCTrustedEvidenceSource source,
  ) async {
    final snapshot = await source.readAuthoritativeSnapshot();
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
        'firstLoss': <String, dynamic>{
          'status': 'NONE',
          'checkpoint': null,
        },
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
          'checkpoint': 'P0',
        },
      },
    );
  }

  String _safeFailureCode(String code) {
    return switch (code) {
      'TRAIN_C_DIRTY_WORKTREE' => code,
      'TRAIN_C_CODE_IDENTITY_MISMATCH' => code,
      _ => 'TRAIN_C_CODE_IDENTITY_MISMATCH',
    };
  }
}
