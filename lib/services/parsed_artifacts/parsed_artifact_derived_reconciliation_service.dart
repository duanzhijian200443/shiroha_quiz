import 'dart:io';

import 'package:path/path.dart' as p;

import '../../application/backup/backup_restore_gate.dart';
import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../application/parsed_artifacts/parsed_artifact_derived_maintenance.dart';
import '../file_library/managed_artifact_storage.dart';
import '../file_library/windows_reparse_point_probe.dart';

enum ParsedArtifactDerivedReconciliationOutcome {
  complete,
  busy,
  incomplete,
}

final class ParsedArtifactDerivedReconciliationReport {
  const ParsedArtifactDerivedReconciliationReport({
    required this.outcome,
    this.staleSidecars = 0,
    this.deletedSidecars = 0,
    this.staleRetrievalBuilds = 0,
  });

  final ParsedArtifactDerivedReconciliationOutcome outcome;
  final int staleSidecars;
  final int deletedSidecars;
  final int staleRetrievalBuilds;
}

/// Reconciles only derived sidecars and retrieval builds after B0 recovery.
/// Current metadata and verified payloads remain the sole artifact authority.
final class ParsedArtifactDerivedReconciliationService {
  ParsedArtifactDerivedReconciliationService({
    required ParsedArtifactDerivedMaintenancePort derivedRows,
    required Directory managedRoot,
    required ManagedArtifactStorage storage,
    required ParsedArtifactLifecyclePort artifacts,
  })  : _derivedRows = derivedRows,
        _managedRoot = p.normalize(managedRoot.path),
        _storage = storage,
        _artifacts = artifacts;

  static const int pageSize = 200;
  static const int maxEntries = 5000;
  static const int maxDeletes = 32;
  static const Duration maxDuration = Duration(seconds: 2);

  final ParsedArtifactDerivedMaintenancePort _derivedRows;
  final String _managedRoot;
  final ManagedArtifactStorage _storage;
  final ParsedArtifactLifecyclePort _artifacts;

  Future<ParsedArtifactDerivedReconciliationReport> reconcile() async {
    final gate = BackupRestoreMutationGate.instance;
    try {
      gate.acquireExclusive();
    } catch (_) {
      return const ParsedArtifactDerivedReconciliationReport(
          outcome: ParsedArtifactDerivedReconciliationOutcome.busy);
    }
    var quiescent = false;
    try {
      try {
        gate.tryEnterQuiescence();
        quiescent = true;
      } catch (_) {
        return const ParsedArtifactDerivedReconciliationReport(
            outcome: ParsedArtifactDerivedReconciliationOutcome.busy);
      }
      final watch = Stopwatch()..start();
      var staleSidecars = 0;
      var deletedSidecars = 0;
      try {
        final current = await _currentSidecarKeys(watch);
        final physical = await _physicalSidecarKeys(watch);
        final stale = physical.difference(current).toList()..sort();
        staleSidecars = stale.length;
        final freshCurrent = await _currentSidecarKeys(watch);
        final freshPhysical = await _physicalSidecarKeys(watch);
        if (!_same(current, freshCurrent) || !_same(physical, freshPhysical)) {
          throw const _IncompleteDerivedReconciliation();
        }
        for (final key in stale.take(maxDeletes)) {
          _checkBound(watch);
          if (freshCurrent.contains(key) || !await _safePhysicalKey(key)) {
            throw const _IncompleteDerivedReconciliation();
          }
          try {
            await _storage.deleteArtifact(key);
            deletedSidecars++;
          } catch (_) {
            // A failed derived delete is retryable on a later startup.
          }
        }
        _checkBound(watch);
        final staleRetrieval =
            await _derivedRows.deleteStaleRetrievalBuilds(maxRows: maxEntries);
        _checkBound(watch);
        return ParsedArtifactDerivedReconciliationReport(
          outcome: ParsedArtifactDerivedReconciliationOutcome.complete,
          staleSidecars: staleSidecars,
          deletedSidecars: deletedSidecars,
          staleRetrievalBuilds: staleRetrieval,
        );
      } catch (_) {
        return ParsedArtifactDerivedReconciliationReport(
          outcome: ParsedArtifactDerivedReconciliationOutcome.incomplete,
          staleSidecars: staleSidecars,
          deletedSidecars: deletedSidecars,
        );
      }
    } finally {
      if (quiescent) gate.exitQuiescence();
      gate.releaseExclusive();
    }
  }

