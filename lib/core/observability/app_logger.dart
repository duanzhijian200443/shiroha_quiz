import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'log_record.dart';
import 'trace_context.dart';

abstract interface class LogSink {
  Future<void> write(LogRecord record);

  Future<void> flush();
}

/// Writes newline-delimited JSON and rotates files before they grow too large.
class RotatingFileLogSink implements LogSink {
  RotatingFileLogSink({
    required this.directory,
    this.fileName = 'shiroha-quiz.log',
    this.maxBytes = 2 * 1024 * 1024,
    this.retainedFiles = 4,
  });

  final Directory directory;
  final String fileName;
  final int maxBytes;
  final int retainedFiles;

  Future<void> _pendingWrite = Future<void>.value();

  File get currentFile => File(p.join(directory.path, fileName));

  @override
  Future<void> write(LogRecord record) {
    final line = '${jsonEncode(record.toJson())}\n';
    _pendingWrite = _pendingWrite
        .then((_) => _writeLine(line))
        .onError((_, __) => _writeLine(line));
    return _pendingWrite;
  }

  Future<void> _writeLine(String line) async {
    await directory.create(recursive: true);
    final file = currentFile;
    final newBytes = utf8.encode(line).length;
    if (await file.exists() && await file.length() + newBytes > maxBytes) {
      await _rotate();
    }
    await file.writeAsString(line, mode: FileMode.append, flush: false);
  }

  Future<void> _rotate() async {
    if (retainedFiles <= 0) {
      final file = currentFile;
      if (await file.exists()) await file.delete();
      return;
    }

    final oldest = File(p.join(directory.path, '$fileName.$retainedFiles'));
    if (await oldest.exists()) await oldest.delete();

    for (var index = retainedFiles - 1; index >= 1; index--) {
      final source = File(p.join(directory.path, '$fileName.$index'));
      if (await source.exists()) {
        await source.rename(p.join(directory.path, '$fileName.${index + 1}'));
      }
    }

    final file = currentFile;
    if (await file.exists()) {
      await file.rename(p.join(directory.path, '$fileName.1'));
    }
  }

  @override
  Future<void> flush() => _pendingWrite;
}

abstract final class AppLogger {
  static LogSink? _sink;
  static String? _logDirectoryPath;

  static String? get logDirectoryPath => _logDirectoryPath;

  static Future<void> initialize({Directory? directory}) async {
    try {
      final baseDirectory = directory ?? await getApplicationSupportDirectory();
      final logDirectory = Directory(p.join(baseDirectory.path, 'logs'));
      _sink = RotatingFileLogSink(directory: logDirectory);
      _logDirectoryPath = logDirectory.path;
      info('File logging initialized', module: 'Observability');
    } catch (error, stackTrace) {
      debugPrint('Unable to initialize file logging: $error\n$stackTrace');
    }
  }

  @visibleForTesting
  static void setSink(LogSink? sink) {
    _sink = sink;
    _logDirectoryPath = null;
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

  static Future<T> span<T>(
    String name,
    Future<T> Function() operation, {
    String? module,
    Map<String, Object?> data = const <String, Object?>{},
  }) async {
    final stopwatch = Stopwatch()..start();
    info('$name started', module: module, data: data);
    try {
      final result = await operation();
      info(
        '$name completed',
        module: module,
        data: <String, Object?>{
          ...data,
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      return result;
    } catch (error) {
      AppLogger.error(
        '$name failed',
        module: module,
        data: <String, Object?>{
          ...data,
          'errorType': error.runtimeType.toString(),
          'status': 'failed',
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    }
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

    if (kDebugMode) debugPrint(jsonEncode(record.toJson()));
    final sink = _sink;
    if (sink != null) {
      unawaited(sink.write(record).catchError((Object error, StackTrace stack) {
        debugPrint('Unable to write application log: $error\n$stack');
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
