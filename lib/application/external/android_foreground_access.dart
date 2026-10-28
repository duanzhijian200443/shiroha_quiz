import 'dart:async';

/// Platform observations, not authentication, a Grant, or P0 Enablement.
final class AndroidForegroundObservation {
  const AndroidForegroundObservation({
    required this.sequence,
    required this.resumed,
    required this.focused,
    required this.interactive,
    required this.unlocked,
    required this.visible,
    required this.network,
  });

  final int sequence;
  final bool resumed, focused, interactive, unlocked, visible;
  final String? network;
  bool get eligible =>
      resumed && focused && interactive && unlocked && network != null;
  bool get withdraws => !visible || !interactive || !unlocked;
}

enum AndroidAccessPhase { off, preparing, ready, suspended, draining, recovery }

/// A resource owner must invalidate immediately and retain custody until close.
/// It supplies no business identity; future composition must also use P0/P15.
abstract interface class AndroidAccessResources {
  void withdraw();
  Future<void> close();
}

/// One original acquisition, including cancellation before resources arrive.
abstract interface class AndroidAccessPreparation {
  Future<AndroidAccessResources> get result;
  void cancel();
  Future<void> get settled;
}

/// Reserves custody before even a synchronous/reentrant acquisition callback.
final class _OwnedPreparation implements AndroidAccessPreparation {
  final _result = Completer<AndroidAccessResources>();
  final _settled = Completer<void>();
  AndroidAccessPreparation? _inner;
  bool _cancelled = false;
  _OwnedPreparation() {
    // Observe early errors while retaining them for the original owning join.
    unawaited(_result.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(_settled.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }
  void start(AndroidAccessPreparation Function() begin) {
    try {
      final inner = _inner = begin();
      if (_cancelled) inner.cancel();
      unawaited(
          inner.result.then(_result.complete, onError: _result.completeError));
      unawaited(inner.settled
          .then(_settled.complete, onError: _settled.completeError));
    } catch (error, stack) {
      _result.completeError(error, stack);
      _settled.completeError(error, stack);
    }
  }

  @override
  Future<AndroidAccessResources> get result => _result.future;
  @override
  Future<void> get settled => _settled.future;
  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _inner?.cancel();
  }
}

/// Foreground lifetime only. This class cannot create a Session or execute tools.
final class AndroidForegroundAccess {
  AndroidForegroundAccess({required Duration Function() elapsed})
      : _elapsed = elapsed;

  final Duration Function() _elapsed;
  AndroidAccessPhase _phase = AndroidAccessPhase.off;
  AndroidForegroundObservation? _observation;
  AndroidAccessPreparation? _preparation;
  AndroidAccessResources? _resources;
  Future<void>? _closing;
  Future<void>? _suspending;
  Duration? _expires;
  Duration? _lastTime;
  String? _network;
  int _generation = 0;
  bool _disposed = false;
  bool _clockInvalid = false;

  AndroidAccessPhase get phase => _phase;
  int get generation => _generation;
  bool get acceptsNew =>
      !_disposed &&
      _phase == AndroidAccessPhase.ready &&
      _observation?.eligible == true &&
      _observation?.network == _network &&
      _timeValid();

  bool _timeValid() {
    final now = _elapsed();
    if (now.isNegative || (_lastTime != null && now < _lastTime!)) {
      _clockInvalid = true;
    }
    if (_clockInvalid) return false;
    _lastTime = now;
    return _expires != null && now < _expires!;
  }

  void observe(AndroidForegroundObservation next) {
    if (_disposed || next.sequence <= (_observation?.sequence ?? -1)) return;
    _observation = next;
    if (_phase == AndroidAccessPhase.off ||
        _phase == AndroidAccessPhase.draining ||
        _phase == AndroidAccessPhase.recovery) {
      return;
    }
    if (next.withdraws || next.network != _network || !_timeValid()) {
      unawaited(disable());
    } else if (!next.eligible) {
      // Pending enable cannot survive a lost local decision surface.
      if (_phase == AndroidAccessPhase.preparing) {
        unawaited(disable());
      } else if (_phase == AndroidAccessPhase.ready) {
        _phase = AndroidAccessPhase.suspended;
        // Admission tokens issued before the interruption stay invalid.
        _generation++;
        _resources?.withdraw();
        final resource = _resources;
        _resources = null;
        _suspending = () async {
          try {
            await resource?.close();
          } catch (_) {
            _phase = AndroidAccessPhase.recovery;
            _expires = null;
          }
        }();
      }
    }
    // Resume is deliberately explicit: the old connection never becomes live.
  }

