import 'trace_context.dart';

enum LogLevel { debug, info, warning, error }

class LogRecord {
  const LogRecord({
    required this.timestamp,
    required this.level,
    required this.message,
    this.correlationId,
    this.traceId,
    this.parentTraceId,
    this.operationKind,
    this.taskId,
    this.module,
    this.data = const <String, Object?>{},
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;

  /// OBS-1 correlation fields. Null when no trace context is active.
  final String? correlationId;
  final String? traceId;
  final String? parentTraceId;
  final TraceOperationKind? operationKind;
  final String? taskId;

  final String? module;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
        'time': timestamp.toUtc().toIso8601String(),
        'level': level.name.toUpperCase(),
        if (correlationId != null) 'correlationId': correlationId,
        if (traceId != null) 'traceId': traceId,
        if (parentTraceId != null) 'parentTraceId': parentTraceId,
        if (operationKind != null) 'operationKind': operationKind!.name,
        if (taskId != null) 'taskId': taskId,
        if (module != null) 'module': module,
        'message': message,
        if (data.isNotEmpty) 'data': data,
      };
}
