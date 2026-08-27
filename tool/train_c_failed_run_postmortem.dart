import 'dart:convert';
import 'dart:io';

import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/services/import_pipeline/candidate_asset_lease.dart';

import 'train_c_evidence_probe.dart';
import 'train_c_isolated_runtime.dart';
import 'train_c_live_attempt_authority.dart';

const trainCPostmortemNotAvailable = 'TRAIN_C_POSTMORTEM_NOT_AVAILABLE';
const trainCPostmortemTaskAmbiguous = 'TRAIN_C_POSTMORTEM_TASK_AMBIGUOUS';
const trainCPostmortemDataInvalid = 'TRAIN_C_POSTMORTEM_DATA_INVALID';
const trainCPostmortemStateChanged = 'TRAIN_C_POSTMORTEM_STATE_CHANGED';
const trainCPostmortemRuntimeUnavailable =
    'TRAIN_C_POSTMORTEM_RUNTIME_UNAVAILABLE';

typedef TrainCFailedRunTaskReader = Future<List<Map<String, dynamic>>> Function(
  String runtimeCapability,
);

/// Read-only recovery of safe facts from one already-consumed TRAIN C run.
///
/// The postmortem accepts only a durable FAILED_CONSUMED Run #1 capability,
/// validates the already-owned isolated runtime, reads only `import_tasks`
/// through the explicit read-only SQLite profile, and verifies that the
/// control-plane snapshot did not change. It never reads a private PDF, a
/// credential store, provider bodies, or raw question text.
final class TrainCFailedRunPostmortem {
  const TrainCFailedRunPostmortem._();

  static Future<Map<String, Object?>> inspect({
    required String capabilityValue,
    TrainCFailedRunTaskReader? taskReader,
  }) async {
    final capability = TrainCLiveAttemptAuthority.fromCapability(
      capabilityValue,
    );
    final before = capability.snapshot;
    _requireFailedConsumed(before);

    final runtimeCapability = capability.runtimeCapabilityForReattach;
    if (!capability.runtimeMatches(runtimeCapability)) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }

    final rows = await (taskReader ?? _readTaskRows)(runtimeCapability);
    final report = _buildSafeReport(before, rows);

    final after = capability.snapshot;
    if (!_sameSnapshot(before, after)) {
      throw const TrainCEvidenceProbeException(trainCPostmortemStateChanged);
    }

