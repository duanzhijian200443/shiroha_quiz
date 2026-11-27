import 'dart:async';

import '../capabilities/capability.dart';
import 'external_authorization.dart';
import 'external_runtime_admission.dart';
import 'external_trust_core.dart';

/// Pure question-only READ predicate. Background/lock-screen continuation never
/// widens a saved STAGE, fileContent, or studyStatistics grant.
bool androidBackgroundQuestionRead(ExternalGrantPolicy policy) =>
    policy.permissions.length == 1 &&
    policy.permissions.contains(CapabilityPermission.read) &&
    policy.categories.length == 1 &&
    policy.categories.contains(ExternalContentCategory.questionContent) &&
    policy.scopes.every((scope) => scope.kind == ExternalTargetKind.bank);

/// Bounded duration choices for an Android pure-question-READ Enable window.
/// Never persisted into a Grant.
enum AndroidAccessDuration {
  fiveMinutes(Duration(minutes: 5)),
  fifteenMinutes(Duration(minutes: 15)),
  thirtyMinutes(Duration(minutes: 30)),
  oneHour(Duration(hours: 1)),
  twoHours(Duration(hours: 2)),
  fourHours(Duration(hours: 4)),
  eightHours(Duration(hours: 8)),
  untilAppStops(null);

  const AndroidAccessDuration(this.limit);
  final Duration? limit;
}

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
    this.backgroundRead = false,
  });

  final int sequence;
  final bool resumed, focused, interactive, unlocked, visible;
  final String? network;
  final bool backgroundRead;
  bool get backgroundEligible =>
      backgroundRead && interactive && unlocked && network != null;
  bool canContinueBackground({required bool whileLocked}) =>
      backgroundEligible || (whileLocked && backgroundRead && network != null);
  bool get eligible =>
      visible &&
      resumed &&
      focused &&
      interactive &&
      unlocked &&
      network != null;
  bool get withdraws => !visible || !interactive || !unlocked;
}

enum AndroidAccessPhase { off, preparing, ready, suspended, draining, recovery }

/// Outcome of authenticating an Android HTTP Bearer request against the current
/// Enable window. Locked brand-new clients are refused without opening a P0
/// [ExternalSession].
sealed class AndroidHttpAuthResult {
  const AndroidHttpAuthResult();
}

final class AndroidHttpAuthenticated extends AndroidHttpAuthResult {
  const AndroidHttpAuthenticated(this.session);
  final ExternalSession session;
}

final class AndroidHttpLockedNewClientRefused extends AndroidHttpAuthResult {
  const AndroidHttpLockedNewClientRefused(this.profileId);
  final String profileId;
}

final class AndroidHttpUnauthenticated extends AndroidHttpAuthResult {
  const AndroidHttpUnauthenticated();
}

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
  bool cancellationFailed = false;
  _OwnedPreparation() {
    // Observe early errors while retaining them for the original owning join.
    unawaited(_result.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(_settled.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }
  void start(AndroidAccessPreparation Function() begin) {
    final AndroidAccessPreparation inner;
    try {
      inner = _inner = begin();
    } catch (error, stack) {
      _result.completeError(error, stack);
      _settled.completeError(error, stack);
      return;
    }
    // Cancellation failure cannot replace the original acquisition or drain.
    unawaited(
        inner.result.then(_result.complete, onError: _result.completeError));
    unawaited(
        inner.settled.then(_settled.complete, onError: _settled.completeError));
    if (_cancelled) _cancelInner();
  }

  @override
  Future<AndroidAccessResources> get result => _result.future;
  @override
  Future<void> get settled => _settled.future;
  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelInner();
  }

  void _cancelInner() {
    try {
      _inner?.cancel();
    } catch (_) {
      cancellationFailed = true;
    }
  }
}

/// Original runtime lifetime with optional Native-supported pure-question READ
/// in background and opt-in lock-screen continuation for already-authenticated
/// clients. This class cannot create a Session or execute tools.
final class AndroidForegroundAccess {
  AndroidForegroundAccess({required Duration Function() elapsed})
      : _elapsed = elapsed;

  final Duration Function() _elapsed;
  AndroidAccessPhase _phase = AndroidAccessPhase.off;
  AndroidForegroundObservation? _observation;
  _OwnedPreparation? _preparation;
  AndroidAccessResources? _resources;
  Future<void>? _closing;
  Future<void>? _suspending;
  Duration? _expires;
  bool _untilAppStops = false;
  Duration? _lastTime;
  String? _network;
  int _generation = 0;
  bool _disposed = false;
  bool _clockInvalid = false;
  bool _allowBackgroundRead = false;
  bool _continueWhileLocked = false;

  bool get _runningEligible => _allowBackgroundRead
      ? _observation?.canContinueBackground(
              whileLocked: _continueWhileLocked) ==
          true
      : _observation?.eligible == true;

