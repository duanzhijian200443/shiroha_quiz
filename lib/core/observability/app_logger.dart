import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'log_record.dart';
import 'log_writer.dart';

export 'log_writer.dart' show LogSink;

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

/// Platform-backed logger facade (OBS-1).
///
/// This file owns everything that needs `dart:io` / Flutter /
/// `path_provider` (rotating file sink, debug console echo, log directory
/// bootstrap) and delegates record production to the pure-Dart [LogWriter]
/// seam, so Application-layer code never depends on this file.
abstract final class AppLogger {
  static String? _logDirectoryPath;

  static String? get logDirectoryPath => _logDirectoryPath;

  static Future<void> initialize({Directory? directory}) async {
    try {
      final baseDirectory = directory ?? await getApplicationSupportDirectory();
      final logDirectory = Directory(p.join(baseDirectory.path, 'logs'));
      LogWriter.setSink(RotatingFileLogSink(directory: logDirectory));
      LogWriter.setRecordHandler(_echoRecordInDebug);
      LogWriter.setSinkErrorHandler(_reportSinkError);
      _logDirectoryPath = logDirectory.path;
      info('File logging initialized', module: 'Observability');
    } catch (error, stackTrace) {
      debugPrint('Unable to initialize file logging: $error\n$stackTrace');
    }
  }

  @visibleForTesting
  static void setSink(LogSink? sink) {
    _logDirectoryPath = null;
    LogWriter.setSink(sink);
    // Debug console echo stays active even without a sink, preserving the
    // original AppLogger debug behavior.
    LogWriter.setRecordHandler(_echoRecordInDebug);
    LogWriter.setSinkErrorHandler(
      sink == null ? null : _reportSinkError,
    );
  }

  static void _echoRecordInDebug(LogRecord record) {
    if (kDebugMode) debugPrint(jsonEncode(record.toJson()));
  }

  static void _reportSinkError(Object error, StackTrace stack) {
    debugPrint('Unable to write application log: $error\n$stack');
  }

  static void debug(
    String message, {
    String? module,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    LogWriter.debug(message, module: module, data: data);
  }

  static void info(
    String message, {
    String? module,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    LogWriter.info(message, module: module, data: data);
  }

  static void warning(
    String message, {
    String? module,
    Object? error,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    LogWriter.warning(message, module: module, error: error, data: data);
  }

  static void error(
    String message, {
    String? module,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    LogWriter.error(
      message,
      module: module,
      error: error,
      stackTrace: stackTrace,
      data: data,
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

  static Future<void> flush() => LogWriter.flush();
}
