import 'dart:async';
import 'dart:collection';

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
  int _activeCount = 0;

  Future<T> run<T>({
    required String taskId,
    required Future<T> Function() operation,
  }) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'must not be empty');
    }

    final completer = Completer<T>();
    _pending.add(
      _QueuedOcrRequest(
        operation: operation,
        complete: (value) => completer.complete(value as T),
        completeError: completer.completeError,
      ),
    );
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_activeCount < maxConcurrentRequests && _pending.isNotEmpty) {
      _start(_pending.removeFirst());
    }
  }

  void _start(_QueuedOcrRequest request) {
    _activeCount++;
    Future<Object?>.sync(request.operation).then<void>(
      (value) {
        _release();
        request.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        _release();
        request.completeError(error, stackTrace);
      },
    );
  }

  void _release() {
    _activeCount--;
    _drain();
  }
}

class _QueuedOcrRequest {
  const _QueuedOcrRequest({
    required this.operation,
    required this.complete,
    required this.completeError,
  });

  final Future<Object?> Function() operation;
  final void Function(Object? value) complete;
  final void Function(Object error, StackTrace stackTrace) completeError;
}
