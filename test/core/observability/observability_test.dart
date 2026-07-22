import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';

class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}
}

void main() {
  tearDown(() {
    AppLogger.setSink(null);
  });

  test('trace and task identifiers survive asynchronous boundaries', () async {
    await TraceContext.run(
      traceId: 'trace-test',
      taskId: 'task-test',
      action: () async {
        await Future<void>.delayed(Duration.zero);
        expect(TraceContext.traceId, 'trace-test');
        expect(TraceContext.taskId, 'task-test');
      },
    );

    expect(TraceContext.traceId, isNull);
    expect(TraceContext.taskId, isNull);
  });

  test('logger attaches trace context and redacts secrets', () async {
    final sink = _MemoryLogSink();
    AppLogger.setSink(sink);

    await TraceContext.run(
      traceId: 'trace-redaction',
      taskId: 'task-redaction',
      action: () async {
        AppLogger.info(
          'Calling service with Bearer abc.def',
          module: 'Test',
          data: <String, Object?>{
            'apiKey': 'private-key',
            'nested': <String, Object?>{'access_token': 'private-token'},
          },
        );
        await AppLogger.flush();
      },
    );

    expect(sink.records, hasLength(1));
    final record = sink.records.single;
    expect(record.traceId, 'trace-redaction');
    expect(record.taskId, 'task-redaction');
    expect(record.message, contains('Bearer [REDACTED]'));
    expect(record.data['apiKey'], '[REDACTED]');
    expect(
      (record.data['nested'] as Map<String, Object?>)['access_token'],
      '[REDACTED]',
    );
  });

  test('logger redacts secrets from URLs, headers, errors, and paths',
      () async {
    final sink = _MemoryLogSink();
    AppLogger.setSink(sink);

    AppLogger.error(
      'Request failed for '
      'https://example.test/generate?key=query-api-key&access_token=query-token&mode=safe',
      module: 'Test',
      error: Exception(
        'Authorization: Basic header-credential\n'
        'apiKey=plain-api-key token: plain-token\n'
        '{"api_key":"json-api-key","token":"json-token",'
        '"Authorization":"Basic json-authorization"}\n'
        'API Error: 400 - {"answer":"private-answer-content"}\n'
        r'FileSystemException: Cannot open file, path = C:\Users\Alice\private\exam.docx',
      ),
      data: const <String, Object?>{
        'Authorization': 'Bearer mapped-authorization',
        'token': 'mapped-token',
      },
    );
    await AppLogger.flush();

    final encoded = sink.records.single.toJson().toString();
    for (final secret in <String>[
      'query-api-key',
      'query-token',
      'header-credential',
      'plain-api-key',
      'plain-token',
      'json-api-key',
      'json-token',
      'json-authorization',
      'private-answer-content',
      r'C:\Users\Alice\private\exam.docx',
      'mapped-authorization',
      'mapped-token',
    ]) {
      expect(encoded, isNot(contains(secret)), reason: 'Leaked: $secret');
    }
    expect(encoded, contains('mode=safe'));
    expect(encoded, contains('[REDACTED]'));
  });

  test('span preserves non-import operation result and lifecycle logs',
      () async {
    final sink = _MemoryLogSink();
    AppLogger.setSink(sink);

    final result = await AppLogger.span(
      'Synthetic operation',
      () async => 42,
      module: 'NonImportTest',
      data: const <String, Object?>{'safeCount': 1},
    );
    await AppLogger.flush();

    expect(result, 42);
    expect(sink.records, hasLength(2));
    expect(sink.records.first.message, 'Synthetic operation started');
    expect(sink.records.last.message, 'Synthetic operation completed');
    expect(sink.records.last.data['safeCount'], 1);
    expect(sink.records.last.data['durationMs'], isA<int>());
  });

  test('global error callbacks preserve unhandled failure semantics', () {
    final source = File('lib/main.dart').readAsStringSync();
    final platformHandler = RegExp(
      r'PlatformDispatcher\.instance\.onError\s*=\s*\(error, stackTrace\)\s*\{([\s\S]*?)\n\s*\};',
    ).firstMatch(source);
    final rootZoneHandler = RegExp(
      r'\}, \(error, stackTrace\) \{([\s\S]*?)\n\s*\}\);',
    ).firstMatch(source);

    expect(platformHandler, isNotNull);
    expect(platformHandler!.group(1), contains('AppLogger.error('));
    expect(platformHandler.group(1), contains('return false;'));
    expect(rootZoneHandler, isNotNull);
    expect(rootZoneHandler!.group(1), contains('AppLogger.error('));
    expect(
      rootZoneHandler.group(1),
      contains('Error.throwWithStackTrace(error, stackTrace);'),
    );
  });

  test('file sink rotates oversized JSONL logs', () async {
    final directory = await Directory.systemTemp.createTemp('shiroha_logs_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final sink = RotatingFileLogSink(
      directory: directory,
      maxBytes: 160,
      retainedFiles: 2,
    );
    final record = LogRecord(
      timestamp: DateTime.utc(2026, 7, 19),
      level: LogLevel.info,
      message: 'x' * 120,
    );

    await sink.write(record);
    await sink.write(record);
    await sink.flush();

    expect(await sink.currentFile.exists(), isTrue);
    expect(
      await File('${sink.currentFile.path}.1').exists(),
      isTrue,
    );
  });
}
