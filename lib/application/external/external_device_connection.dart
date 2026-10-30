import 'dart:async';

enum ExternalDeviceKind { unselected, windows, android }

enum ExternalDevicePhase {
  disconnected,
  waitingAuthorization,
  connected,
  ending,
  busy,
  needsAttention,
}

enum ExternalDeviceFailure {
  targetNotSelected,
  busy,
  needsAttention,
  targetUnavailable
}

final class ExternalDeviceException implements Exception {
  const ExternalDeviceException(this.failure);
  final ExternalDeviceFailure failure;
  @override
  String toString() => 'ExternalDeviceException(${failure.name})';
}

/// Non-secret local references only. They never contain network addresses,
/// database paths, credentials or an authorization grant.
final class ExternalDeviceTarget {
  const ExternalDeviceTarget.unselected()
      : kind = ExternalDeviceKind.unselected,
        reference = null;
  const ExternalDeviceTarget.windows()
      : kind = ExternalDeviceKind.windows,
        reference = null;
  ExternalDeviceTarget.android(String value)
      : kind = ExternalDeviceKind.android,
        reference = value {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(value)) {
      throw const ExternalDeviceException(
          ExternalDeviceFailure.targetUnavailable);
    }
  }
  final ExternalDeviceKind kind;
  final String? reference;
  @override
  bool operator ==(Object other) =>
      other is ExternalDeviceTarget &&
      kind == other.kind &&
      reference == other.reference;
  @override
  int get hashCode => Object.hash(kind, reference);
}

/// A dirty record is retained across App restart and excluded from portable
/// backup. Neither startup nor selecting another device clears uncertain work.
final class ExternalDeviceSelection {
  ExternalDeviceSelection(
      {required this.target, this.generation = 0, this.needsCleanup = false}) {
    if (generation < 0 || generation >= 0x7fffffffffffffff) {
      throw const ExternalDeviceException(ExternalDeviceFailure.needsAttention);
    }
  }
  final ExternalDeviceTarget target;
  final int generation;
  final bool needsCleanup;
}

abstract interface class ExternalDeviceSelectionStore {
  Future<ExternalDeviceSelection?> readDeviceSelection();
  Future<void> saveDeviceSelection(ExternalDeviceSelection value);

  /// Only the original live lease may finish its exact dirty-to-clean write
  /// during B0 maintenance; replacement, selection and recovery remain gated.
  Future<void> settleDeviceLease(ExternalDeviceLease lease);
  Future<void> acknowledgeDeviceCleanup(
      ExternalDeviceSelection expected, ExternalDeviceSelection replacement,
      {required bool Function() isCurrent});
}

final class ExternalDeviceLease {
  ExternalDeviceLease._(this._store, this.target, this.generation);
  final ExternalDeviceSelectionStore _store;
  final ExternalDeviceTarget target;
  final int generation;
  bool _settling = false;

  /// Data can only consume this proof while its original Application owner is
  /// joining clean settlement. A retained lease cannot clear a later marker.
  void requireSettlement(ExternalDeviceSelectionStore store) {
    if (!identical(_store, store) || !_settling) {
      throw const ExternalDeviceException(ExternalDeviceFailure.needsAttention);
    }
  }
}

/// App-level admission and durable cleanup barrier shared by target selection
/// and the original relay owner. A lease grants no target-App authorization.
final class ExternalDeviceConnection {
  ExternalDeviceConnection(
      {required this.store,
      required this.availableTargets,
      required this.endConnection,
      this.verifyRecovery});
  final ExternalDeviceSelectionStore store;
  final Future<List<ExternalDeviceTarget>> Function() availableTargets;
  final Future<void> Function() endConnection;
  final Future<void> Function(ExternalDeviceTarget)? verifyRecovery;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  ExternalDeviceSelection _selection =
      ExternalDeviceSelection(target: const ExternalDeviceTarget.unselected());
  ExternalDevicePhase _phase = ExternalDevicePhase.disconnected;
  ExternalDeviceLease? _active;
  bool _initialized = false, _changing = false, _closed = false;
  Future<void>? _recovering;
  List<ExternalDeviceTarget> _targets = const [];
  ExternalDeviceSelection get selection => _selection;
  ExternalDevicePhase get phase => _phase;
  List<ExternalDeviceTarget> get targets => _targets;
  bool get changing => _changing;
  bool get recovering => _recovering != null;
  bool get canRecover =>
      _initialized &&
      !_closed &&
      !_changing &&
      _active == null &&
      _phase == ExternalDevicePhase.needsAttention &&
      _selection.needsCleanup &&
      _selection.target.kind == ExternalDeviceKind.android &&
      verifyRecovery != null;
  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Never _fail(ExternalDeviceFailure failure) =>
      throw ExternalDeviceException(failure);
  void _admit() {
    if (!_initialized ||
        _closed ||
        _phase == ExternalDevicePhase.needsAttention) {
      _fail(ExternalDeviceFailure.needsAttention);
    }
    if (_changing) _fail(ExternalDeviceFailure.busy);
  }

  void _attention() {
    _phase = ExternalDevicePhase.needsAttention;
    _notify();
  }

