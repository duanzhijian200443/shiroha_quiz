import 'dart:async';

import '../../domain/conversations/conversation.dart';
import '../capabilities/capability.dart';
import 'external_generated_stage.dart';
import 'external_invocation_core.dart';
import 'external_trust_core.dart';

/// Trusted composition checks, never values decoded from a business request.
/// Implementations own their readiness proof; this seam performs no I/O itself.
abstract interface class LocalHostReadinessPort {
  Future<void> ensureDatabaseReady();
  Future<void> ensureRecoveryComplete();
  Future<void> ensureModulesAndRoutesReady();
  bool get isCurrent;
}

enum LocalHostState { disabled, starting, ready, stopping, stopped }

/// Fixed safe admission classification; underlying exceptions are never retained.
final class LocalHostAdmissionException implements Exception {
  const LocalHostAdmissionException(this.failure);
  final CapabilityFailure failure;
  @override
  String toString() => 'LocalHostAdmissionException(${failure.name})';
}

/// Opaque entry minted from an existing authenticated, App-bound Session.
/// Neither identity nor authorization can be reconstructed from request fields.
final class LocalHostSessionEntry {
  LocalHostSessionEntry._(this._owner, this._session, this._grantRevision);
  final LocalHostDispatchCore _owner;
  final ExternalSession _session;
  final int _grantRevision;
}

/// Offline trusted composition only. No listener, wire parser or production
/// composition is installed. Constructed instances default to disabled.
final class LocalHostDispatchCore {
  LocalHostDispatchCore(
      {required ExternalCapabilityGateway gateway,
      required LocalHostReadinessPort readiness})
      : _gateway = gateway,
        _readiness = readiness;

  final ExternalCapabilityGateway _gateway;
  final LocalHostReadinessPort _readiness;
  LocalHostState _state = LocalHostState.disabled;
  int? _generation;
  int _pending = 0;
  Completer<void>? _idle;
  Future<void>? _shutdown;
  LocalHostState get state => _state;
  int get pendingCount => _pending;

  /// Read-only prerequisite for an inactive transport; only the existing
  /// Application startup path may perform readiness preparation.
  bool get isReady => _ready;

  /// Read-only settlement barrier for an inactive transport's owning slots.
  /// A caller deadline/result is not evidence that owning work has finished.
  Future<void> get whenSettled => Future.wait([
        _gateway.whenIdle,
        _gateway.reads.whenIdle,
        _gateway.stages.whenIdle,
        _idle?.future ?? Future<void>.value(),
      ]).then((_) {});

  static const _routes = <CapabilityId>[
    ExternalCapabilities.listTargets,
    ExternalCapabilities.createReadContext,
    ExternalCapabilities.searchQuestions,
    ExternalCapabilities.getQuestionDetail,
    ExternalCapabilities.listFileSelections,
    ExternalCapabilities.createFileContext,
    ExternalCapabilities.retrieveFileContent,
    ExternalCapabilities.getFilePassage,
    ExternalCapabilities.stage,
    ExternalCapabilities.reconcile,
  ];
  static final _denied = CapabilityContext(
      principal: CapabilityPrincipal.denied,
      capabilities: const [],
      permissions: const [],
      scope: ConversationScope.global(),
      authorizedScope: ConversationScope.global());

