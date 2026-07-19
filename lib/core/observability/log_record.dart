enum LogLevel { debug, info, warning, error }

class LogRecord {
  const LogRecord({
    required this.timestamp,
    required this.level,
    required this.message,
    this.traceId,
    this.taskId,
    this.module,
    this.data = const <String, Object?>{},
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? traceId;
  final String? taskId;
  final String? module;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
        'time': timestamp.toUtc().toIso8601String(),
        'level': level.name.toUpperCase(),
        if (traceId != null) 'traceId': traceId,
        if (taskId != null) 'taskId': taskId,
        if (module != null) 'module': module,
        'message': message,
        if (data.isNotEmpty) 'data': data,
      };
}