  Future<void> enable(AndroidAccessPreparation Function(int generation) begin,
      {Duration duration = const Duration(hours: 8)}) async {
    if (_disposed ||
        _clockInvalid ||
        _phase != AndroidAccessPhase.off ||
        _observation?.eligible != true ||
        duration <= Duration.zero ||
        duration > const Duration(hours: 8)) {
      throw StateError('android_access_unavailable');
    }
    final now = _elapsed();
    if (now.isNegative || (_lastTime != null && now < _lastTime!)) {
      throw StateError('android_access_unavailable');
    }
    _lastTime = now;
    _expires = now + duration;
    _network = _observation!.network;
    await _prepare(begin);
  }

  /// Only a fresh connection can resume the SAME unexpired foreground period.
  Future<void> resume(
      AndroidAccessPreparation Function(int generation) begin) async {
    if (_disposed || _phase != AndroidAccessPhase.suspended) {
      throw StateError('android_access_unavailable');
    }
    final original = _generation;
    await _suspending;
    if (original != _generation ||
        _phase != AndroidAccessPhase.suspended ||
        _observation?.eligible != true ||
        !_timeValid()) {
      await disable();
      return;
    }
    await _prepare(begin);
  }

  Future<void> _prepare(
      AndroidAccessPreparation Function(int generation) begin) async {
    _phase = AndroidAccessPhase.preparing;
    final original = ++_generation;
    try {
      // Owner is acquired synchronously, before the first asynchronous wait.
      final preparation = _OwnedPreparation();
      _preparation = preparation;
      preparation.start(() => begin(original));
      final resources = await preparation.result;
      _resources = resources;
      if (_disposed ||
          original != _generation ||
          _phase != AndroidAccessPhase.preparing ||
          _observation?.eligible != true ||
          !_timeValid()) {
        resources.withdraw();
        await disable();
        return;
      }
      await preparation.settled;
      if (original != _generation ||
          _phase != AndroidAccessPhase.preparing ||
          _observation?.eligible != true ||
          !_timeValid()) {
        await disable();
        return;
      }
      _preparation = null;
      _phase = AndroidAccessPhase.ready;
    } catch (_) {
      await disable();
    }
  }

  /// Navigation after enable is independent of this pending-only cancellation.
  Future<void> cancelPending() =>
      _phase == AndroidAccessPhase.preparing ? disable() : Future<void>.value();

  /// Called by the owning timer; observing an expired authority never renews it.
  Future<void> checkDeadline() =>
      _expires != null && !_timeValid() ? disable() : Future<void>.value();

  Future<void> disable() {
    if (_closing != null) return _closing!;
    if (_phase == AndroidAccessPhase.off ||
        _phase == AndroidAccessPhase.recovery) {
      return Future<void>.value();
    }
    _generation++;
    _phase = AndroidAccessPhase.draining;
    _expires = null;
    final preparation = _preparation;
    preparation?.cancel();
    _resources?.withdraw();
    return _closing = () async {
      var clean = true;
      await _suspending;
      if (_phase == AndroidAccessPhase.recovery) clean = false;
      AndroidAccessResources? acquired = _resources;
      if (preparation != null) {
        try {
          acquired ??= await preparation.result;
        } catch (_) {
          // Acquisition may fail cleanly; its independent settlement decides.
        }
        acquired?.withdraw();
        try {
          await preparation.settled;
        } catch (_) {
          clean = false;
        }
      }
      try {
        await acquired?.close();
      } catch (_) {
        clean = false;
      }
      _resources = null;
      _preparation = null;
      _network = null;
      _phase = clean ? AndroidAccessPhase.off : AndroidAccessPhase.recovery;
    }()
        .whenComplete(() => _closing = null);
  }

  Future<void> dispose() {
    _disposed = true;
    return disable();
  }
}
