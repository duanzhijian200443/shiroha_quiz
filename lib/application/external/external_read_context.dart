import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../domain/generated_question/generated_question_contract.dart';
import 'external_authorization.dart';
import 'external_invocation_core.dart';
import 'external_question_read.dart';
import 'external_runtime_admission.dart';
import 'external_trust_core.dart';

enum ExternalReadFailure {
  denied,
  stale,
  resourceLimit,
  cancelled,
  deadlineExceeded,
  unavailable,
  invalidRequest,
  dataCorrupt
}

final class ExternalReadException implements Exception {
  const ExternalReadException(this.failure);
  final ExternalReadFailure failure;
  @override
  String toString() => 'ExternalReadException(${failure.name})';
}

Never externalReadFail(ExternalReadFailure failure) =>
    throw ExternalReadException(failure);

/// Internal authorized target snapshot, never a request-supplied authority.
final class ExternalReadTarget {
  const ExternalReadTarget(this.bankName, this.projectId, this.folderName);
  final String bankName;
  final String? projectId, folderName;
  ExternalGrantScope get scope => ExternalGrantScope(
      kind: ExternalTargetKind.bank, targetId: bankName, projectId: projectId);
  @override
  bool operator ==(Object other) =>
      other is ExternalReadTarget &&
      bankName == other.bankName &&
      projectId == other.projectId &&
      folderName == other.folderName;
  @override
  int get hashCode => Object.hash(bankName, projectId, folderName);
}

final class ExternalReadSnapshot {
  ExternalReadSnapshot(this.grant, Iterable<ExternalReadTarget> targets)
      : targets = List.unmodifiable(targets);
  final ExternalGrant grant;
  final List<ExternalReadTarget> targets;
}

/// Data loads only current explicitly granted bank scopes, in a read transaction.
/// check must run across awaits and immediately before returning any result.
abstract interface class ExternalTargetReadPort {
  Future<ExternalReadSnapshot> query(ExternalRuntimeAccess access,
      int? expectedRevision, void Function() check);
}

/// Exactly the four frozen fields; no internal authority or global counts.
final class ExternalTargetMetadata {
  ExternalTargetMetadata._(this.targetRef, ExternalReadTarget target)
      : bankName = target.bankName,
        projectId = target.projectId,
        folderName = target.folderName;
  final String targetRef, bankName;
  final String? projectId, folderName;
  Map<String, Object?> toJson() => {
        'targetRef': targetRef,
        'bankName': bankName,
        'projectId': projectId,
        'folderName': folderName,
      };
}

