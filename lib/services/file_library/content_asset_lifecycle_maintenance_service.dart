import 'dart:convert';

import 'package:meta/meta.dart';

import '../../application/backup/backup_restore_gate.dart';
import '../../application/import_review/typed_review_snapshot.dart';
import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../data/models/typed_import_commit_guard.dart';
import '../../data/repositories/content_asset_reclamation_observation_repository.dart';
import '../../application/content/content_asset_authority.dart';
import '../../application/content/content_asset_maintenance.dart';
import 'managed_content_asset_store.dart';

final class ContentAssetLifecycleMaintenanceService
    implements ContentAssetMaintenancePort {
  ContentAssetLifecycleMaintenanceService({
    required ContentAssetRootPagePort rootPages,
    required ManagedContentAssetStore contentAssets,
    required ParsedArtifactLifecyclePort parsedArtifacts,
    required ContentAssetReclamationObservationRepository observations,
    int Function()? nowUtcSeconds,
    @visibleForTesting Future<void> Function()? beforeExactDeleteForTesting,
  })  : _rootPages = rootPages,
        _contentAssets = contentAssets,
        _parsedArtifacts = parsedArtifacts,
        _observations = observations,
        _nowUtcSeconds = nowUtcSeconds ?? _systemUtcSeconds,
        _beforeExactDelete = beforeExactDeleteForTesting;

  static const int graceSeconds = 72 * 60 * 60;
  static const int rootPageSize = 200;
  static const int questionMarkCeiling = 10000;
  static const int maxDeletesPerPass = 32;
  static const Duration markWallLimit = Duration(seconds: 2);
  static const Duration sweepWallLimit = Duration(seconds: 2);

  final ContentAssetRootPagePort _rootPages;
  final ManagedContentAssetStore _contentAssets;
  final ParsedArtifactLifecyclePort _parsedArtifacts;
  final ContentAssetReclamationObservationRepository _observations;
  final int Function() _nowUtcSeconds;
  final Future<void> Function()? _beforeExactDelete;

  static int _systemUtcSeconds() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  @override
  Future<ContentAssetMaintenanceReport> reportOnly() => _run(false);

  @override
  Future<ContentAssetMaintenanceReport> sweepEligible() => _run(true);

  Future<ContentAssetMaintenanceReport> _run(bool destructive) async {
    final sweepWatch = Stopwatch()..start();
    final gate = BackupRestoreMutationGate.instance;
    try {
      gate.acquireExclusive();
    } catch (_) {
      return const ContentAssetMaintenanceReport(
        outcome: ContentAssetMaintenanceOutcome.busy,
      );
    }
    var quiescent = false;
    try {
      try {
        gate.tryEnterQuiescence();
        quiescent = true;
      } catch (_) {
        return const ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.busy,
        );
      }
      final Set<ContentAssetIdentity> roots;
      try {
        roots = await _scanRoots();
      } on _RootScanBoundException {
        return const ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.incompleteRoots,
          boundHit: true,
        );
      } catch (_) {
        return const ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.incompleteRoots,
        );
      }
      final List<ContentAssetRecord> inventory;
      try {
        inventory = await _contentAssets.inspectCompleteInventory();
      } on ContentAssetPhysicalInventoryException catch (error) {
        return ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.incompleteInventory,
          unknownCount: error.unknownCount,
          boundHit: error.boundHit,
        );
      } catch (_) {
        return const ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.incompleteInventory,
        );
      }
      final physical = <ContentAssetIdentity>{
        for (final asset in inventory) (asset.sourceId, asset.localAssetId),
      };
      if (!physical.containsAll(roots)) {
        return const ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.incompleteInventory,
        );
      }
      final now = _nowUtcSeconds();
      if (now < 0) {
        return const ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.ledgerUnavailable,
        );
      }
      final Map<ContentAssetIdentity, ContentAssetReclamationObservation>
          observed;
      try {
        observed = await _observations.recordCompleteObservation(
          physical: physical,
          live: roots,
          nowUtcSeconds: now,
        );
      } catch (_) {
        return const ContentAssetMaintenanceReport(
          outcome: ContentAssetMaintenanceOutcome.ledgerUnavailable,
        );
      }
      final eligible = <ContentAssetIdentity>{
        for (final entry in observed.entries)
          if (!entry.value.newlyObserved &&
              now - entry.value.firstUnreachableAt >= graceSeconds)
            entry.key,
      };
      final base = ContentAssetMaintenanceReport(
        outcome: ContentAssetMaintenanceOutcome.complete,
        physicalCount: physical.length,
        liveCount: roots.length,
        unobservedCount:
            observed.values.where((entry) => entry.newlyObserved).length,
        gracePendingCount: observed.values
            .where((entry) =>
                !entry.newlyObserved &&
                now - entry.firstUnreachableAt < graceSeconds)
            .length,
        graceEligibleCount: eligible.length,
      );
      if (!destructive || eligible.isEmpty) return base;
      if (sweepWatch.elapsed >= sweepWallLimit) {
        return _withOutcome(
            base, ContentAssetMaintenanceOutcome.revalidationFailed);
      }

      // Re-read every authority and physical identity after ledger admission.
      final Set<ContentAssetIdentity> freshRoots;
      final List<ContentAssetRecord> freshInventory;
      try {
        freshRoots = await _scanRoots();
        freshInventory = await _contentAssets.inspectCompleteInventory();
      } catch (_) {
        return _withOutcome(
            base, ContentAssetMaintenanceOutcome.revalidationFailed);
      }
      final freshByIdentity = <ContentAssetIdentity, ContentAssetRecord>{
        for (final asset in freshInventory)
          (asset.sourceId, asset.localAssetId): asset,
      };
      if (!_sameRecords(inventory, freshInventory) ||
          !_sameIdentities(roots, freshRoots) ||
          eligible.any(freshRoots.contains)) {
        return _withOutcome(
            base, ContentAssetMaintenanceOutcome.revalidationFailed);
      }
      final selected = eligible.take(maxDeletesPerPass).toList(growable: false);
      for (final key in selected) {
        final record = freshByIdentity[key];
        if (sweepWatch.elapsed >= sweepWallLimit ||
            record == null ||
            !await _contentAssets.isExactTargetUnchanged(record)) {
          return _withOutcome(
              base, ContentAssetMaintenanceOutcome.revalidationFailed);
        }
      }
      await _beforeExactDelete?.call();
      var deleted = 0;
      for (final key in selected) {
        if (sweepWatch.elapsed >= sweepWallLimit) {
          return _withOutcome(
              base, ContentAssetMaintenanceOutcome.revalidationFailed,
              deletedCount: deleted);
        }
        if (!await _contentAssets.deleteExactIfUnchanged(
          freshByIdentity[key]!,
        )) {
          return _withOutcome(
            base,
            ContentAssetMaintenanceOutcome.deleteFailed,
            deletedCount: deleted,
          );
        }
        deleted++;
      }
      // The next complete scan observes any remaining physical orphans.
      // Delete only the exact rows whose bytes were removed successfully.
      try {
        await _observations.reset(selected);
      } catch (_) {
        // Rows are derived evidence for absent bytes. A future complete scan
        // will remove them; deletion already had full proof.
      }
      return _withOutcome(base, ContentAssetMaintenanceOutcome.complete,
          deletedCount: deleted);
    } finally {
      if (quiescent) gate.exitQuiescence();
      gate.releaseExclusive();
    }
  }

  ContentAssetMaintenanceReport _withOutcome(
    ContentAssetMaintenanceReport base,
    ContentAssetMaintenanceOutcome outcome, {
    int deletedCount = 0,
  }) =>
      ContentAssetMaintenanceReport(
        outcome: outcome,
        physicalCount: base.physicalCount,
        liveCount: base.liveCount,
        unobservedCount: base.unobservedCount,
        gracePendingCount: base.gracePendingCount,
        graceEligibleCount: base.graceEligibleCount,
        deletedCount: deletedCount,
        unknownCount: base.unknownCount,
        boundHit: base.boundHit,
      );

  bool _sameIdentities(
    Set<ContentAssetIdentity> left,
    Set<ContentAssetIdentity> right,
  ) =>
      left.length == right.length && left.containsAll(right);

  bool _sameRecords(
    List<ContentAssetRecord> left,
    List<ContentAssetRecord> right,
  ) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      final a = left[i];
      final b = right[i];
      if (a.sourceId != b.sourceId ||
          a.localAssetId != b.localAssetId ||
          a.storageKey != b.storageKey ||
          a.sizeBytes != b.sizeBytes ||
          a.sha256 != b.sha256) {
        return false;
      }
    }
    return true;
  }

  Future<Set<ContentAssetIdentity>> _scanRoots() async {
    final roots = <ContentAssetIdentity>{};
    final markWatch = Stopwatch()..start();
    void checkMark() {
      if (markWatch.elapsed >= markWallLimit) {
        throw const _RootScanBoundException();
      }
    }

    var questionCount = 0;
    while (true) {
      checkMark();
      final rows = await _rootPages.questionPage(
          offset: questionCount, limit: rootPageSize);
      if (rows.isEmpty) break;
      questionCount += rows.length;
      if (questionCount > questionMarkCeiling) {
        throw const _RootScanBoundException();
      }
      for (final draft in rows) {
        checkMark();
        if (draft == null) continue;
        final declared = <ContentAssetIdentity>{
          for (final asset in draft.assetRefs)
            (asset.sourceId, asset.localAssetId),
        };
        final reachable = _draftImages(draft);
        if (!declared.containsAll(reachable)) throw const FormatException();
        roots.addAll(reachable);
      }
    }

    var artifactCount = 0;
    while (true) {
      checkMark();
      final rows = await _rootPages.currentArtifactFileIdsPage(
          offset: artifactCount, limit: rootPageSize);
      if (rows.isEmpty) break;
      artifactCount += rows.length;
      if (artifactCount > questionMarkCeiling) {
        throw const _RootScanBoundException();
      }
      for (final fileId in rows) {
        checkMark();
        final snapshot = await _parsedArtifacts.getCurrentArtifact(fileId);
        for (final asset in snapshot.sourceDocument.assetRefs) {
          roots.add((asset.sourceId, asset.localAssetId));
        }
      }
    }

    var taskCount = 0;
    while (true) {
      checkMark();
      final taskRows = await _rootPages.importTaskPage(
          offset: taskCount, limit: rootPageSize);
      if (taskRows.isEmpty) break;
      taskCount += taskRows.length;
      if (taskCount > questionMarkCeiling) {
        throw const _RootScanBoundException();
      }
      for (final row in taskRows) {
        checkMark();
        final status = row.status;
        final rawDiagnostics = row.diagnostics;
        if (status != 1 && rawDiagnostics == null) continue;
        final diagnostics = rawDiagnostics == null
            ? <String, dynamic>{}
            : jsonDecode(rawDiagnostics);
        if (diagnostics is! Map<String, dynamic>) throw const FormatException();
        final owner = _candidateOwner(diagnostics);
        if (owner != null) roots.addAll(owner);
        final cleanupOwner = _candidateOwner(diagnostics, cleanup: true);
        if (cleanupOwner != null) roots.addAll(cleanupOwner);
        if (status != 1) continue;
        final route = decodeImportStorageRoute(
          diagnostics[TypedImportCommitPersistence.keyImportStorageRoute],
        );
        final parsed = jsonDecode(row.parsedData as String);
        if (parsed is! List) throw const FormatException();
        for (final item in parsed) {
          if (item is! Map<String, dynamic>) throw const FormatException();
          const codec = TypedReviewSnapshotCodec();
          codec.requireTypedEnvelope(route, item);
          if (route == ImportStorageRoute.legacyV1) {
            if (codec.containsEnvelope(item)) throw const FormatException();
            continue;
          }
          final snapshot =
              codec.decodeRequired(item[TypedReviewSnapshotCodec.mapKey]);
          final images = _draftImages(snapshot.draft);
          roots.addAll(images);
        }
      }
    }
    checkMark();
    return roots;
  }

  Set<ContentAssetIdentity> _draftImages(QuestionDraftV2 draft) {
    final images = <ContentAssetIdentity>{};
    void collect(RichContent content) {
      for (final image in reachableImageNodes(content)) {
        images.add((image.sourceId, image.localAssetId));
      }
    }

    collect(draft.stem);
    for (final option in draft.options) {
      collect(option.content);
    }
    if (draft.answer case ContentAnswer(:final content)) collect(content);
    if (draft.explanation != null) collect(draft.explanation!);
    return images;
  }

  Set<ContentAssetIdentity>? _candidateOwner(
    Map<String, dynamic> diagnostics, {
    bool cleanup = false,
  }) {
    final sourceKey = cleanup
        ? '_candidate_asset_cleanup_source_id'
        : '_candidate_asset_source_id';
    final idsKey = cleanup
        ? '_candidate_asset_cleanup_local_ids'
        : '_candidate_asset_local_ids';
    final source = diagnostics[sourceKey];
    final rawIds = diagnostics[idsKey];
    if (source == null && rawIds == null) return null;
    final pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
    if (source is! String ||
        !pattern.hasMatch(source) ||
        rawIds is! List ||
        rawIds.any((id) => id is! String || !pattern.hasMatch(id))) {
      throw const FormatException();
    }
    return <ContentAssetIdentity>{
      for (final id in rawIds) (source, id as String),
    };
  }
}

final class _RootScanBoundException implements Exception {
  const _RootScanBoundException();
}
