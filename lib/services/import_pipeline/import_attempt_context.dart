import 'dart:async';
import 'dart:math';

enum ImportAttemptState {
  queued,
  running,
  cancelRequested,
  cancelled,
  readyForReview,
  failed,
  interrupted,
}

class ImportAttemptRef {
  const ImportAttemptRef({
    required this.taskId,
    required this.attemptNumber,
    required this.attemptToken,
    required this.traceId,
  });

  final String taskId;
  final int attemptNumber;
  final String attemptToken;
  final String traceId;
}

abstract final class ImportAttemptContext {
  static const Symbol _attemptKey = #shirohaImportAttempt;

  static ImportAttemptRef? get current =>
      Zone.current[_attemptKey] as ImportAttemptRef?;

  static Future<T> run<T>({
    required ImportAttemptRef attempt,
    required Future<T> Function() action,
  }) {
    return runZoned(
      action,
      zoneValues: <Object?, Object?>{_attemptKey: attempt},
    );
  }
}

abstract final class ImportAttemptToken {
  static final Random _random = Random.secure();

  static String create() {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final entropy = _random.nextInt(0x7fffffff).toRadixString(16);
    return 'attempt-$timestamp-$entropy';
  }
}