  bool get _ready {
    try {
      if (_state != LocalHostState.ready ||
          _generation != _gateway.admission.trust.generation ||
          !_readiness.isCurrent) {
        return false;
      }
      _gateway.admission.validate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _requireReady() {
    if (!_ready) {
      throw const LocalHostAdmissionException(
          CapabilityFailure.temporarilyUnavailable);
    }
  }

  /// Explicit offline startup. These checks cannot authenticate or enable a
  /// Profile. Startup is one-shot; replacement requires a fresh composition.
  Future<void> startOffline() {
    if (_state != LocalHostState.disabled) {
      throw const LocalHostAdmissionException(
          CapabilityFailure.temporarilyUnavailable);
    }
    _state = LocalHostState.starting;
    _generation = _gateway.admission.trust.generation;
    return _track(() async {
      try {
        await _readiness.ensureDatabaseReady();
        _checkStartup();
        await _readiness.ensureRecoveryComplete();
        _checkStartup();
        await _readiness.ensureModulesAndRoutesReady();
        _checkStartup();
        final definitions = _gateway.executor.registry.definitions;
        if (definitions.length != _routes.length ||
            definitions.any((definition) =>
                !_routes.contains(definition.id) ||
                (definition.permission != CapabilityPermission.read &&
                    definition.permission != CapabilityPermission.stage))) {
          throw const LocalHostAdmissionException(
              CapabilityFailure.temporarilyUnavailable);
        }
        _state = LocalHostState.ready;
      } catch (_) {
        if (_state == LocalHostState.starting) _state = LocalHostState.stopped;
        throw const LocalHostAdmissionException(
            CapabilityFailure.temporarilyUnavailable);
      }
    });
  }

  void _checkStartup() {
    if (_state != LocalHostState.starting ||
        _generation != _gateway.admission.trust.generation ||
        !_readiness.isCurrent) {
      throw const LocalHostAdmissionException(
          CapabilityFailure.temporarilyUnavailable);
    }
    _gateway.admission.validate();
  }

  Future<LocalHostSessionEntry> bindSession(ExternalSession session) {
    _requireReady();
    return _track(() async {
      try {
        final access = await _gateway.admission.admit(session);
        _requireReady();
        access.validate();
        final grant = access.grantSnapshot;
        if (grant == null || grant.revokedAtUtcMs != null) {
          throw const LocalHostAdmissionException(
              CapabilityFailure.accessDenied);
        }
        return LocalHostSessionEntry._(this, session, grant.revision);
      } catch (_) {
        throw const LocalHostAdmissionException(CapabilityFailure.accessDenied);
      }
    });
  }

  bool _entryIsCurrent(LocalHostSessionEntry? entry) {
    if (!_ready || entry == null || !identical(entry._owner, this)) {
      return false;
    }
    try {
      _gateway.admission.validateSession(entry._session);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _admitEntry(LocalHostSessionEntry entry) async {
    if (!_entryIsCurrent(entry)) {
      throw const LocalHostAdmissionException(CapabilityFailure.accessDenied);
    }
    final access = await _gateway.admission.admit(entry._session);
    final grant = access.grantSnapshot;
    if (!_entryIsCurrent(entry) ||
        grant == null ||
        grant.revokedAtUtcMs != null ||
        grant.revision != entry._grantRevision) {
      throw const LocalHostAdmissionException(CapabilityFailure.accessDenied);
    }
  }

  Future<ExternalExecutionContext> _open(LocalHostSessionEntry entry,
          Future<ExternalExecutionContext> Function() mint) =>
      _track(() async {
        try {
          await _admitEntry(entry);
          final context = await mint();
          if (!_entryIsCurrent(entry) ||
              context.authorization.revision != entry._grantRevision) {
            throw const LocalHostAdmissionException(
                CapabilityFailure.accessDenied);
          }
          return context;
        } catch (_) {
          throw const LocalHostAdmissionException(
              CapabilityFailure.accessDenied);
        }
      });

  Future<ExternalExecutionContext> openRead(LocalHostSessionEntry entry,
          {String? context}) =>
      _open(entry,
          () => _gateway.openRead(session: entry._session, context: context));

  Future<ExternalExecutionContext> openStage(
          LocalHostSessionEntry entry, ExternalStageContext context) =>
      _open(entry,
          () => _gateway.openStage(session: entry._session, context: context));

  Future<ExternalExecutionContext> openReconciliation(
          LocalHostSessionEntry entry, String submissionKey) =>
      _open(
          entry,
          () => _gateway.openReconciliation(
              session: entry._session, submissionKey: submissionKey));

  /// The typed allowlist is not a string/Map executor. P7 alone owns handler
  /// admission, current authorization, effect evidence and final data release.
  Future<CapabilityResult<O>> dispatch<I, O>(CapabilityId<I, O> id, I input,
      {required LocalHostSessionEntry? entry,
      required ExternalExecutionContext context,
      ExternalCallControl? control,
      bool Function()? responseAvailable}) {
    CapabilityResult<O> reject(CapabilityFailure failure) =>
        _gateway.executor.reject(
            _routes.contains(id)
                ? id
                : CapabilityId<I, O>('local_host_rejected'),
            _denied,
            failure);
    if (!_ready) {
      return Future.value(reject(CapabilityFailure.temporarilyUnavailable));
    }
    if (!_routes.contains(id)) {
      final knownName = _routes.any((route) => route.value == id.value);
      return Future.value(reject(knownName
          ? CapabilityFailure.invalidRequest
          : CapabilityFailure.unknownCapability));
    }
    if (!_entryIsCurrent(entry) ||
        context.authorization.revision != entry!._grantRevision) {
      return Future.value(reject(CapabilityFailure.accessDenied));
    }
    return _track(() => _gateway.execute(id, input,
        session: entry._session,
        context: context,
        control: control,
        responseAvailable: () =>
            _entryIsCurrent(entry) && (responseAvailable?.call() ?? true)));
  }

  Future<T> _track<T>(Future<T> Function() work) async {
    if (_pending++ == 0) _idle = Completer<void>();
    try {
      return await work();
    } finally {
      if (--_pending == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// Reject new calls immediately; wait for real owning work, including work
  /// that outlived a caller deadline. Await before B0 swap/runtime replacement.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _state = LocalHostState.stopping;
    _gateway.close();
    _gateway.reads.close();
    _gateway.stages.close();
    return _shutdown = _drain();
  }

  Future<void> _drain() async {
    await Future.wait([
      _gateway.whenIdle,
      _gateway.reads.whenIdle,
      _gateway.stages.whenIdle,
      _idle?.future ?? Future<void>.value(),
    ]);
    _state = LocalHostState.stopped;
  }
}
