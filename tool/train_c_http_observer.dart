// Safe request/phase accounting for the TRAIN C offline harness.
//
// This file deliberately contains no HTTP client wrapper. The transparent
// dart:io interception lives in [train_c_http_overrides.dart] and delegates
// to the production-created client so it cannot replace production transport
// policy.

import 'train_c_live_attempt_authority.dart';

enum TrainCPhase {
  preflight,
  parse,
  pendingReview,
  commit,
  restart,
  backupExport,
  restore,
  complete,
}

extension TrainCPhaseX on TrainCPhase {
  String get wireName => switch (this) {
        TrainCPhase.preflight => 'preflight',
        TrainCPhase.parse => 'parse',
        TrainCPhase.pendingReview => 'pendingReview',
        TrainCPhase.commit => 'commit',
        TrainCPhase.restart => 'restart',
        TrainCPhase.backupExport => 'backupExport',
        TrainCPhase.restore => 'restore',
        TrainCPhase.complete => 'complete',
      };
}

enum TrainCRequestKind { layoutPost, remoteCropGet, unexpected }

extension TrainCRequestKindX on TrainCRequestKind {
  String get wireName => switch (this) {
        TrainCRequestKind.layoutPost => 'layout_post',
        TrainCRequestKind.remoteCropGet => 'remote_crop_get',
        TrainCRequestKind.unexpected => 'unexpected',
      };
}

/// Fixed safe error categories used by the harness protocol.
final class TrainCProtocolException implements Exception {
  const TrainCProtocolException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class _TrainCNetworkEvent {
  _TrainCNetworkEvent({required this.kind, required this.phase});

  final TrainCRequestKind kind;
  final TrainCPhase phase;
  String statusCategory = 'dispatched';
  int durationMs = 0;
}

/// Frozen production request authority. CI cross-checks this value against the
/// default [ZhipuOcrClient] constructor so trusted acceptance cannot let the
/// evidence producer choose its own page chunk.
const int trainCProductionPdfPageChunkSize = 30;

/// Computes expected layout requests from the production chunk size.
///
/// [pageChunkSize] is retained only as an observed/reported value for the
/// evidence schema. It is deliberately not an authority for the calculation.
int trainCExpectedLayoutRequestCount({
  required int pageCount,
  required int pageChunkSize,
}) {
  if (pageCount <= 0 || pageChunkSize <= 0) {
    throw const TrainCProtocolException('TRAIN_C_INPUT_INVALID');
  }
  return (pageCount + trainCProductionPdfPageChunkSize - 1) ~/
      trainCProductionPdfPageChunkSize;
}

/// In-memory request/phase ledger for the TRAIN C entrypoint.
///
/// The ledger observes only HTTP method, safe status category and timing. It
/// never reads a request URI, request body, response body or exception detail.
/// It is a guard around the production entrypoint, not a second OCR transport.
final class TrainCRequestLedger {
  TrainCRequestLedger({this.attemptAuthority, this.providerDisabled = false});

  final TrainCLiveAttemptAuthority? attemptAuthority;
  final bool providerDisabled;

  TrainCPhase _phase = TrainCPhase.preflight;
  int? _expectedLayoutRequests;
  int _layoutPostCount = 0;
  int _remoteCropRequestCount = 0;
  int _unexpectedProviderRequestCount = 0;
  int _providerResponseCount = 0;
  int _networkFailureCount = 0;
  bool _attemptConsumed = false;
  final List<_TrainCNetworkEvent> _events = <_TrainCNetworkEvent>[];
  final Map<String, int> _responseStatusCounts = <String, int>{};

  TrainCPhase get phase => _phase;
  bool get attemptConsumed => _attemptConsumed;
  int get layoutPostCount => _layoutPostCount;
  int get remoteCropRequestCount => _remoteCropRequestCount;
  int get unexpectedProviderRequestCount => _unexpectedProviderRequestCount;
  int get providerResponseCount => _providerResponseCount;
  int get networkFailureCount => _networkFailureCount;
  int get providerDispatchCount =>
      _layoutPostCount +
      _remoteCropRequestCount +
      _unexpectedProviderRequestCount;

  /// Opens the one and only live parse window.
  void beginParse({required int expectedLayoutRequests}) {
    if (_phase != TrainCPhase.preflight || _attemptConsumed) {
      throw const TrainCProtocolException('TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED');
    }
    if (expectedLayoutRequests <= 0) {
      throw const TrainCProtocolException('TRAIN_C_INPUT_INVALID');
    }
    attemptAuthority?.assertParseAllowed();
    attemptAuthority?.markParseRunning();
    _expectedLayoutRequests = expectedLayoutRequests;
    _phase = TrainCPhase.parse;
  }

