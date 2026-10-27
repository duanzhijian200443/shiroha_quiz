import 'dart:async';

import '../capabilities/capability.dart';
import '../generated_question/generated_local_authority.dart';
import 'external_generated_stage.dart';
import 'external_authorization.dart';
import 'external_invocation_core.dart';
import 'external_read_context.dart';
import 'external_trust_core.dart';
import 'local_host_dispatch.dart';

/// Fixed source-only STAGE limits; none of these renews caller authority.
abstract final class FirstPartyStageLimits {
  static const preparation = Duration(seconds: 2);
  static const waiting = Duration(seconds: 120);
  static const completion = Duration(seconds: 10);
  static const bridgeResponse = Duration(seconds: 132);
  static const bridgeExchange = Duration(seconds: 142);
}

typedef StageApprovalSchedule = void Function() Function(
    Duration delay, void Function() action);

void Function() _defaultSchedule(Duration delay, void Function() action) {
  final timer = Timer(delay, action);
  return timer.cancel;
}

/// One App-generation owner, shared by all its request projections. It holds no
/// transaction, credential, durable approval, completed-call journal or writer.
final class FirstPartyStageApproval {
  FirstPartyStageApproval({
    required this.host,
    required this.stages,
    required this.localOwner,
    required bool Function() compositionIsCurrent,
    Duration Function()? monotonicNow,
    StageApprovalSchedule? schedule,
  })  : _current = compositionIsCurrent,
        _nowOverride = monotonicNow,
        _schedule = schedule ?? _defaultSchedule {
    stages.runtimeAdmission.onClose(cancel);
  }

  final LocalHostDispatchCore host;
  final ExternalGeneratedStageService stages;
  final GeneratedLocalAuthoritySession localOwner;
  final bool Function() _current;
  final Duration Function()? _nowOverride;
  final StageApprovalSchedule _schedule;
  final _clock = Stopwatch()..start();
  Duration get _now => _nowOverride?.call() ?? _clock.elapsed;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _work = <Future<void>>{};
  FirstPartyStageApprovalView? _view;
  FirstPartyStageRequest? _request;
  bool _closed = false;

  bool get _live =>
      !_closed && _current() && localOwner.isCurrent && host.isReady;
  int get pendingCount => _request == null ? 0 : 1;
  bool get waitingForUser => _request?._awaiting == true;
  Stream<void> get changes => _changes.stream;
  Future<void> get whenSettled => Future.wait(_work.toList()).then((_) {});

  /// Only the current first-party control view receives this local object.
  FirstPartyStageApprovalView openView() {
    _view?.close();
    if (!_live) _deny();
    return _view = FirstPartyStageApprovalView._(this);
  }

  bool hasLiveRequestFor(String? profileId) {
    final request = _request;
    if (request == null || request.profileId != profileId) return false;
    try {
      _check(request);
      return true;
    } catch (_) {
      return false;
    }
  }

  Never _deny([CapabilityFailure failure = CapabilityFailure.accessDenied]) =>
      throw LocalHostAdmissionException(failure);

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _check(FirstPartyStageRequest request) {
    final failure = request._control.failure;
    if (failure != null) {
      _deny(failure == ExternalFailure.deadlineExceeded
          ? CapabilityFailure.deadlineExceeded
          : CapabilityFailure.cancelled);
    }
    if (!_live ||
        !identical(_request, request) ||
        request._failure != null ||
        request._session.failure != null ||
        !request._available()) {
      _deny(request._failure ?? CapabilityFailure.accessDenied);
    }
    if (request._submissionJson.isEmpty) {
      _deny(CapabilityFailure.invalidRequest);
    }
    request._access?.validate();
  }

  Future<T> _track<T>(Future<T> Function() action) {
    final done = Completer<void>();
    _work.add(done.future);
    return () async {
      try {
        return await action();
      } finally {
        done.complete();
        _work.remove(done.future);
      }
    }();
  }

  Future<T> _interruptible<T>(FirstPartyStageRequest request, Future<T> work) =>
      Future.any([
        work,
        request._control.interrupted.then<T>((_) {
          _check(request);
          return _deny();
        }),
      ]);

