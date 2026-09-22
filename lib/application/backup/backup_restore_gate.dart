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
  /// Every admitted action owns a scope that stays usable for its own
  /// descendants until that action finishes, so a still-running nested action
  /// may keep starting nested work after the root action returned. Callbacks
  /// whose owning action has already finished — and independent workflows —
  /// acquire a new lease and stay blocked during maintenance. The lease is
  /// released only once the root and every admitted descendant have finished.
  Future<T> runMutation<T>(Future<T> Function() action) async {
    final inherited = Zone.current[_mutationContextKey];
    final scope = inherited is _MutationScope && inherited.isActive
        ? inherited.admitChild()
        : _MutationScope(_RootMutationContext(acquireMutationLease()));
    try {
      return await runZoned(action, zoneValues: {_mutationContextKey: scope});
    } finally {
      scope.close();
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

/// One root mutation lease plus every action admitted under it.
final class _RootMutationContext {
  _RootMutationContext(this._lease);

  final BackupRestoreMutationLease _lease;
  int _openActions = 0;

  void actionOpened() => _openActions++;

  void actionClosed() {
    if (--_openActions == 0) _lease.release();
  }
}

/// One admitted mutation action. The scope admits descendants until the action
/// itself finishes, even when its root action has already returned.
final class _MutationScope {
  _MutationScope(this._context) {
    _context.actionOpened();
  }

  final _RootMutationContext _context;
  bool _active = true;

  bool get isActive => _active;

  _MutationScope admitChild() => _MutationScope(_context);

  void close() {
    if (!_active) return;
    _active = false;
    _context.actionClosed();
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