  Future<void> load() async {
    if (_initialized || _changing || _closed) _fail(ExternalDeviceFailure.busy);
    _changing = true;
    try {
      final saved = await store.readDeviceSelection();
      _targets = List.unmodifiable(await availableTargets());
      _selection = saved ?? _selection;
      _initialized = true;
      if (_selection.needsCleanup) _attention();
    } catch (_) {
      _attention();
      rethrow;
    } finally {
      _changing = false;
      _notify();
    }
  }

  Future<ExternalDeviceLease> begin() async {
    _admit();
    if (_active != null) _fail(ExternalDeviceFailure.busy);
    if (_selection.target.kind == ExternalDeviceKind.unselected) {
      _fail(ExternalDeviceFailure.targetNotSelected);
    }
    if (!(await availableTargets()).contains(_selection.target)) {
      _fail(ExternalDeviceFailure.targetUnavailable);
    }
    // The availability await is not a lease. Recheck against a concurrent
    // selection/begin before writing the dirty record and starting any child.
    _admit();
    if (_active != null) _fail(ExternalDeviceFailure.busy);
    _changing = true;
    try {
      final pending = ExternalDeviceSelection(
          target: _selection.target,
          generation: _selection.generation,
          needsCleanup: true);
      await store.saveDeviceSelection(pending);
      _selection = pending;
      final lease = _active =
          ExternalDeviceLease._(store, pending.target, pending.generation);
      _phase = ExternalDevicePhase.waitingAuthorization;
      return lease;
    } catch (_) {
      _attention();
      rethrow;
    } finally {
      _changing = false;
      _notify();
    }
  }

  void connected(ExternalDeviceLease lease) {
    if (identical(lease, _active) &&
        !_changing &&
        !_closed &&
        _phase != ExternalDevicePhase.needsAttention) {
      _phase = ExternalDevicePhase.connected;
      _notify();
    }
  }

  Future<void> settled(ExternalDeviceLease lease, {required bool clean}) async {
    if (!identical(lease, _active) ||
        lease._settling ||
        _phase == ExternalDevicePhase.needsAttention) {
      _fail(ExternalDeviceFailure.needsAttention);
    }
    if (!clean) {
      _attention();
      _fail(ExternalDeviceFailure.needsAttention);
    }
    lease._settling = true;
    try {
      final settled = ExternalDeviceSelection(
          target: _selection.target, generation: _selection.generation);
      await store.settleDeviceLease(lease);
      _selection = settled;
      _active = null;
      if (!_changing) _phase = ExternalDevicePhase.disconnected;
      _notify();
    } catch (_) {
      _attention();
      rethrow;
    } finally {
      lease._settling = false;
    }
  }

  Future<void> select(ExternalDeviceTarget target) async {
    _admit();
    if (target == _selection.target) return;
    if (target.kind != ExternalDeviceKind.unselected &&
        !(await availableTargets()).contains(target)) {
      _fail(ExternalDeviceFailure.targetUnavailable);
    }
    _admit();
    _changing = true;
    _phase = ExternalDevicePhase.ending;
    _notify();
    try {
      await endConnection();
      if (_active != null ||
          _selection.needsCleanup ||
          _phase == ExternalDevicePhase.needsAttention) {
        _fail(ExternalDeviceFailure.needsAttention);
      }
      final next = ExternalDeviceSelection(
          target: target, generation: _selection.generation + 1);
      await store.saveDeviceSelection(next);
      _selection = next;
      _phase = ExternalDevicePhase.disconnected;
    } catch (_) {
      _attention();
      rethrow;
    } finally {
      _changing = false;
      _notify();
    }
  }

  /// An explicit local confirmation starts a fresh proof, never a business
  /// replay. Only a restarted owner with no borrowed live lease can recover.
  Future<void> recover(int expectedGeneration,
      {required bool Function() isCurrent}) {
    if (!canRecover ||
        expectedGeneration != _selection.generation ||
        !isCurrent()) {
      return Future.error(
          const ExternalDeviceException(ExternalDeviceFailure.needsAttention));
    }
    final original = _selection;
    _changing = true;
    _notify();
    return _recovering = () async {
      try {
        if (!(await availableTargets()).contains(original.target)) {
          _fail(ExternalDeviceFailure.targetUnavailable);
        }
        if (_closed || !isCurrent()) {
          _fail(ExternalDeviceFailure.needsAttention);
        }
        // The injected owner joins the original proof process, key retirement
        // and both streams before returning. A mere absent PID is insufficient.
        await verifyRecovery!(original.target);
        if (_closed || !isCurrent()) {
          _fail(ExternalDeviceFailure.needsAttention);
        }
        final recovered = ExternalDeviceSelection(
            target: original.target, generation: original.generation + 1);
        await store.acknowledgeDeviceCleanup(original, recovered,
            isCurrent: () => !_closed && isCurrent());
        _selection = recovered;
        _phase = ExternalDevicePhase.disconnected;
      } catch (_) {
        _attention();
        rethrow;
      } finally {
        _changing = false;
        _recovering = null;
        _notify();
      }
    }();
  }

  void withdraw() => _closed = true;

  /// Called after the original relay close, including late acquisition/drains.
  Future<void> close() async {
    withdraw();
    try {
      await _recovering;
    } catch (_) {/* Original recovery kept its marker. */}
    if (_active != null) _fail(ExternalDeviceFailure.needsAttention);
    await _changes.close();
  }
}