final class ExternalTargetPage {
  ExternalTargetPage._(Iterable<ExternalTargetMetadata> items, this.nextCursor)
      : items = List.unmodifiable(items);
  final List<ExternalTargetMetadata> items;
  final String? nextCursor;
  Map<String, Object?> toJson() => {
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

enum ExternalReadValidity { authorized, invalid, unavailable }

enum _HandleKind { target, cursor, context, question, questionCursor }

final class _Handle {
  _Handle(this.kind, this.access, this.snapshot, this.createdAt, this.expiresAt,
      {this.target,
      this.offset = 0,
      this.parentContext,
      this.questionKey,
      this.query});
  final _HandleKind kind;
  final ExternalRuntimeAccess access;
  final ExternalReadSnapshot snapshot;
  final DateTime createdAt, expiresAt;
  final ExternalReadTarget? target;
  final int offset;
  final _Handle? parentContext;
  final ExternalQuestionKey? questionKey;
  final String? query;
  // This candidate authorizes no source files/evidence. Empty is intentional;
  // future source reads must add their own current file scope/Egress checks.
  final List<GeneratedEvidence> approvedEvidence = const [];
  final Set<String> approvedFileIds = const {};
}

/// Context-minted Data proof; no public constructor or wire decoder. Current
/// durable authorization is still checked by the owning Data transaction.
final class ExternalQuestionReadAccess {
  ExternalQuestionReadAccess._(this._owner, this.runtime, this._context);
  final ExternalReadContextService _owner;
  final ExternalRuntimeAccess runtime;
  final _Handle _context;
  ExternalReadTarget get target => _context.target!;
  int get revision => _context.snapshot.grant.revision;
  void validate() {
    runtime.validate();
    _context.access.validate();
    if (_owner._closed ||
        !_owner._handles.values.contains(_context) ||
        !_owner.admission.trust.clock.now().isBefore(_context.expiresAt)) {
      externalReadFail(ExternalReadFailure.denied);
    }
  }
}

/// Unpublished Application-only READ foundation. No Host, MCP or STAGE route.
/// Uses P3's admission instance; handles never reconstruct authentication.
final class ExternalReadContextService {
  ExternalReadContextService({
    required this.admission,
    required ExternalTargetReadPort targets,
    ExternalQuestionReadPort? questions,
    this.maxActiveHandles = 256,
    this.maxHandlesPerProfile = 160,
    this.maxContexts = 64,
    this.maxContextsPerProfile = 16,
    this.maxInFlight = 16,
    this.maxInFlightPerProfile = 4,
    this.maxResponseBytes = 32768,
    this.maxQueryDuration = const Duration(seconds: 2),
    this.contextLifetime = const Duration(minutes: 15),
  })  : _targets = targets,
        _questions = questions {
    if ([
          maxActiveHandles,
          maxHandlesPerProfile,
          maxContexts,
          maxContextsPerProfile,
          maxInFlight,
          maxInFlightPerProfile,
          maxResponseBytes
        ].any((n) => n < 1) ||
        maxQueryDuration <= Duration.zero ||
        maxQueryDuration > const Duration(seconds: 2) ||
        contextLifetime <= Duration.zero ||
        contextLifetime > const Duration(minutes: 15)) {
      throw ArgumentError('Invalid READ candidate bounds');
    }
    if (questions != null &&
        (maxActiveHandles > 256 ||
            maxHandlesPerProfile > 160 ||
            maxContexts > 64 ||
            maxContextsPerProfile > 16 ||
            maxInFlight > 16 ||
            maxInFlightPerProfile > 4 ||
            maxResponseBytes > 32768)) {
      throw ArgumentError('Invalid Question READ candidate bounds');
    }
    admission.onClose(close);
    _cleanup = Timer.periodic(const Duration(seconds: 30), (_) => sweep());
  }

  final ExternalRuntimeAdmission admission;
  final ExternalTargetReadPort _targets;
  final ExternalQuestionReadPort? _questions;
  final int maxActiveHandles,
      maxHandlesPerProfile,
      maxContexts,
      maxContextsPerProfile,
      maxInFlight,
      maxInFlightPerProfile,
      maxResponseBytes;
  final Duration maxQueryDuration, contextLifetime;
  final _random = Random.secure();
  final _handles = <String, _Handle>{};
  final _pending = <String, int>{};
  Timer? _cleanup;
  bool _closed = false;
  Completer<void>? _idle;
  int get activeHandleCount => _handles.length;
  int get pendingCount => _pending.values.fold(0, (a, b) => a + b);
  Future<void> get whenIdle => _idle?.future ?? Future.value();

  void close() {
    _closed = true;
    _cleanup?.cancel();
    _handles.clear();
    admission.removeOnClose(close);
  }

  /// Periodic bounded cleanup; also called before every admission/mint.
  void sweep() {
    _handles.removeWhere((_, handle) {
      if (!admission.trust.clock.now().isBefore(handle.expiresAt)) return true;
      try {
        handle.access.validate();
        return false;
      } catch (_) {
        return true;
      }
    });
    _handles.removeWhere((_, handle) =>
        handle.parentContext != null &&
        !_handles.values.contains(handle.parentContext));
  }

  _Handle _lookup(
      String token, _HandleKind kind, ExternalRuntimeAccess access) {
    if (token.length != 43) externalReadFail(ExternalReadFailure.denied);
    final handle = _handles[token];
    if (handle == null ||
        handle.kind != kind ||
        !identical(handle.access.session.principal, access.session.principal) ||
        handle.access.generation != access.generation) {
      externalReadFail(ExternalReadFailure.denied);
    }
    handle.access.validate();
    if (!admission.trust.clock.now().isBefore(handle.expiresAt)) {
      _handles.remove(token);
      externalReadFail(ExternalReadFailure.stale);
    }
    return handle;
  }

  String _mint(_Handle handle, List<String> allocations) {
    sweep();
    final owned = _handles.values.where((h) =>
        identical(h.access.session.principal, handle.access.session.principal));
    if (_handles.length >= maxActiveHandles ||
        owned.length >= maxHandlesPerProfile ||
        (handle.kind == _HandleKind.context &&
            (_handles.values
                        .where((h) => h.kind == _HandleKind.context)
                        .length >=
                    maxContexts ||
                owned.where((h) => h.kind == _HandleKind.context).length >=
                    maxContextsPerProfile))) {
      externalReadFail(ExternalReadFailure.resourceLimit);
    }
    String token;
    do {
      token = base64UrlEncode(List.generate(32, (_) => _random.nextInt(256)))
          .replaceAll('=', '');
    } while (_handles.containsKey(token));
    _handles[token] = handle;
    allocations.add(token);
    return token;
  }

  bool _same(ExternalReadSnapshot a, ExternalReadSnapshot b) =>
      a.grant.revision == b.grant.revision &&
      a.targets.length == b.targets.length &&
      Iterable.generate(a.targets.length)
          .every((i) => a.targets[i] == b.targets[i]);

  Future<ExternalTargetPage> listTargets(
          {required ExternalSession session,
          int pageSize = 20,
          String? cursor,
          ExternalCallControl? control}) =>
      _run(session, control, (access, check, allocations) async {
        if (pageSize < 1 || pageSize > 50) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        final previous =
            cursor == null ? null : _lookup(cursor, _HandleKind.cursor, access);
        final snapshot = await _targets.query(
            access, previous?.snapshot.grant.revision, check);
        if (previous != null && !_same(previous.snapshot, snapshot)) {
          _handles.remove(cursor);
          externalReadFail(ExternalReadFailure.stale);
        }
        final offset = previous?.offset ?? 0;
        final end = min(snapshot.targets.length, offset + pageSize);
        final selected = snapshot.targets.sublist(offset, end);
        // Recheck current policy/relations after all awaited work, before mint/output.
        final release =
            await _targets.query(access, snapshot.grant.revision, check);
        if (!_same(snapshot, release)) {
          externalReadFail(ExternalReadFailure.stale);
        }
        check();
        final now = admission.trust.clock.now();
        final items = <ExternalTargetMetadata>[];
        for (final target in selected) {
          final ref = _mint(
              _Handle(_HandleKind.target, access, snapshot, now,
                  now.add(contextLifetime),
                  target: target),
              allocations);
          items.add(ExternalTargetMetadata._(ref, target));
        }
        String? next;
        if (end < snapshot.targets.length) {
          next = _mint(
              _Handle(_HandleKind.cursor, access, snapshot, now,
                  now.add(contextLifetime),
                  offset: end),
              allocations);
        }
        final page = ExternalTargetPage._(items, next);
        if (utf8.encode(jsonEncode(page.toJson())).length > maxResponseBytes) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        check();
        return page;
      });

  /// Accepts only an App-minted selection reference, never a bank/Profile id.
  Future<String> createContext(
          {required ExternalSession session,
          required String targetRef,
          ExternalCallControl? control}) =>
      _run(session, control, (access, check, allocations) async {
        final selected = _lookup(targetRef, _HandleKind.target, access);
        final current = await _targets.query(
            access, selected.snapshot.grant.revision, check);
        if (!current.targets.contains(selected.target)) {
          externalReadFail(ExternalReadFailure.stale);
        }
        check();
        if (maxResponseBytes < 43) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        final now = admission.trust.clock.now();
        return _mint(
            _Handle(_HandleKind.context, access, current, now,
                now.add(contextLifetime),
                target: selected.target),
            allocations);
      });

  Future<ExternalReadValidity> contextStatus(
      {required ExternalSession session,
      required String context,
      ExternalCallControl? control}) async {
    try {
      return await _run(session, control, (access, check, allocations) async {
        final handle = _lookup(context, _HandleKind.context, access);
        final current =
            await _targets.query(access, handle.snapshot.grant.revision, check);
        if (!current.targets.contains(handle.target)) {
          _handles.remove(context);
          externalReadFail(ExternalReadFailure.stale);
        }
        check();
        return ExternalReadValidity.authorized;
      });
    } on ExternalReadException catch (e) {
      return e.failure == ExternalReadFailure.unavailable ||
              e.failure == ExternalReadFailure.resourceLimit
          ? ExternalReadValidity.unavailable
          : ExternalReadValidity.invalid;
    }
  }

  /// Single Context target only. Cursor/QuestionRefs share the original registry
  /// and its capacity; they never prolong or expand the owning Context.
  Future<ExternalQuestionSearchPage> searchQuestions({
    required ExternalSession session,
    required String context,
    required String query,
    String? cursor,
    int pageSize = 20,
    ExternalCallControl? control,
  }) =>
      _run(session, control, (runtime, check, allocations) async {
        final handle = _lookup(context, _HandleKind.context, runtime);
        if (query.isEmpty ||
            query.length > 200 ||
            query.trim().isEmpty ||
            pageSize < 1 ||
            pageSize > 50) {
          externalReadFail(ExternalReadFailure.invalidRequest);
        }
        final normalized = query.trim().toLowerCase();
        final previous = cursor == null
            ? null
            : _lookup(cursor, _HandleKind.questionCursor, runtime);
        if (previous != null &&
            (!identical(previous.parentContext, handle) ||
                previous.query != normalized)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final port =
            _questions ?? (externalReadFail(ExternalReadFailure.unavailable));
        final access = ExternalQuestionReadAccess._(this, runtime, handle);
        access.validate();
        final page = await port.search(
            access, normalized, pageSize, previous?.questionKey, check);
        check();
        access.validate();
        await port.release(
            access,
            [
              for (final item in page.items) item.key,
              if (page.nextKey != null &&
                  !page.items.any((i) => i.key == page.nextKey))
                page.nextKey!
            ],
            check);
        check();
        access.validate();
        final now = admission.trust.clock.now();
        final items = <ExternalQuestionHit>[];
        for (final item in page.items) {
          final ref = _mint(
              _Handle(_HandleKind.question, runtime, handle.snapshot, now,
                  handle.expiresAt,
                  target: handle.target,
                  parentContext: handle,
                  questionKey: item.key),
              allocations);
          items.add(ExternalQuestionHit.project(ref, item.summary));
        }
        final next = page.nextKey == null
            ? null
            : _mint(
                _Handle(_HandleKind.questionCursor, runtime, handle.snapshot,
                    now, handle.expiresAt,
                    target: handle.target,
                    parentContext: handle,
                    questionKey: page.nextKey,
                    query: normalized),
                allocations);
        final result = ExternalQuestionSearchPage(items, next);
        if (utf8.encode(jsonEncode(result.toJson())).length >
            maxResponseBytes) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        check();
        access.validate();
        return result;
      });

  Future<ExternalQuestionDetail> getQuestionDetail({
    required ExternalSession session,
    required String context,
    required String questionRef,
    ExternalCallControl? control,
  }) =>
      _run(session, control, (runtime, check, allocations) async {
        final handle = _lookup(context, _HandleKind.context, runtime);
        final selected = _lookup(questionRef, _HandleKind.question, runtime);
        if (!identical(selected.parentContext, handle)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final port =
            _questions ?? (externalReadFail(ExternalReadFailure.unavailable));
        final access = ExternalQuestionReadAccess._(this, runtime, handle);
        access.validate();
        final detail = await port.detail(access, selected.questionKey!, check);
        check();
        if (utf8.encode(jsonEncode(detail.toJson())).length >
            maxResponseBytes) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        await port.release(access, [selected.questionKey!], check);
        check();
        access.validate();
        return detail;
      });

  Future<T> _run<T>(
      ExternalSession session,
      ExternalCallControl? control,
      Future<T> Function(ExternalRuntimeAccess, void Function(), List<String>)
          operation) async {
    try {
      if (_closed) externalReadFail(ExternalReadFailure.denied);
      admission.validateSession(session);
      sweep();
      if (pendingCount >= maxInFlight ||
          (_pending[session.principal.profileId] ?? 0) >=
              maxInFlightPerProfile) {
        externalReadFail(ExternalReadFailure.resourceLimit);
      }
    } on ExternalAuthException {
      externalReadFail(ExternalReadFailure.denied);
    }
    final id = session.principal.profileId;
    if (pendingCount == 0) _idle = Completer<void>();
    _pending[id] = (_pending[id] ?? 0) + 1;
    final stopped = Completer<T>();
    final allocations = <String>[];
    bool released = false;
    bool abandoned = false;
    final watch = Stopwatch()..start();
    final deadline = admission.trust.clock.now().add(maxQueryDuration);
    void check() {
      if (_closed || abandoned) externalReadFail(ExternalReadFailure.denied);
      admission.validateSession(session);
      final interruption = control?.failure;
      if (interruption != null) {
        externalReadFail(interruption == ExternalFailure.cancelled
            ? ExternalReadFailure.cancelled
            : ExternalReadFailure.deadlineExceeded);
      }
      if (watch.elapsed >= maxQueryDuration ||
          !admission.trust.clock.now().isBefore(deadline)) {
        externalReadFail(ExternalReadFailure.deadlineExceeded);
      }
    }

    void stop(ExternalReadFailure failure) {
      abandoned = true;
      if (!stopped.isCompleted) {
        stopped.completeError(ExternalReadException(failure));
      }
    }

    final timer = Timer(
        maxQueryDuration, () => stop(ExternalReadFailure.deadlineExceeded));
    control?.interrupted.then((failure) {
      if (watch.isRunning) {
        stop(failure == ExternalFailure.cancelled
            ? ExternalReadFailure.cancelled
            : ExternalReadFailure.deadlineExceeded);
      }
    });
    final pending = () async {
      try {
        check();
        final access = await admission.admit(session);
        check();
        final result = await operation(access, check, allocations);
        check();
        released = true;
        return result;
      } on ExternalReadException {
        rethrow;
      } on ExternalAuthException {
        externalReadFail(ExternalReadFailure.denied);
      } catch (_) {
        externalReadFail(ExternalReadFailure.unavailable);
      } finally {
        if (!released) {
          for (final token in allocations) {
            _handles.remove(token);
          }
        }
        timer.cancel();
        watch.stop();
        final count = _pending[id]! - 1;
        if (count == 0) {
          _pending.remove(id);
        } else {
          _pending[id] = count;
        }
        if (pendingCount == 0) {
          _idle?.complete();
          _idle = null;
        }
      }
    }();
    return Future.any([pending, stopped.future]);
  }
}
