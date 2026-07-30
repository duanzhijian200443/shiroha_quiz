import 'dart:async';
import 'dart:collection';

enum OcrRequestCancellation { notFound, queued, running }

class OcrRequestCancelledException implements Exception {
  const OcrRequestCancelledException();

  @override
  String toString() => 'OcrRequestCancelledException';
}

class OcrRequestScheduler {
  OcrRequestScheduler({
    this.maxConcurrentRequests = defaultMaxConcurrentRequests,
  }) {
    if (maxConcurrentRequests <= 0) {
      throw ArgumentError.value(
        maxConcurrentRequests,
        'maxConcurrentRequests',
        'must be greater than zero',
      );
    }
  }

  static const int defaultMaxConcurrentRequests = 2;

  final int maxConcurrentRequests;
  final Queue<_QueuedOcrRequest> _pending = Queue<_QueuedOcrRequest>();
  final List<_QueuedOcrRequest> _active = <_QueuedOcrRequest>[];
  int _activeCount = 0;

  Future<T> run<T>({
    required String taskId,
    String? attemptToken,
    required Future<T> Function() operation,
  }) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'must not be empty');
    }
    final safeAttemptToken = attemptToken?.trim();
    if (attemptToken != null && safeAttemptToken!.isEmpty) {
      throw ArgumentError.value(
        attemptToken,
        'attemptToken',
        'must not be empty',
      );
    }
    if (safeAttemptToken != null &&
        _containsAttempt(taskId, safeAttemptToken)) {
      throw StateError('Duplicate OCR attempt');
    }

    final completer = Completer<T>();
    _pending.add(
      _QueuedOcrRequest(
        taskId: taskId,
        attemptToken: safeAttemptToken,
        operation: operation,
        complete: (value) => completer.complete(value as T),
        completeError: completer.completeError,
      ),
    );
    _drain();
    return completer.future;
  }

  OcrRequestCancellation cancel({
    required String taskId,
    required String attemptToken,
  }) {
    final safeTaskId = taskId.trim();
    final safeAttemptToken = attemptToken.trim();
    if (safeTaskId.isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'must not be empty');
    }
    if (safeAttemptToken.isEmpty) {
      throw ArgumentError.value(
        attemptToken,
        'attemptToken',
        'must not be empty',
      );
    }

    _QueuedOcrRequest? queued;
    for (final request in _pending) {
      if (request.matches(safeTaskId, safeAttemptToken)) {
        queued = request;
        break;
      }
    }
    if (queued != null) {
      _pending.remove(queued);
      queued.completeCancelled();
      return OcrRequestCancellation.queued;
    }

    for (final request in _active) {
      if (request.matches(safeTaskId, safeAttemptToken)) {
        request.cancellationRequested = true;
        return OcrRequestCancellation.running;
      }
    }
    return OcrRequestCancellation.notFound;
  }

  bool _containsAttempt(String taskId, String attemptToken) {
    return _pending.any((request) => request.matches(taskId, attemptToken)) ||
        _active.any((request) => request.matches(taskId, attemptToken));
  }

  void _drain() {
    while (_activeCount < maxConcurrentRequests && _pending.isNotEmpty) {
      _start(_pending.removeFirst());
    }
  }

  void _start(_QueuedOcrRequest request) {
    _activeCount++;
    _active.add(request);
    Future<Object?>.sync(request.operation).then<void>(
      (value) {
        final cancelled = request.cancellationRequested;
        _release(request);
        if (cancelled) {
          request.completeCancelled();
        } else {
          request.complete(value);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        final cancelled = request.cancellationRequested;
        _release(request);
        if (cancelled) {
          request.completeCancelled(stackTrace);
        } else {
          request.completeError(error, stackTrace);
        }
      },
    );
  }

  void _release(_QueuedOcrRequest request) {
    _active.remove(request);
    _activeCount--;
    _drain();
  }
}

class _QueuedOcrRequest {
  _QueuedOcrRequest({
    required this.taskId,
    required this.attemptToken,
    required this.operation,
    required this.complete,
    required this.completeError,
  });

  final String taskId;
  final String? attemptToken;
  final Future<Object?> Function() operation;
  final void Function(Object? value) complete;
  final void Function(Object error, StackTrace stackTrace) completeError;
  bool cancellationRequested = false;

  bool matches(String candidateTaskId, String candidateAttemptToken) {
    return taskId == candidateTaskId && attemptToken == candidateAttemptToken;
  }

  void completeCancelled([StackTrace? stackTrace]) {
    completeError(
      const OcrRequestCancelledException(),
      stackTrace ?? StackTrace.current,
    );
  }
}