  Future<Set<String>> _currentSidecarKeys(Stopwatch watch) async {
    final result = <String>{};
    var offset = 0;
    while (true) {
      _checkBound(watch);
      final rows =
          await _derivedRows.currentPage(offset: offset, limit: pageSize);
      if (rows.isEmpty) break;
      offset += rows.length;
      if (offset > maxEntries) throw const _IncompleteDerivedReconciliation();
      for (final row in rows) {
        _checkBound(watch);
        final fileId = row.fileId;
        final snapshot = await _artifacts.getCurrentArtifact(fileId);
        final expected =
            _storage.allocateArtifactStorageKey(snapshot.artifact.artifactId);
        if (row.storageKey != expected) {
          throw const _IncompleteDerivedReconciliation();
        }
        result.add(expected);
      }
    }
    return result;
  }

  Future<Set<String>> _physicalSidecarKeys(Stopwatch watch) async {
    final root = Directory(_managedRoot);
    final artifacts = Directory(p.join(_managedRoot, 'artifacts'));
    if (!await _isPlainDirectory(root)) {
      throw const _IncompleteDerivedReconciliation();
    }
    final kind =
        await FileSystemEntity.type(artifacts.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return <String>{};
    if (!await _isPlainDirectory(artifacts)) {
      throw const _IncompleteDerivedReconciliation();
    }
    final keys = <String>{};
    await for (final entity in artifacts.list(followLinks: false)) {
      _checkBound(watch);
      if (keys.length >= maxEntries ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file ||
          WindowsReparsePointProbe.isReparsePoint(entity.path)) {
        throw const _IncompleteDerivedReconciliation();
      }
      final name = p.basename(entity.path);
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$').hasMatch(name) &&
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json\.tmp\.[0-9]+\.[0-9]+$')
              .hasMatch(name)) {
        throw const _IncompleteDerivedReconciliation();
      }
      final key = 'artifacts/$name';
      if (!await _safePhysicalKey(key)) {
        throw const _IncompleteDerivedReconciliation();
      }
      keys.add(key);
    }
    return keys;
  }

  Future<bool> _safePhysicalKey(String key) async {
    try {
      final root = Directory(_managedRoot);
      final artifacts = Directory(p.join(_managedRoot, 'artifacts'));
      final target = File(p.join(_managedRoot, key));
      if (!await _isPlainDirectory(root) ||
          !await _isPlainDirectory(artifacts) ||
          await FileSystemEntity.type(target.path, followLinks: false) !=
              FileSystemEntityType.file ||
          WindowsReparsePointProbe.isReparsePoint(target.path)) {
        return false;
      }
      final rootResolved = p.normalize(await root.resolveSymbolicLinks());
      final artifactsResolved =
          p.normalize(await artifacts.resolveSymbolicLinks());
      final targetResolved = p.normalize(await target.resolveSymbolicLinks());
      return p.isWithin(rootResolved, artifactsResolved) &&
          p.dirname(targetResolved) == artifactsResolved;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isPlainDirectory(Directory directory) async {
    try {
      return await FileSystemEntity.type(directory.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          !WindowsReparsePointProbe.isReparsePoint(directory.path);
    } catch (_) {
      return false;
    }
  }

  void _checkBound(Stopwatch watch) {
    if (watch.elapsed >= maxDuration) {
      throw const _IncompleteDerivedReconciliation();
    }
  }

  bool _same(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);
}

final class _IncompleteDerivedReconciliation implements Exception {
  const _IncompleteDerivedReconciliation();
}
