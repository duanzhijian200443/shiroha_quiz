import 'dart:async';

import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';

/// Process-wide B0 mutation gate.
///
/// It is deliberately a single bounded singleton rather than a
/// repository-wide state machine. Any durable mutation authority that must
/// not run while a restore commit is in its SWAPPING window calls
/// [ensureMutationAllowed] at the entry point; B0 itself uses
/// [acquireExclusive] to prevent a second backup/restore.
abstract final class BackupRestoreMutationGate {
  static final BackupRestoreMutationGateState instance =
      BackupRestoreMutationGateState();

  static void resetForTesting() {
    instance.resetForTesting();
  }
}

final class BackupRestoreMutationGateState {
  final Object _mutationContextKey = Object();
  bool _exclusive = false;
  bool _maintenanceRequested = false;
  int _activeMutations = 0;
  Completer<void>? _drainWaiter;

  bool get isExclusive => _exclusive;
  bool get isMaintenance => _maintenanceRequested;
  int get activeMutationCount => _activeMutations;

  void acquireExclusive() {
    if (_exclusive) {
      throw const BackupException(BackupFailure.restoreBusy);
    }
    _exclusive = true;
  }

  void releaseExclusive() {
    _exclusive = false;
  }

  /// Requests maintenance and drains active mutation leases. New mutations
  /// are rejected immediately; already-running lease holders finish (or are
  /// cancelled by their owner), and only then does this future complete.
  Future<void> enterQuiescence() async {
    if (_maintenanceRequested) {
      throw const BackupException(BackupFailure.restoreBusy);
    }
    _maintenanceRequested = true;
    while (_activeMutations > 0) {
      final waiter = Completer<void>();
      _drainWaiter = waiter;
      await waiter.future;
    }
    _drainWaiter = null;
  }

  void exitQuiescence() {
    _maintenanceRequested = false;
  }

  void ensureMutationAllowed() {
    if (_maintenanceRequested) {
      throw const BackupException(BackupFailure.restoreBlocked);
    }
  }

  BackupRestoreMutationLease acquireMutationLease() {
    ensureMutationAllowed();
    _activeMutations++;
    return BackupRestoreMutationLease._(this);
  }

  /// One root mutation owns one external lease for its whole async tree.
  ///
  /// Awaited nested calls inherit the root context and add no lease, so
  /// quiescence still drains exactly one root mutation. A nested mutation that
  /// is still running when the root action returns keeps that lease alive until
  /// it finishes, so no already-started work can cross the restore drain
  /// boundary. Work started after the root action returned acquires its own
  /// lease and stays blocked during maintenance.
  Future<T> runMutation<T>(Future<T> Function() action) async {
    final inherited = Zone.current[_mutationContextKey];
    if (inherited is _RootMutationContext && inherited.admitNested()) {
      try {
        return await action();
      } finally {
        inherited.nestedFinished();
      }
    }
    final context = _RootMutationContext(acquireMutationLease());
    try {
      return await runZoned(action, zoneValues: {_mutationContextKey: context});
    } finally {
      context.rootFinished();
    }
  }

  void _releaseMutationLease() {
    _activeMutations--;
    if (_activeMutations == 0) {
      _drainWaiter?.complete();
    }
  }

  void resetForTesting() {
    _exclusive = false;
    _maintenanceRequested = false;
    _activeMutations = 0;
    _drainWaiter = null;
  }
}

/// One root mutation lease plus every nested mutation started under it.
///
/// The lease stays held until the root action and all nested mutations that
/// started before it returned have finished, so quiescence cannot drain while
/// already-started leased work is still in flight.
final class _RootMutationContext {
  _RootMutationContext(this._lease);

  final BackupRestoreMutationLease _lease;
  int _openActions = 1;
  bool _rootReturned = false;

  bool admitNested() {
    if (_rootReturned || _lease._released) return false;
    _openActions++;
    return true;
  }

  void nestedFinished() {
    if (--_openActions == 0) _lease.release();
  }

  void rootFinished() {
    _rootReturned = true;
    if (--_openActions == 0) _lease.release();
  }
}

/// Held for the full async lifetime of one durable mutation. Release exactly
/// once; a double release is a programming error.
final class BackupRestoreMutationLease {
  BackupRestoreMutationLease._(this._gate);

  final BackupRestoreMutationGateState _gate;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _gate._releaseMutationLease();
  }
}
