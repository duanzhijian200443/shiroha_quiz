// ignore_for_file: depend_on_referenced_packages

import 'package:http/http.dart' as http;

/// Production phases in which an OCR provider request is forbidden.
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

/// In-memory request/phase ledger for the TRAIN C entrypoint.
///
/// The ledger observes only HTTP method, safe status category and timing. It
/// deliberately never reads a request URL, request body, response body or
/// exception detail. It is a guard around the production entrypoint, not a
/// second implementation of OCR transport or image-budget policy.
final class TrainCRequestLedger {
  TrainCRequestLedger();

  TrainCPhase _phase = TrainCPhase.preflight;
  int? _expectedLayoutRequests;
  int _layoutPostCount = 0;
  int _remoteCropRequestCount = 0;
  int _unexpectedProviderRequestCount = 0;
  int _providerResponseCount = 0;
  bool _attemptConsumed = false;
  final List<_TrainCNetworkEvent> _events = <_TrainCNetworkEvent>[];
  final Map<String, int> _responseStatusCounts = <String, int>{};

  TrainCPhase get phase => _phase;
  bool get attemptConsumed => _attemptConsumed;
  int get providerDispatchCount =>
      _layoutPostCount +
      _remoteCropRequestCount +
      _unexpectedProviderRequestCount;
  int get providerResponseCount => _providerResponseCount;
  int get remoteCropRequestCount => _remoteCropRequestCount;
  int get unexpectedProviderRequestCount => _unexpectedProviderRequestCount;

  /// Opens the one and only live parse window.
  void beginParse({required int expectedLayoutRequests}) {
    if (_phase != TrainCPhase.preflight || _attemptConsumed) {
      throw const TrainCProtocolException('TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED');
    }
    if (expectedLayoutRequests <= 0) {
      throw const TrainCProtocolException('TRAIN_C_INPUT_INVALID');
    }
    _expectedLayoutRequests = expectedLayoutRequests;
    _phase = TrainCPhase.parse;
  }

  /// Closes the parse window without permitting an implicit retry.
  void finishParse({required bool successful}) {
    if (_phase != TrainCPhase.parse) {
      throw const TrainCProtocolException('TRAIN_C_HARNESS_NOT_READY');
    }
    if (successful && _layoutPostCount != _expectedLayoutRequests) {
      throw const TrainCProtocolException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
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

  TrainCRequestKind classify(http.BaseRequest request) {
    return switch (request.method.toUpperCase()) {
      'POST' => TrainCRequestKind.layoutPost,
      'GET' => TrainCRequestKind.remoteCropGet,
      _ => TrainCRequestKind.unexpected,
    };
  }

  int recordDispatch(TrainCRequestKind kind) {
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

    _attemptConsumed = true;
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
  }

  Map<String, Object?> safeSummary() {
    return <String, Object?>{
      'phase': _phase.wireName,
      'attemptConsumed': _attemptConsumed,
      'providerDispatchCount': providerDispatchCount,
      'providerResponseCount': _providerResponseCount,
      'remoteCropRequestCount': _remoteCropRequestCount,
      'unexpectedProviderRequestCount': _unexpectedProviderRequestCount,
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

/// Transparent package:http wrapper for the production composition seam.
///
/// It observes headers only. Stream ownership and response-body handling stay
/// entirely with the production client.
final class TrainCHttpObserver extends http.BaseClient {
  TrainCHttpObserver({
    required http.Client innerClient,
    required TrainCRequestLedger ledger,
  })  : _innerClient = innerClient,
        _ledger = ledger;

  final http.Client _innerClient;
  final TrainCRequestLedger _ledger;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final eventIndex = _ledger.recordDispatch(_ledger.classify(request));
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _innerClient.send(request);
      _ledger.recordResponse(
        eventIndex: eventIndex,
        statusCode: response.statusCode,
        durationMs: stopwatch.elapsedMilliseconds,
      );
      return response;
    } catch (_) {
      _ledger.recordNetworkFailure(
        eventIndex: eventIndex,
        durationMs: stopwatch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  @override
  void close() => _innerClient.close();
}
