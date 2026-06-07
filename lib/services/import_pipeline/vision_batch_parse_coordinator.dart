import 'dart:async';

class VisionBatchParseResult {
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
  final int batchCount;
  final int failedBatchCount;

  const VisionBatchParseResult({
    required this.questions,
    required this.warnings,
    required this.diagnostics,
    required this.batchCount,
    required this.failedBatchCount,
  });
}

class VisionBatchParseCoordinator {
  const VisionBatchParseCoordinator();

  Future<VisionBatchParseResult> parse({
    required List<String> imagePaths,
    int pagesPerBatch = 4,
    int maxConcurrency = 3,
    required Future<List<Map<String, dynamic>>> Function(
            List<String> batchPaths)
        parseBatch,
    void Function(double progress, String status)? onProgress,
    void Function(int batchIdx)? onBatchScheduled,
    void Function(int batchIdx, List<Map<String, dynamic>> questions)?
        onBatchSuccess,
    void Function(int batchIdx, Object error)? onBatchFailed,
    void Function(int batchIdx, Object error)? onBatchRetry,
    Future<void> Function(Duration duration)? delayOverride, // For testing
  }) async {
    final List<String> warnings = [];
    final Map<String, dynamic> diagnostics = {};

    if (maxConcurrency < 1) {
      maxConcurrency = 1;
    }

    if (imagePaths.isEmpty) {
      warnings.add('Vision 解析未接收到任何图片资产');
      return VisionBatchParseResult(
        questions: const [],
        warnings: warnings,
        diagnostics: const {
          'status': 'empty_input',
        },
        batchCount: 0,
        failedBatchCount: 0,
      );
    }

    final List<List<String>> batches = [];
    for (int i = 0; i < imagePaths.length; i += pagesPerBatch) {
      final end = (i + pagesPerBatch).clamp(0, imagePaths.length);
      batches.add(imagePaths.sublist(i, end));
    }

    final int totalBatches = batches.length;
    final List<List<Map<String, dynamic>>?> orderedResults =
        List.filled(totalBatches, null);
    final List<int> pendingIndices = List.generate(totalBatches, (i) => i);
    final List<String> batchErrors = [];
    int failedBatchCount = 0;

    int currentConcurrency = maxConcurrency;

    Future<void> sleep(Duration duration) async {
      if (delayOverride != null) {
        await delayOverride(duration);
      } else {
        await Future.delayed(duration);
      }
    }

    while (pendingIndices.isNotEmpty) {
      final List<Future<void>> workers = [];
      final int workerCount =
          currentConcurrency.clamp(1, pendingIndices.length);

      for (int w = 0; w < workerCount; w++) {
        workers.add(() async {
          while (pendingIndices.isNotEmpty) {
            final batchIdx = pendingIndices.removeAt(0);
            final batch = batches[batchIdx];

            onBatchScheduled?.call(batchIdx);
            onProgress?.call(
              0.1 + (batchIdx / totalBatches) * 0.8,
              'Vision 批次 ${batchIdx + 1}/$totalBatches 解析中...',
            );

            try {
              final res = await parseBatch(batch);
              orderedResults[batchIdx] = res;
              onBatchSuccess?.call(batchIdx, res);
            } catch (e) {
              final errorStr = e.toString().toLowerCase();
              final isTransient = errorStr.contains('429') ||
                  errorStr.contains('too many requests') ||
                  errorStr.contains('connection closed') ||
                  errorStr.contains('clientexception') ||
                  errorStr.contains('socketexception') ||
                  errorStr.contains('broken pipe') ||
                  errorStr.contains('timeout');

              if (isTransient) {
                onBatchRetry?.call(batchIdx, e);
                // Re-insert index at the front to retry
                pendingIndices.insert(0, batchIdx);
                if (currentConcurrency > 1) {
                  currentConcurrency--;
                }

                final delay = errorStr.contains('timeout')
                    ? const Duration(seconds: 10)
                    : const Duration(seconds: 3);
                await sleep(delay);
                return; // Return from this worker, triggering a retry loop restart
              } else {
                onBatchFailed?.call(batchIdx, e);
                failedBatchCount++;
                batchErrors.add('批次 $batchIdx 视觉解析失败: $e');
                warnings.add('批次 ${batchIdx + 1} 视觉解析失败，已跳过该批次。');
              }
            }
          }
        }());
      }

      await Future.wait(workers);
    }

    final List<Map<String, dynamic>> mergedQuestions = [];
    for (final batchResult in orderedResults) {
      if (batchResult != null) {
        mergedQuestions.addAll(batchResult);
      }
    }

    diagnostics['totalBatches'] = totalBatches;
    diagnostics['failedBatchCount'] = failedBatchCount;
    diagnostics['concurrencyHistory'] = {
      'initialMax': maxConcurrency,
      'finalConcurrency': currentConcurrency,
    };
    if (batchErrors.isNotEmpty) {
      diagnostics['errors'] = batchErrors;
    }

    return VisionBatchParseResult(
      questions: mergedQuestions,
      warnings: warnings,
      diagnostics: diagnostics,
      batchCount: totalBatches,
      failedBatchCount: failedBatchCount,
    );
  }
}