    return <String, Object?>{
      ...report,
      'stateUnchanged': true,
    };
  }

  static void _requireFailedConsumed(TrainCLiveRunCapabilitySnapshot state) {
    if (state.runNumber != 1 ||
        state.attemptState != TrainCLiveRunAttemptState.consumed ||
        state.phase != TrainCLiveRunPhase.failedConsumed ||
        !state.runtimeBound) {
      throw const TrainCEvidenceProbeException(trainCPostmortemNotAvailable);
    }
  }

  static Future<List<Map<String, dynamic>>> _readTaskRows(
    String runtimeCapability,
  ) async {
    try {
      return await TrainCIsolatedRuntime.inspectReadOnlyFromCapability(
        runtimeCapability,
        (db) async {
          final rows = await db.query(
            'import_tasks',
            columns: const <String>['status', 'parsed_data', 'diagnostics'],
          );
          return rows
              .map((row) => Map<String, dynamic>.from(row))
              .toList(growable: false);
        },
      );
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCEvidenceProbeException(
        trainCPostmortemRuntimeUnavailable,
      );
    }
  }

  static Map<String, Object?> _buildSafeReport(
    TrainCLiveRunCapabilitySnapshot state,
    List<Map<String, dynamic>> rows,
  ) {
    final pending = rows
        .where(
          (row) =>
              row['status'] ==
              TypedImportCommitPersistence.pendingReviewStatusCode,
        )
        .toList(growable: false);
    if (pending.length != 1) {
      throw const TrainCEvidenceProbeException(trainCPostmortemTaskAmbiguous);
    }

    final row = pending.single;
    final parsed = _decodeList(row['parsed_data']);
    final diagnostics = _decodeMap(row['diagnostics']);

    final routeRaw =
        diagnostics?[TypedImportCommitPersistence.keyImportStorageRoute];
    final routePresent = routeRaw != null;
    String? route;
    if (routePresent) {
      try {
        route = importStorageRouteSerialization(
          decodeImportStorageRoute(routeRaw),
        );
      } catch (_) {
        throw const TrainCEvidenceProbeException(trainCPostmortemDataInvalid);
      }
    }

    final reasonRaw =
        diagnostics?[TypedImportCommitPersistence.keyImportStorageReason];
    final reasonPresent = reasonRaw != null;
    String? reason;
    if (reasonPresent) {
      try {
        reason = normalizeImportStorageReason(reasonRaw);
      } catch (_) {
        throw const TrainCEvidenceProbeException(trainCPostmortemDataInvalid);
      }
    }

    final sourceRaw = diagnostics?[candidateAssetSourceIdKey];
    final idsRaw = diagnostics?[candidateAssetLocalIdsKey];
    final leaseFieldsPresent = sourceRaw != null || idsRaw != null;
    final sourceIdPresent = sourceRaw is String && sourceRaw.trim().isNotEmpty;
    final localIds = idsRaw is List
        ? idsRaw.whereType<String>().where((value) => value.trim().isNotEmpty)
        : const Iterable<String>.empty();
    final localIdCount = localIds.length;
    final lease = decodeCandidateAssetLeaseFromDiagnostics(diagnostics);

    return <String, Object?>{
      'stage': 'TRAIN-C-P8-D1',
      'status': 'PASS',
      'runNumber': state.runNumber,
      'attemptState': state.attemptState.wireName,
      'phase': state.phase.wireName,
      'revision': state.revision,
      'runtimeIdentityPreserved': state.runtimeBound,
      'importTaskCount': rows.length,
      'pendingReviewTaskCount': pending.length,
      'parsedDataPresent': parsed != null,
      'parsedQuestionCount': parsed?.length ?? 0,
      'storageRoutePresent': routePresent,
      'storageRoute': route,
      'storageReasonPresent': reasonPresent,
      'storageReason': reason,
      'candidateLeaseFieldsPresent': leaseFieldsPresent,
      'candidateLeasePresent': lease != null,
      'candidateLeaseMalformed': leaseFieldsPresent && lease == null,
      'candidateLeaseSourceIdPresent': sourceIdPresent,
      'candidateLeaseLocalIdCount': localIdCount,
    };
  }

  static List<dynamic>? _decodeList(Object? raw) {
    if (raw == null) return null;
    try {
      final value = raw is String ? jsonDecode(raw) : raw;
      if (value is List) return value;
    } catch (_) {
      // Converted to the fixed safe error below.
    }
    throw const TrainCEvidenceProbeException(trainCPostmortemDataInvalid);
  }

  static Map<String, dynamic>? _decodeMap(Object? raw) {
    if (raw == null) return null;
    try {
      final value = raw is String ? jsonDecode(raw) : raw;
      if (value is Map) return Map<String, dynamic>.from(value);
    } catch (_) {
      // Converted to the fixed safe error below.
    }
    throw const TrainCEvidenceProbeException(trainCPostmortemDataInvalid);
  }

  static bool _sameSnapshot(
    TrainCLiveRunCapabilitySnapshot before,
    TrainCLiveRunCapabilitySnapshot after,
  ) {
    return before.runNumber == after.runNumber &&
        before.approvedHarnessHead == after.approvedHarnessHead &&
        before.approvedBase == after.approvedBase &&
        before.runtimeIdentity == after.runtimeIdentity &&
        before.attemptState == after.attemptState &&
        before.phase == after.phase &&
        before.revision == after.revision;
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 1 || args.single != '--postmortem') {
    stderr.writeln(trainCPostmortemNotAvailable);
    exitCode = 2;
    return;
  }

  final capabilityValue =
      Platform.environment[trainCLiveAttemptCapabilityEnvironment]?.trim() ??
          '';
  if (capabilityValue.isEmpty) {
    stderr.writeln(trainCPostmortemNotAvailable);
    exitCode = 1;
    return;
  }

  try {
    final report = await TrainCFailedRunPostmortem.inspect(
      capabilityValue: capabilityValue,
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } on TrainCEvidenceProbeException catch (error) {
    stderr.writeln(error.code);
    exitCode = 1;
  } on TrainCIsolationException {
    stderr.writeln(trainCPostmortemRuntimeUnavailable);
    exitCode = 1;
  } catch (_) {
    stderr.writeln(trainCPostmortemDataInvalid);
    exitCode = 1;
  }
}