  AndroidAccessPhase get phase => _phase;
  int get generation => _generation;
  bool get allowBackgroundRead => _allowBackgroundRead;
  bool get continueWhileLocked => _continueWhileLocked;
  bool get untilAppStops => _untilAppStops;

  /// Remaining duration for the existing finite caller.
  Duration get remaining =>
      boundedRemaining ?? (throw StateError('android_access_process_bound'));

  /// Exact finite remaining duration, or `null` when `untilAppStops` is active.
  Duration? get boundedRemaining {
    if (!_timeValid()) return Duration.zero;
    if (_untilAppStops) return null;
    return _expires! - _elapsed();
  }

  /// Admits new client authentications / sessions only while unlocked and
  /// interactive. Locked continuation never admits brand-new clients.
  bool get acceptsNew =>
      _observation?.interactive == true &&
      _observation?.unlocked == true &&
      allowsAuthenticatedUse;

  /// Admits requests from clients/sessions that were already authenticated
  /// while unlocked during this same Enable window.
  bool get allowsAuthenticatedUse =>
      !_disposed &&
      _phase == AndroidAccessPhase.ready &&
      _runningEligible &&
      _observation?.network == _network &&
      _timeValid();

  /// Policy for the current HTTP window. An opted-in background window admits
  /// only pure question READ Profiles, including while the App is visible.
  bool allowsHttpReadGrant(ExternalGrant? grant) =>
      allowsAuthenticatedUse &&
      grant != null &&
      grant.revokedAtUtcMs == null &&
      grant.policy.permissions.contains(CapabilityPermission.read) &&
      (!_allowBackgroundRead || androidBackgroundQuestionRead(grant.policy));

  Future<ExternalGrant?> currentHttpReadGrant(
    ExternalRuntimeAdmission admission,
    ExternalSession session,
  ) async {
    if (!allowsAuthenticatedUse) return null;
    final generation = _generation;
    try {
      final access = await admission.admit(session);
      final grant = access.grantSnapshot;
      if (generation == _generation && allowsHttpReadGrant(grant)) {
        return grant;
      }
    } on ExternalAuthException {
      return null;
    }
    return null;
  }

  bool _timeValid() {
    final now = _elapsed();
    if (now.isNegative || (_lastTime != null && now < _lastTime!)) {
      _clockInvalid = true;
    }
    if (_clockInvalid) return false;
    _lastTime = now;
    final expiry = _expires;
    return _untilAppStops || (expiry != null && now < expiry);
  }

  void observe(AndroidForegroundObservation next) {
    if (_disposed || next.sequence <= (_observation?.sequence ?? -1)) return;
    _observation = next;
    if (_phase == AndroidAccessPhase.off ||
        _phase == AndroidAccessPhase.draining ||
        _phase == AndroidAccessPhase.recovery) {
      return;
    }
    final runningBackground =
        _allowBackgroundRead && _phase == AndroidAccessPhase.ready;
    if ((runningBackground
            ? !next.canContinueBackground(whileLocked: _continueWhileLocked)
            : next.withdraws) ||
        next.network != _network ||
        !_timeValid()) {
      unawaited(disable());
    } else if (!next.eligible && !runningBackground) {
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

  Future<void> enable(
    AndroidAccessPreparation Function(int generation) begin, {
    Duration? duration = const Duration(hours: 8),
    bool allowBackgroundRead = false,
    bool continueWhileLocked = false,
  }) async {
    if (_disposed ||
        _clockInvalid ||
        _phase != AndroidAccessPhase.off ||
        ((continueWhileLocked || duration == null) && !allowBackgroundRead) ||
        _observation?.eligible != true ||
        (duration != null &&
            (duration <= Duration.zero ||
                duration > const Duration(hours: 8)))) {
      throw StateError('android_access_unavailable');
    }
    final now = _elapsed();
    if (now.isNegative || (_lastTime != null && now < _lastTime!)) {
      throw StateError('android_access_unavailable');
    }
    _lastTime = now;
    _allowBackgroundRead = allowBackgroundRead;
    _continueWhileLocked = continueWhileLocked;
    _untilAppStops = duration == null;
    _expires = duration == null ? null : now + duration;
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
      (_expires != null || _untilAppStops) && !_timeValid()
          ? disable()
          : Future<void>.value();

  Future<void> disable() {
    if (_closing != null) return _closing!;
    if (_phase == AndroidAccessPhase.off ||
        _phase == AndroidAccessPhase.recovery) {
      return Future<void>.value();
    }
    _generation++;
    _phase = AndroidAccessPhase.draining;
    _expires = null;
    _untilAppStops = false;
    _allowBackgroundRead = false;
    _continueWhileLocked = false;
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
        // A reentrant cancel can fail only after begin returns. Check the latch
        // after joining the real operation, including any late resource.
        if (preparation.cancellationFailed) clean = false;
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