  Future<void> _validate(FirstPartyStageRequest request) async {
    _check(request);
    if (!identical(await request._authenticate(), request._session)) _deny();
    _check(request);
    final read =
        await host.openRead(request._entry, context: request._contextRef);
    _check(request);
    if (!identical(read.session, request._session) || read.readAccess == null) {
      _deny();
    }
    if (request._revision != null &&
        read.authorization.revision != request._revision) {
      _deny();
    }
    request._revision ??= read.authorization.revision;
    request._access ??= read.readAccess;
    final choice = request._choice;
    if (choice != null &&
        await stages.checkTargetForApproval(request._session, choice.target) !=
            request._revision) {
      _deny();
    }
    _check(request);
  }

  /// Trusted request composition only. S/E are the original admitted objects;
  /// the immutable raw text is retained without parsing candidate content.
  Future<ExternalExecutionContext> waitForApproval({
    required ExternalSession session,
    required LocalHostSessionEntry entry,
    required String contextRef,
    required String submissionJson,
    required ExternalCallControl control,
    required Future<ExternalSession?> Function() authenticate,
    required bool Function() available,
    void Function()? onWaiting,
  }) async {
    if (!_live) _deny();
    if (_request != null) _deny(CapabilityFailure.budgetDenied);
    final request = _request = FirstPartyStageRequest._(this, session, entry,
        contextRef, submissionJson, control, authenticate, available);
    request._cancelTimer =
        _schedule(FirstPartyStageLimits.preparation, control.expireDeadline);
    try {
      await _interruptible(request, _track(() async {
        await _validate(request);
        final choices = await localOwner.targets();
        _check(request);
        final target = request._access!.target;
        for (final choice in choices) {
          if (choice.target.bankName == target.bankName &&
              choice.target.projectId == target.projectId &&
              choice.target.folderName == target.folderName) {
            request._choice = choice;
            break;
          }
        }
        if (request._choice == null) _deny();
        await _validate(request);
      }));
      final access = await _interruptible(
          request, _track(() => stages.runtimeAdmission.admit(session)));
      _check(request);
      final grant = access.grantSnapshot;
      if (grant == null ||
          grant.revokedAtUtcMs != null ||
          grant.revision != request._revision) {
        _deny();
      }
      request._cancelTimer!();
      if (grant.policy.generationMode != ExternalGenerationMode.confirm) {
        request._cancelTimer =
            _schedule(FirstPartyStageLimits.completion, control.expireDeadline);
        await _interruptible(request, _approve(request));
        final context = await _interruptible(request, request._decision.future);
        _check(request);
        if (context == null) _deny();
        return context;
      }
      if (_view == null) _deny();
      request._due = _now + FirstPartyStageLimits.waiting;
      request._awaiting = true;
      request._cancelTimer =
          _schedule(FirstPartyStageLimits.waiting, control.expireDeadline);
      onWaiting?.call();
      _poll(request);
      _changed();
      final context = await _interruptible(request, request._decision.future);
      _check(request);
      if (context == null) _deny();
      return context;
    } finally {
      request._awaiting = false;
      request._cancelPoll?.call();
      // The completion timer and slot survive the caller result until actual
      // owning settlement and transport close acknowledge finish().
      _changed();
    }
  }

  void _poll(FirstPartyStageRequest request) {
    request._cancelPoll = _schedule(const Duration(seconds: 1), () {
      if (!request._awaiting) return;
      unawaited(_track(() async {
        try {
          await _validate(request);
          if (request._awaiting) _poll(request);
        } catch (_) {
          _invalidate(request, CapabilityFailure.accessDenied);
        }
      }));
    });
  }

  void _invalidate(FirstPartyStageRequest request, CapabilityFailure failure) {
    if (request._failure != null) return;
    request._failure = failure;
    request._awaiting = false;
    request._cancelTimer?.call();
    if (request._control.failure == null) {
      request._cancelTimer = _schedule(
          FirstPartyStageLimits.completion, request._control.expireDeadline);
    }
    request._cancelPoll?.call();
    if (!request._decision.isCompleted) request._decision.complete(null);
    _changed();
  }

