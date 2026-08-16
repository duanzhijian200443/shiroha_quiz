import 'dart:async';

import 'log_record.dart';
import 'trace_context.dart';

/// Pure-Dart log output contract (OBS-1). Implementations may be platform
/// backed (rotating file) or in-memory (tests).
abstract interface class LogSink {
  Future<void> write(LogRecord record);

  Future<void> flush();
}

/// Pure-Dart logging seam used by application-layer code.
///
/// This file must stay free of `dart:io`, Flutter and `path_provider`
/// dependencies so the Application layer never transitively depends on
/// platform/logging infrastructure. The platform-backed wiring
/// ([RotatingFileLogSink], debug console echo, path_provider bootstrap) lives
/// in `app_logger.dart` and plugs in here through [setSink],
/// [setRecordHandler] and [setSinkErrorHandler]. Log product behavior
/// (structured records, correlation injection, redaction) is owned by this
/// seam and is identical regardless of the sink.
abstract final class LogWriter {
  static LogSink? _sink;
  static void Function(LogRecord record)? _recordHandler;
  static void Function(Object error, StackTrace stack)? _sinkErrorHandler;

  /// Sets the active sink; null disables file/stream output.
  static void setSink(LogSink? sink) {
    _sink = sink;
  }

  /// Optional observer for every produced record (for example a debug-mode
  /// console echo owned by the platform layer).
  static void setRecordHandler(void Function(LogRecord record)? handler) {
    _recordHandler = handler;
  }

  /// Optional observer for sink write failures. Sink failures never change
  /// business results: logging is best effort.
  static void setSinkErrorHandler(
    void Function(Object error, StackTrace stack)? handler,
  ) {
    _sinkErrorHandler = handler;
  }

  static void debug(
    String message, {
    String? module,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    _write(LogLevel.debug, message, module: module, data: data);
  }

  static void info(
    String message, {
    String? module,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    _write(LogLevel.info, message, module: module, data: data);
  }

  static void warning(
    String message, {
    String? module,
    Object? error,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    _write(
      LogLevel.warning,
      message,
      module: module,
      data: <String, Object?>{
        ...data,
        if (error != null) 'error': error.toString(),
      },
    );
  }

  static void error(
    String message, {
    String? module,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    _write(
      LogLevel.error,
      message,
      module: module,
      data: <String, Object?>{
        ...data,
        if (error != null) 'error': error.toString(),
        if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      },
    );
  }

  static Future<void> flush() async {
    await _sink?.flush();
  }

  static void _write(
    LogLevel level,
    String message, {
    String? module,
    required Map<String, Object?> data,
  }) {
    final record = LogRecord(
      timestamp: DateTime.now(),
      level: level,
      correlationId: TraceContext.correlationId,
      traceId: TraceContext.traceId,
      parentTraceId: TraceContext.parentTraceId,
      operationKind: TraceContext.operationKind,
      taskId: TraceContext.taskId,
      module: module,
      message: _sanitizeString(message, maxLength: 4000),
      data: _sanitizeMap(data),
    );

    _recordHandler?.call(record);
    final sink = _sink;
    if (sink != null) {
      unawaited(sink.write(record).catchError((Object error, StackTrace stack) {
        _sinkErrorHandler?.call(error, stack);
      }));
    }
  }

  static Map<String, Object?> _sanitizeMap(Map<String, Object?> source) {
    return source.map(
      (key, value) => MapEntry(key, _sanitizeValue(key, value)),
    );
  }

  static Object? _sanitizeValue(String key, Object? value) {
    final normalizedKey = key.toLowerCase().replaceAll(RegExp(r'[_-]'), '');
    if (normalizedKey.contains('authorization') ||
        normalizedKey.contains('apikey') ||
        normalizedKey.contains('accesstoken') ||
        normalizedKey == 'token' ||
        normalizedKey.contains('password') ||
        normalizedKey.contains('secret')) {
      return '[REDACTED]';
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (nestedKey, nestedValue) => MapEntry(
          nestedKey.toString(),
          _sanitizeValue(nestedKey.toString(), nestedValue),
        ),
      );
    }
    if (value is Iterable) {
      return value
          .take(100)
          .map((item) => _sanitizeValue(key, item))
          .toList(growable: false);
    }
    if (value is num || value is bool || value == null) return value;
    return _sanitizeString(value.toString(), maxLength: 12000);
  }

  static String _sanitizeString(String value, {required int maxLength}) {
    var sanitized = value;

    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'([?&](?:api[_-]?key|key|access[_-]?token|token|authorization|auth|password|secret|client[_-]?secret)=)([^&#\s]+)',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'''((?:"|')?\bauthorization\b(?:"|')?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\r\n,;}]+)''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'''((?:"|')?\b(?:api[_-]?key|access[_-]?token|token|password|secret|client[_-]?secret)\b(?:"|')?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^&#\s,;}]+)''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'(\b(?:API|Vision|Gemini|Zhipu|GLM-OCR)[^\r\n]*?(?:Error|failed)\s*:\s*\d+\s*-\s*)([^\r\n]*)',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'''((?:"|')?\b(?:file[_-]?)?path\b(?:"|')?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\r\n,;}]+)''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    if (sanitized.length > maxLength) {
      sanitized = '${sanitized.substring(0, maxLength)}...[TRUNCATED]';
    }
    return sanitized;
  }
}
