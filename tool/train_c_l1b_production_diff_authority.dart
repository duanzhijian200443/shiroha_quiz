import 'dart:io';

import 'train_c_evidence_probe.dart';

/// The only production seam permitted by the TRAIN C L1B harness.
///
/// The path allowlist is not sufficient by itself: the reviewed file blob is
/// also supplied out of band and checked against the current reviewed HEAD.
const trainCL1BApprovedProductionPath =
    'lib/services/import_pipeline/import_pipeline_service.dart';

/// Compatibility names for focused preflight tests. The authority itself is
/// implemented by [TrainCL1BProductionDiffAuthority] below.
const trainCL1BAllowedProductionPaths = <String>{
  trainCL1BApprovedProductionPath,
};

List<String> trainCL1BReadProductionDiffPaths(String productionBase) {
  return TrainCL1BProductionDiffAuthority.readProductionDiffPaths(
    productionBase,
  );
}

final class TrainCL1BProductionDiffResult {
  const TrainCL1BProductionDiffResult({
    required this.totalProductionDiffCount,
    required this.approvedProductionDiffCount,
    required this.unexpectedProductionDiffCount,
    required this.approvedSeamMatched,
  });

  final int totalProductionDiffCount;
  final int approvedProductionDiffCount;
  final int unexpectedProductionDiffCount;
  final bool approvedSeamMatched;
}

/// Shared L1B production-diff authority.
///
/// Offline preflight, the default live gate, and trusted runtime evidence all
/// use this same semantic check. The approved file blob is intentionally an
/// out-of-band value; a candidate cannot change the production file and a
/// repository constant in the same commit to self-authorize the change.
final class TrainCL1BProductionDiffAuthority {
  TrainCL1BProductionDiffAuthority({
    required this.approvedHarnessHead,
    required this.approvedBase,
    required this.approvedProductionBase,
    required this.approvedProductionSeamBlobSha,
    this.currentHeadReader = _readCurrentHead,
    this.masterReader = _readOriginMaster,
    this.changedPathsReader = _readChangedProductionPaths,
    this.blobReader = _readBlobSha,
  });

  final String approvedHarnessHead;
  final String approvedBase;
  final String approvedProductionBase;
  final String approvedProductionSeamBlobSha;
  final String Function() currentHeadReader;
  final String Function() masterReader;
  final List<String> Function(String productionBase) changedPathsReader;
  final String Function(String head, String path) blobReader;

  TrainCL1BProductionDiffResult verify() {
    final currentHead = currentHeadReader().trim();
    final currentBase = masterReader().trim();
    if (currentHead != approvedHarnessHead || currentBase != approvedBase) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }
    final result = inspect();
    if (result.unexpectedProductionDiffCount != 0 ||
        !result.approvedSeamMatched) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }
    return result;
  }

  TrainCL1BProductionDiffResult inspect() {
    if (!_isSha(approvedHarnessHead) ||
        !_isSha(approvedBase) ||
        !_isSha(approvedProductionBase) ||
        !_isSha(approvedProductionSeamBlobSha)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    final paths = changedPathsReader(approvedProductionBase)
        .map((path) => path.trim().replaceAll('\\', '/'))
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    final approved = <String>[];
    for (final path in paths) {
      if (path != trainCL1BApprovedProductionPath) continue;
      final blob = blobReader(approvedHarnessHead, path).trim();
      if (blob == approvedProductionSeamBlobSha) approved.add(path);
    }
    final unexpected = paths.length - approved.length;
    return TrainCL1BProductionDiffResult(
      totalProductionDiffCount: paths.length,
      approvedProductionDiffCount: approved.length,
      unexpectedProductionDiffCount: unexpected,
      approvedSeamMatched: paths.length == 1 && approved.length == 1,
    );
  }

  static String readProductionSeamBlobSha(String head) {
    if (!_isSha(head)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return _readBlobSha(head, trainCL1BApprovedProductionPath).trim();
  }

  static List<String> readProductionDiffPaths(String productionBase) {
    return _readChangedProductionPaths(productionBase);
  }

  static String _readCurrentHead() {
    return _runGit(const <String>['rev-parse', 'HEAD']);
  }

  static String _readOriginMaster() {
    return _runGit(const <String>['rev-parse', 'origin/master']);
  }

  static List<String> _readChangedProductionPaths(String productionBase) {
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
        .toList(growable: false);
  }

  static String _readBlobSha(String head, String path) {
    return _runGit(<String>['rev-parse', '$head:$path']);
  }

  static String _runGit(List<String> args) {
    final result = Process.runSync('git', args);
    if (result.exitCode != 0 || result.stdout is! String) {
      throw const TrainCEvidenceProbeException(
          'TRAIN_C_CODE_IDENTITY_MISMATCH');
    }
    return (result.stdout as String).trim();
  }

  static bool _isSha(String value) => RegExp(r'^[0-9a-f]{40}$').hasMatch(value);
}