  Future<void> _confirm(
      FirstPartyStageApprovalView view, FirstPartyStageRequest request) async {
    if (!identical(view, _view) ||
        !request._awaiting ||
        request._due == null ||
        _now >= request._due!) {
      _deny();
    }
    _check(request);
    request._awaiting = false; // Exactly one UI action may claim the request.
    request._cancelTimer!();
    request._cancelPoll?.call();
    request._cancelTimer = _schedule(
        FirstPartyStageLimits.completion, request._control.expireDeadline);
    _changed();
    await _approve(request);
  }

  Future<void> _approve(FirstPartyStageRequest request) async {
    await _track(() async {
      try {
        await _validate(request);
        final approved = await stages
            .approveTarget(request._session, request._choice!.target, const []);
        _check(request);
        if (approved.grantRevision != request._revision) _deny();
        await _validate(request);
        final context = await host.openStage(request._entry, approved);
        _check(request);
        if (!identical(context.session, request._session)) _deny();
        if (!request._decision.isCompleted) request._decision.complete(context);
      } catch (_) {
        _invalidate(request, CapabilityFailure.accessDenied);
      }
    });
  }

  /// Disable/close cancels the request, without disabling unrelated Profiles.
  void cancel() {
    final request = _request;
    if (request == null) return;
    request._control.cancel();
    _invalidate(request, CapabilityFailure.cancelled);
  }

  /// Only the trusted transport owner calls this after real drain and close.
  void finish(ExternalCallControl control, {required bool clean}) {
    final request = _request;
    if (request == null || !identical(control, request._control)) return;
    request._cancelTimer?.call();
    request._cancelPoll?.call();
    if (clean) _request = null;
    if (!request._released.isCompleted) request._released.complete(clean);
    _changed();
  }

  Future<void> close() async {
    _closed = true;
    cancel();
    await whenSettled;
    final request = _request;
    if (request != null && !await request._released.future) _deny();
    stages.runtimeAdmission.removeOnClose(cancel);
    await _changes.close();
  }
}

/// First-party display only; request authority and content remain private.
final class FirstPartyStageRequest {
  FirstPartyStageRequest._(
      this._owner,
      this._session,
      this._entry,
      this._contextRef,
      this._submissionJson,
      this._control,
      this._authenticate,
      this._available);
  final FirstPartyStageApproval _owner;
  final ExternalSession _session;
  final LocalHostSessionEntry _entry;
  final String _contextRef, _submissionJson;
  final ExternalCallControl _control;
  final Future<ExternalSession?> Function() _authenticate;
  final bool Function() _available;
  final _decision = Completer<ExternalExecutionContext?>();
  final _released = Completer<bool>();
  ExternalQuestionReadAccess? _access;
  GeneratedReviewTargetChoice? _choice;
  int? _revision;
  Duration? _due;
  bool _awaiting = false;
  CapabilityFailure? _failure;
  void Function()? _cancelTimer, _cancelPoll;
  String get profileId => _session.principal.profileId;
  String get targetLabel => _choice!.label;
  int get remainingSeconds =>
      ((_due! - _owner._now).inMilliseconds / 1000).ceil().clamp(0, 120);
}

/// One current local UI view, never a wire approval ticket.
final class FirstPartyStageApprovalView {
  FirstPartyStageApprovalView._(this._owner);
  final FirstPartyStageApproval _owner;
  Stream<void> get changes => _owner._changes.stream;
  FirstPartyStageRequest? get pending {
    final request = _owner._request;
    if (!identical(_owner._view, this) || request?._awaiting != true) {
      return null;
    }
    try {
      _owner._check(request!);
      return request;
    } catch (_) {
      return null;
    }
  }

  Future<void> confirm(FirstPartyStageRequest request) =>
      _owner._confirm(this, request);
  void reject(FirstPartyStageRequest request) {
    if (!identical(_owner._view, this) || !identical(pending, request)) return;
    _owner._invalidate(request, CapabilityFailure.accessDenied);
  }

  void close() {
    if (!identical(_owner._view, this)) return;
    if (_owner._request?._awaiting == true &&
        !_owner._request!._decision.isCompleted) {
      _owner.cancel();
    }
    _owner._view = null;
  }
}
