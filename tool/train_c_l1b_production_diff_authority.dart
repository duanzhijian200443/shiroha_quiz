import 'dart:io';

import 'train_c_evidence_probe.dart';
import 'train_c_production_authority_token.dart';
import 'train_c_review_authorization.dart';

/// The historical production seam permitted by the TRAIN C L1B harness.
///
/// Historical L1B remains a single-file, exact-blob authority. Final Package-B
/// closure uses a separate `lib_tree:<sha>` token supplied out of band; that
/// mode pins the complete production `lib/` tree instead of widening this
/// historical path allowlist.
const trainCL1BApprovedProductionPath =
    'lib/services/import_pipeline/import_pipeline_service.dart';

/// Compatibility names for focused preflight tests. This remains the frozen
/// historical L1B allowlist; final Package-B authority does not mutate it.
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

/// Shared TRAIN C production identity authority.
///
/// There are deliberately two bounded modes:
///
/// * Historical L1B: one exact production seam blob relative to the frozen
///   TRAIN-B production baseline.
/// * Final Package-B: an out-of-band `lib_tree:<sha>` token pins the complete
///   `lib/` tree at the independently reviewed harness HEAD. Diff counts are
///   then measured from the contemporaneous reviewed base/master identity.
///
/// In both modes the approved value is supplied out of band. A candidate
/// cannot change production code and a repository constant in the same commit
/// to self-authorize that change.
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
    this.libTreeReader = _readLibTreeSha,
  });

  final String approvedHarnessHead;
  final String approvedBase;
  final String approvedProductionBase;
  final String approvedProductionSeamBlobSha;
  final String Function() currentHeadReader;
  final String Function() masterReader;
  final List<String> Function(String productionBase) changedPathsReader;
  final String Function(String head, String path) blobReader;
  final String Function(String head) libTreeReader;

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
    final finalLibTree = trainCFinalLibTreeShaFromAuthorityToken(
      approvedProductionSeamBlobSha,
    );
    if (finalLibTree != null) return _inspectFinalLibTree(finalLibTree);
    return _inspectHistoricalL1BSeam();
  }

  TrainCL1BProductionDiffResult _inspectFinalLibTree(String finalLibTree) {
    if (!_isSha(approvedHarnessHead) ||
        !_isSha(approvedBase) ||
        !_isSha(approvedProductionBase) ||
        !_isSha(finalLibTree)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    final paths = changedPathsReader(approvedBase)
        .map(_normalizePath)
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    final actualTree = libTreeReader(approvedHarnessHead).trim();
    final matched = actualTree == finalLibTree;
    return TrainCL1BProductionDiffResult(
      totalProductionDiffCount: paths.length,
      approvedProductionDiffCount: matched ? paths.length : 0,
      unexpectedProductionDiffCount: matched ? 0 : paths.length,
      approvedSeamMatched: matched,
    );
  }

  TrainCL1BProductionDiffResult _inspectHistoricalL1BSeam() {
    if (!_isSha(approvedHarnessHead) ||
        !_isSha(approvedBase) ||
        !_isSha(approvedProductionBase) ||
        !_isSha(approvedProductionSeamBlobSha)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    final paths = changedPathsReader(approvedProductionBase)
        .map(_normalizePath)
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

  /// Offline helper used by focused repository-state tests and old preflight.
  ///
  /// On the exact historical L1B shape it returns the historical seam blob.
  /// Once the checkout contains any other production shape it returns a
  /// complete-lib-tree authority token. Live execution never derives its own
  /// token here: live review authorization still requires the value from the
  /// explicit out-of-band environment.
  static String readProductionSeamBlobSha(String head) {
    if (!_isSha(head)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    final historicalPaths = _readChangedProductionPathsAtHead(
      trainCApprovedProductionBase,
      head,
    ).map(_normalizePath).where((path) => path.isNotEmpty).toList();
    if (historicalPaths.length == 1 &&
        historicalPaths.single == trainCL1BApprovedProductionPath) {
      return _readBlobSha(head, trainCL1BApprovedProductionPath).trim();
    }
    return trainCFinalLibTreeAuthorityToken(_readLibTreeSha(head));
  }

  static String readFinalLibTreeAuthorityToken(String head) {
    if (!_isSha(head)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return trainCFinalLibTreeAuthorityToken(_readLibTreeSha(head));
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
    return _readChangedProductionPathsAtHead(productionBase, 'HEAD');
  }

  static List<String> _readChangedProductionPathsAtHead(
    String productionBase,
    String head,
  ) {
    final result = Process.runSync(
      'git',
      <String>[
        'diff',
        '--name-only',
        '$productionBase..$head',
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

  static String _readLibTreeSha(String head) {
    return _runGit(<String>['rev-parse', '$head:lib']);
  }

  static String _runGit(List<String> args) {
    final result = Process.runSync('git', args);
    if (result.exitCode != 0 || result.stdout is! String) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return (result.stdout as String).trim();
  }

  static String _normalizePath(String path) =>
      path.trim().replaceAll('\\', '/');

  static bool _isSha(String value) => RegExp(r'^[0-9a-f]{40}$').hasMatch(value);
}
