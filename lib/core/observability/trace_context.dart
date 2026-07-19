import 'dart:async';
import 'dart:math';

/// Correlation data that follows an asynchronous operation through Dart zones.
abstract final class TraceContext {
  static const Symbol _traceIdKey = #shirohaTraceId;
  static const Symbol _taskIdKey = #shirohaTaskId;

  static final Random _random = Random.secure();

  static String? get traceId => Zone.current[_traceIdKey] as String?;
  static String? get taskId => Zone.current[_taskIdKey] as String?;

  static Future<T> run<T>({
    required Future<T> Function() action,
    String? traceId,
    String? taskId,
  }) {
    return runZoned(
      action,
      zoneValues: <Object?, Object?>{
        _traceIdKey: traceId ?? createTraceId(),
        if (taskId != null) _taskIdKey: taskId,
      },
    );
  }

  static String createTraceId() {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final entropy = _random.nextInt(0x7fffffff).toRadixString(16);
    return 'trace-$timestamp-$entropy';
  }
}
