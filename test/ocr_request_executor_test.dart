import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_executor.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

void main() {
  test('only transient failures are retryable', () {
    for (final error in <Object>[
      const ZhipuOcrRequestException(statusCode: 429),
      const ZhipuOcrRequestException(statusCode: 500),
      const ZhipuOcrRequestException(statusCode: 503),
      TimeoutException('timeout'),
      const SocketException('connection lost'),
      http.ClientException('connection lost'),
      const RetryableOcrProviderFailure(retryable: true),
    ]) {
      expect(OcrRequestExecutor.isTransientFailure(error), isTrue);
    }
    for (final error in <Object>[
      const ZhipuOcrRequestException(statusCode: 400),
      const ZhipuOcrRequestException(statusCode: 401),
      const ZhipuOcrAuthenticationException(),
      const ZhipuOcrResponseFormatException(),
      const ZhipuOcrInvalidPdfException(),
      const OcrRequestCancelledException(),
      const ZhipuOcrRequestException(),
      const RetryableOcrProviderFailure(retryable: false),
      const FormatException('unsupported file'),
      StateError('empty OCR'),
    ]) {
      expect(OcrRequestExecutor.isTransientFailure(error), isFalse);
    }
  });

  test('timeout choices reach each provider attempt and retries stop at 3',
      () async {
    for (final seconds
        in ImportAdvancedPreferences.allowedOcrRequestTimeoutSeconds) {
      var attempts = 0;
      final seen = <Duration>[];
      final executor = OcrRequestExecutor(
        scheduler: OcrRequestScheduler(maxConcurrentRequests: 1),
        preferencesLoader: () async => ImportAdvancedPreferences(
          ocrRequestTimeoutSeconds: seconds,
        ),
        delay: (_) async {},
      );
      await expectLater(
        executor.run<void>(
          taskId: 'timeout-$seconds',
          operation: (timeout) async {
            attempts++;
            seen.add(timeout);
            throw TimeoutException('transient');
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(attempts, 3);
      expect(seen, everyElement(Duration(seconds: seconds)));
    }
  });

  test('disabled retry, empty OCR, auth and cancel have one attempt', () async {
    for (final (enabled, error) in <(bool, Object)>[
      (false, TimeoutException('transient')),
      (true, StateError('empty OCR')),
      (true, const ZhipuOcrAuthenticationException()),
      (true, const OcrRequestCancelledException()),
    ]) {
      var attempts = 0;
      final executor = OcrRequestExecutor(
        scheduler: OcrRequestScheduler(maxConcurrentRequests: 1),
        preferencesLoader: () async =>
            ImportAdvancedPreferences(autoRetryEnabled: enabled),
        delay: (_) async {},
      );
      await expectLater(
        executor.run<void>(
          taskId: 'single-$enabled-${error.runtimeType}',
          operation: (_) async {
            attempts++;
            throw error;
          },
        ),
        throwsA(anything),
      );
      expect(attempts, 1);
    }
  });

  test('a retry waits outside the scheduler and re-enters at budget 1',
      () async {
    final retryDelay = Completer<void>();
    final otherStarted = Completer<void>();
    final otherRelease = Completer<void>();
    var active = 0;
    var peak = 0;
    var firstAttempts = 0;
    final executor = OcrRequestExecutor(
      scheduler: OcrRequestScheduler(maxConcurrentRequests: 1),
      preferencesLoader: () async => ImportAdvancedPreferences.defaults,
      delay: (_) => retryDelay.future,
    );
    final first = executor.run<void>(
      taskId: 'document',
      operation: (_) async {
        active++;
        if (active > peak) peak = active;
        firstAttempts++;
        active--;
        if (firstAttempts == 1) throw TimeoutException('transient');
      },
    );
    await Future<void>.delayed(Duration.zero);
    final other = executor.run<void>(
      taskId: 'photo',
      operation: (_) async {
        active++;
        if (active > peak) peak = active;
        otherStarted.complete();
        await otherRelease.future;
        active--;
      },
    );
    await otherStarted.future;
    retryDelay.complete();
    await Future<void>.delayed(Duration.zero);
    expect(firstAttempts, 1);
    otherRelease.complete();
    await Future.wait([first, other]);
    expect(firstAttempts, 2);
    expect(peak, 1);
  });

  test('cancel during backoff prevents another provider call', () async {
    final delay = Completer<void>();
    var runnable = true;
    var attempts = 0;
    final executor = OcrRequestExecutor(
      scheduler: OcrRequestScheduler(maxConcurrentRequests: 1),
      preferencesLoader: () async => ImportAdvancedPreferences.defaults,
      delay: (_) => delay.future,
    );
    final run = executor.run<void>(
      taskId: 'cancel',
      isRunnable: () => runnable,
      operation: (_) async {
        attempts++;
        throw TimeoutException('transient');
      },
    );
    await Future<void>.delayed(Duration.zero);
    runnable = false;
    delay.complete();
    await expectLater(run, throwsA(isA<OcrRequestCancelledException>()));
    expect(attempts, 1);
  });
}
