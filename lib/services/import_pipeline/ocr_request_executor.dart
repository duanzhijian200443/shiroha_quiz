import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../application/import/import_advanced_preferences.dart';
import '../llm_providers/zhipu_ocr_client.dart';
import 'ocr_request_scheduler.dart';

/// One logical OCR request. Every provider attempt re-enters the shared
/// scheduler; waiting for a retry never occupies a provider slot.
final class OcrRequestExecutor {
  OcrRequestExecutor({
    required OcrRequestScheduler scheduler,
    required ImportAdvancedPreferencesLoader preferencesLoader,
    Future<void> Function(Duration)? delay,
  })  : _scheduler = scheduler,
        _preferencesLoader = preferencesLoader,
        _delay = delay ?? Future<void>.delayed;

  final OcrRequestScheduler _scheduler;
  final ImportAdvancedPreferencesLoader _preferencesLoader;
  final Future<void> Function(Duration) _delay;

  static const int maxExtraRetries = 2;

  Future<T> run<T>({
    required String taskId,
    String? attemptToken,
    required Future<T> Function(Duration timeout) operation,
    bool Function()? isRunnable,
  }) async {
    final preferences = await _preferencesLoader();
    final timeout = Duration(
      seconds: preferences.effectiveOcrRequestTimeoutSeconds,
    );
    for (var attempt = 0;; attempt++) {
      if (isRunnable != null && !isRunnable()) {
        throw const OcrRequestCancelledException();
      }
      try {
        return await _scheduler.run(
          taskId: taskId,
          attemptToken: attemptToken,
          operation: () {
            if (isRunnable != null && !isRunnable()) {
              throw const OcrRequestCancelledException();
            }
            return operation(timeout);
          },
        );
      } catch (error) {
        if (isRunnable != null && !isRunnable()) {
          throw const OcrRequestCancelledException();
        }
        if (!preferences.autoRetryEnabled ||
            attempt >= maxExtraRetries ||
            !isTransientFailure(error)) {
          rethrow;
        }
        await _delay(Duration(milliseconds: attempt == 0 ? 250 : 750));
      }
    }
  }

  static bool isTransientFailure(Object error) => switch (error) {
        TimeoutException() ||
        SocketException() ||
        http.ClientException() =>
          true,
        ZhipuOcrRequestException(:final statusCode) => statusCode == 429 ||
            (statusCode != null && statusCode >= 500 && statusCode <= 599),
        RetryableOcrProviderFailure(:final retryable) => retryable,
        _ => false,
      };
}

/// A provider adapter may expose an explicit transient classification without
/// leaking a response body or credentials into application control flow.
final class RetryableOcrProviderFailure implements Exception {
  const RetryableOcrProviderFailure({required this.retryable});

  final bool retryable;
}