  /// Closes the parse window without permitting an implicit retry.
  void finishParse({required bool successful}) {
    if (_phase != TrainCPhase.parse) {
      throw const TrainCProtocolException('TRAIN_C_HARNESS_NOT_READY');
    }
    if (successful) {
      if (_layoutPostCount != _expectedLayoutRequests) {
        throw const TrainCProtocolException(
          'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
        );
      }
      if (_providerResponseCount != providerDispatchCount ||
          _networkFailureCount != 0) {
        throw const TrainCProtocolException(
          'TRAIN_C_PROVIDER_RESPONSE_RESOURCE_FAILURE',
        );
      }
    }
    _phase = successful ? TrainCPhase.pendingReview : TrainCPhase.complete;
  }

  /// Enters a post-parse phase. Provider dispatch is rejected in all of them.
  void enterPhase(TrainCPhase next) {
    final allowed = switch ((_phase, next)) {
      (TrainCPhase.pendingReview, TrainCPhase.commit) => true,
      (TrainCPhase.commit, TrainCPhase.restart) => true,
      (TrainCPhase.restart, TrainCPhase.backupExport) => true,
      (TrainCPhase.backupExport, TrainCPhase.restore) => true,
      (TrainCPhase.restore, TrainCPhase.complete) => true,
      _ => false,
    };
    if (!allowed) {
      throw const TrainCProtocolException('TRAIN_C_HARNESS_NOT_READY');
    }
    _phase = next;
  }

  TrainCRequestKind classifyMethod(String method) {
    return switch (method.toUpperCase()) {
      'POST' => TrainCRequestKind.layoutPost,
      'GET' => TrainCRequestKind.remoteCropGet,
      _ => TrainCRequestKind.unexpected,
    };
  }

  int recordDispatchMethod(String method) {
    return recordDispatch(classifyMethod(method));
  }

  int recordDispatch(TrainCRequestKind kind) {
    if (providerDisabled) {
      throw const TrainCProtocolException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
    }
    if (_phase != TrainCPhase.parse) {
      _unexpectedProviderRequestCount++;
      throw const TrainCProtocolException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
    }
    if (kind == TrainCRequestKind.unexpected) {
      _unexpectedProviderRequestCount++;
      throw const TrainCProtocolException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
    }
    if (kind == TrainCRequestKind.layoutPost &&
        _layoutPostCount >= (_expectedLayoutRequests ?? 0)) {
      throw const TrainCProtocolException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
    }

    // Run #1 is consumed durably by the first legitimate provider dispatch.
    // Later requests that belong to this already-open parse window are still
    // part of the same Run and remain bounded by this ledger's phase/request
    // contract. A fresh ledger/process must pass assertParseAllowed() again,
    // which fails once the durable capability is CONSUMED.
    if (!_attemptConsumed) {
      attemptAuthority?.consumeAtDispatch();
      _attemptConsumed = true;
    }
    if (kind == TrainCRequestKind.layoutPost) {
      _layoutPostCount++;
    } else {
      _remoteCropRequestCount++;
    }
    _events.add(_TrainCNetworkEvent(kind: kind, phase: _phase));
    return _events.length - 1;
  }

  void recordResponse({
    required int eventIndex,
    required int statusCode,
    required int durationMs,
  }) {
    final event = _eventAt(eventIndex);
    event.statusCategory = _statusCategory(statusCode);
    event.durationMs = durationMs < 0 ? 0 : durationMs;
    _providerResponseCount++;
    _responseStatusCounts.update(
      event.statusCategory,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  void recordNetworkFailure({
    required int eventIndex,
    required int durationMs,
  }) {
    final event = _eventAt(eventIndex);
    event.statusCategory = 'network_failure';
    event.durationMs = durationMs < 0 ? 0 : durationMs;
    _networkFailureCount++;
  }

  Map<String, Object?> safeSummary() {
    return <String, Object?>{
      'phase': _phase.wireName,
      'attemptConsumed': _attemptConsumed,
      'layoutPostCount': _layoutPostCount,
      'providerDispatchCount': providerDispatchCount,
      'providerResponseCount': _providerResponseCount,
      'remoteCropRequestCount': _remoteCropRequestCount,
      'unexpectedProviderRequestCount': _unexpectedProviderRequestCount,
      'networkFailureCount': _networkFailureCount,
      'eventCount': _events.length,
      'responseStatusCounts': Map<String, int>.unmodifiable(
        _responseStatusCounts,
      ),
    };
  }

  _TrainCNetworkEvent _eventAt(int eventIndex) {
    if (eventIndex < 0 || eventIndex >= _events.length) {
      throw const TrainCProtocolException('TRAIN_C_HARNESS_NOT_READY');
    }
    return _events[eventIndex];
  }

  static String _statusCategory(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) return 'success';
    if (statusCode >= 300 && statusCode < 400) return 'redirect';
    if (statusCode >= 400 && statusCode < 500) return 'client_error';
    if (statusCode >= 500 && statusCode < 600) return 'server_error';
    return 'other';
  }
}
